import { constants } from 'node:os';
import type { Address } from 'viem';
import { minterAbi, type Chain } from './chain.ts';
import { coalesce } from './coalesce.ts';
import { rpcRow } from './endpoint.ts';
import { paint } from './log.ts';
import { statusRows, type Row } from './standing.ts';

/**
 * The miner refreshes the box on each trade, ticket, block and error; this
 * catches what changes without one, like someone else's block moving the network row.
 */
const REFRESH_MS = 60_000;
/** How the CLI sets its own RPC, in the status row and the log. */
export const RPC_FIX = '--rpc <url>';
const LABEL_WIDTH = 9;
const CSI = '\x1b[';
const SAVE = '\x1b7';
const RESTORE = '\x1b8';

export type StatusBox = {
  /** Re-read the chain and redraw. */
  refresh: () => void;
  /** Count a block this session found. */
  won: () => void;
};

/**
 * `rows` as a box at most `columns` wide: dim frame and labels, values as is
 * but a warning (⚠) red, each row cut with an ellipsis if the terminal is too narrow.
 */
export function render(rows: Row[], columns: number): string[] {
  const inner = Math.max(10, Math.min(columns - 4, Math.max(...rows.map(([, v]) => LABEL_WIDTH + v.length))));
  const rule = '─'.repeat(inner + 2);
  const body = rows.map(([label, value]) => {
    const text = `${label.padEnd(LABEL_WIDTH)}${value}`;
    const fit = text.length > inner ? `${text.slice(0, inner - 1)}…` : text.padEnd(inner);
    const shown = value.startsWith('⚠') ? paint(['bold', 'red'], fit.slice(LABEL_WIDTH)) : fit.slice(LABEL_WIDTH);
    return `${paint('dim', '│')} ${paint('dim', fit.slice(0, LABEL_WIDTH))}${shown} ${paint('dim', '│')}`;
  });
  return [paint('dim', `╭${rule}╮`), ...body, paint('dim', `╰${rule}╯`)];
}

/**
 * The owner's standing, pinned below the log on a terminal. An ANSI scroll
 * region confines the log to the rows above the box, so the log scrolls and the
 * box stays put. Off a terminal there is no box: the log lines are the record.
 */
export async function statusBox(c: Chain, owner: Address): Promise<StatusBox> {
  const out = process.stdout;
  if (!out.isTTY) return { refresh: () => {}, won: () => {} };

  const token = await c.read.readContract({ address: c.net.minter, abi: minterAbi, functionName: 'token' });
  let found = 0;
  const read = async () => [...(await statusRows(c, token, owner, found)), rpcRow(c, RPC_FIX)];
  let rows = await read();
  const height = rows.length + 2;

  const draw = () => {
    const top = out.rows - height;
    const box = render(rows, out.columns).map((l, i) => `${CSI}${top + 1 + i};1H${CSI}2K${l}`);
    out.write(`${SAVE}${box.join('')}${RESTORE}`);
  };
  // Setting a scroll region homes the cursor, hence the saves around it. The
  // cursor sits on the blank line after the last log line: clear below it,
  // scroll the log up if it would run under the box, then pin the box.
  const reserve = () => {
    out.write(
      `${SAVE}${CSI}r${RESTORE}${CSI}J${'\n'.repeat(height)}${CSI}${height}A` +
        `${SAVE}${CSI}1;${out.rows - height}r${RESTORE}`,
    );
    draw();
  };
  const release = () => out.write(`${SAVE}${CSI}r${RESTORE}${CSI}J`);

  reserve();
  out.on('resize', reserve);
  process.on('exit', release);
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => process.exit(128 + constants.signals[signal]));

  const refresh = coalesce(async () => {
    try {
      rows = await read();
      draw();
    } catch {
      // Keep the last numbers: the mining pass reports RPC trouble in the log.
    }
  });
  setInterval(refresh, REFRESH_MS).unref();
  return {
    refresh,
    won: () => {
      found++;
      refresh();
    },
  };
}
