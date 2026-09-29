import { parseUnits, type Address } from 'viem';

async function info<T>(url: string, body: object): Promise<T> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Hyperliquid info ${JSON.stringify(body)}: HTTP ${res.status}`);
  return (await res.json()) as T;
}

/** A perp market; `asset` is its id on HyperEVM, as the minter takes it. */
export type Perp = { name: string; szDecimals: number; asset: number };

type Meta = { universe: { name: string; szDecimals: number }[] };

/**
 * Every perp on every perp dex, from `allPerpMetas` (one meta per dex, in
 * `perpDexs` order, main dex first; HIP-3 coins are named dex:COIN). HyperEVM's
 * L1Read precompiles number a main-dex perp by its meta index, and a HIP-3 perp
 * as dexIndex·10000 + index. Hyperliquid's order API numbers HIP-3 perps 100000
 * higher than that; L1Read, and so the minter, does not.
 */
export function perps(metas: Meta[]): Perp[] {
  return metas
    .flatMap((meta, dex) => meta.universe.map(({ name, szDecimals }, i) => ({ name, szDecimals, asset: dex * 10_000 + i })));
}

export async function perpUniverse(url: string): Promise<Perp[]> {
  return perps(await info<Meta[]>(url, { type: 'allPerpMetas' }));
}

type DexStates = { clearinghouseStates: [dex: string, state: { assetPositions: { position: { coin: string; szi: string } }[] }][] };

/** The coins with a non-zero position in an `allDexsClearinghouseState` snapshot. */
export function heldIn(data: DexStates): string[] {
  return data.clearinghouseStates.flatMap(([, state]) =>
    state.assetPositions.filter((p) => Number(p.position.szi) !== 0).map((p) => p.position.coin),
  );
}

/**
 * Coins `user` holds a non-zero perp position in, on every perp dex. The info
 * endpoint answers one dex per request and there are many, so this takes
 * the snapshot a websocket subscription sends first, then closes it.
 */
export function heldCoins(wsUrl: string, user: Address): Promise<string[]> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const fail = (why: string) => {
      clearTimeout(timer);
      ws.close();
      reject(new Error(`Hyperliquid positions: ${why}`));
    };
    const timer = setTimeout(() => fail('no answer in 10s'), 10_000);
    ws.addEventListener('open', () =>
      ws.send(JSON.stringify({ method: 'subscribe', subscription: { type: 'allDexsClearinghouseState', user } })),
    );
    ws.addEventListener('message', (e) => {
      const msg = JSON.parse(String(e.data));
      if (msg.channel !== 'allDexsClearinghouseState') return;
      clearTimeout(timer);
      ws.close();
      resolve(heldIn(msg.data));
    });
    ws.addEventListener('error', () => fail('websocket error'));
  });
}

/** Names of `user`'s subaccounts (Hyperliquid answers null when there are none). */
export async function subAccountNames(url: string, user: Address): Promise<string[]> {
  const subs = await info<{ name: string }[] | null>(url, { type: 'subAccounts', user });
  return (subs ?? []).map((s) => s.name);
}

/** One fill as Hyperliquid streams it. `side` is B(uy) or A(sell); sizes are decimal strings; `time` in ms. */
export type Fill = { coin: string; side: 'B' | 'A'; sz: string; startPosition: string; time: number };

/** `user`'s fills after `time`, on every perp dex, oldest first. */
export function fillsAfter(url: string, user: Address, time: number): Promise<Fill[]> {
  return info<Fill[]>(url, { type: 'userFillsByTime', user, startTime: time + 1 });
}

/** The position `f` leaves behind, in units of 10^-szDecimals (as L1Read reports szi). */
export function sziAfter(f: Omit<Fill, 'time'>, szDecimals: number): bigint {
  const sz = parseUnits(f.sz, szDecimals);
  return parseUnits(f.startPosition, szDecimals) + (f.side === 'B' ? sz : -sz);
}

/**
 * Call `onFills` with each batch of `user`'s new fills, reconnecting whenever
 * the socket drops, until `signal` aborts. The snapshot of past fills sent on
 * subscribing is skipped; fills missed while disconnected are left to the
 * caller's backstop.
 */
export function watchFills(url: string, user: Address, onFills: (fills: Fill[]) => void, signal: AbortSignal): void {
  if (signal.aborted) return;
  const ws = new WebSocket(url);
  const stop = () => ws.close();
  signal.addEventListener('abort', stop, { once: true });
  let ping: ReturnType<typeof setInterval> | undefined;
  ws.addEventListener('open', () => {
    ws.send(JSON.stringify({ method: 'subscribe', subscription: { type: 'userFills', user } }));
    // Hyperliquid closes a socket that has been silent for 60 s.
    ping = setInterval(() => ws.send(JSON.stringify({ method: 'ping' })), 50_000);
  });
  ws.addEventListener('message', (e) => {
    const msg = JSON.parse(String(e.data));
    if (msg.channel === 'userFills' && !msg.data.isSnapshot) onFills(msg.data.fills);
  });
  ws.addEventListener('close', () => {
    clearInterval(ping);
    signal.removeEventListener('abort', stop);
    setTimeout(() => watchFills(url, user, onFills, signal), 2000);
  });
}
