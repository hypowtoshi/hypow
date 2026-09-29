/**
 * Chrome slows a hidden tab's timers to once a second, and after five minutes
 * hidden to once a minute. The user trades in another tab, so this one is
 * hidden while it matters: a draw waiting for its drand round, or a receipt
 * being polled, would stall for up to a minute and lose its block to a faster
 * miner. A worker's timers are exempt, so the page's timers are replaced with
 * ones that tick in a worker.
 */
const WORKER = `const t = new Map();
onmessage = ({ data: [id, ms] }) => {
  if (ms < 0) { clearTimeout(t.get(id)); t.delete(id); return; }
  t.set(id, setTimeout(() => { t.delete(id); postMessage(id); }, ms));
};`;

type Timer = { fn: () => void; every?: number };

export function installWorkerTimers(): void {
  let worker: Worker;
  try {
    worker = new Worker(URL.createObjectURL(new Blob([WORKER], { type: 'text/javascript' })));
  } catch {
    return; // Some pages may not start workers (opened from a file, strict CSP): keep the page's own timers.
  }
  const timers = new Map<number, Timer>();
  const native = { clearTimeout, clearInterval };
  // Above any id the browser's own timers reach, so clears can tell them apart.
  let next = 2 ** 30;

  worker.onmessage = ({ data: id }: MessageEvent<number>) => {
    const timer = timers.get(id);
    if (!timer) return;
    if (timer.every === undefined) timers.delete(id);
    else worker.postMessage([id, timer.every]);
    timer.fn();
  };
  const start = (fn: () => void, ms: number, every?: number) => {
    const id = next++;
    timers.set(id, { fn, every });
    worker.postMessage([id, Math.max(0, ms)]);
    return id;
  };
  const clear = (id: number | undefined, fallback: (id: number) => void) => {
    if (id === undefined) return;
    if (timers.delete(id)) worker.postMessage([id, -1]);
    else fallback(id);
  };

  const g = globalThis as unknown as Record<string, unknown>;
  g.setTimeout = (fn: (...a: unknown[]) => void, ms = 0, ...args: unknown[]) => start(() => fn(...args), ms);
  g.setInterval = (fn: (...a: unknown[]) => void, ms = 0, ...args: unknown[]) => start(() => fn(...args), ms, Math.max(0, ms));
  g.clearTimeout = (id?: number) => clear(id, native.clearTimeout);
  g.clearInterval = (id?: number) => clear(id, native.clearInterval);
}
