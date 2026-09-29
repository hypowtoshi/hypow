#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { getAddress, isAddress, parseEther } from 'viem';
import { loadOwner } from './home.ts';
import { format } from './log.ts';
import { mine } from './mine.ts';
import { MAINNET } from './network.ts';
import { describe, hype } from './text.ts';

const USAGE = `usage: hypow mine [--owner 0x…] [--gas <HYPE>] [--rpc <url>] [--no-browser]

Mines on HyperEVM mainnet. The key, owner and RPC are kept in ~/.hypow/mainnet.

  --owner 0x…     the wallet you trade with, if you'd rather authorize by hand
                  than through the browser page
  --gas <HYPE>    HYPE the page sends the miner key for gas (default ${hype(MAINNET.gasFund)})
  --rpc <url>     your own HyperEVM RPC, tried before the public ones. The
                  first run asks for it; either way it is saved
  --no-browser    print the authorize page's address instead of opening it
  -h, --help      show this help

On a terminal, a status box stays pinned below the log: your HYPOW, the
attempts you have saved, blocks found this session, the miner key's gas and
the network. Set NO_COLOR to turn off color. Piped output is plain lines.`;

async function main(): Promise<void> {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    allowNegative: true,
    options: {
      owner: { type: 'string' },
      gas: { type: 'string' },
      rpc: { type: 'string' },
      browser: { type: 'boolean', default: true },
      help: { type: 'boolean', short: 'h' },
    },
  });
  if (values.help) {
    console.log(USAGE);
    process.exit(0);
  }
  if (positionals.length !== 1 || positionals[0] !== 'mine') {
    console.log(USAGE);
    process.exit(positionals.length === 0 ? 0 : 1);
  }

  if (values.owner !== undefined && !isAddress(values.owner)) throw new Error(`--owner ${values.owner} is not an address`);
  const gas = values.gas === undefined ? MAINNET.gasFund : parseEther(values.gas);
  if (gas < MAINNET.minGas) throw new Error(`--gas must be at least ${hype(MAINNET.minGas)} HYPE`);

  const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  await mine(version, {
    owner: values.owner ? getAddress(values.owner) : loadOwner(),
    manual: values.owner !== undefined,
    gas,
    browser: values.browser,
    rpc: values.rpc,
  });
}

main().catch((err) => {
  console.error(format('error', describe(err)));
  process.exit(1);
});
