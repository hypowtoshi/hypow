/**
 * Wrap `run` so that calls never overlap: a call while it runs queues exactly
 * one more run, however many calls arrive, and that run starts when the current
 * one ends. `run` must not reject.
 */
export function coalesce(run: () => Promise<void>): () => void {
  let running = false;
  let queued = false;
  const loop = async () => {
    running = true;
    do {
      queued = false;
      await run();
    } while (queued);
    running = false;
  };
  return () => {
    if (running) queued = true;
    else void loop();
  };
}
