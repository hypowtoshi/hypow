import { search } from '../src/protocol.ts';

// Runs one draw's search off the page's thread; see searchInWorker in main.ts.
self.onmessage = ({ data: { seed, owner, k, target } }: MessageEvent) => {
  self.postMessage(search(seed, owner, k, target));
};
