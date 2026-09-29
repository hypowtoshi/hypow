import type { Address, Hex } from 'viem';
import { connect, minterAbi, setSpenderBySig, watch, type Reader, type SpenderAuth } from '../src/chain.ts';
import { coalesce } from '../src/coalesce.ts';
import { ready, run, status, type Status } from '../src/core.ts';
import { explainRateLimits, rpcProblem, rpcRow, wantsPublic } from '../src/endpoint.ts';
import { MAINNET as net } from '../src/network.ts';
import { statusRows } from '../src/standing.ts';
import { describe, hype, short, sleep } from '../src/text.ts';
import { account, authorize, discover, fund, type Wallet } from './authorize.ts';
import { loadKey, loadOwner, loadRpc, saveOwner, saveRpc, type Store } from './store.ts';
import { el, span, terminal, type Command } from './terminal.ts';
import { installWorkerTimers } from './timers.ts';
import { walletError } from './wallet-error.ts';

// Injected by build.ts.
declare const SEARCH_WORKER: string;
declare const VERSION: string;

/**
 * The browser miner: the CLI's mining core with a key kept in this browser,
 * driven from a terminal in the page (see terminal.ts) whose #miner-status
 * shows the CLI's status box. The page hears `hypow:owner` (the address mined
 * for, or null) and `hypow:mining` (true or false) on window.
 *
 * A page with a #hypow-cli config is the CLI's authorize page instead (see
 * src/authorize.ts): the same connect and authorize & fund for the CLI's key,
 * whose signature goes to the CLI to submit. It holds no key and never mines.
 */
installWorkerTimers();

type CliConfig = { token: string; key: Address; gas: string };
const cliConfig = document.getElementById('hypow-cli');
const cli = cliConfig ? (JSON.parse(cliConfig.textContent!) as CliConfig) : undefined;

const store: Store = () => localStorage;
const gas = cli ? BigInt(cli.gas) : net.gasFund;
const BY_HAND = 'stop the miner and authorize by hand with npx hypow mine --owner 0xYourAddress';
/** How the page names the key it authorizes, and the other kind of miner that authorizing replaces. */
const words = cli
  ? { key: "your CLI miner's key", name: 'your CLI miner', where: 'on this machine', replaces: 'a browser miner, and a browser miner would replace this one' }
  : { key: "this browser's miner key", name: 'this browser', where: 'here', replaces: 'a CLI miner (npx hypow mine), and the CLI would replace this one' };
/** As the CLI's box: mining refreshes it on events, this catches the rest. */
const STATUS_MS = 60_000;
/** How the browser miner sets its own RPC, in the status row and the log. */
const RPC_FIX = '/rpc';
const COPIED_MS = 1_000;
const t = terminal();
const { line } = t;
const statusEl = el('miner-status');
const walletEl = el('wallet');

const searchUrl = URL.createObjectURL(new Blob([SEARCH_WORKER], { type: 'text/javascript' }));

function searchInWorker(seed: Uint8Array, owner: Address, k: number, target: Uint8Array): Promise<number> {
  const worker = new Worker(searchUrl);
  return new Promise((resolve, reject) => {
    worker.onmessage = (e: MessageEvent<number>) => {
      worker.terminate();
      resolve(e.data);
    };
    worker.onerror = (e) => {
      worker.terminate();
      reject(new Error(e.message));
    };
    worker.postMessage({ seed, owner, k, target });
  });
}

const local = cli ? undefined : loadKey(store);
/** The key this page mines with, over the user's own RPC if they set one (/rpc); the CLI's page has none. */
let miner = local && connect(net, local.key, loadRpc(store));
let c: Reader = miner ?? watch(net, cli!.key);
/** The address this browser mines for. The CLI keeps its own. */
let owner = cli ? undefined : loadOwner(store);
let wallet: Wallet | undefined;
/** A connect is open in the wallet, from the terminal or the header. */
let connecting = false;
let mining: { stop: AbortController; done: Promise<void> } | undefined;
let token: Address | undefined;
let found = 0;

function announce(): void {
  window.dispatchEvent(new CustomEvent('hypow:owner', { detail: owner ?? null }));
  window.dispatchEvent(new CustomEvent('hypow:mining', { detail: mining !== undefined }));
  showWallet();
}

function button(className: string, text: string, act: () => void): HTMLButtonElement {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = className;
  b.textContent = text;
  b.addEventListener('click', act);
  return b;
}

/** The connected owner, whose small dropdown copies the address or disconnects as /forget does. */
function ownerButton(who: Address): HTMLElement {
  const box = document.createElement('div');
  box.className = 'wallet-box';
  const drop = document.createElement('div');
  drop.className = 'drop';
  drop.hidden = true;
  const copy = button('', 'Copy address', () => {
    void navigator.clipboard.writeText(who).then(
      () => flash('Copied'),
      () => flash('Copy failed'),
    );
  });
  const flash = (said: string) => {
    copy.textContent = said;
    setTimeout(() => (copy.textContent = 'Copy address'), COPIED_MS);
  };
  drop.append(
    copy,
    button('', 'Disconnect', () => {
      drop.hidden = true;
      fromHeader(forget, 'disconnected')();
    }),
  );
  box.append(button('btn', short(who), () => (drop.hidden = !drop.hidden)), drop);
  return box;
}

/**
 * The connect popup: every wallet the browser has, each a row with its icon.
 * Picking one is the terminal's connect, so a terminal waiting at its connect
 * picker moves straight on.
 */
async function connectDialog(): Promise<void> {
  const dialog = document.createElement('dialog');
  dialog.className = 'connect';
  const close = () => dialog.close();
  const head = document.createElement('div');
  head.className = 'connect-head';
  const x = button('x', '×', close);
  x.setAttribute('aria-label', 'close');
  head.append(span('title', 'Connect a wallet'), x);
  const list = document.createElement('div');
  list.className = 'connect-list';
  const wallets = await discover();
  for (const w of wallets) {
    const row = button('connect-row', '', () => {
      close();
      fromHeader(() => connectWith(w), 'connected from the header')();
    });
    if (w.icon) {
      const img = document.createElement('img');
      img.src = w.icon;
      img.alt = '';
      row.append(img);
    }
    row.append(span('name', w.name));
    list.append(row);
  }
  if (wallets.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'connect-empty';
    if (cli) empty.append(`No browser wallet found · install one, or ${BY_HAND}`);
    else {
      const toCli = document.createElement('a');
      toCli.href = '#cli';
      toCli.textContent = 'use the CLI';
      toCli.addEventListener('click', (e) => {
        e.preventDefault();
        close();
        window.dispatchEvent(new CustomEvent('hypow:cli'));
      });
      empty.append('No browser wallet found · install one, or ', toCli);
    }
    list.append(empty);
  }
  dialog.append(head, span('dim', 'The wallet you trade with on Hyperliquid. Connecting moves no funds.'), list);
  // A click on the backdrop lands on the dialog itself.
  dialog.addEventListener('click', (e) => e.target === dialog && close());
  dialog.addEventListener('close', () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}

/** The header's wallet control, on every tab: "connect wallet", or the connected owner. */
function showWallet(): void {
  walletEl.replaceChildren(owner ? ownerButton(owner) : button('btn', 'connect wallet', () => void connectDialog()));
}

// The owner's dropdown closes on a click elsewhere or esc.
const closeDrops = () => {
  for (const d of walletEl.querySelectorAll<HTMLElement>('.drop')) d.hidden = true;
};
document.addEventListener('click', (e) => {
  if (!walletEl.contains(e.target as Node)) closeDrops();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeDrops();
});

/** Run `act` for the header, closing whatever picker the terminal has open. */
const fromHeader = (act: () => Promise<void>, why: string) => () => {
  t.cancel(why);
  void t.exclusive(act);
};

async function rows() {
  token ??= await c.read.readContract({ address: net.minter, abi: minterAbi, functionName: 'token' });
  // The CLI's page reads over the public endpoints whatever RPC the CLI mines on, so it has no rpc row.
  return [...(await statusRows(c, token, owner!, found)), ...(miner ? [rpcRow(miner, RPC_FIX)] : [])];
}

/** The CLI's status box, as rows under the log. */
const refresh = coalesce(async () => {
  if (!owner) {
    statusEl.replaceChildren(span('value', 'not connected'));
    return;
  }
  try {
    const shown = await rows();
    statusEl.replaceChildren(
      ...shown.map(([label, value]) => {
        const r = document.createElement('div');
        r.append(span('label', label), span(value.startsWith('⚠') ? 'value alarm' : 'value', value));
        return r;
      }),
    );
  } catch {
    // Keep the last numbers: the log reports RPC trouble when mining.
  }
});

const commands: Command[] = [
  { name: 'pause', desc: 'stop mining', run: pause },
  { name: 'resume', desc: 'start mining again', run: resume },
  { name: 'status', desc: 'where things stand', run: printStatus },
  { name: 'topup', desc: 'send the miner key HYPE for fees', run: topUp },
  { name: 'rpc', desc: 'use your own HyperEVM RPC', run: askRpc },
  { name: 'clear', desc: 'clear the log', run: async () => t.clear() },
  { name: 'forget', desc: 'stop, and forget this address', run: forget },
];

/** An empty enter opens the command menu; anything else that isn't a /command is a mistake. */
const commandPrompt = (list: Command[]) => async (v: string) =>
  v ? line('error', `${v} isn't a command · type / for the list`) : t.menu(list);

async function askConnect(): Promise<void> {
  t.ask('connect', askConnect, []);
  if ((await t.choose('Mine for the wallet you trade with', ['Connect wallet'])) === 0) return connectWallet();
}

/** The browser's wallet: straight to it when there is one, a picker when there are several. */
async function pickWallet(): Promise<Wallet | undefined> {
  const wallets = await discover();
  if (wallets.length === 0) {
    line(
      'no wallet',
      location.protocol === 'file:'
        ? 'wallets do not load on a page opened from a file · open it over http(s)'
        : `no browser wallet found here · install one, or ${cli ? BY_HAND : 'run npx hypow mine (the cli tab)'}`,
    );
    return undefined;
  }
  const k = wallets.length === 1 ? 0 : await t.choose('Select a wallet', wallets.map((w) => w.name));
  return wallets[k];
}

async function connectWallet(): Promise<void> {
  t.ask('connect', askConnect, []);
  const w = await pickWallet();
  if (w) return connectWith(w);
}

/** Connect `w`, from the terminal or the header, then go on to mining or authorizing. */
async function connectWith(w: Wallet): Promise<void> {
  if (connecting) return;
  connecting = true;
  try {
    owner = await account(w.provider);
  } catch (err) {
    line('error', walletError(err));
    return;
  } finally {
    connecting = false;
  }
  wallet = w;
  if (cli) await toCli('/owner', { owner });
  else saveOwner(store, owner);
  announce();
  refresh();
  const s = await status(c, owner);
  // A browser key short of HYPE starts anyway: the core pauses and offers a top-up.
  if (cli ? ready(s) : s.spender) {
    line('owner', `${short(owner)} connected`);
    return authorized();
  }
  line('owner', `${short(owner)} connected · the wallet you trade with gets the rewards`);
  return askAuthorize();
}

async function askAuthorize(): Promise<void> {
  if (!wallet) return connectWallet();
  t.ask('authorize', askAuthorize, []);
  line('authorize', `${words.key} needs your OK to play your attempts`);
  line('', `it is a small separate wallet ${words.where} that pays the mining fees, so it also needs ${hype(gas)} HYPE`);
  line('', `you have one miner at a time: this replaces ${words.replaces}`);
  const k = await t.choose(`Authorize ${words.name} to mine for ${short(owner!)}`, [
    'Authorize & fund · one signature, then one HYPE transfer',
    'Use a different wallet',
    'Forget this address',
  ]);
  if (k === 0) return authorizeAndFund();
  if (k === 1) return connectWallet();
  if (k === 2) return forget();
}

/** The browser's key submits the owner's signature itself; the CLI's page hands it to the CLI. */
const submit = (auth: SpenderAuth): Promise<Hex> =>
  cli ? toCli<{ hash: Hex }>('/spender', auth).then((r) => r.hash) : setSpenderBySig(miner!, auth);

async function authorizeAndFund(): Promise<void> {
  try {
    await authorize(c, wallet!.provider, owner!, { gas, keyName: words.key, submit }, line);
  } catch (err) {
    line('error', walletError(err));
    return askAuthorize();
  }
  return authorized();
}

/** The owner has authorized the key: mine here, or hand back to the CLI. */
async function authorized(): Promise<void> {
  return cli ? handBack() : start(await status(c, owner!));
}

/** A request to the CLI serving this page. */
async function toCli<T>(path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'content-type': 'application/json', 'x-hypow-token': cli!.token },
    body: body === undefined ? undefined : JSON.stringify(body, (_, v) => (typeof v === 'bigint' ? v.toString() : v)),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`the CLI says: ${json.error}`);
  return json;
}

/** Wait for the CLI to see the key authorized and funded, then send the user back to it. */
async function handBack(): Promise<void> {
  line('waiting', `waiting for ${words.name} to see it on chain…`);
  for (;;) {
    const s = await toCli<{ spender: boolean; gas: boolean } | null>('/status');
    if (s?.spender && s.gas) break;
    await sleep(1500);
  }
  t.note('Done · go back to your terminal', [
    "Your CLI miner is authorized and funded. It now watches your trading on Hyperliquid: every perp trade you make earns attempts, and the miner uses them to try to find a winning hash. Go back to your terminal and keep it running; you'll see each trade and ticket there.",
    'You can close this window.',
  ]);
  el('miner-line').hidden = true;
}

/** A remembered owner who authorized this browser's key: mining needs no wallet. */
async function askStart(s: Status): Promise<void> {
  t.ask('start', () => askStart(s), []);
  const k = await t.choose(`Mine for ${short(owner!)}`, ['Start mining', 'Use a different wallet', 'Forget this address']);
  if (k === 0) return start(s);
  if (k === 1) return connectWallet();
  if (k === 2) return forget();
}

async function start(s: Status): Promise<void> {
  const who = owner!;
  const stop = new AbortController();
  line('owner', `${short(who)} · key authorized · miner key holds ${hype(s.balance)} HYPE for fees`);
  line('mining', 'keep this tab open · trade on Hyperliquid in another tab · enter for commands');
  const platform = {
    line: explainRateLimits(line, miner!.own, RPC_FIX),
    search: searchInWorker,
    refresh,
    won: () => {
      found++;
      refresh();
    },
    gas: (low: boolean) => {
      refresh();
      if (low) void offerTopUp();
      else t.cancel('topped up');
    },
  };
  const done = run(miner!, who, platform, stop.signal).catch((err) => line('error', describe(err)));
  mining = { stop, done };
  announce();
  t.ask('miner', commandPrompt(commands), commands);
}

/** Stop mining once the ticket in play, if any, is settled. */
async function halt(): Promise<void> {
  if (!mining) return;
  mining.stop.abort();
  await mining.done;
  mining = undefined;
  announce();
}

async function pause(): Promise<void> {
  if (!mining) return line('paused', 'not mining · /resume to start');
  await halt();
  line('paused', 'not mining · a trade opened and closed while paused earns nothing');
  t.ask('paused', commandPrompt(commands), commands);
}

async function resume(): Promise<void> {
  if (mining) return line('mining', 'already mining');
  const s = await status(c, owner!);
  return s.spender ? start(s) : askAuthorize();
}

/** The picker the core's low-gas pause opens, unless another one is on screen (then /topup does it). */
async function offerTopUp(): Promise<void> {
  if (t.picking()) return line('', 'type /topup to send it from your wallet');
  const k = await t.choose('The miner key is out of HYPE for fees', [`Top up the miner key · send ${hype(net.gasFund)} HYPE from your wallet`]);
  if (k === 0) await t.exclusive(topUp);
}

/** Send the key HYPE from the browser's wallet. Any account can: it needn't be the owner. */
async function topUp(): Promise<void> {
  const w = wallet ?? (await pickWallet());
  if (!w) return;
  try {
    await fund(c, w.provider, await account(w.provider), gas, line);
    refresh();
  } catch (err) {
    line('error', walletError(err));
  }
}

async function askRpc(): Promise<void> {
  line('rpc', 'paste your HyperEVM RPC URL · a free one from Alchemy, QuickNode, … · enter nothing, or "public", for the public endpoints');
  t.ask('rpc url', useRpc, [], (v) => (URL.canParse(v) ? `${new URL(v).origin}/…` : v));
}

/** Check the answer to /rpc, save it, and move the miner onto it, the user's RPC ahead of the public ones as in the CLI. */
async function useRpc(answer: string): Promise<void> {
  const url = wantsPublic(answer) ? undefined : answer;
  const p = url && (await rpcProblem(net, url));
  if (p) return line('rpc', `${p} · paste another, or enter nothing for the public endpoints`);
  const was = mining !== undefined;
  if (was) line('rpc', 'switching · mining stops once the ticket in play is settled, then starts again');
  await halt();
  saveRpc(store, url);
  miner = connect(net, local!.key, url);
  c = miner;
  line(...rpcRow(miner, RPC_FIX));
  refresh();
  if (was) return start(await status(c, owner!));
  t.ask('paused', commandPrompt(commands), commands);
}

async function printStatus(): Promise<void> {
  line('owner', `${owner} · ${mining ? 'mining' : 'not mining'}`);
  for (const [label, value] of await rows()) line(label, value);
}

async function forget(): Promise<void> {
  await halt();
  line('forgot', `forgot ${short(owner!)} · ${words.key} stays authorized until you authorize another miner`);
  owner = undefined;
  wallet = undefined;
  if (!cli) saveOwner(store, undefined);
  announce();
  refresh();
  return askConnect();
}

if (cli) {
  line('hypow', `authorize ${VERSION} · ${net.name} · minter ${short(net.minter)}`);
  line('miner key', `${cli.key} · ${words.key}, kept ${words.where} · a small separate wallet that pays mining fees`);
  line('', 'this page only authorizes it · it mines in your terminal, not here');
} else {
  line('hypow', `browser ${VERSION} · ${net.name} · minter ${short(net.minter)}`);
  line(
    'miner key',
    `${short(c.account.address)} (${local!.created ? 'new, ' : ''}${local!.kept ? 'saved in this browser)' : "this browser won't save it) · it lasts while this tab is open"}` +
      ' · a small separate wallet that pays mining fees',
  );
  line(...rpcRow(miner!, RPC_FIX));
  line('', 'mines only while this tab is open · trade on Hyperliquid in another tab');
}
line('', 'only trades on your main account mine, not on subaccounts or vaults');
announce();
refresh();
setInterval(refresh, STATUS_MS);
void t.exclusive(async () => {
  if (!owner) return askConnect();
  line('owner', `${short(owner)} (remembered)`);
  const s = await status(c, owner);
  return s.spender ? askStart(s) : askConnect();
});
