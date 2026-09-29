import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setImmediate as tick } from 'node:timers/promises';
import { coalesce } from '../src/coalesce.ts';

/** A run that stays open until the test releases it, counting how many started. */
function gatedRun() {
  const releases: (() => void)[] = [];
  let started = 0;
  const run = () => {
    started++;
    return new Promise<void>((resolve) => releases.push(resolve));
  };
  return { run, started: () => started, release: () => releases.shift()!() };
}

test('calls during a run queue exactly one more run', async () => {
  const g = gatedRun();
  const trigger = coalesce(g.run);
  trigger();
  trigger();
  trigger();
  trigger();
  await tick();
  assert.equal(g.started(), 1);
  g.release();
  await tick();
  assert.equal(g.started(), 2);
  g.release();
  await tick();
  assert.equal(g.started(), 2);
});

test('a call after the runs settle starts a new run', async () => {
  const g = gatedRun();
  const trigger = coalesce(g.run);
  trigger();
  g.release();
  await tick();
  trigger();
  await tick();
  assert.equal(g.started(), 2);
});

test('a call during the queued run queues another', async () => {
  const g = gatedRun();
  const trigger = coalesce(g.run);
  trigger();
  trigger();
  g.release();
  await tick();
  trigger();
  g.release();
  await tick();
  assert.equal(g.started(), 3);
});
