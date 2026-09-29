import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HttpRequestError } from 'viem';
import { walletError } from '../web/wallet-error.ts';

const RATE_LIMITED = "your wallet's HyperEVM RPC is rate-limited · try again, or pick another RPC in your wallet's network settings";

test("a rate limit from the wallet's RPC is named as one, however the wallet shapes it", () => {
  const shapes = [
    { code: -32005, message: 'Request exceeds defined limit' },
    { code: -32603, message: 'Internal JSON-RPC error.', data: { code: -32005, message: 'rate limited' } },
    { code: 429, message: 'HTTP error' },
    new Error('Request exceeds defined limit. URL: https://rpc.example.com Request body: {"method":"eth_getTransactionCount"} Details: rate limited'),
    new Error('429 Too Many Requests'),
  ];
  for (const err of shapes) assert.equal(walletError(err), RATE_LIMITED);
});

test("the page's own reads failing aren't blamed on the wallet", () => {
  const ours = new HttpRequestError({ url: 'https://rpc.example', status: 429, details: 'rate limited' });
  assert.notEqual(walletError(ours), RATE_LIMITED);
});

test('other wallet errors keep their own words', () => {
  assert.equal(walletError({ code: 4001, message: 'User rejected the request.' }), 'declined in the wallet');
  assert.equal(walletError({ code: -32002 }), 'the wallet already has a request open · check its window');
  assert.equal(walletError(new Error('insufficient funds for gas')), 'insufficient funds for gas');
});
