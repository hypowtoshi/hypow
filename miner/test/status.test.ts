import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rpcRow } from '../src/endpoint.ts';
import { render, RPC_FIX } from '../src/status.ts';

const rows: [string, string][] = [
  ['wallet', '12.00 HYPOW · 3 attempts saved'],
  ['network', 'block 4 · difficulty 5,000,000,000'],
];

test('the box hugs its longest row', () => {
  const box = render(rows, 200);
  assert.equal(box.length, 4);
  assert.equal(box[0], `╭${'─'.repeat(9 + rows[1][1].length + 2)}╮`);
  assert.equal(box[2], `│ network  ${rows[1][1]} │`);
  assert.equal(new Set(box.map((l) => l.length)).size, 1);
});

test('a narrow terminal cuts rows instead of wrapping them', () => {
  const box = render(rows, 30);
  for (const l of box) assert.equal(l.length, 30);
  assert.equal(box[2], '│ network  block 4 · diffic… │');
});

test('the box ends with the rpc row: a warning on the public endpoints, the host of your own', () => {
  const pub = render([...rows, rpcRow({ own: false, rpcHost: 'rpc.hyperliquid.xyz' }, RPC_FIX)], 200);
  assert.equal(pub[3], '│ rpc      ⚠ using the rate-limited public RPC · trading often may miss blocks · to set your own RPC: --rpc <url> │');
  const own = render([...rows, rpcRow({ own: true, rpcHost: 'rpc.example.com' }, RPC_FIX)], 200);
  assert.match(own[3], /^│ rpc      your own · rpc\.example\.com +│$/);
});
