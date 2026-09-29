import assert from 'node:assert/strict';
import { test } from 'node:test';
import { bytesToHex } from 'viem';
import {
  DRAND_GENESIS,
  openDrawsSince,
  parseDrand,
  publishTime,
  search,
  seedOf,
  targetOf,
  ticketHash,
  ticketSize,
} from '../src/protocol.ts';

// drand evmnet round 10,000,000 (also contracts/test/utils/Drand.sol SIG_0).
const SIG = '2c7b65b5acfe55256910ca71cf0a0fa71ac34c2a1167f86a22930a03e70ebec00f7a530796e7ee38600b06da0390634a9b154e3eebc3b323dde2111e1c8ebdf3';
const OWNER = '0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266'; // anvil account 0
const seed = seedOf(`0x${SIG}`);

// Expected values below come from foundry's cast:
//   cast keccak 0x<SIG>
//   cast keccak $(cast abi-encode "f(bytes32,address,uint256)" <seed> <owner> <nonce>)
test('seed is keccak256 of the raw signature bytes', () => {
  assert.equal(bytesToHex(seed), '0xb3cd0f7cd129b95bdae6a1bb0df482847fd97abb1073418d70c802cc3dc57c57');
});

test('ticket hash matches abi.encode(seed, owner, nonce) hashed by cast', () => {
  assert.equal(ticketHash(seed, OWNER, 1), '0x02e1c84849f1865c5fce02016b21fb4c39f0139298ba42413ef404ae3ce320be');
  // Above 2^32, so both nonce words are written.
  assert.equal(
    ticketHash(seed, OWNER, 12345678901),
    '0x524de714909239dbc5dcad495dd8685c3ddc810292f5a06aca5f910c31884206',
  );
});

test('search finds the first winning attempt at difficulty 100', () => {
  // 55 is the first nonce whose cast-computed hash is below uint256.max / 100.
  assert.equal(search(seed, OWNER, 1000, targetOf(100n)), 55);
  assert.equal(search(seed, OWNER, 54, targetOf(100n)), 0);
  assert.equal(search(seed, OWNER, 55, targetOf(100n)), 55);
});

test('target is type(uint256).max / difficulty', () => {
  assert.equal(bytesToHex(targetOf(1n)), `0x${'f'.repeat(64)}`);
  assert.equal(bytesToHex(targetOf(100n)), '0x028f5c28f5c28f5c28f5c28f5c28f5c28f5c28f5c28f5c28f5c28f5c28f5c28f');
});

test('a ticket is a tenth of the difficulty, floored at a twentieth of the drain, capped at the bank', () => {
  assert.equal(ticketSize(6n, 1014n), 51n); // tiny D: the bank/20 floor governs
  assert.equal(ticketSize(1_000_000n, 1000n), 1000n); // bank well under D: one ticket
  assert.equal(ticketSize(1_000_000n, 50_000_000n), 2_500_000n); // big bank: 20 tickets
  assert.equal(ticketSize(1_000_000n, 1_500_000n), 100_000n); // D/10 governs
  assert.equal(ticketSize(1n, 1n), 1n);
  assert.equal(ticketSize(6n, 0n), 0n);
});

test('round r publishes at DRAND_GENESIS + (r - 1) * 3, as the minter assumes', () => {
  assert.equal(publishTime(1), DRAND_GENESIS);
  assert.equal(publishTime(2), DRAND_GENESIS + 3);
  assert.equal(publishTime(10_000_000), 1757521072);
});

test('drand response parses to the 64-byte signature', () => {
  assert.equal(parseDrand({ round: 10_000_000, signature: SIG }, 10_000_000), `0x${SIG}`);
  assert.equal(parseDrand({ round: 1, signature: SIG.toUpperCase() }, 1), `0x${SIG}`);
  assert.throws(() => parseDrand({ round: 10_000_001, signature: SIG }, 10_000_000), /wanted 10000000/);
  assert.throws(() => parseDrand({ round: 1, signature: SIG.slice(2) }, 1), /64 bytes/);
  assert.throws(() => parseDrand({ round: 1 }, 1), /64 bytes/);
});

// HypowMinter.targetRound() for a block stamped t: drandRound(t) + ROUND_LEAD.
const targetRound = (t: number) => Math.floor((t - DRAND_GENESIS) / 3) + 1 + 2;

test('a spend stamped openDrawsSince(L) or later draws on an open round; one a second earlier does not', () => {
  for (const lastWon of [20_000_000n, 20_000_001n, 20_000_002n]) {
    const since = openDrawsSince(lastWon);
    for (const t of [since, since + 1, since + 2, since + 3]) assert.ok(targetRound(t) > Number(lastWon), `t=${t} lastWon=${lastWon}`);
    assert.equal(targetRound(since - 1), Number(lastWon));
  }
});

test('with no win yet every spend since genesis is open', () => {
  assert.ok(openDrawsSince(0n) < DRAND_GENESIS);
});
