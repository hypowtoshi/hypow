import assert from 'node:assert/strict';
import { test } from 'node:test';
import { sziAfter } from '../src/hyperliquid.ts';

test('a fill leaves its start position plus a buy or minus a sell, in szDecimals units', () => {
  assert.equal(sziAfter({ coin: 'BTC', side: 'A', sz: '0.00012', startPosition: '0.0002' }, 5), 8n);
  assert.equal(sziAfter({ coin: 'BTC', side: 'B', sz: '0.00012', startPosition: '0.00008' }, 5), 20n);
  assert.equal(sziAfter({ coin: 'ETH', side: 'A', sz: '0.5', startPosition: '-1.25' }, 4), -17500n);
  assert.equal(sziAfter({ coin: 'SOL', side: 'B', sz: '3', startPosition: '0.0' }, 2), 300n);
});
