import {
  createPublicClient,
  createWalletClient,
  decodeAbiParameters,
  defineChain,
  encodeAbiParameters,
  fallback,
  http,
  parseAbi,
  parseEventLogs,
  type Address,
  type Hex,
} from 'viem';
import { nonceManager, privateKeyToAccount } from 'viem/accounts';
import type { Network } from './network.ts';

export const minterAbi = parseAbi([
  'function capture(address member, uint32[] assets) returns (uint128 k)',
  'function spend(address owner, uint128 maxK) returns (uint64 round, uint128 k)',
  'function settle(address owner, uint64 round, bytes signature, uint256 nonce) returns (uint256 reward)',
  'function setSpender(address newSpender)',
  'function setSpenderBySig(address owner, address newSpender, uint256 nonce, uint256 deadline, bytes signature)',
  'function nonces(address) view returns (uint256)',
  'function spender(address) view returns (address)',
  'function creditDelegate(address) view returns (address)',
  'function credits(address) view returns (uint128)',
  'function draws(address, uint64) view returns (uint128)',
  'function memberSlots(address, uint32) view returns (int64 lastSnapshotSzi, bool known, uint64 lastMarkPx)',
  'function memberAssetsLength(address member) view returns (uint256)',
  'function memberAssets(address member, uint256 index) view returns (uint32)',
  'function token() view returns (address)',
  'function difficulty() view returns (uint128)',
  'function winCount() view returns (uint64)',
  'function lastWonRound() view returns (uint64)',
  'function wonBy(uint64 round) view returns (address owner, uint128 difficulty, uint128 reward)',
  'event AssetRegistered(address indexed member, uint32 indexed asset, int64 baselineSzi)',
  'event Captured(address indexed member, address indexed destination, uint128 cents)',
  'event Spent(address indexed owner, uint64 indexed round, uint128 k, uint128 drawK)',
  'event Won(address indexed owner, uint64 indexed round, uint64 indexed winCount, uint256 nonce, uint256 reward, address caller)',
]);

export type Chain = ReturnType<typeof connect>;
/** A miner key's view of the chain, without the key: all the CLI's authorize page needs. */
export type Reader = ReturnType<typeof watch>;

/**
 * Multicall3's canonical address, deployed on HyperEVM.
 * Public RPCs ration requests per IP, so reads made together, balances
 * included, go as one eth_call through it. HTTP batching isn't used: it saved
 * no request here, and viem then retries eth_fillTransaction, which HyperEVM
 * lacks, on every public endpoint before each transaction.
 */
const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11';

/** The user's own `rpc`, if any, is tried first for everything, ahead of the public endpoints. */
function clients(net: Network, rpc: string | undefined) {
  const own = rpc ? [rpc] : [];
  const rpcs = [...own, ...net.rpcs];
  const chain = defineChain({
    id: net.chainId,
    name: net.name,
    nativeCurrency: { name: 'HYPE', symbol: 'HYPE', decimals: 18 },
    rpcUrls: { default: { http: rpcs } },
    contracts: { multicall3: { address: MULTICALL3 } },
  });
  const transport = fallback(rpcs.map((url) => http(url)));
  return {
    chain,
    transport,
    /** Whether the user's own RPC comes first. */
    own: rpc !== undefined,
    /** Host only: the path of a keyed RPC carries its API key. */
    rpcHost: new URL(rpcs[0]).host,
    read: createPublicClient({ chain, transport, batch: { multicall: true } }),
    logs: createPublicClient({ chain, transport: fallback([...own, ...net.logRpcs].map((url) => http(url))) }),
  };
}

/** Read, log and write clients for `net`, writing as the miner key. */
export function connect(net: Network, key: Hex, rpc: string | undefined) {
  const { chain, transport, own, rpcHost, read, logs } = clients(net, rpc);
  const account = privateKeyToAccount(key, { nonceManager });
  return { net, account, own, rpcHost, read, logs, write: createWalletClient({ chain, transport, account }) };
}

/** Read `net` over the public endpoints as the miner key `key` sees it. */
export function watch(net: Network, key: Address) {
  const { own, rpcHost, read } = clients(net, undefined);
  return { net, account: { address: key }, own, rpcHost, read };
}

/** An owner's EIP-712 SetSpender signature, which any account may submit. */
export type SpenderAuth = { owner: Address; nonce: bigint; deadline: bigint; signature: Hex };

/** Submit `auth`, naming the miner key as the owner's spender, and wait for it to land. */
export async function setSpenderBySig(c: Chain, auth: SpenderAuth): Promise<Hex> {
  const hash = await c.write.writeContract({
    address: c.net.minter,
    abi: minterAbi,
    functionName: 'setSpenderBySig',
    args: [auth.owner, c.account.address, auth.nonce, auth.deadline, auth.signature],
  });
  const receipt = await c.read.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`the authorization failed · tx ${hash}`);
  return hash;
}

/** L1Read's position2 precompile: (int64 szi, uint64 entryNtl, int64 isolatedRawUsd, uint32 leverage, bool isIsolated). */
const POSITION2 = '0x0000000000000000000000000000000000000813';

/** `owner`'s position size in `asset` as HyperEVM sees it now, in units of 10^-szDecimals. */
export async function l1Szi(c: Chain, owner: Address, asset: number): Promise<bigint> {
  const { data } = await c.read.call({
    to: POSITION2,
    data: encodeAbiParameters([{ type: 'address' }, { type: 'uint32' }], [owner, asset]),
  });
  if (!data) throw new Error('position2 returned nothing');
  return decodeAbiParameters([{ type: 'int64' }], data)[0];
}

type WriteName = 'capture' | 'spend' | 'settle';

/**
 * Gas for a minter write estimated at `estimate`. capture and spend capture the
 * owner's positions, and a fill landing between the estimate and the block makes
 * that capture record a change the estimate didn't see (about 30k gas per
 * asset), so a tight limit runs out. Unused gas is refunded.
 */
export function padGas(estimate: bigint): bigint {
  return (estimate * 3n) / 2n;
}

/**
 * Send a minter write from the miner key and wait for it; returns the hash and
 * decoded events. The estimate skips the nonce and fee lookups the write makes
 * anyway, and only the miner key sends from it, so nothing can replace the
 * transaction: both would be RPC requests for nothing.
 */
export async function transact(c: Chain, functionName: WriteName, args: readonly unknown[]) {
  const call = { address: c.net.minter, abi: minterAbi, functionName, args } as Parameters<typeof c.write.writeContract>[0];
  const estimate = await c.read.estimateContractGas({ ...call, account: c.account, prepare: false } as Parameters<typeof c.read.estimateContractGas>[0]);
  const hash = await c.write.writeContract({ ...call, gas: padGas(estimate) });
  const receipt = await c.read.waitForTransactionReceipt({ hash, checkReplacement: false });
  if (receipt.status !== 'success') throw new Error(`${functionName} reverted · tx ${hash}`);
  return { hash, events: parseEventLogs({ abi: minterAbi, logs: receipt.logs }) };
}
