import { getAddress, isAddress, isHex, type Address, type Hex } from 'viem';
import { generatePrivateKey } from 'viem/accounts';

/**
 * The browser's counterpart of ~/.hypow. Reaching localStorage itself can
 * throw (private windows, blocked site data), so it is fetched inside the
 * try on every access, and a failure reads as "nothing saved". Earlier
 * releases put the network in the names, so they keep "mainnet" and existing
 * keys keep working.
 */
export type Store = () => Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

const item = (name: string) => `hypow.mainnet.${name}`;

function get(store: Store, name: string): string | null {
  try {
    return store().getItem(item(name));
  } catch {
    return null;
  }
}

function put(store: Store, name: string, value: string | undefined): boolean {
  try {
    if (value === undefined) store().removeItem(item(name));
    else store().setItem(item(name), value);
    return true;
  } catch {
    return false;
  }
}

/**
 * The miner key, created on first visit. `created` is true when it was just
 * generated; `kept` is false when the browser wouldn't store it, so it lasts
 * only as long as this tab.
 */
export function loadKey(store: Store): { key: Hex; created: boolean; kept: boolean } {
  const saved = get(store, 'minerKey');
  if (saved !== null && isHex(saved) && saved.length === 66) return { key: saved, created: false, kept: true };
  const key = generatePrivateKey();
  return { key, created: true, kept: put(store, 'minerKey', key) };
}

export function loadOwner(store: Store): Address | undefined {
  const owner = get(store, 'owner');
  return owner !== null && isAddress(owner) ? getAddress(owner) : undefined;
}

export function saveOwner(store: Store, owner: Address | undefined): void {
  put(store, 'owner', owner);
}

/** The user's own RPC URL, or undefined for the public endpoints. It carries their API key, so it is never shown. */
export function loadRpc(store: Store): string | undefined {
  return get(store, 'rpc') ?? undefined;
}

export function saveRpc(store: Store, url: string | undefined): void {
  put(store, 'rpc', url);
}
