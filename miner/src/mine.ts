import { extname } from 'node:path';
import { Worker } from 'node:worker_threads';
import type { Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { authorize } from './authorize.ts';
import { connect } from './chain.ts';
import { explainRateLimits, rpcRow } from './endpoint.ts';
import { run } from './core.ts';
import { home, loadKey, saveOwner } from './home.ts';
import { line } from './log.ts';
import { MAINNET } from './network.ts';
import { chooseRpc } from './rpc.ts';
import { RPC_FIX, statusBox } from './status.ts';
import { hype, retrying, short } from './text.ts';

export async function mine(
  version: string,
  opts: { owner?: Address; manual: boolean; gas: bigint; browser: boolean; rpc: string | undefined },
): Promise<void> {
  line('hypow', `${version} · ${MAINNET.name} · minter ${short(MAINNET.minter)}`);
  const { key, created } = loadKey();
  line(
    'miner key',
    `${short(privateKeyToAccount(key).address)} (${created ? 'new, ' : ''}saved to ${home().replace(process.env.HOME ?? '', '~')}) · a small separate wallet that pays mining fees`,
  );
  const c = connect(MAINNET, key, await chooseRpc(MAINNET, opts.rpc));
  line(...rpcRow(c, RPC_FIX));

  const { owner, status } = await authorize(c, opts);
  saveOwner(owner);
  line('owner', `${short(owner)} · key authorized · miner key holds ${hype(status.balance)} HYPE for fees`);
  const say = explainRateLimits(line, c.own, RPC_FIX);
  const box = await retrying(say, () => statusBox(c, owner), 5_000);
  // The core's lines say what to send where; the box just shows the new balance.
  await run(c, owner, { line: say, search: searchInWorker, ...box, gas: box.refresh }, new AbortController().signal);
}

// search-worker.ts from source, search-worker.js next to the built dist/cli.js.
const SEARCH_WORKER = new URL(`./search-worker${extname(import.meta.url)}`, import.meta.url);

function searchInWorker(seed: Uint8Array, owner: Address, k: number, target: Uint8Array): Promise<number> {
  const worker = new Worker(SEARCH_WORKER, { workerData: { seed, owner, k, target } });
  return new Promise((resolve, reject) => {
    worker.once('message', resolve);
    worker.once('error', reject);
  });
}
