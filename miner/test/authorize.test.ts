import assert from 'node:assert/strict';
import { test } from 'node:test';
import { zeroAddress, type Address, type Hex } from 'viem';
import type { Reader, SpenderAuth } from '../src/chain.ts';
import { MAINNET } from '../src/network.ts';

// web/authorize.ts listens for wallet announcements on window as it loads.
(globalThis as { window?: EventTarget }).window = new EventTarget();
const { authorize } = await import('../web/authorize.ts');

const net = MAINNET;
const owner: Address = '0x2222222222222222222222222222222222222222';
const key: Address = '0x1111111111111111111111111111111111111111';

/** A chain where the key starts as `spender` or not, holding `balance`, and a wallet that logs each request. */
function setup(start: { spender: boolean; balance: bigint }, reject?: string) {
  const calls: string[] = [];
  let balance = start.balance;
  const c = {
    net,
    account: { address: key },
    read: {
      readContract: async ({ functionName }: { functionName: string }) => (functionName === 'nonces' ? 7n : start.spender ? key : zeroAddress),
      getBalance: async () => balance,
      waitForTransactionReceipt: async () => ({ status: 'success' }),
    },
  } as unknown as Reader;
  const provider = {
    request: async ({ method }: { method: string }) => {
      if (method === reject) throw Object.assign(new Error('User rejected the request.'), { code: 4001 });
      if (method === 'eth_chainId') return `0x${net.chainId.toString(16)}`;
      calls.push(method);
      if (method === 'eth_sendTransaction') {
        balance = net.gasFund;
        return '0xaa';
      }
      return `0x${'11'.repeat(64)}1b`;
    },
  };
  const submitted: SpenderAuth[] = [];
  const submit = async (auth: SpenderAuth): Promise<Hex> => {
    calls.push('submit');
    submitted.push(auth);
    return '0xbb';
  };
  const run = () => authorize(c, provider, owner, { gas: net.gasFund, keyName: 'the key', submit }, () => {});
  return { calls, submitted, run };
}

test('the owner signs first, then funds the key, then the signature is submitted', async () => {
  const { calls, submitted, run } = setup({ spender: false, balance: 0n });
  const before = BigInt(Math.floor(Date.now() / 1000));
  await run();
  assert.deepEqual(calls, ['eth_signTypedData_v4', 'eth_sendTransaction', 'submit']);
  assert.equal(submitted[0].nonce, 7n);
  // An hour, so a slow transfer between signing and submitting can't expire it.
  assert.ok(submitted[0].deadline >= before + 3600n);
});

test('a declined signature spends nothing', async () => {
  const { calls, run } = setup({ spender: false, balance: 0n }, 'eth_signTypedData_v4');
  await assert.rejects(run(), { code: 4001 });
  assert.deepEqual(calls, []);
});

test('a funded key only needs the signature, an authorized one only the HYPE', async () => {
  const funded = setup({ spender: false, balance: net.gasFund });
  await funded.run();
  assert.deepEqual(funded.calls, ['eth_signTypedData_v4', 'submit']);
  const authorized = setup({ spender: true, balance: 0n });
  await authorized.run();
  assert.deepEqual(authorized.calls, ['eth_sendTransaction']);
});
