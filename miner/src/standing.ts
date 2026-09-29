import { erc20Abi, type Address } from 'viem';
import { minterAbi, type Reader } from './chain.ts';
import { amount, count, hype } from './text.ts';

export type Row = [label: string, value: string];

/**
 * The owner's standing, as both the CLI's status box and the browser miner show
 * it. `token` is the minter's token; `found` counts blocks this session found.
 */
export async function statusRows(c: Reader, token: Address, owner: Address, found: number): Promise<Row[]> {
  const minter = { address: c.net.minter, abi: minterAbi } as const;
  const [hypow, saved, gas, difficulty, height] = await Promise.all([
    c.read.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [owner] }),
    c.read.readContract({ ...minter, functionName: 'credits', args: [owner] }),
    c.read.getBalance({ address: c.account.address }),
    c.read.readContract({ ...minter, functionName: 'difficulty' }),
    c.read.readContract({ ...minter, functionName: 'winCount' }),
  ]);
  return [
    ['wallet', `${amount(hypow)} HYPOW · ${count(saved)} attempts saved`],
    ['session', `${found} block${found === 1 ? '' : 's'} found`],
    ['gas', `${hype(gas)} HYPE in the miner key · pays mining fees`],
    ['network', `block ${count(height)} · difficulty ${count(difficulty)}`],
  ];
}
