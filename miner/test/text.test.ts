import assert from 'node:assert/strict';
import { test } from 'node:test';
import { retrying } from '../src/text.ts';

test('retrying reports each failure to the given sink and returns the first success', async () => {
  const lines: [string, string][] = [];
  const causes: unknown[] = [];
  let calls = 0;
  const got = await retrying(
    (label, message, cause) => {
      lines.push([label, message]);
      causes.push(cause);
    },
    async () => {
      if (++calls < 3) throw new Error(`boom ${calls}`);
      return 'ok';
    },
    1,
  );
  assert.equal(got, 'ok');
  assert.deepEqual(lines, [
    ['error', 'boom 1 · retrying in 0.001s'],
    ['error', 'boom 2 · retrying in 0.001s'],
  ]);
  assert.deepEqual(
    causes.map((e) => (e as Error).message),
    ['boom 1', 'boom 2'],
    'each line carries its error, for the sink to explain',
  );
});
