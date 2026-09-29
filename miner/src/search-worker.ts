import { parentPort, workerData } from 'node:worker_threads';
import { search } from './protocol.ts';

// Runs one draw's search off the main thread; see searchDraw in mine.ts.
const { seed, owner, k, target } = workerData;
parentPort!.postMessage(search(seed, owner, k, target));
