# Hypow

A fair-launch token mined by **trading** on Hyperliquid. The work that meters
issuance is realised trade volume, not compute — internally the mechanism is
**Proof of Trade**. The system lives entirely on Hyperliquid: a token on
HyperEVM with a hard-capped supply of 21,000,000,000, and a single mining
contract that observes user perp positions through L1Read precompiles.

No premine, no team allocation, no VC round. Every token in existence arises
from on-chain mining activity.

## How it works

The minter is a **state witness**, not a trade router. Users trade natively on
Hyperliquid through any path; the contract reads their HyperCore perp position
before and after, and counts the dollar-magnitude of the position change as
mining volume. The contract never calls CoreWriter and never takes custody —
the user is always the trader of record.

The minter (v5) is a **credit bank with a lottery**:

- **`capture(member, assets[])`** — reads the member's positions and banks the
  realised volume since each baseline (`|Δszi| · markPx`, in cents) as
  credits. Credits never expire. The first capture of an asset baselines at the
  member's *current* position and credits nothing, so positions held before
  mining started never count; capturing a flat asset registers it at zero so its
  next open counts in full. Growth (an open or an add) is priced at the
  current mark; a shrink (a close or a partial close) at the lower of the
  current mark and the price recorded for the position, which a capture of the
  unchanged position can only raise and any change resets to the current mark.
  A flip is both. So a close captured after the position is gone never earns
  more than its recorded price (this stops a HIP-3 deployer from closing wash
  legs uncaptured and then ramping its own market's mark). Only the
  owner, or the spender the owner authorized (below), may capture a solo
  member: the mark at capture prices the volume, so a stranger could only pick
  a bad one.
- **`spend(owner, maxK)`** — moves up to `maxK` banked credits into a **draw**
  on a drand round two rounds in the future, which nobody can know yet. Only the
  owner may spend, or one spender the owner authorized (`setSpender`, or
  `setSpenderBySig` with an EIP-712 signature; `address(0)` revokes). Rewards
  always mint to the owner.
- **`settle(owner, round, signature, nonce)`** — permissionless. Verifies the
  drand evmnet BLS signature for `round`. A draw of `k` credits holds tickets
  `1..k`; ticket `nonce` wins iff `keccak256(seed, owner, nonce)` falls below
  the difficulty target, where `seed` is the keccak256 of the verified 64-byte
  signature (not drand's sha256 `randomness` field).
  A win mints the current emission reward and retargets difficulty if the
  window elapsed.

A cashed win on drand round R closes R and every earlier round
(`lastWonRound`); nothing else closes a draw, and there is no deadline. A
ticket can't die before its round is published, and a winner must cash before
anyone cashes a later round. At most one win per round mints (`wonBy(round)`).
Because the seed does not exist when credits are committed, splitting volume
across addresses gives no advantage.

**`setCreditDelegate(pool)`** joins a pool: from then on only the pool can
capture the member, and captured credits go into the pool's own bank, which the
pool spends like any owner. Wins mint to the pool. How a pool pays its members
is up to the pool: pools are community-built on this delegation hook, and the
launch deploys none. The repo ships `TestPool`, a minimal test-only contract
that proves the hook end to end. It pays members nothing and is not a payout
design. A reference PPLNS pool was removed after the v5 delta audit showed that
paying wins by credits contributed, not credits drawn, lets a later contributor
take the wins of a large contribution still in the pool's bank. Pool builders
should pay each win by the credits actually drawn; [PROTOCOL.md](PROTOCOL.md#pools)
has the guidance.

Emission follows a continuous exponential-decay reward curve; difficulty
retargets on a Bitcoin-style window (multiplicative movement clamped at 4×).
The token's single minter is set at deployment and is irrevocable — the cap
cannot be raised and the minter cannot be changed.

## Repository layout

| Path         | What it is                                                              |
|--------------|-------------------------------------------------------------------------|
| `contracts/` | The Solidity minter and token (Foundry), plus a test-only pool. `forge-std`, `prb-math` and `bls-solidity` (drand BLS verification, pinned at `11af179`) are vendored under `lib/`. |
| `miner/`     | `hypow`, the reference miner CLI (Node, viem).                          |
| `site/`      | The website: the whitepaper, the blocks list and the in-browser miner.  |

## Miner CLI (`miner/`)

`hypow mine` mines for the wallet you trade with, on HyperEVM mainnet.
Requires Node 22.18 or newer (it runs the TypeScript sources directly).

Run the published package:

```bash
npx hypow mine            # npx hypow --help lists the flags
```

Or build it from source. Clone this repository, install the miner's
dependencies once, then run it from the checkout:

```bash
git clone https://github.com/hypowtoshi/hypow hypow && cd hypow
npm ci --prefix miner
npx ./miner mine          # npx ./miner --help lists the flags
```

It keeps its saved state in `~/.hypow/mainnet` (`HYPOW_HOME` moves it). On
first run it creates a miner key in `key` there and asks for a HyperEVM RPC
URL. Press Enter to use the public endpoints anyway. They are shared and rate-limited per IP: past its budget the official
one refuses every call for about a minute, and the miner freezes that long, so
trades are captured late or missed and winning tickets can be cashed too late.
The miner makes almost no requests while you don't trade, so how much this
bites depends on how often you trade. Your own RPC is recommended; a free one
(Alchemy, QuickNode, …) will do. The answer is saved to `rpc` next to the key
and asked only once; `--rpc <url>` changes it later. The miner tries it before
the public endpoints and prints only its host, since the URL's path carries
your API key. Without a terminal (scripts, agents) it doesn't ask: it uses
`--rpc` or the public ones. On the public endpoints the status box's `rpc` row
stays a red warning, and each time a rate limit actually stalls the miner the
log says so, at most once every three minutes.

It then opens `http://localhost:4747`: the browser miner below, in a mode that
only authorizes the CLI's key. It connects your browser wallet (the connected
address is the owner that trades and gets the rewards), which sends the key a
little HYPE for gas (`--gas <HYPE>`, default 0.01) and signs an EIP-712 `SetSpender`. The page hands the signature to the
CLI, whose key submits it through `setSpenderBySig`. The page holds no key and
doesn't mine. Without a browser wallet, run `npx ./miner mine --owner 0x…` and
send the two transactions it prints yourself: `setSpender(key)` on the minter,
and the HYPE to the key. The owner is saved to `owner` next to the key, so
later runs start mining straight away.

It then registers your coins (current positions are the starting point and
earn nothing) and follows your fills on Hyperliquid's websocket. Perps on every
perp dex mine, builder-deployed (HIP-3) ones included; spot doesn't. The minter
credits only the change between two captures of a position, so right after
each fill the miner waits for HyperEVM to show the new position, captures it,
buys a ticket on an upcoming drand round, searches it, and cashes any win. A
trade opened and closed faster than that (about 4 s end to end on a private
RPC) is missed. The miner key is a small separate wallet that pays the mining
fees; when it holds less than it needs, mining pauses, the miner says where to
send HYPE, and it resumes by itself once the HYPE lands. `DEBUG=1` prints full
errors.

```bash
cd miner && npm run typecheck && npm test
```

### Browser miner (`miner/web/`)

The same mining loop (`src/core.ts`) also runs in a web page, for people who
won't install the CLI. `npm run build` bundles it into one self-contained
script, `miner/dist/hypow-miner.js`, next to `dist/cli.html`, the page the CLI
serves it in (`npm ci` and `npm pack` run the build, which also compiles the
CLI to `dist/cli.js`). A page loads it and provides a terminal:
`#miner-log` (the CLI's log lines, plus arrow-key pickers), `#miner-status`
(the CLI's status box, from the same rows in `src/standing.ts`),
`#miner-suggest` (slash-command suggestions) and `#miner-line` holding
`#miner-prompt` and `#miner-input` (the prompt), plus `#wallet` for the
header's wallet control: "connect wallet" opens a popup of the browser's
wallets; once connected it shows the owner, whose menu copies the address or
disconnects. Enter on an empty prompt opens the
command menu: `/pause`, `/resume`, `/status`, `/topup`, `/rpc`, `/clear`, `/forget`.
`/rpc` is the CLI's `--rpc`: it checks the URL serves the chain, saves it in
`localStorage` and moves the miner onto it; nothing, or `public`, goes back to
the public endpoints. The page
learns the owner and whether it is mining from `hypow:owner` and `hypow:mining`
events on `window`. A page that also carries a `#hypow-cli` config (the CLI's
page) only connects and authorizes the CLI's key, then sends you back to the
terminal.

The miner key lives in the browser's `localStorage`. The page connects the
wallet you trade with, which sends the key its gas and signs an EIP-712 `SetSpender` that the key submits through
`setSpenderBySig`. An owner has one spender, so authorizing the browser
replaces a CLI miner and vice versa. It mines only while its tab is open. Its
timers run in a worker, because Chrome slows a hidden tab's own timers to once
a minute and the user trades in another tab. Wallets don't inject into pages
opened from a file, so serve it over http.

## Website (`site/`)

The whitepaper, a live list of mined blocks, and the in-browser miner above.
`index.html` is the whole page; it loads the miner bundle, `hypow-miner.js`,
which the miner build copies next to it:

```bash
npm ci --prefix miner     # also runs the build; npm run build --prefix miner rebuilds
cd site && python3 -m http.server 8000   # http://localhost:8000
```

Deploying it is copying those two files to any static host. The blocks list
reads the chain itself, from constants in the page's own script, and shows
the mainnet minter.

## Contracts (`contracts/`)

Requires [Foundry](https://book.getfoundry.sh/). Dependencies are vendored, so
no `forge install` is needed.

```bash
cd contracts
forge build
forge test          # unit, fuzz, invariant and BLS differential tests (real drand fixtures)
uvx --from halmos==0.3.3 halmos   # symbolic proofs (token, capture, settle, pool delegation)
```

The `forge` suite mocks the L1Read precompiles, so it cannot catch a drift in
the real precompile addresses, encoding, return layout, or price scaling. That
boundary is validated separately against a live chain:

```bash
script/live-e2e.py
RPC=<url> script/live-e2e.py   # the RPC URL is never printed
```

It runs *this build's* code against the live chain with no deploy, gas, key or
transaction: `cast call --override-code` injects the compiled bytecode for a
single `eth_call`. (A Foundry fork can't do this: precompiles live in the node,
not as EVM code, so a forked `eth_getCode` returns empty and the decode reverts.)
It checks, each with a negative control that must fail:

- `perpAssetInfo` for every perp dex, at precompile id `dex·10000 + index`
  (not the trading API's `100000 + …` form), matches the info API's metadata.
- For a positioned trader on the validator dex and on selected HIP-3 dexes, found
  through the info API: `markPx` and `szi` scale as `capture()` assumes,
  `capture()` from a zero baseline equals `|szi|·markPx/1e4`, a shrink from a
  held baseline pays at the lower of the stored and live marks and stores the
  live mark, and an unchanged capture only raises the stored mark.
- The minter's drand verifier accepts the latest evmnet round, and the script
  reports its gas.

Deployment:

- **Local Anvil:** `script/local-deploy.sh` — etches and seeds the L1Read
  precompiles the minter's capture path reads, then deploys.
- **HyperEVM mainnet:** `script/deploy.sh` — deploys via raw
  `cast send --create`, so every step runs on the real chain rather than in
  Foundry's local simulator, which lacks the L1Read precompiles. The deployer is a
  Foundry keystore account (`cast wallet import hypow-deployer --interactive`),
  and every genesis parameter must be passed explicitly — they are immutable.
  `TARGET_INTERVAL_SECONDS` is in seconds of `block.timestamp`, not HyperCore L1
  blocks (those advance ~13-16 per second):

  ```bash
  DEPLOYER_ACCOUNT=hypow-deployer RPC_URL=https://rpc.hyperliquid.xyz/evm \
  GENESIS_DIFFICULTY=1 TARGET_INTERVAL_SECONDS=60 RETARGET_WINDOW=2016 \
  script/deploy.sh
  ```

