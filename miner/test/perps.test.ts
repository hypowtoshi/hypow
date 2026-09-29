import assert from 'node:assert/strict';
import { test } from 'node:test';
import { heldIn, perps } from '../src/hyperliquid.ts';

const meta = (...names: string[]) => ({ universe: names.map((name) => ({ name, szDecimals: 2 })) });
const empty = meta();

// L1Read's perpAssetInfo and position2 precompiles number perps this way.
test('main-dex perps keep their meta index; HIP-3 perps are dexIndex·10000 + index', () => {
  const metas = [meta('SOL', 'APT', 'ATOM', 'BTC'), meta('test:ABC'), meta('unit:ES', 'unit:NQ'), ...Array(8).fill(empty), meta('zigg:ZIGG', 'zigg:AAPL')];
  const id = Object.fromEntries(perps(metas).map((p) => [p.name, p.asset]));
  assert.deepEqual(id, { SOL: 0, APT: 1, ATOM: 2, BTC: 3, 'test:ABC': 10000, 'unit:ES': 20000, 'unit:NQ': 20001, 'zigg:ZIGG': 110000, 'zigg:AAPL': 110001 });
});

test('held coins span every dex of the snapshot, flat positions excluded', () => {
  const position = (coin: string, szi: string) => ({ position: { coin, szi } });
  const held = heldIn({
    clearinghouseStates: [
      ['', { assetPositions: [position('BTC', '0.0002'), position('ETH', '0.0')] }],
      ['KNETIQ', { assetPositions: [] }],
      ['test', { assetPositions: [position('test:ABC', '-121.0')] }],
    ],
  });
  assert.deepEqual(held, ['BTC', 'test:ABC']);
});
