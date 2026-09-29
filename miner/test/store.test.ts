import assert from 'node:assert/strict';
import { test } from 'node:test';
import { loadKey, loadOwner, loadRpc, saveOwner, saveRpc, type Store } from '../web/store.ts';

function memory(): Store {
  const items = new Map<string, string>();
  const storage = {
    getItem: (k: string) => items.get(k) ?? null,
    setItem: (k: string, v: string) => void items.set(k, v),
    removeItem: (k: string) => void items.delete(k),
  };
  return () => storage;
}

const refused: Store = () => {
  throw new DOMException('The operation is insecure.', 'SecurityError');
};

test('the key is created once, then read back', () => {
  const store = memory();
  const first = loadKey(store);
  assert.deepEqual({ created: first.created, kept: first.kept }, { created: true, kept: true });
  assert.deepEqual(loadKey(store), { key: first.key, created: false, kept: true });
});

test('a browser that refuses storage still gets a key, for this tab only', () => {
  const a = loadKey(refused);
  const b = loadKey(refused);
  assert.equal(a.kept, false);
  assert.notEqual(a.key, b.key);
});

test('the owner is saved checksummed, forgotten, and unreadable storage means none', () => {
  const store = memory();
  saveOwner(store, '0x000000000000000000000000000000000000dEaD');
  assert.equal(loadOwner(store), '0x000000000000000000000000000000000000dEaD');
  saveOwner(store, undefined);
  assert.equal(loadOwner(store), undefined);
  saveOwner(refused, '0x000000000000000000000000000000000000dEaD');
  assert.equal(loadOwner(refused), undefined);
});

test('your own RPC is saved, reverted to the public endpoints, and unreadable storage means public', () => {
  const store = memory();
  assert.equal(loadRpc(store), undefined);
  saveRpc(store, 'https://rpc.example/v2/key');
  assert.equal(loadRpc(store), 'https://rpc.example/v2/key');
  saveRpc(store, undefined);
  assert.equal(loadRpc(store), undefined);
  saveRpc(refused, 'https://rpc.example/v2/key');
  assert.equal(loadRpc(refused), undefined);
});

test('names keep the mainnet prefix earlier releases saved under', () => {
  const store = memory();
  const { key } = loadKey(store);
  saveOwner(store, '0x000000000000000000000000000000000000dEaD');
  saveRpc(store, 'https://rpc.example/v2/key');
  assert.equal(store().getItem('hypow.mainnet.minerKey'), key);
  assert.equal(store().getItem('hypow.mainnet.owner'), '0x000000000000000000000000000000000000dEaD');
  assert.equal(store().getItem('hypow.mainnet.rpc'), 'https://rpc.example/v2/key');
});
