import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { getAddress, isAddress, isHex, type Address, type Hex } from 'viem';
import { generatePrivateKey } from 'viem/accounts';

const PUBLIC = 'public';

/**
 * Where the key, owner and RPC are saved. Earlier releases kept one directory
 * per network, so mainnet's stays under mainnet/ and existing keys keep
 * working. HYPOW_HOME puts them elsewhere.
 */
export const home = () => process.env.HYPOW_HOME ?? join(homedir(), '.hypow', 'mainnet');

function write(name: string, value: string): void {
  mkdirSync(home(), { recursive: true, mode: 0o700 });
  writeFileSync(join(home(), name), `${value}\n`, { mode: 0o600 });
}

function read(name: string): string | undefined {
  const path = join(home(), name);
  return existsSync(path) ? readFileSync(path, 'utf8').trim() : undefined;
}

/** The miner key, created on first run. `created` is true when it was just generated. */
export function loadKey(): { key: Hex; created: boolean } {
  const saved = read('key');
  if (saved !== undefined) {
    if (!isHex(saved) || saved.length !== 66) throw new Error(`${join(home(), 'key')} is not a private key`);
    return { key: saved, created: false };
  }
  const key = generatePrivateKey();
  write('key', key);
  return { key, created: true };
}

export function loadOwner(): Address | undefined {
  const owner = read('owner');
  return owner !== undefined && isAddress(owner) ? getAddress(owner) : undefined;
}

export function saveOwner(owner: Address): void {
  write('owner', owner);
}

/**
 * The saved RPC choice: the user's own URL, null for the public endpoints, or
 * undefined if they haven't chosen yet. A URL carries their API key, so it
 * lives here and is never printed.
 */
export function loadRpc(): string | null | undefined {
  const rpc = read('rpc');
  return rpc === PUBLIC ? null : rpc;
}

export function saveRpc(url: string | null): void {
  write('rpc', url ?? PUBLIC);
}
