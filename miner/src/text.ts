import { formatEther } from 'viem';

/**
 * Where a miner's log lines go: the terminal for the CLI, the page for the
 * browser. An error line carries the error as `cause`, for the sink to explain.
 */
export type Line = (label: string, message: string, cause?: unknown) => void;

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** 0x1234abcd…cdef → 0x1234…cdef */
export function short(hex: string): string {
  return `${hex.slice(0, 6)}…${hex.slice(-4)}`;
}

/** 1284n → "1,284" */
export function count(n: bigint | number): string {
  return n.toLocaleString('en-US');
}

/** wei → "12,721.59" */
export function amount(wei: bigint): string {
  return Number(formatEther(wei)).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

/** wei → "0.002" (HYPE gas amounts) */
export function hype(wei: bigint): string {
  return Number(formatEther(wei)).toLocaleString('en-US', { maximumFractionDigits: 4 });
}

/** An error as one readable line; the full error only under DEBUG=1. */
export function describe(err: unknown): string {
  if (process.env.DEBUG === '1') console.error(err);
  const e = err as { shortMessage?: string; message?: string; cause?: { code?: string } };
  // viem puts a revert reason on the line after its summary, so keep both.
  const msg = (e.shortMessage ?? e.message ?? String(err)).replace(/\s+/g, ' ').trim();
  // Node's fetch says only "fetch failed"; the network reason is on the cause.
  return e.cause?.code ? `${msg} (${e.cause.code})` : msg;
}

/** Run `fn` until it succeeds, reporting each failure as one line. */
export async function retrying<T>(line: Line, fn: () => Promise<T>, delayMs: number): Promise<T> {
  for (;;) {
    try {
      return await fn();
    } catch (err) {
      line('error', `${describe(err)} · retrying in ${delayMs / 1000}s`, err);
      await sleep(delayMs);
    }
  }
}
