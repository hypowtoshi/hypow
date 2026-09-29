import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer, type IncomingMessage } from 'node:http';
import { setTimeout as sleep } from 'node:timers/promises';
import { encodeFunctionData, getAddress, isAddress, isHex, type Address } from 'viem';
import { minterAbi, setSpenderBySig, type Chain } from './chain.ts';
import { ready, status, type Status } from './core.ts';
import { line } from './log.ts';
import { covers } from './network.ts';
import { describe, hype, retrying, short } from './text.ts';

export const PORT = 4747;

async function waitForChain(c: Chain, owner: Address): Promise<Status> {
  for (;;) {
    const s = await retrying(line, () => status(c, owner), 3000);
    if (ready(s)) return s;
    await sleep(3000);
  }
}

/**
 * Get `owner` to authorize the key and fund its gas. A saved or given owner
 * that is already set up passes straight through. With `--owner` the user does
 * the two transactions by hand; otherwise a local page, the browser miner in
 * its authorize-only mode, drives their wallet.
 */
export async function authorize(
  c: Chain,
  opts: { owner?: Address; manual: boolean; gas: bigint; browser: boolean },
): Promise<{ owner: Address; status: Status }> {
  if (opts.owner) {
    const given = opts.owner;
    const s = await retrying(line, () => status(c, given), 3000);
    if (ready(s)) return { owner: opts.owner, status: s };
    // Already authorized: say why setup is back, so a top-up doesn't look like a fresh start.
    if (s.spender) line('gas low', `miner key has ${hype(s.balance)} HYPE, needs ${hype(c.net.minGas)} · top it up to keep mining`);
    if (opts.manual) {
      printManual(c, opts.owner, s, opts.gas);
      return { owner: opts.owner, status: await waitForChain(c, opts.owner) };
    }
  }
  return viaPage(c, opts.gas, opts.browser);
}

function printManual(c: Chain, owner: Address, s: Status, gas: bigint): void {
  const key = c.account.address;
  line('authorize', `authorize this key from ${owner} on ${c.net.name} (chain ${c.net.chainId}):`);
  if (!s.spender) {
    line('', `· call setSpender(${key}) on the minter ${c.net.minter}`);
    line('', `  (calldata ${setSpenderData(key)})`);
  }
  if (!s.gas) line('', `· send ${hype(gas)} HYPE to ${key} · ${covers(c.net, gas)}`);
  line('waiting', 'waiting for both to land on chain…');
}

function setSpenderData(key: Address) {
  return encodeFunctionData({ abi: minterAbi, functionName: 'setSpender', args: [key] });
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  let body = '';
  for await (const chunk of req) body += chunk;
  return JSON.parse(body);
}

/** The built browser miner and the page that runs it for the CLI (see build.ts). */
function page(file: string): string {
  return readFileSync(new URL(`../dist/${file}`, import.meta.url), 'utf8');
}

/**
 * Serve the browser miner, in its authorize-only mode, until the chain shows
 * the connected owner has set the key as spender and the key holds gas. The
 * page tells us who the owner is and hands over the owner's SetSpender
 * signature, which the key submits here; a per-run token keeps other local
 * pages from posting either.
 */
async function viaPage(c: Chain, gas: bigint, browser: boolean): Promise<{ owner: Address; status: Status }> {
  const token = randomBytes(16).toString('hex');
  const config = { token, key: c.account.address, gas: gas.toString() };
  const html = page('cli.html').replace('/*CONFIG*/', JSON.stringify(config));
  const script = page('hypow-miner.js');
  let owner: Address | undefined;
  let latest: Status | undefined;

  const server = createServer(async (req, res) => {
    const json = (code: number, body: unknown) => {
      res.writeHead(code, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body, (_, v) => (typeof v === 'bigint' ? v.toString() : v)));
    };
    try {
      if (req.method === 'GET' && req.url === '/') {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        res.end(html);
        return;
      }
      if (req.method === 'GET' && req.url === '/hypow-miner.js') {
        res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
        res.end(script);
        return;
      }
      if (req.headers['x-hypow-token'] !== token) return json(403, { error: 'bad token' });
      if (req.method === 'POST' && req.url === '/owner') {
        const { owner: posted } = (await readJson(req)) as { owner?: string };
        if (!posted || !isAddress(posted)) return json(400, { error: 'not an address' });
        owner = getAddress(posted);
        latest = await status(c, owner);
        line('owner', `${short(owner)} connected · waiting for the chain…`);
        return json(200, latest);
      }
      if (req.method === 'POST' && req.url === '/spender') {
        const auth = (await readJson(req)) as { owner: string; nonce: string; deadline: string; signature: string };
        if (!isAddress(auth.owner) || !isHex(auth.signature)) return json(400, { error: 'not a SetSpender signature' });
        const hash = await setSpenderBySig(c, {
          owner: getAddress(auth.owner),
          nonce: BigInt(auth.nonce),
          deadline: BigInt(auth.deadline),
          signature: auth.signature,
        });
        line('authorized', `${short(auth.owner)} signed · the key submitted it · tx ${short(hash)}`);
        return json(200, { hash });
      }
      if (req.method === 'GET' && req.url === '/status') return json(200, latest ?? null);
      json(404, { error: 'not found' });
    } catch (err) {
      json(500, { error: describe(err) });
    }
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', (err: NodeJS.ErrnoException) =>
      reject(
        // The usual holder is another miner waiting at this same step. Two
        // miners for one owner would take the authorization from each other.
        err.code === 'EADDRINUSE'
          ? new Error(`port ${PORT} is taken, most likely by another hypow miner on this machine · stop it, then run this again`)
          : err,
      ),
    );
    server.listen(PORT, '127.0.0.1', resolve);
  });

  const url = `http://localhost:${PORT}`;
  line('authorize', browser ? `${url} — opening browser…` : `open ${url} in the browser that has your wallet`);
  if (browser) openBrowser(url);

  let done: { owner: Address; status: Status } | undefined;
  while (!done) {
    await sleep(2000);
    const polled = owner;
    if (!polled) continue;
    latest = await retrying(line, () => status(c, polled), 3000);
    if (ready(latest)) done = { owner: polled, status: latest };
  }
  // Give the page a poll or two to show "Done" before the server goes away.
  await sleep(4000);
  server.close();
  return done;
}

function openBrowser(url: string): void {
  const [cmd, args] =
    process.platform === 'darwin'
      ? ['open', [url]]
      : process.platform === 'win32'
        ? ['cmd', ['/c', 'start', '', url]]
        : ['xdg-open', [url]];
  spawn(cmd, args, { detached: true, stdio: 'ignore' }).on('error', () => {}).unref();
}
