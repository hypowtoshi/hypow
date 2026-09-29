// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHypowToken} from "./interfaces/IHypowToken.sol";
import {L1Read} from "./lib/L1Read.sol";
import {Emission} from "./lib/Emission.sol";
import {BLS} from "bls-solidity/libraries/BLS.sol";

/// @title HypowMinter (v5, credit bank + drand lottery)
/// @notice Sole authorized minter for HypowToken. Implements Proof of Trade by
///         observation: a member trades natively on Hyperliquid through any path,
///         and this contract reads their HyperCore positions via L1Read
///         precompiles. The realised |Δszi|·markPx volume is banked as credits.
///         Credits are then committed into a draw on a FUTURE drand round, and
///         the round's verified BLS signature decides whether the draw won.
///
///         Why the future round: any seed that is public when credits are
///         committed can be ground by splitting volume across identities.
///         drand round R is published only 3–6 s after `spend` commits to
///         it, so nothing about the outcome is knowable at commit time, and
///         splitting k credits over N addresses gives the same total win chance
///         as one draw.
///
///         Flow:
///           - `capture(member, assets)` — the member, or the one spender the
///             member authorized. Banks the member's realised volume into
///             `credits[member]`. A member delegated to a pool can be captured
///             only by that pool, and the credits go into the pool's bank
///             instead, which the pool spends like any owner.
///           - `spend(owner, maxK)` — the owner, or the one spender the owner
///             authorized. Captures the owner's tracked assets, then moves up to
///             `maxK` banked credits into a draw on round `targetRound()`.
///           - `settle(owner, round, signature, nonce)` — permissionless. Verifies
///             drand's signature for `round`; ticket `nonce` of the draw wins iff
///             keccak256(seed, owner, nonce) < 2^256/difficulty. A win mints the
///             block reward to the owner.
///
///         A cashed win on drand round R closes R and every earlier round
///         (`lastWonRound`). Nothing else closes a draw and there is no deadline:
///         a draw can't die before its round is published, and the next win on a
///         later round acts as the deadline. So a winner must cash before anyone
///         cashes a later round, instead of holding a known win for a convenient
///         moment (e.g. around a retarget).
///
///         This contract is the only minter ever authorized by HypowToken.
///         No governance, no admin, no upgrade authority. The contract holds
///         nothing; members' funds never leave their HyperCore accounts.
contract HypowMinter {
    // ------------------------------------------------------------------
    // Configuration (immutable)
    // ------------------------------------------------------------------

    IHypowToken public immutable token;

    /// @dev Genesis difficulty. Bounded by uint128 max.
    uint128 public immutable genesisDifficulty;

    /// @dev Target inter-win interval, in seconds of `block.timestamp`. e.g. 60 →
    ///      one win per minute. Seconds, not HyperCore L1 blocks: the L1 block
    ///      number advances ~13.5/s on mainnet and ~16/s on testnet (measured
    ///      2026-09-24), a rate that differs per network and can change with
    ///      Hyperliquid upgrades.
    uint64 public immutable targetIntervalSeconds;

    /// @dev Retarget cadence, in number of wins (Bitcoin uses 2016).
    uint32 public immutable retargetWindow;

    /// @dev Multiplicative cap on per-retarget difficulty movement. Also the
    ///      crash escape's trigger: a window that has run this many times its
    ///      whole target time retargets early.
    uint8 public constant RETARGET_CLAMP = 4;

    /// @dev drand evmnet (scheme bls-bn254-unchained-on-g1). Round r is
    ///      published at DRAND_GENESIS + (r − 1)·DRAND_PERIOD.
    uint256 public constant DRAND_GENESIS = 1727521075;
    uint256 public constant DRAND_PERIOD = 3;

    /// @dev How many rounds ahead of the latest published one a spend targets.
    ///      Two rounds put the target 3–6 s in the future, which absorbs the
    ///      sub-second lag of HyperEVM's block.timestamp behind wall time.
    uint64 public constant ROUND_LEAD = 2;

    /// @dev Hash-to-curve domain separation tag drand evmnet signs under.
    bytes public constant DRAND_DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    /// @dev drand evmnet group public key (G2), chain hash 04f1e906…8c3, as served
    ///      by api.drand.sh/v2/beacons/evmnet/info (bytes x1‖x0‖y1‖y0). Four
    ///      constants because a struct cannot be constant. Hardcoded rather than
    ///      a constructor argument so the beacon a deployment trusts is fixed in
    ///      reviewed source. No on-G2 check at construction: a constant can't
    ///      change per deploy, so the unit tests check it once, and verify real
    ///      evmnet signatures against it.
    uint256 internal constant _DRAND_KEY_X0 = 0x0557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f;
    uint256 internal constant _DRAND_KEY_X1 = 0x07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382;
    uint256 internal constant _DRAND_KEY_Y0 = 0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b;
    uint256 internal constant _DRAND_KEY_Y1 = 0x0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6;

    bytes32 internal constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant SET_SPENDER_TYPEHASH =
        keccak256("SetSpender(address owner,address spender,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_CREDIT_DELEGATE_TYPEHASH =
        keccak256("SetCreditDelegate(address owner,address pool,uint256 nonce,uint256 deadline)");

    /// @dev secp256k1n / 2. Signatures with a higher s are the malleable twin of
    ///      a low-s signature and are rejected (EIP-2).
    uint256 internal constant _SECP256K1N_HALF = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @dev `known` means a baseline exists. An asset is on the member's tracked
    ///      list exactly while `known && lastSnapshotSzi != 0`, so no separate flag
    ///      is kept. `lastMarkPx` is the mark the baseline position is capped
    ///      at: what closing it can earn per unit (see `_captureAsset`). It is uint64 because the markPx
    ///      precompile returns uint64, so every mark it can report is stored
    ///      exactly; the three fields pack into one storage slot.
    struct MemberSlot {
        int64 lastSnapshotSzi;
        bool known;
        uint64 lastMarkPx;
    }

    /// @dev Who cashed the win on a drand round, the difficulty its ticket was
    ///      priced at (before the win's own retarget), and the reward minted.
    ///      Published so a contract owner (a pool) can book its win no matter who
    ///      called `settle`: a contract cannot read its own events, and a balance
    ///      delta only works if the owner triggers the settle itself. A PPLNS pool
    ///      sizes the win's payout window from the difficulty. The reward fits
    ///      uint128 because it never exceeds the token cap.
    struct Win {
        address owner;
        uint128 difficulty;
        uint128 reward;
    }

    /// @notice (member, asset) ⇒ position baseline.
    mapping(address => mapping(uint32 => MemberSlot)) public memberSlots;

    /// @notice member ⇒ assets the member currently holds a non-zero tracked
    ///         position in. Drives `spend`'s capture. Pushed when a position opens
    ///         from a known zero baseline (or is first seen non-zero), swap-removed
    ///         on close, so it self-bounds to the member's concurrently-held perps.
    mapping(address => uint32[]) internal _memberAssets;

    /// @notice owner ⇒ banked credits in cents. Credits never expire.
    mapping(address => uint128) public credits;

    /// @notice owner ⇒ drand round ⇒ credits in the draw. A draw on a round at or
    ///         below `lastWonRound` is closed and can never be cashed.
    mapping(address => mapping(uint64 => uint128)) public draws;

    /// @notice owner ⇒ authorized spender. address(0) means only the owner may spend.
    mapping(address => address) public spender;

    /// @notice member ⇒ pool the member's captures go to. address(0) means solo.
    mapping(address => address) public creditDelegate;

    /// @notice owner ⇒ EIP-712 nonce, shared by both signed permission changes.
    ///         Every permission change (signed or direct) consumes one, so a
    ///         signed authorization the owner has since overridden can't be
    ///         replayed.
    mapping(address => uint256) public nonces;

    /// @notice drand round ⇒ the win cashed on it. At most one per round, since a
    ///         win closes its own round.
    mapping(uint64 => Win) public wonBy;

    /// @notice Current difficulty. A ticket wins iff its hash < 2^256/difficulty.
    uint128 public difficulty;

    /// @notice Number of blocks found so far; indexes the emission curve.
    uint64 public winCount;

    /// @notice Round of the latest cashed win (0 before the first). It and every
    ///         earlier round are closed. Only ever increases.
    uint64 public lastWonRound;

    /// @notice `block.timestamp` of the last retarget (or of deployment).
    uint64 public lastRetargetTime;

    /// @notice `winCount` at the last retarget (0 at deployment).
    uint64 public lastRetargetWinCount;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice First capture of (member, asset): the baseline is recorded at the
    ///         member's current position and nothing is credited, so positions
    ///         held before the first capture never count.
    event AssetRegistered(address indexed member, uint32 indexed asset, int64 baselineSzi);

    /// @notice The asset entered the member's tracked list (a non-zero position).
    event AssetTracked(address indexed member, uint32 indexed asset);

    /// @notice The asset left the tracked list. Either the position closed, and
    ///         its baseline stays known at zero so a re-open is credited from
    ///         zero, or the owner untracked it and the baseline is forgotten.
    event AssetUntracked(address indexed member, uint32 indexed asset);

    /// @notice A capture realised `cents` of the member's volume. `destination`
    ///         is the bank credited: the member's own, or the member's pool's.
    event Captured(address indexed member, address indexed destination, uint128 cents);

    /// @notice `k` credits were committed to `owner`'s draw on `round`; `drawK` is
    ///         the draw's new total.
    event Spent(address indexed owner, uint64 indexed round, uint128 k, uint128 drawK);

    /// @notice Block `winCount` was found by `owner`'s ticket `nonce` on `round`,
    ///         closing `round` and every earlier round.
    event Won(
        address indexed owner,
        uint64 indexed round,
        uint64 indexed winCount,
        uint256 nonce,
        uint256 reward,
        address caller
    );

    event SpenderSet(address indexed owner, address indexed spender);

    /// @notice `pool` is the normalised value (address(0) for solo).
    event CreditDelegated(address indexed member, address indexed pool);

    event DifficultyRetargeted(uint128 oldDifficulty, uint128 newDifficulty);

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    constructor(IHypowToken _token, uint128 _genesisDifficulty, uint64 _targetIntervalSeconds, uint32 _retargetWindow) {
        require(address(_token) != address(0), "token zero");
        require(_genesisDifficulty > 0, "difficulty zero");
        require(_targetIntervalSeconds > 0, "interval zero");
        require(_retargetWindow > 0, "window zero");

        token = _token;
        genesisDifficulty = _genesisDifficulty;
        targetIntervalSeconds = _targetIntervalSeconds;
        retargetWindow = _retargetWindow;

        difficulty = _genesisDifficulty;
        // forge-lint: disable-next-line(unsafe-typecast)
        lastRetargetTime = uint64(block.timestamp);
    }

    // ------------------------------------------------------------------
    // Capture
    // ------------------------------------------------------------------

    /// @notice Snapshot `member`'s positions in `assets` and realise the volume
    ///         since each baseline. Solo: banked into `credits[member]`, and
    ///         callable only by the member or `spender[member]`, like `spend`.
    ///         Only they can spend the bank, so a stranger's capture helps
    ///         nobody; it could only pick the mark that prices the member's
    ///         volume (e.g. capping a held position's next close at a dip) or
    ///         register assets the member never asked for. Pooled: banked into
    ///         `credits[pool]`, which the pool spends as an ordinary owner, and
    ///         callable only by the pool, so the pool books the member's share in
    ///         the same transaction.
    ///
    ///         A pooled capture once went straight into the pool's draw, because
    ///         the pool kept its ledger per draw round and needed the round back.
    ///         A draw wins at most one block, so a large one wasted most of its
    ///         winning tickets. A PPLNS pool books by credits contributed instead
    ///         of by round, so it can bank and size its own draws.
    /// @return k The cents captured.
    function capture(address member, uint32[] calldata assets) external returns (uint128 k) {
        require(member != address(0), "member zero");
        address pool = creditDelegate[member];
        if (pool != address(0)) require(msg.sender == pool, "pooled capture by pool only");
        else _requireSpender(member);

        uint256 total;
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; i++) {
            uint32 asset = assets[i];
            total += _captureAsset(member, asset, L1Read.position2(member, asset).szi);
        }
        k = _toU128Sat(total);
        _bank(member, pool == address(0) ? member : pool, k);
    }

    /// @dev Capture every tracked asset of `owner` into their bank. Iterates a
    ///      memory copy because closing positions swap-remove from the stored list.
    ///      An unreadable asset (e.g. a removed HIP-3 market) is skipped, leaving
    ///      its slot untouched, so one dead asset can't brick the owner's spends.
    function _captureTracked(address owner) internal {
        uint32[] memory list = _memberAssets[owner];
        uint256 total;
        for (uint256 i = 0; i < list.length; i++) {
            (bool ok, L1Read.Position memory pos) = L1Read.tryPosition2(owner, list[i]);
            if (ok) total += _captureAsset(owner, list[i], pos.szi);
        }
        _bank(owner, owner, _toU128Sat(total));
    }

    /// @dev Credit `k` of `member`'s realised volume to `dest`'s bank.
    function _bank(address member, address dest, uint128 k) internal {
        if (k == 0) return;
        credits[dest] = _toU128Sat(uint256(credits[dest]) + k);
        emit Captured(member, dest, k);
    }

    /// @dev Register-or-advance one (member, asset) baseline to `current` and
    ///      return the realised cents. Without a mark price the baseline is held
    ///      and nothing is credited. Keeps the tracked list equal to the set of
    ///      known assets with a non-zero baseline.
    ///
    ///      Pricing: the part of the change that reduces the baseline position
    ///      (a close, a partial close, or the closing leg of a flip) is valued
    ///      at the lower of the current mark and the mark stored by the slot's
    ///      last priced capture. The part that increases it (an open, an add,
    ///      or the opening leg of a flip) is valued at the current mark, as a
    ///      fresh open always was. Why: a HIP-3 market's deployer posts its
    ///      mark. Without the cap, wash legs opened and captured at $1, then
    ///      closed (or settled by `haltTrading`) uncaptured, could be captured
    ///      after the deployer ramps the now-empty market to 10×, earning the
    ///      close at $10 with no position at risk.
    ///
    ///      The stored mark: after a change it is the current mark. A capture
    ///      of an unchanged position may only raise it, so a capture during a
    ///      dip can't lower the cap on the position's next close, while a
    ///      capture after a rise lifts it, and an honest close loses at most
    ///      the rise since the last capture. A change must store the current
    ///      mark, never the max: otherwise a tiny leftover position could keep
    ///      an old high mark as the cap for a large position added later.
    function _captureAsset(address member, uint32 asset, int64 current) internal returns (uint128 cents) {
        MemberSlot storage slot = memberSlots[member][asset];

        if (!slot.known) {
            L1Read.PerpAssetInfo memory info = L1Read.perpAssetInfo(asset);
            // Only perps have maxLeverage > 0. Spot ids passed to the perp
            // precompile either revert (L1Read's require) or return a zeroed
            // struct; either way they fail here.
            require(info.maxLeverage > 0, "not a perp");
            // Defends against pathological returns; 24 is well above any real
            // perp's szDecimals.
            require(info.szDecimals <= 24, "szDecimals too large");

            // Baseline at the CURRENT position with no credit: positions held
            // before a member's first capture don't count (otherwise anyone
            // holding a large position at launch gets a free bank). A flat first
            // touch records a zero baseline so the next open counts in full, but
            // is not tracked, so registering cannot spam the list.
            slot.known = true;
            slot.lastSnapshotSzi = current;
            emit AssetRegistered(member, asset, current);
            if (current != 0) {
                _track(member, asset);
                // A failed read leaves 0, so a close captured before any priced
                // capture of the position earns nothing rather than an
                // uncapped mark.
                (, slot.lastMarkPx) = L1Read.tryMarkPx(asset);
            }
            return 0;
        }

        int64 prev = slot.lastSnapshotSzi;
        if (current == 0 && prev == 0) return 0;

        // No price (delisted/halted/removed market): skip rather than brick, and
        // hold the baseline, tracking included, so the volume is credited at the
        // next good read instead of being lost to whoever captured during the
        // outage.
        (bool ok, uint64 mark) = L1Read.tryMarkPx(asset);
        if (!ok || mark == 0) return 0;

        uint64 last = slot.lastMarkPx;
        if (current == prev) {
            if (mark > last) slot.lastMarkPx = mark;
            return 0;
        }
        slot.lastSnapshotSzi = current;
        slot.lastMarkPx = mark;
        if (prev == 0) _track(member, asset);
        else if (current == 0) _evict(member, asset);
        return _deltaCents(prev, current, last < mark ? last : mark, mark);
    }

    /// @notice Drop `asset` from `owner`'s tracked list and forget its baseline.
    ///         Only the owner or `spender[owner]`, like `spend`. For a market that
    ///         can no longer be read (e.g. a removed HIP-3 venue): `spend` skips
    ///         it but can never evict it, so its loop would pay for it forever.
    ///         The next capture of the asset re-baselines at the then-current
    ///         position with no credit, so the untracked position is never
    ///         credited, and any volume since its last capture is forfeited.
    function untrack(address owner, uint32 asset) external {
        _requireSpender(owner);
        MemberSlot storage slot = memberSlots[owner][asset];
        require(slot.known && slot.lastSnapshotSzi != 0, "not tracked");
        delete memberSlots[owner][asset];
        _evict(owner, asset);
    }

    function _track(address member, uint32 asset) internal {
        _memberAssets[member].push(asset);
        emit AssetTracked(member, asset);
    }

    /// @dev Swap-remove `asset` from `member`'s tracked list. The list is small
    ///      (currently-held perps), so the linear scan is cheap next to the
    ///      precompile reads around it. The slot is left to the caller.
    function _evict(address member, uint32 asset) internal {
        uint32[] storage list = _memberAssets[member];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            if (list[i] == asset) {
                list[i] = list[n - 1];
                list.pop();
                break;
            }
        }
        emit AssetUntracked(member, asset);
    }

    /// @dev Cents for `prev` → `current`: the reduced size (|prev| on a flip,
    ///      else how much |szi| shrank) at `reducePx`, plus the increased size
    ///      (|current| on a flip, else how much |szi| grew) at `increasePx`,
    ///      each |size| × markPx / 10^4.
    ///
    ///      Derivation: Hyperliquid's `markPx` precompile returns the price scaled
    ///      by 10^(6 − szDecimals), and `szi` is scaled by 10^szDecimals. The two
    ///      szDecimals cancel:
    ///          usd   = (|Δszi|/10^szDecimals) × (markPx/10^(6−szDecimals))
    ///                = (|Δszi| × markPx) / 10^6
    ///          cents = usd × 100 = (|Δszi| × markPx) / 10^4
    ///      so the divisor is a constant 10_000, independent of szDecimals.
    function _deltaCents(int64 prev, int64 current, uint64 reducePx, uint64 increasePx)
        internal
        pure
        returns (uint128)
    {
        uint256 p = _abs(prev);
        uint256 c = _abs(current);
        uint256 reduced;
        uint256 increased;
        if ((prev < 0 && current > 0) || (prev > 0 && current < 0)) {
            (reduced, increased) = (p, c);
        } else if (c >= p) {
            increased = c - p;
        } else {
            reduced = p - c;
        }
        return _toU128Sat((reduced * uint256(reducePx) + increased * uint256(increasePx)) / 10_000);
    }

    function _abs(int64 x) internal pure returns (uint256) {
        // int256 holds -type(int64).min, so the negation can't overflow.
        // forge-lint: disable-next-line(unsafe-typecast)
        return x >= 0 ? uint256(int256(x)) : uint256(-int256(x));
    }

    /// @dev Clamp to uint128, saturating at the max rather than overflowing.
    function _toU128Sat(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) return type(uint128).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    // ------------------------------------------------------------------
    // Spend
    // ------------------------------------------------------------------

    /// @notice Move up to `maxK` of `owner`'s banked credits into their draw on
    ///         `targetRound()`. Only the owner or `spender[owner]` may call it:
    ///         when and how much to spend (e.g. saving through a high difficulty)
    ///         is the owner's decision. The reward of any win always mints to the
    ///         owner. Taking a maximum rather than an exact
    ///         amount lets a client quote k from a view without reverting when the
    ///         bank moved before inclusion. k == 0 is a no-op returning zeros.
    ///
    ///         The target must be open (above `lastWonRound`), else this reverts:
    ///         a draw on a closed round can never settle, so the credits would
    ///         burn. Normally the target is ROUND_LEAD rounds past the latest
    ///         published round, which bounds `lastWonRound`; only a block
    ///         timestamp lagging wall time by more than ~3 s (beyond the spec's
    ///         lag assumption) reaches the revert.
    /// @return round The drand round the draw targets.
    /// @return k The credits committed.
    function spend(address owner, uint128 maxK) external returns (uint64 round, uint128 k) {
        _requireSpender(owner);

        // A delegated owner's fresh volume belongs to the pool; only the credits
        // banked before joining are spent solo.
        if (creditDelegate[owner] == address(0)) _captureTracked(owner);

        uint128 bank = credits[owner];
        k = maxK < bank ? maxK : bank;
        if (k == 0) return (0, 0);
        credits[owner] = bank - k;
        round = targetRound();
        require(round > lastWonRound, "round closed");
        uint128 drawK = _toU128Sat(uint256(draws[owner][round]) + k);
        draws[owner][round] = drawK;
        emit Spent(owner, round, k, drawK);
    }

    function _requireSpender(address owner) internal view {
        address allowed = spender[owner];
        require(msg.sender == owner || (allowed != address(0) && msg.sender == allowed), "not spender");
    }

    // ------------------------------------------------------------------
    // Settle
    // ------------------------------------------------------------------

    /// @notice Cash ticket `nonce` of `owner`'s draw on `round`, given drand's
    ///         signature for that round. Permissionless: the reward always mints
    ///         to the owner.
    ///
    ///         Settle either mints or reverts. Only a win changes state. A draw on
    ///         a closed round (`round <= lastWonRound`) reverts rather than being
    ///         deleted, so a caller never pays for a no-op; its slot is harmless,
    ///         since no spend can reach a closed round again. A losing ticket
    ///         reverts and must NOT delete the draw: the draw holds k tickets, and
    ///         one losing nonce says nothing about the others, so deleting would
    ///         let anyone void a winning draw.
    ///
    ///         The ticket is priced at the CURRENT difficulty. Difficulty moves
    ///         only on a win, and any win cashed since this draw was bought is on
    ///         an earlier round (an equal or later one would have closed it).
    ///
    ///         The seed is keccak256 of the 64-byte signature (x‖y, as served by
    ///         the drand API). Coordinates are checked to be < p, so the encoding
    ///         is canonical and the seed is unique per round. It is NOT drand's
    ///         published `randomness` field (the sha256 of the signature):
    ///         off-chain tools searching for a winning nonce must hash the
    ///         `signature` with keccak256 themselves.
    /// @return reward The amount minted to `owner`.
    function settle(address owner, uint64 round, bytes calldata signature, uint256 nonce)
        external
        returns (uint256 reward)
    {
        require(round > lastWonRound, "round closed");
        uint128 k = draws[owner][round];
        require(k > 0, "no draw");
        require(nonce >= 1 && nonce <= k, "nonce out of range");

        bytes32 seed = _verifiedSeed(round, signature);
        uint128 d = difficulty;
        require(uint256(keccak256(abi.encode(seed, owner, nonce))) < _target(d), "ticket loses");

        // Effects before the mint (CEI).
        delete draws[owner][round];
        lastWonRound = round;
        uint64 wc = winCount;
        winCount = wc + 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        _maybeRetarget(uint64(block.timestamp));

        // Clamped to remaining cap room. With the deployed R0/λ the emission
        // total asymptotes below the cap, so this is defensive: it keeps a
        // re-tuned curve from bricking settles.
        reward = Emission.currentReward(wc);
        uint256 remaining = token.CAP() - token.totalSupply();
        if (reward > remaining) reward = remaining;
        // forge-lint: disable-next-line(unsafe-typecast)
        wonBy[round] = Win({owner: owner, difficulty: d, reward: uint128(reward)});
        if (reward > 0) token.mint(owner, reward);

        emit Won(owner, round, wc, nonce, reward, msg.sender);
    }

    /// @dev Verify drand evmnet's BLS signature on `round` and derive the seed.
    ///      The signed message is keccak256(uint64 round, 8 bytes big-endian),
    ///      hashed to G1 under DRAND_DST. Rejects signatures that are not valid G1
    ///      points before pairing (BN254 G1 has cofactor 1, so on-curve ⇒ in group).
    ///
    ///      Virtual only so the Halmos settle proofs can stand in for the pairing
    ///      check, which Halmos cannot execute (it has no concrete modexp). Nothing
    ///      overrides it in production; the real verifier is exercised against
    ///      committed drand fixtures in the unit tests.
    function _verifiedSeed(uint64 round, bytes calldata signature) internal view virtual returns (bytes32) {
        BLS.PointG1 memory sig = BLS.g1Unmarshal(signature);
        require(BLS.isValidPointG1(sig), "signature not on G1");
        BLS.PointG1 memory message = BLS.hashToPoint(DRAND_DST, abi.encodePacked(keccak256(abi.encodePacked(round))));
        BLS.PointG2 memory key = _drandKey();
        (bool pairingOk, bool callOk) = BLS.verifySingle(sig, key, message);
        require(pairingOk && callOk, "bad drand signature");
        return keccak256(signature);
    }

    function _drandKey() internal pure returns (BLS.PointG2 memory) {
        return BLS.PointG2([_DRAND_KEY_X0, _DRAND_KEY_X1], [_DRAND_KEY_Y0, _DRAND_KEY_Y1]);
    }

    // ------------------------------------------------------------------
    // Permissions
    // ------------------------------------------------------------------

    /// @notice Authorize `newSpender` as the only non-owner allowed to spend the
    ///         caller's bank. address(0) revokes, leaving the owner alone.
    function setSpender(address newSpender) external {
        _setSpender(msg.sender, newSpender);
    }

    /// @notice `setSpender` authorised by the owner's EIP-712
    ///         SetSpender{owner, spender, nonce, deadline} signature, so the
    ///         owner's wallet needs no HyperEVM gas. Valid until `deadline`
    ///         (a unix timestamp, inclusive).
    function setSpenderBySig(
        address owner,
        address newSpender,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkSig(
            owner,
            keccak256(abi.encode(SET_SPENDER_TYPEHASH, owner, newSpender, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _setSpender(owner, newSpender);
    }

    /// @notice Join `pool` (the caller's captures go to its bank) or leave with
    ///         address(0) or your own address. Credits already banked stay in the
    ///         bank. No re-baselining is needed: capture timing no longer matters,
    ///         so a switch simply changes where the next capture's delta goes.
    function setCreditDelegate(address pool) external {
        _setCreditDelegate(msg.sender, pool);
    }

    /// @notice `setCreditDelegate` authorised by the owner's EIP-712
    ///         SetCreditDelegate{owner, pool, nonce, deadline} signature. Valid
    ///         until `deadline` (a unix timestamp, inclusive).
    function setCreditDelegateBySig(
        address owner,
        address pool,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _checkSig(
            owner,
            keccak256(abi.encode(SET_CREDIT_DELEGATE_TYPEHASH, owner, pool, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _setCreditDelegate(owner, pool);
    }

    function _setSpender(address owner, address newSpender) internal {
        spender[owner] = newSpender;
        nonces[owner]++;
        emit SpenderSet(owner, newSpender);
    }

    function _setCreditDelegate(address member, address pool) internal {
        address dest = pool == member ? address(0) : pool;
        creditDelegate[member] = dest;
        nonces[member]++;
        emit CreditDelegated(member, dest);
    }

    /// @notice EIP-712 domain separator. Binds chain id and this contract, so a
    ///         signature is valid on exactly one deployment on one chain.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(_DOMAIN_TYPEHASH, keccak256("HypowMinter"), keccak256("5"), block.chainid, address(this))
            );
    }

    /// @dev Require `signature` to be `owner`'s ECDSA signature over the typed
    ///      struct at the owner's current nonce, not past its deadline. EOA
    ///      signers only.
    function _checkSig(address owner, bytes32 structHash, uint256 nonce, uint256 deadline, bytes calldata signature)
        internal
        view
    {
        require(block.timestamp <= deadline, "signature expired");
        require(nonce == nonces[owner], "bad nonce");
        require(signature.length == 65, "bad signature length");
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        require(uint256(s) <= _SECP256K1N_HALF, "signature s too high");
        require(v == 27 || v == 28, "bad signature v");
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == owner, "bad signature");
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The latest drand round published at time `t`.
    function drandRound(uint256 t) public pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64((t - DRAND_GENESIS) / DRAND_PERIOD + 1);
    }

    /// @notice The round a spend in this block commits to: not yet published.
    function targetRound() public view returns (uint64) {
        return drandRound(block.timestamp) + ROUND_LEAD;
    }

    /// @notice Number of assets `member` currently tracks.
    function memberAssetsLength(address member) external view returns (uint256) {
        return _memberAssets[member].length;
    }

    /// @notice Index `i` of `member`'s tracked list. Reverts out of bounds.
    function memberAssets(address member, uint256 index) external view returns (uint32) {
        return _memberAssets[member][index];
    }

    // ------------------------------------------------------------------
    // Difficulty retargeting
    // ------------------------------------------------------------------

    /// @dev The threshold below which a ticket hash wins at difficulty D.
    function _target(uint128 D) internal pure returns (uint256) {
        unchecked {
            return type(uint256).max / uint256(D);
        }
    }

    /// @dev Retarget after `retargetWindow` wins, or early once the current
    ///      window has run RETARGET_CLAMP× the whole window's target time (the
    ///      crash escape). Either way difficulty scales by expected/actual
    ///      elapsed seconds, expected being the window's wins so far times the
    ///      target interval, clamped to RETARGET_CLAMP× either way. At a full
    ///      window this is Bitcoin's rule exactly; an escape always hits the
    ///      clamp and divides by RETARGET_CLAMP. Called once per win after the
    ///      increment. Arithmetic is widened to uint256 so pathological deploy
    ///      params can't overflow.
    ///
    ///      Why the escape: after a ~98% drop in mining volume, wins slow ~50×,
    ///      so a full window would take ~70 days on mainnet and recovery ~3
    ///      months. The escape needs 4× the whole window's target time (~5.6
    ///      days on mainnet), not a short fixed delay: Bitcoin Cash's 2017 EDA
    ///      fired after 12 h and was gamed by hash power leaving and returning.
    ///
    ///      The clock is `block.timestamp`, which the contract already trusts
    ///      for the drand target round. Validators can skew it by only seconds,
    ///      negligible against a 2016-minute window; a timestamp that fails to
    ///      advance is floored to one second elapsed.
    function _maybeRetarget(uint64 nowTime) internal {
        uint64 last = lastRetargetTime;
        uint256 elapsed = nowTime > last ? uint256(nowTime - last) : uint256(1);
        uint256 wins = winCount - lastRetargetWinCount;
        uint256 windowTime = uint256(retargetWindow) * uint256(targetIntervalSeconds);
        if (wins < retargetWindow && elapsed < windowTime * RETARGET_CLAMP) return;

        uint256 expected = wins * uint256(targetIntervalSeconds);
        uint256 minElapsed = expected / RETARGET_CLAMP;
        uint256 maxElapsed = expected * RETARGET_CLAMP;
        if (elapsed < minElapsed) elapsed = minElapsed;
        if (elapsed > maxElapsed) elapsed = maxElapsed;

        uint128 old = difficulty;
        uint256 next = (uint256(old) * expected) / elapsed;
        if (next == 0) next = 1;
        if (next > type(uint128).max) next = type(uint128).max;

        // forge-lint: disable-next-line(unsafe-typecast)
        difficulty = uint128(next);
        lastRetargetTime = nowTime;
        lastRetargetWinCount = winCount;
        // forge-lint: disable-next-line(unsafe-typecast)
        emit DifficultyRetargeted(old, uint128(next));
    }
}
