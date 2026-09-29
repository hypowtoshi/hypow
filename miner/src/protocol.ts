import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, hexToBytes, type Address, type Hex } from 'viem';

// drand evmnet, as hardcoded in HypowMinter (DRAND_GENESIS / DRAND_PERIOD).
export const DRAND_GENESIS = 1727521075;
const DRAND_PERIOD = 3;
const DRAND_URL = 'https://api.drand.sh/v2/beacons/evmnet/rounds/';

/** Unix time (seconds) at which drand publishes `round`. */
export function publishTime(round: number): number {
  return DRAND_GENESIS + (round - 1) * DRAND_PERIOD;
}

/** As HypowMinter.ROUND_LEAD: a spend draws on the round this many past the latest published one. */
const ROUND_LEAD = 2;

/**
 * The earliest block time at which a draw that is still open after `lastWon`
 * can have been bought. A spend in a block at time t draws on the round
 * published last by t, plus ROUND_LEAD, and only rounds after `lastWon` can
 * still be settled.
 */
export function openDrawsSince(lastWon: bigint): number {
  return publishTime(Number(lastWon) + 1 - ROUND_LEAD);
}

/**
 * How many attempts to put in each ticket of a drain of `bank` attempts: a
 * tenth of the difficulty, or a twentieth of the bank if that is more, and
 * never more than the bank. A ticket wins at most one block, so attempts past
 * the first win are wasted; at D/10 that waste stays under 5%. The bank/20
 * floor bounds a drain to about 20 tickets where D is tiny (the launch
 * ramp), so each ticket just wins more surely. `bank` is fixed for the
 * whole drain: recomputed per ticket, the floor would decay toward D/10.
 */
export function ticketSize(difficulty: bigint, bank: bigint): bigint {
  const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;
  const cap = ceilDiv(difficulty, 10n);
  const floor = ceilDiv(bank, 20n);
  const size = cap > floor ? cap : floor;
  return size < bank ? size : bank;
}

/** Parse drand's `{round, signature}` JSON: the 64-byte G1 point x‖y the minter verifies. */
export function parseDrand(body: unknown, round: number): Hex {
  const { round: got, signature } = body as { round?: unknown; signature?: unknown };
  if (got !== round) throw new Error(`drand returned round ${String(got)}, wanted ${round}`);
  if (typeof signature !== 'string' || !/^[0-9a-f]{128}$/i.test(signature)) {
    throw new Error('drand signature is not 64 bytes of hex');
  }
  return `0x${signature.toLowerCase()}`;
}

/** Fetch drand's signature for a published round. */
export async function fetchDrand(round: number): Promise<Hex> {
  const res = await fetch(DRAND_URL + round);
  if (!res.ok) throw new Error(`drand round ${round}: HTTP ${res.status}`);
  return parseDrand(await res.json(), round);
}

/** The ticket seed: keccak256 of the raw signature bytes (not drand's `randomness`). */
export function seedOf(signature: Hex): Uint8Array {
  return keccak_256(hexToBytes(signature));
}

/** The winning threshold at `difficulty`: type(uint256).max / difficulty, as 32 big-endian bytes. */
export function targetOf(difficulty: bigint): Uint8Array {
  return hexToBytes(`0x${((2n ** 256n - 1n) / difficulty).toString(16).padStart(64, '0')}`);
}

function lessThan(a: Uint8Array, b: Uint8Array): boolean {
  for (let i = 0; i < 32; i++) if (a[i] !== b[i]) return a[i] < b[i];
  return false;
}

/** The 96-byte abi.encode(bytes32 seed, address owner, uint256 nonce) preimage, nonce unset. */
function preimage(seed: Uint8Array, owner: Address): Uint8Array {
  const buf = new Uint8Array(96);
  buf.set(seed, 0);
  buf.set(hexToBytes(owner), 44);
  return buf;
}

/** Write `nonce` (< 2^53) big-endian into the last 8 bytes of the preimage. */
function setNonce(buf: Uint8Array, nonce: number): void {
  let n = nonce;
  for (let i = 95; i >= 88; i--) {
    buf[i] = n % 256;
    n = Math.floor(n / 256);
  }
}

/**
 * Search attempts 1..k for the first winning one; 0 if none wins. A ticket wins
 * iff keccak256(abi.encode(seed, owner, nonce)) < target. The preimage is built
 * once and only the nonce word is rewritten.
 */
export function search(seed: Uint8Array, owner: Address, k: number, target: Uint8Array): number {
  const buf = preimage(seed, owner);
  for (let nonce = 1; nonce <= k; nonce++) {
    setNonce(buf, nonce);
    if (lessThan(keccak_256(buf), target)) return nonce;
  }
  return 0;
}

/** The ticket hash of one attempt. */
export function ticketHash(seed: Uint8Array, owner: Address, nonce: number): Hex {
  const buf = preimage(seed, owner);
  setNonce(buf, nonce);
  return bytesToHex(keccak_256(buf));
}
