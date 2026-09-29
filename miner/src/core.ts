import { isAddressEqual, zeroAddress, type Address, type Hex } from 'viem';
import { l1Szi, minterAbi, transact, type Chain, type Reader } from './chain.ts';
import { coalesce } from './coalesce.ts';
import { fillsAfter, heldCoins, perpUniverse, subAccountNames, sziAfter, watchFills, type Fill, type Perp } from './hyperliquid.ts';
import { fetchDrand, openDrawsSince, publishTime, seedOf, targetOf, ticketSize } from './protocol.ts';
import { covers } from './network.ts';
import { amount, count, describe, hype, retrying, short, sleep, type Line } from './text.ts';

/**
 * The mining loop, shared by the CLI and the browser miner. Each platform
 * brings its own log sink, nonce search and status display; the chain client
 * it passes in already writes as its miner key.
 */
export type Platform = {
  line: Line;
  /** protocol.ts's search, run off the thread that drives the loop. */
  search: (seed: Uint8Array, owner: Address, k: number, target: Uint8Array) => Promise<number>;
  /** Re-read and show the owner's standing: after each pass, ticket and gas change. */
  refresh: () => void;
  /** Count a block found. */
  won: () => void;
  /** The miner key ran out of HYPE for fees (true), or was topped up again (false). */
  gas: (low: boolean) => void;
};

const RETRY_MS = 5_000;
/** How often Hyperliquid is asked for fills the websocket missed, and how soon a pass HyperEVM lagged behind is repeated. */
const BACKSTOP_MS = 60_000;
const L1READ_POLL_MS = 1_000;
const L1READ_CAP_MS = 15_000;
const MAX_U128 = 2n ** 128n - 1n;
const LOG_CHUNK = 1000n;
const GAS_POLL_MS = 5_000;

export type Miner = { c: Chain; owner: Address; universe: Perp[]; p: Platform; signal: AbortSignal; funded: () => Promise<boolean> };

export type Status = { spender: boolean; gas: boolean; balance: bigint };

/** Whether `owner` has authorized the key and the key holds gas, as the chain says. */
export async function status(c: Reader, owner: Address): Promise<Status> {
  const [spender, balance] = await Promise.all([
    c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'spender', args: [owner] }),
    c.read.getBalance({ address: c.account.address }),
  ]);
  return { spender: spender === c.account.address, gas: balance >= c.net.minGas, balance };
}

export const ready = (s: Status) => s.spender && s.gas;

/**
 * Hold everything while the key can't pay for transactions: when `balance()`
 * is below `min`, report it once, then poll every `pollMs` until it is back at
 * `min` and report that. Resolves true once funded, false if `signal` aborts first.
 */
export async function untilFunded(
  balance: () => Promise<bigint>,
  min: bigint,
  pollMs: number,
  signal: AbortSignal,
  report: { low: (balance: bigint) => void; funded: (balance: bigint) => void },
): Promise<boolean> {
  let b = await balance();
  if (b >= min) return true;
  report.low(b);
  while (b < min) {
    if (signal.aborted) return false;
    await sleep(pollMs);
    b = await balance();
  }
  report.funded(b);
  return !signal.aborted;
}

const perpNamed = (universe: Perp[], coin: string) => universe.find((p) => p.name === coin);
const nameOf = (universe: Perp[], asset: number) => universe.find((p) => p.asset === asset)?.name ?? `asset ${asset}`;

/**
 * Mine for `owner` until `signal` aborts. Resolves once aborted and whatever
 * pass was under way has finished, so a restart never overlaps it.
 */
export async function run(c: Chain, owner: Address, p: Platform, signal: AbortSignal): Promise<void> {
  const { line } = p;
  const key = c.account.address;
  const funded = () =>
    untilFunded(() => c.read.getBalance({ address: key }), c.net.minGas, GAS_POLL_MS, signal, {
      low: (b) => {
        line('gas low', `the miner key holds ${hype(b)} HYPE, too little for fees · mining paused`);
        line('', `send ${hype(c.net.gasFund)} HYPE to ${key} on ${c.net.name} · ${covers(c.net, c.net.gasFund)} · mining resumes once it lands`);
        p.gas(true);
      },
      funded: (b) => {
        line('funded', `the miner key holds ${hype(b)} HYPE for fees · mining again`);
        p.gas(false);
      },
    });
  if (!(await retrying(line, funded, RETRY_MS))) return;
  // A member of a pool can only be captured by the pool, so every capture this
  // miner tried would revert, forever. Its trades still earn, for the pool.
  const pool = await retrying(line, () => poolOf(c, owner), RETRY_MS);
  if (pool !== zeroAddress) {
    line('pooled', `${short(owner)} has joined the pool ${short(pool)} · its trades earn for the pool, and only the pool can capture them`);
    line('', 'this miner mines solo · to mine here, leave the pool by calling setCreditDelegate(0x0) on the minter, then start again');
    return;
  }
  // A subaccount or vault has no key of its own, so it can never authorize a
  // miner: its trades would bank credits that nobody can ever play.
  const subs = await retrying(line, () => subAccountNames(c.net.hyperliquidInfo, owner), RETRY_MS);
  if (subs.length > 0) {
    line('subaccounts', `your subaccounts ${subs.join(', ')} don't mine · only trades on this main account mine, not on subaccounts or vaults`);
  }

  const m: Miner = {
    c,
    owner,
    universe: await retrying(line, () => perpUniverse(c.net.hyperliquidInfo), RETRY_MS),
    p,
    signal,
    funded,
  };
  await retrying(line, () => register(m), RETRY_MS);
  await retrying(line, () => resume(m), RETRY_MS);
  if (signal.aborted) return;

  // The minter credits only the change between two captures of a position, so
  // a trade opened and closed between captures earns nothing. Hence a pass
  // right after every fill, while the position is still open.
  const fills = new Map<Perp, bigint>(); // perp → position its latest fill left, not yet captured
  const state = { idle: false, fills };
  let latest = Promise.resolve();
  const pass = coalesce(
    () =>
      (latest = (async () => {
        if (signal.aborted) return;
        const targets = new Map(fills);
        fills.clear();
        try {
          // Fetched while HyperEVM catches up with the fills, which it takes longer to do.
          const held = heldCoins(c.net.hyperliquidWs, owner);
          held.catch(() => {});
          // A capture before HyperEVM showed the fill missed it; a pass once it has catches up.
          if (!(await reflected(m, targets))) setTimeout(pass, BACKSTOP_MS);
          await tick(m, state, await held);
        } catch (err) {
          line('error', `${describe(err)} · retrying in ${RETRY_MS / 1000}s`, err);
          setTimeout(pass, RETRY_MS);
        }
        p.refresh();
      })()),
  );
  let seen = Date.now(); // the newest fill handled, by Hyperliquid's clock
  const onFills = (batch: Fill[]) => {
    for (const f of batch) {
      seen = Math.max(seen, f.time);
      const perp = perpNamed(m.universe, f.coin);
      if (!perp) continue; // spot fills don't mine
      fills.set(perp, sziAfter(f, perp.szDecimals));
      line('trade', `${f.side === 'B' ? 'bought' : 'sold'} ${f.sz} ${f.coin}`);
    }
    pass();
  };
  watchFills(c.net.hyperliquidWs, owner, onFills, signal);
  // The websocket misses fills while it reconnects. Asking Hyperliquid for them
  // costs no HyperEVM request, so an idle miner makes none.
  const backstop = setInterval(async () => {
    try {
      // Filtered again: the websocket may have delivered some while Hyperliquid answered.
      const missed = (await fillsAfter(c.net.hyperliquidInfo, owner, seen)).filter((f) => f.time > seen);
      if (missed.length > 0 && !signal.aborted) onFills(missed);
    } catch (err) {
      line('error', `${describe(err)} · asking again in ${BACKSTOP_MS / 1000}s`, err);
    }
  }, BACKSTOP_MS);
  pass();

  await new Promise((resolve) => signal.addEventListener('abort', resolve, { once: true }));
  clearInterval(backstop);
  // A pass queued behind the running one returns at once, but replaces `latest`.
  for (let last; last !== latest; ) await (last = latest);
}

/**
 * Wait until HyperEVM shows each asset at the position its latest fill left.
 * L1Read trails Hyperliquid by a few blocks, and a capture before it catches
 * up would miss the fill. False if it hadn't caught up by the cap.
 */
async function reflected({ c, owner, p }: Miner, targets: Map<Perp, bigint>): Promise<boolean> {
  const deadline = Date.now() + L1READ_CAP_MS;
  for (const [perp, szi] of targets) {
    while ((await l1Szi(c, owner, perp.asset)) !== szi) {
      if (Date.now() > deadline) {
        p.line('lagging', `HyperEVM doesn't show your ${perp.name} fill after ${L1READ_CAP_MS / 1000}s · capturing anyway, and again in ${BACKSTOP_MS / 1000}s`);
        return false;
      }
      await sleep(L1READ_POLL_MS);
    }
  }
  return true;
}

/**
 * Baseline the coins the owner holds plus the usual starter coins, so the first
 * trade in any of them counts. Positions held now are the starting point and
 * earn nothing; only volume traded from here on does.
 */
async function register({ c, owner, universe, p }: Miner): Promise<void> {
  const held = await heldCoins(c.net.hyperliquidWs, owner);
  const coins = [...new Set([...held, ...c.net.starterCoins])];
  const known = coins.map((coin) => perpNamed(universe, coin)).filter((perp) => perp !== undefined);
  const slots = await Promise.all(
    known.map((perp) =>
      c.read.readContract({
        address: c.net.minter,
        abi: minterAbi,
        functionName: 'memberSlots',
        args: [owner, perp.asset],
      }),
    ),
  );
  const fresh = known.filter((_, i) => !slots[i][1]);
  if (fresh.length === 0) return;
  await transact(c, 'capture', [owner, fresh.map((perp) => perp.asset)]);
  p.line('registered', `registered ${fresh.map((perp) => perp.name).join(' ')} · your current positions are the starting point`);
  p.line('', 'only trading from now on earns attempts');
}

/** Settle any open draw a previous run left behind. Nothing is stored locally: the Spent logs are the record. */
async function resume(m: Miner): Promise<void> {
  for (const [round, k] of await openDraws(m.c, m.owner, m.p.line, RETRY_MS)) {
    m.p.line('resuming', `resuming a ticket of ${count(k)} attempts on round ${round}`);
    await draw(m, round, k);
  }
}

/**
 * `owner`'s draws that can still settle, as round → attempts. Only Spent logs
 * from the block where such a draw could first have been bought are read:
 * public RPCs budget log queries by the blocks they span (the official
 * HyperEVM one allows about 2,000 a minute), so a walk from the deploy block
 * would take longer each day and, retried from the start, never finish. For
 * the same reason a failed chunk is retried alone, keeping the walk so far.
 */
export async function openDraws(c: Pick<Chain, 'net' | 'read' | 'logs'>, owner: Address, line: Line, retryMs: number): Promise<Map<bigint, bigint>> {
  const [head, lastWon] = await Promise.all([c.logs.getBlockNumber(), lastWonRound(c)]);
  const timestamp = async (n: bigint) => (await c.read.getBlock({ blockNumber: n })).timestamp;
  const start = await firstBlockAt(timestamp, c.net.deployBlock, head, BigInt(openDrawsSince(lastWon)));
  const rounds = new Set<bigint>();
  for (let from = start; from <= head; from += LOG_CHUNK) {
    const to = from + LOG_CHUNK - 1n < head ? from + LOG_CHUNK - 1n : head;
    const logs = await retrying(
      line,
      () => c.logs.getContractEvents({ address: c.net.minter, abi: minterAbi, eventName: 'Spent', args: { owner }, fromBlock: from, toBlock: to }),
      retryMs,
    );
    for (const log of logs) if (log.args.round! > lastWon) rounds.add(log.args.round!);
  }
  const open = new Map<bigint, bigint>();
  for (const round of rounds) {
    const k = await c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'draws', args: [owner, round] });
    if (k > 0n) open.set(round, k);
  }
  return open;
}

/** The first block from `from` to `head` stamped `since` or later, or `head` if none is. Block timestamps never decrease. */
export async function firstBlockAt(timestamp: (n: bigint) => Promise<bigint>, from: bigint, head: bigint, since: bigint): Promise<bigint> {
  let [lo, hi] = [from, head];
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    if ((await timestamp(mid)) >= since) hi = mid;
    else lo = mid + 1n;
  }
  return lo;
}

/**
 * One pass: capture new opens, then play the whole bank. A drain plays the
 * bank as it stood when the drain began, one ticket per drand round; each
 * ticket waits for its round, so no two spends share one. A fill meanwhile
 * ends the drain between tickets, so the pass it queued captures it at once:
 * spend() captures only tracked coins, and a coin that was flat when the drain
 * began, opened and closed again before the drain ends, would earn nothing.
 * The next drain plays what this one left. An abort stops it between tickets.
 */
export async function tick(m: Miner, state: { idle: boolean; fills: ReadonlyMap<Perp, bigint> }, held: string[]): Promise<void> {
  const { c, owner, universe, p, signal } = m;
  if (!(await m.funded())) return;

  // spend() captures only tracked assets, so a position opened in an untracked
  // (flat-registered or never-seen) coin needs its own capture first.
  const tracked = await trackedAssets(c, owner);
  const opens = held
    .map((coin) => perpNamed(universe, coin)?.asset)
    .filter((a) => a !== undefined && !tracked.includes(a));
  if (opens.length > 0) {
    const { events } = await transact(c, 'capture', [owner, opens]);
    for (const e of events) {
      if (e.eventName === 'AssetRegistered') p.line('registered', `registered ${nameOf(universe, e.args.asset)} · your current position is the starting point`);
      if (e.eventName === 'Captured') p.line('captured', `+${count(e.args.cents)} attempts`);
    }
  }

  while (!signal.aborted) {
    // Simulated only to skip the transaction when nothing is spendable. It
    // counts the capture spend() performs first, so it sees fresh trades too.
    const { result } = await c.read.simulateContract({
      address: c.net.minter,
      abi: minterAbi,
      functionName: 'spend',
      args: [owner, MAX_U128],
      account: c.account,
    });
    const bank = result[1];
    if (bank === 0n) break;
    state.idle = false;

    for (let left = bank; left > 0n; ) {
      if (signal.aborted || state.fills.size > 0 || !(await m.funded())) return;
      const { events } = await transact(c, 'spend', [owner, ticketSize(await difficulty(c), bank)]);
      for (const e of events) if (e.eventName === 'Captured') p.line('captured', `+${count(e.args.cents)} attempts`);
      const spent = events.find((e) => e.eventName === 'Spent');
      // The simulation counted a position that was closed again by the time the
      // spend captured it, so there was nothing to spend: the trade was too quick.
      if (!spent) {
        p.line('missed', 'that trade closed before HyperEVM captured it · nothing to play');
        return;
      }
      left -= spent.args.k;
      // The minter picks a drand round that isn't out yet, so nobody knows the draw when buying.
      const drawsIn = Math.max(0, Math.ceil(publishTime(Number(spent.args.round)) - Date.now() / 1000));
      p.line('ticket', `${count(spent.args.k)} attempts → round ${spent.args.round} · draws in ${drawsIn}s`);
      p.refresh();
      await draw(m, spent.args.round, spent.args.drawK);
    }
  }
  if (signal.aborted) return;
  if (!state.idle) p.line('waiting', 'waiting for your next trade on Hyperliquid');
  state.idle = true;
}

/**
 * Wait for `round`'s drand beacon, search the draw's k attempts, and cash the
 * first win. A winning ticket is worth a block, so a failure after the beacon
 * is retried until the cash lands or the round closes. Left behind for the next
 * ticket, it would be lost for good: a later win, this miner's own included,
 * closes the round. Each try searches again at the current difficulty, which a
 * win on an earlier round may have moved.
 */
export async function draw(m: Miner, round: bigint, k: bigint): Promise<void> {
  const wait = publishTime(Number(round)) * 1000 - Date.now();
  if (wait > 0) await sleep(wait + 500);
  const signature = await retrying(m.p.line, () => fetchDrand(Number(round)), 2000);
  await retrying(m.p.line, () => cash(m, round, k, signature), RETRY_MS);
}

async function cash({ c, owner, p }: Miner, round: bigint, k: bigint, signature: Hex): Promise<void> {
  const d = await difficulty(c);
  p.line('drawn', `round ${round} drawn · searching ${count(k)} attempts at difficulty ${count(d)}`);
  const nonce = await p.search(seedOf(signature), owner, Number(k), targetOf(d));
  if (nonce === 0) {
    p.line('searching', `searched ${count(k)}/${count(k)} · no win`);
    return;
  }
  p.line('searching', `attempt ${count(nonce)}/${count(k)} wins · cashing it`);
  // Closed by someone else's win, or by our own settle on an earlier try whose receipt we never read.
  if ((await lastWonRound(c)) >= round) {
    const [winner, , reward] = await c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'wonBy', args: [round] });
    if (!isAddressEqual(winner, owner)) return p.line('lost', 'someone else found this block first');
    p.won();
    return p.line('BLOCK', `found on round ${round} · +${amount(reward)} HYPOW → ${short(owner)}`);
  }
  const { hash, events } = await transact(c, 'settle', [owner, round, signature, BigInt(nonce)]);
  const won = events.find((e) => e.eventName === 'Won');
  if (!won) throw new Error('settle emitted no win');
  p.won();
  p.line(`BLOCK ${won.args.winCount + 1n}`, `found on round ${round} · +${amount(won.args.reward)} HYPOW → ${short(owner)} · tx ${short(hash)}`);
}

function poolOf(c: Reader, owner: Address): Promise<Address> {
  return c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'creditDelegate', args: [owner] });
}

async function difficulty(c: Chain): Promise<bigint> {
  return c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'difficulty' });
}

async function lastWonRound(c: Pick<Chain, 'net' | 'read'>): Promise<bigint> {
  return c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'lastWonRound' });
}

async function trackedAssets(c: Chain, owner: Address): Promise<number[]> {
  const n = await c.read.readContract({
    address: c.net.minter,
    abi: minterAbi,
    functionName: 'memberAssetsLength',
    args: [owner],
  });
  return Promise.all(
    Array.from({ length: Number(n) }, (_, i) =>
      c.read.readContract({
        address: c.net.minter,
        abi: minterAbi,
        functionName: 'memberAssets',
        args: [owner, BigInt(i)],
      }),
    ),
  );
}
