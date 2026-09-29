import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { home, loadKey, loadOwner, loadRpc, saveOwner, saveRpc } from '../src/home.ts';

test('the key, owner and RPC are kept in ~/.hypow/mainnet', () => {
  delete process.env.HYPOW_HOME;
  process.env.HOME = mkdtempSync(join(tmpdir(), 'hypow-home-'));
  assert.equal(home(), join(process.env.HOME, '.hypow', 'mainnet'));

  assert.equal(loadRpc(), undefined);
  const key = loadKey().key;
  saveOwner('0x000000000000000000000000000000000000dEaD');
  saveRpc(null);
  assert.deepEqual(loadKey(), { key, created: false });
  assert.equal(loadOwner(), '0x000000000000000000000000000000000000dEaD');
  assert.equal(loadRpc(), null);
});
