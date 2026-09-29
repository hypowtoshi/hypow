import { createPublicClient, http } from 'viem';
import type { Network } from './network.ts';
import type { Row } from './standing.ts';
import type { Line } from './text.ts';

/**
 * The miner's HyperEVM RPC, shared by the CLI and the browser. The public
 * endpoints ration requests per IP: past its eth_getLogs budget the official
 * one refuses every call from the IP for about a minute, and a miner on them
 * freezes that long. The user's own endpoint doesn't.
 */

/** Whether a typed RPC answer asks for the public endpoints: nothing, or "public". */
export const wantsPublic = (answer: string) => answer === '' || answer.toLowerCase() === 'public';

/** Why `url` can't serve `net`, or undefined if it can. Never quotes the URL: its path carries an API key. */
export async function rpcProblem(net: Network, url: string): Promise<string | undefined> {
  if (!URL.canParse(url) || !/^https?:$/.test(new URL(url).protocol)) return 'not an http(s) URL';
  try {
    const id = await createPublicClient({ transport: http(url, { timeout: 10_000, retryCount: 0 }) }).getChainId();
    return id === net.chainId ? undefined : `it serves chain ${id}, not ${net.name} (chain ${net.chainId})`;
  } catch {
    return "can't reach it";
  }
}

const RATE_LIMITED = /rate.?limit|exceeds defined limit|too many requests/i;

type Failure = { code?: unknown; status?: unknown; message?: unknown; details?: unknown; data?: { code?: unknown; message?: unknown }; cause?: unknown };

/**
 * Whether an RPC turned a request away for sending too many: HTTP 429, JSON-RPC
 * -32005, or words to that effect. viem wraps the RPC's answer in the causes of
 * its own errors, and wallets nest it under `data`, so both are searched.
 */
export function rateLimited(err: unknown): boolean {
  for (let e = err as Failure | undefined; e; e = e.cause as Failure | undefined) {
    if ([e.code, e.status, e.data?.code].some((c) => c === -32005 || c === 429)) return true;
    if (RATE_LIMITED.test(`${e.message ?? ''} ${e.details ?? ''} ${e.data?.message ?? ''}`)) return true;
  }
  return false;
}

/** The chain client's RPC, as the status row shows it. `fix` is how this miner sets its own: --rpc <url>, or /rpc. */
export function rpcRow(c: { own: boolean; rpcHost: string }, fix: string): Row {
  return ['rpc', c.own ? `your own · ${c.rpcHost}` : `⚠ using the rate-limited public RPC · trading often may miss blocks · to set your own RPC: ${fix}`];
}

/** How often a rate limit is explained in the log, at most. */
export const RATE_LIMIT_NOTE_MS = 180_000;

/**
 * `line`, plus a line saying what a rate limit means whenever an error it
 * reports was one, at most once every RATE_LIMIT_NOTE_MS. `own` is whether the
 * miner is on the user's own RPC; `fix` as for rpcRow.
 */
export function explainRateLimits(line: Line, own: boolean, fix: string, now = Date.now): Line {
  let last = -Infinity;
  return (label, message, cause) => {
    line(label, message, cause);
    if (!rateLimited(cause) || now() - last < RATE_LIMIT_NOTE_MS) return;
    last = now();
    if (own) line('rpc', 'your own RPC rate-limited you · the miner retries until it answers again');
    else line('⚠ rpc', `the public RPC rate-limited you · mining paused about a minute · set your own with ${fix}`);
  };
}
