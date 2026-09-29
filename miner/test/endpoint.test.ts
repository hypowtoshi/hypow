import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { test } from 'node:test';
import { ContractFunctionExecutionError, HttpRequestError, LimitExceededRpcError, RpcRequestError, parseAbi } from 'viem';
import { explainRateLimits, RATE_LIMIT_NOTE_MS, rateLimited, rpcProblem, rpcRow, wantsPublic } from '../src/endpoint.ts';
import { MAINNET } from '../src/network.ts';

const net = MAINNET;

test('a rate limit is recognized however the RPC, viem or a wallet shapes it', () => {
  const limit = new LimitExceededRpcError(new RpcRequestError({ body: {}, error: { code: -32005, message: 'rate limited' }, url: 'https://rpc.example' }));
  const shapes = [
    new HttpRequestError({ url: 'https://rpc.example', status: 429 }),
    limit,
    // A contract read wraps the transport's error in its causes.
    new ContractFunctionExecutionError(limit, { abi: parseAbi(['function winCount() view returns (uint64)']), functionName: 'winCount' }),
    new Error('fetch failed', { cause: new Error('429 Too Many Requests') }),
    { code: -32005, message: 'Request exceeds defined limit' },
    { code: -32603, message: 'Internal JSON-RPC error.', data: { code: -32005, message: 'rate limited' } },
    { code: 429, message: 'HTTP error' },
    new Error('you have been rate-limited'),
  ];
  for (const err of shapes) assert.equal(rateLimited(err), true, String(err));
});

test("other failures aren't taken for a rate limit", () => {
  const others = [
    new HttpRequestError({ url: 'https://rpc.example', status: 500 }),
    new Error('execution reverted'),
    new Error('fetch failed', { cause: { code: 'ECONNRESET' } }),
    { code: 4001, message: 'User rejected the request.' },
    undefined,
    null,
  ];
  for (const err of others) assert.equal(rateLimited(err), false, String(err));
});

test('the rpc row warns on the public endpoints and names only the host of your own', () => {
  assert.deepEqual(rpcRow({ own: false, rpcHost: 'rpc.hyperliquid.xyz' }, '/rpc'), ['rpc', '⚠ using the rate-limited public RPC · trading often may miss blocks · to set your own RPC: /rpc']);
  assert.deepEqual(rpcRow({ own: false, rpcHost: 'rpc.hyperliquid.xyz' }, '--rpc <url>'), ['rpc', '⚠ using the rate-limited public RPC · trading often may miss blocks · to set your own RPC: --rpc <url>']);
  assert.deepEqual(rpcRow({ own: true, rpcHost: 'rpc.example.com' }, '/rpc'), ['rpc', 'your own · rpc.example.com']);
});

test('nothing or "public" asks for the public endpoints', () => {
  for (const answer of ['', 'public', 'PUBLIC']) assert.equal(wantsPublic(answer), true, answer);
  assert.equal(wantsPublic('https://rpc.example/v2/key'), false);
});

/** A JSON-RPC server answering eth_chainId with `chainId`. */
async function serving(chainId: number) {
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d));
    req.on('end', () => {
      const { id } = JSON.parse(body);
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ jsonrpc: '2.0', id, result: `0x${chainId.toString(16)}` }));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v2/secret-key`, close: () => server.close() };
}

test("an RPC URL is checked for the chain it serves, and a problem never quotes the URL", async () => {
  assert.equal(await rpcProblem(net, 'not a url'), 'not an http(s) URL');
  assert.equal(await rpcProblem(net, 'wss://rpc.example'), 'not an http(s) URL');
  const right = await serving(net.chainId);
  const wrong = await serving(1);
  try {
    assert.equal(await rpcProblem(net, right.url), undefined);
    const p = await rpcProblem(net, wrong.url);
    assert.equal(p, `it serves chain 1, not ${net.name} (chain ${net.chainId})`);
    assert.doesNotMatch(p!, /secret-key/);
  } finally {
    right.close();
    wrong.close();
  }
  assert.equal(await rpcProblem(net, 'http://127.0.0.1:1/v2/secret-key'), "can't reach it");
});

/** A clock the test moves, and the lines a sink saw. */
function rig() {
  let t = 0;
  const said: string[] = [];
  return { said, now: () => t, pass: (ms: number) => (t += ms), line: (label: string, message: string) => void said.push(`${label}: ${message}`) };
}

const limited = new HttpRequestError({ url: 'https://rpc.example', status: 429 });

test('a rate limit on the public endpoints is explained once, then not again for a few minutes', () => {
  const r = rig();
  const line = explainRateLimits(r.line, false, '/rpc', r.now);
  const note = '⚠ rpc: the public RPC rate-limited you · mining paused about a minute · set your own with /rpc';
  line('error', 'HTTP request failed. · retrying in 5s', limited);
  line('error', 'HTTP request failed. · retrying in 5s', limited);
  r.pass(RATE_LIMIT_NOTE_MS - 1);
  line('error', 'HTTP request failed. · retrying in 5s', limited);
  r.pass(1);
  line('error', 'HTTP request failed. · retrying in 5s', limited);
  assert.deepEqual(r.said, [
    'error: HTTP request failed. · retrying in 5s',
    note,
    'error: HTTP request failed. · retrying in 5s',
    'error: HTTP request failed. · retrying in 5s',
    'error: HTTP request failed. · retrying in 5s',
    note,
  ]);
});

test('on your own RPC a rate limit is reported plainly, and other lines pass through untouched', () => {
  const r = rig();
  const line = explainRateLimits(r.line, true, '/rpc', r.now);
  line('captured', '+100 attempts');
  line('error', 'execution reverted · retrying in 5s', new Error('execution reverted'));
  line('error', 'HTTP request failed. · retrying in 5s', limited);
  assert.deepEqual(r.said, [
    'captured: +100 attempts',
    'error: execution reverted · retrying in 5s',
    'error: HTTP request failed. · retrying in 5s',
    'rpc: your own RPC rate-limited you · the miner retries until it answers again',
  ]);
});
