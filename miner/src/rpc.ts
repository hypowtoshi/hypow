import { stdin, stdout } from 'node:process';
import { createInterface } from 'node:readline/promises';
import { rpcProblem, wantsPublic } from './endpoint.ts';
import { loadRpc, saveRpc } from './home.ts';
import { line } from './log.ts';
import type { Network } from './network.ts';

/**
 * The user's own RPC, or undefined for the public endpoints. `--rpc` wins and
 * is saved; otherwise the saved choice; otherwise, on a terminal, ask once and
 * save the answer, "public" included. Without a terminal, the public endpoints.
 */
export async function chooseRpc(net: Network, flag: string | undefined): Promise<string | undefined> {
  if (flag !== undefined) {
    const p = await rpcProblem(net, flag);
    if (p) throw new Error(`--rpc: ${p}`);
    saveRpc(flag);
    return flag;
  }
  const saved = loadRpc();
  if (saved !== undefined) return saved ?? undefined;
  if (!stdin.isTTY) return undefined;

  // Worded as the browser's /rpc; the rpc row the miner prints next warns if the answer was public.
  line('rpc', 'paste your HyperEVM RPC URL · a free one from Alchemy, QuickNode, … · asked once, change it later with --rpc');
  const rl = createInterface({ input: stdin, output: stdout });
  try {
    for (;;) {
      const answer = (await rl.question('HyperEVM RPC URL (Enter for the rate-limited public one): ')).trim();
      const url = wantsPublic(answer) ? undefined : answer;
      const p = url && (await rpcProblem(net, url));
      if (p) {
        line('rpc', `${p} · try again`);
        continue;
      }
      saveRpc(url ?? null);
      return url;
    }
  } finally {
    rl.close();
  }
}
