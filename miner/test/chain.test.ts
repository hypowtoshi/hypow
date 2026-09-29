import assert from 'node:assert/strict';
import { test } from 'node:test';
import { padGas } from '../src/chain.ts';

// Measured: a spend estimated at 111,628 gas ran out when a fill in a
// second asset landed first; spends capturing two assets used up to 117,978.
test('a write gets half again its estimate, enough for a capture the estimate missed', () => {
  assert.equal(padGas(111_628n), 167_442n);
  assert.ok(padGas(111_628n) > 111_628n + 30_000n);
});
