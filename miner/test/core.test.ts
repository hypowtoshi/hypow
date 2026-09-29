import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { encodeAbiParameters, encodeEventTopics } from 'viem';
import { minterAbi, type Chain } from '../src/chain.ts';
import { draw, firstBlockAt, openDraws, run, tick, untilFunded, type Miner } from '../src/core.ts';
import { MAINNET } from '../src/network.ts';
import { openDrawsSince } from '../src/protocol.ts';

/** A balance that reads each value of `seq` in turn, then stays at the last. */
function balances(...seq: bigint[]) {
  let i = 0;
  return async () => seq[Math.min(i++, seq.length - 1)];
}

function recorder() {
  const said: string[] = [];
  return { said, report: { low: (b: bigint) => said.push(`low ${b}`), funded: (b: bigint) => said.push(`funded ${b}`) } };
}

test('a funded key goes straight on, saying nothing', async () => {
  const r = recorder();
  assert.equal(await untilFunded(balances(300n), 300n, 1, new AbortController().signal, r.report), true);
  assert.deepEqual(r.said, []);
});

test('below the minimum it pauses, says so once, and goes on the moment the key is topped up', async () => {
  const r = recorder();
  assert.equal(await untilFunded(balances(10n, 10n, 10n, 2000n), 300n, 1, new AbortController().signal, r.report), true);
  assert.deepEqual(r.said, ['low 10', 'funded 2000']);
});

test('an abort while waiting ends the wait without going on', async () => {
  const r = recorder();
  const stop = new AbortController();
  const waiting = untilFunded(balances(10n), 300n, 1, stop.signal, r.report);
  stop.abort();
  assert.equal(await waiting, false);
  assert.deepEqual(r.said, ['low 10']);
});

test('an owner that joined a pool is told why this miner stops, before it tries to capture', async () => {
  const pool = '0x4444444444444444444444444444444444444444';
  const reads: string[] = [];
  const c = {
    net: MAINNET,
    account: { address: '0x0000000000000000000000000000000000000001' },
    read: {
      getBalance: async () => MAINNET.minGas,
      readContract: async ({ functionName }: { functionName: string }) => {
        reads.push(functionName);
        if (functionName === 'creditDelegate') return pool;
        throw new Error(`unexpected read ${functionName}`);
      },
    },
  };
  const said: string[] = [];
  const p = { line: (label: string, text: string) => said.push(`${label}: ${text}`), search: async () => 0, refresh: () => {}, won: () => {}, gas: () => {} };
  await run(c as unknown as Chain, '0x6666666666666666666666666666666666666666', p, new AbortController().signal);
  assert.deepEqual(reads, ['creditDelegate']);
  assert.match(said[0], /^pooled: .*0x4444…4444/);
});

/** Block n stamped as listed; several blocks can share a second. */
const stamps = (ts: number[]) => {
  let reads = 0;
  return { read: async (n: bigint) => (reads++, BigInt(ts[Number(n)])), reads: () => reads };
};

test('firstBlockAt finds the first block stamped at or after a time, in a logarithmic number of reads', async () => {
  const ts = [10, 11, 11, 11, 12, 13, 13, 20, 21, 22, 23, 24, 25, 26, 27, 28];
  const head = BigInt(ts.length - 1);
  for (const [since, want] of [[0, 0], [10, 0], [11, 1], [12, 4], [14, 7], [20, 7], [28, 15]] as const) {
    const s = stamps(ts);
    assert.equal(await firstBlockAt(s.read, 0n, head, BigInt(since)), BigInt(want), `since ${since}`);
    assert.ok(s.reads() <= 4, `since ${since}: ${s.reads()} reads`);
  }
  assert.equal(await firstBlockAt(stamps(ts).read, 0n, head, 99n), head, 'nothing that late: just the head');
  assert.equal(await firstBlockAt(stamps(ts).read, 5n, head, 0n), 5n, 'never before `from`');
});

test('openDraws reads Spent logs only from the block an open draw could start in, and retries a failed chunk alone', async () => {
  const lastWon = 21_000_000n;
  const since = BigInt(openDrawsSince(lastWon));
  const deployBlock = 1_000n;
  const head = 5_500n;
  // Block n is stamped one second after block n-1; block 3,000 is the first at `since`.
  const stampOf = (n: bigint) => since - 3_000n + n;
  const ranges: string[] = [];
  let failed = false;
  const c = {
    net: { ...MAINNET, deployBlock },
    logs: {
      getBlockNumber: async () => head,
      getContractEvents: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
        ranges.push(`${fromBlock}-${toBlock}`);
        if (fromBlock === 4_000n && !failed) {
          failed = true;
          throw new Error('rate limited');
        }
        return fromBlock === 4_000n ? [{ args: { round: lastWon + 1n } }, { args: { round: lastWon } }] : [];
      },
    },
    read: {
      getBlock: async ({ blockNumber }: { blockNumber: bigint }) => ({ timestamp: stampOf(blockNumber) }),
      readContract: async ({ functionName, args }: { functionName: string; args?: unknown[] }) => {
        if (functionName === 'lastWonRound') return lastWon;
        if (functionName === 'draws') return args![1] === lastWon + 1n ? 76n : 0n;
        throw new Error(`unexpected read ${functionName}`);
      },
    },
  };
  const said: string[] = [];
  const open = await openDraws(c as unknown as Chain, '0x0000000000000000000000000000000000000002', (label, text) => said.push(`${label}: ${text}`), 1);
  assert.deepEqual([...open], [[lastWon + 1n, 76n]]);
  assert.deepEqual(ranges, ['3000-3999', '4000-4999', '4000-4999', '5000-5500']);
  assert.deepEqual(said, ['error: rate limited · retrying in 0.001s']);
});

/** A miner whose bank holds 100 attempts; records the minter writes it tries (the first one stops the test). */
function banked() {
  const writes: string[] = [];
  const c = {
    net: MAINNET,
    account: { address: '0x0000000000000000000000000000000000000001' },
    read: {
      readContract: async ({ functionName }: { functionName: string }) => {
        if (functionName === 'memberAssetsLength') return 0n;
        if (functionName === 'difficulty') return 1n;
        throw new Error(`unexpected read ${functionName}`);
      },
      simulateContract: async () => ({ result: [0n, 100n] }),
      estimateContractGas: async ({ functionName }: { functionName: string }) => {
        writes.push(functionName);
        throw new Error('stop: a write was about to be sent');
      },
    },
  };
  const p = { line: () => {}, search: async () => 0, refresh: () => {}, won: () => {}, gas: () => {} };
  const m = { c, owner: '0x0000000000000000000000000000000000000002', universe: [], p, signal: new AbortController().signal, funded: async () => true };
  return { m: m as unknown as Miner, writes };
}

test('a drain plays its bank while no fill has arrived', async () => {
  const { m, writes } = banked();
  await assert.rejects(tick(m, { idle: false, fills: new Map() }, []), /stop: a write/);
  assert.deepEqual(writes, ['spend']);
});

test('a fill that arrived during a drain ends it before the next ticket, so its pass can capture it', async () => {
  const { m, writes } = banked();
  const fill = new Map([[{ name: 'ETH', szDecimals: 4, asset: 1 }, 45n]]);
  await tick(m, { idle: false, fills: fill }, []);
  assert.deepEqual(writes, []);
});

const ME = '0x0000000000000000000000000000000000000002';
const SOMEONE = '0x0000000000000000000000000000000000000003';
const ROUND = 1_000n; // published long ago, so a draw on it doesn't wait

/** Run `pending` with timers faked, moving the clock on until it settles: retries sleep 5 s. */
async function fastForward<T>(pending: () => Promise<T>): Promise<T> {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    let done = false;
    const p = pending().finally(() => (done = true));
    p.catch(() => {});
    while (!done) {
      await new Promise((r) => setImmediate(r));
      mock.timers.tick(1_000);
    }
    return await p;
  } finally {
    mock.timers.reset();
  }
}

/**
 * A miner whose draw on ROUND wins with nonce 5. `fail` lists the chain calls to fail once each
 * ('estimate' before sending the settle, 'receipt' after it was sent), and `closedBy` who has won
 * ROUND or later once a call has failed.
 */
function winner(fail: string[], closedBy?: string) {
  const said: string[] = [];
  let won = 0;
  let failed = false;
  const failOnce = (call: string) => {
    const i = fail.indexOf(call);
    if (i < 0) return;
    fail.splice(i, 1);
    failed = true;
    throw new Error('rate limited');
  };
  const wonLog = {
    topics: encodeEventTopics({ abi: minterAbi, eventName: 'Won', args: { owner: ME, round: ROUND, winCount: 41n } }),
    data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }, { type: 'address' }], [5n, 12n * 10n ** 18n, ME]),
  };
  const c = {
    net: MAINNET,
    account: { address: '0x0000000000000000000000000000000000000001' },
    read: {
      readContract: async ({ functionName }: { functionName: string }) => {
        if (functionName === 'difficulty') return 1n;
        if (functionName === 'lastWonRound') return failed && closedBy ? ROUND : ROUND - 1n;
        if (functionName === 'wonBy') return [closedBy, 1n, 12n * 10n ** 18n];
        throw new Error(`unexpected read ${functionName}`);
      },
      estimateContractGas: async () => (failOnce('estimate'), 100_000n),
      waitForTransactionReceipt: async () => (failOnce('receipt'), { status: 'success', logs: [wonLog] }),
    },
    write: { writeContract: async () => '0x1234' },
  };
  const p = { line: (label: string, text: string) => said.push(`${label}: ${text}`), search: async () => 5, refresh: () => {}, won: () => won++, gas: () => {} };
  const m = { c, owner: ME, universe: [], p, signal: new AbortController().signal, funded: async () => true } as unknown as Miner;
  return { m, said, won: () => won };
}

function drand(t: { mock: typeof mock }) {
  t.mock.method(globalThis, 'fetch', async () => new Response(JSON.stringify({ round: Number(ROUND), signature: 'ab'.repeat(64) })));
}

test('a winning ticket whose cash fails for a moment is cashed on a retry, not dropped for the next ticket', async (t) => {
  drand(t);
  const w = winner(['estimate']);
  await fastForward(() => draw(w.m, ROUND, 10n));
  assert.equal(w.won(), 1);
  assert.equal(w.said.filter((l) => l.startsWith('error: rate limited')).length, 1);
  assert.match(w.said.at(-1)!, /^BLOCK 42: found on round 1000/);
});

test('a winning ticket whose round someone else closes meanwhile ends as lost', async (t) => {
  drand(t);
  const w = winner(['estimate'], SOMEONE);
  await fastForward(() => draw(w.m, ROUND, 10n));
  assert.equal(w.won(), 0);
  assert.equal(w.said.at(-1), 'lost: someone else found this block first');
});

test('a cash that landed but whose receipt was lost is counted as our block, not as lost', async (t) => {
  drand(t);
  const w = winner(['receipt'], ME);
  await fastForward(() => draw(w.m, ROUND, 10n));
  assert.equal(w.won(), 1);
  assert.match(w.said.at(-1)!, /^BLOCK: found on round 1000 · \+12\.00 HYPOW/);
});
