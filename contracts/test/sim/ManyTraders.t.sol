// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {HypowToken} from "../../src/HypowToken.sol";
import {Emission} from "../../src/lib/Emission.sol";
import {TestPool} from "../utils/TestPool.sol";
import {SimBase, SimMinter, SimDrand} from "./SimBase.sol";

/// @dev Drives a many-trader world: 30 solo traders plus 10 who can join or
///      leave either of two test pools (the delegation hook's contract
///      delegates), three perps, a keeper and an outsider. Every action is
///      checked against an independent model of the minter (position baselines,
///      banks including the pools', draws, difficulty, emission): the model
///      predicts each call's outcome, including the exact revert reason, and the
///      handler asserts the contract agreed. The invariant then re-checks the
///      whole state after every step.
///
///      Settle is modelled from the chain's point of view: a draw can be
///      settled only once its round is published, a win on round R closes R
///      and every earlier round, and clients sometimes settle late, sometimes
///      withhold a known win and cash it later (losing it if a later round was
///      cashed first), and sometimes race a rival on the same round.
contract SimHandler is SimBase {
    uint256 public constant SOLO = 30;
    uint256 public constant POOLABLE = 10;
    uint256 public constant N = SOLO + POOLABLE;
    uint64 public constant TARGET = 60;
    uint32 public constant WINDOW = 10;
    /// Most tickets a client scans for a win in one draw.
    uint256 constant SCAN_CAP = 4096;
    uint256 constant MAX_HELD = 16;
    address public constant KEEPER = address(0xC0FFEE);
    address public constant OUTSIDER = address(0x0B5E);

    SimMinter public minter;
    HypowToken public token;
    TestPool[2] public pools;
    address[] public actors;

    // ----- model: capture -----
    struct Slot {
        int64 base;
        bool known;
        uint64 mark;
    }

    uint64[3] baseMark = [uint64(1_000), 300_000, 1_500_000];
    /// Largest position move per trade, ~$20 at the base mark.
    int64[3] maxMove = [int64(20_000), 60, 12];
    uint64[3] public mMark;
    mapping(address => mapping(uint32 => int64)) public mPos;
    mapping(address => mapping(uint32 => Slot)) internal mSlot;

    // ----- model: banks, draws, permissions -----
    mapping(address => uint256) public mBank;
    mapping(address => address) public mDelegate;
    mapping(address => address) public mSpender;
    mapping(address => mapping(uint64 => uint256)) public mDraw;
    mapping(address => uint256) public mBal;

    struct Key {
        address owner;
        uint64 round;
    }

    /// Draws on open rounds, and draws frozen by a win on their round or later.
    Key[] public openKeys;
    Key[] public frozenKeys;
    mapping(address => mapping(uint64 => bool)) keySeen;
    uint256 public frozenSum;

    /// Σ realised volume, and the part consumed by cashed wins.
    uint256 public captured;
    uint256 public wonK;

    // ----- model: wins, difficulty, emission -----
    uint64 public mLastWon;
    uint64 public mWinCount;
    uint128 public mDiff;
    uint64 public mLastRetarget;
    uint64 public mLastRetargetWin;
    uint256 public minted;
    uint64[] public wonRounds;
    mapping(uint64 => address) public mWonBy;
    mapping(uint64 => uint256) public mWonReward;
    mapping(uint64 => uint128) public mWonDiff;

    struct Held {
        address owner;
        uint64 round;
        uint256 nonce;
    }

    Held[] held;

    // ----- stats -----
    uint256 public steps;
    uint256 public retargets;
    uint256 public escapes;
    uint256 public racesLost;
    uint256 public heldCashed;
    uint256 public heldLost;
    uint256 public closedRejected;
    uint256 public poolWins;
    uint64 public firstRound;

    constructor(SimMinter m, HypowToken t, uint128 genesisDiff) {
        minter = m;
        token = t;
        mDiff = genesisDiff;
        mLastRetarget = uint64(block.timestamp);
        firstRound = m.targetRound();
        _setPerpAssetInfo(2, 2);
        for (uint32 a = 0; a < 3; a++) {
            _mark(a, baseMark[a]);
        }
        for (uint256 p = 0; p < 2; p++) {
            pools[p] = new TestPool(m);
        }
        // Every trader onboards flat in all three perps, so its first trade
        // already counts, then half authorize the keeper and the last ten join
        // a pool.
        uint32[] memory all = _assets(6);
        for (uint256 i = 0; i < N; i++) {
            address a = _addr(0x10000, i);
            actors.push(a);
            _mCaptureAll(a, all);
            vm.prank(a);
            m.capture(a, all);
            if (i % 2 == 0) _setSpenderTo(a, KEEPER);
            if (i >= SOLO) _delegate(a, address(pools[(i - SOLO) / 5]));
        }
    }

    modifier step() {
        steps++;
        _;
        _sweepClosed();
    }

    // ==================================================================
    // Actions
    // ==================================================================

    /// Move a trader's position in one perp: a random move, a close, or a flip.
    /// Half the time the trader's client captures the perp straight after, and
    /// half of those it also spends the whole bank.
    function trade(uint256 ti, uint256 ai, int256 move, uint256 mode) external step {
        address t = _actor(ti);
        uint32 a = _perp(ai);
        int64 cur = mPos[t][a];
        int64 next;
        if (mode % 8 == 0) {
            next = 0;
        } else if (mode % 8 == 1) {
            next = -cur;
        } else {
            int64 m = maxMove[a];
            // forge-lint: disable-next-line(unsafe-typecast)
            next = int64(_bound(int256(cur) + _bound(move, -int256(m), int256(m)), -50 * int256(m), 50 * int256(m)));
        }
        mPos[t][a] = next;
        _setPosition(t, a, next);
        if (mode % 16 >= 8) return;
        _capture(t, _a(a), mode / 16);
        if (mode % 16 < 4) _spend(t, t, 0);
    }

    /// Capture a trader's chosen perps: into the trader's bank when solo (the
    /// owner or its spender; anyone else must revert), into the pool's bank
    /// through the pool when pooled (anyone may call the pool).
    function capture(uint256 ti, uint256 mask, uint256 ci) external step {
        _capture(_actor(ti), _assets(mask), ci);
    }

    function _capture(address t, uint32[] memory assets, uint256 ci) internal {
        address pool = mDelegate[t];
        if (pool == address(0)) {
            address caller = _spendCaller(t, ci);
            if (!_mayspend(t, caller)) {
                vm.prank(caller);
                vm.expectRevert(bytes("not spender"));
                minter.capture(t, assets);
                return;
            }
            uint256 k = _mCaptureAll(t, assets);
            vm.prank(caller);
            assertEq(minter.capture(t, assets), k, "solo capture k");
            mBank[t] += k;
            captured += k;
            return;
        }
        if (ci % 4 == 0) {
            // Nobody but the pool may capture a pooled member.
            vm.prank(_anyone(ci / 4));
            vm.expectRevert(bytes("pooled capture by pool only"));
            minter.capture(t, assets);
            return;
        }
        uint256 k2 = _mCaptureAll(t, assets);
        vm.prank(_anyone(ci / 4));
        assertEq(TestPool(pool).contribute(t, assets), k2, "pooled capture k");
        mBank[pool] += k2;
        captured += k2;
    }

    /// Spend some, all or none of a bank, as the owner, its spender, or an
    /// unauthorized caller (which must revert).
    function spend(uint256 ti, uint256 amount, uint256 ci) external step {
        address t = _actor(ti);
        _spend(t, _spendCaller(t, ci), amount);
    }

    function _spend(address t, address caller, uint256 amount) internal {
        if (!_mayspend(t, caller)) {
            vm.prank(caller);
            vm.expectRevert(bytes("not spender"));
            minter.spend(t, type(uint128).max);
            return;
        }
        // Spend captures the tracked perps first, unless the owner is pooled.
        uint256 fresh;
        if (mDelegate[t] == address(0)) {
            for (uint32 a = 0; a < 3; a++) {
                if (mSlot[t][a].known && mSlot[t][a].base != 0) fresh += _mCapture(t, a);
            }
        }
        mBank[t] += fresh;
        captured += fresh;
        uint256 maxK = _maxK(mBank[t], amount);
        vm.prank(caller);
        // maxK is uint128 max or at most twice a bank of summed small trades.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint64 round, uint128 got) = minter.spend(t, uint128(maxK));
        _mSpent(t, maxK, round, got);
    }

    /// Spend some, all or none of a pool's bank through the pool (anyone may
    /// ask it to). Nobody else may spend the bank on the minter directly.
    function poolSpend(uint256 pi, uint256 amount, uint256 ci) external step {
        address pool = address(pools[pi % 2]);
        if (ci % 4 == 0) {
            vm.prank(_anyone(ci / 4));
            vm.expectRevert(bytes("not spender"));
            minter.spend(pool, type(uint128).max);
            return;
        }
        uint256 maxK = _maxK(mBank[pool], amount);
        vm.prank(_anyone(ci / 4));
        // As in _spend.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint64 round, uint128 got) = TestPool(pool).spend(uint128(maxK));
        _mSpent(pool, maxK, round, got);
    }

    /// `amount` picks maxK: 0 mod 4 spends the whole bank.
    function _maxK(uint256 bank, uint256 amount) internal pure returns (uint256) {
        if (amount % 4 == 0) return type(uint128).max;
        if (amount % 4 == 1) return 0;
        if (amount % 4 == 2) return bank / 2;
        return _bound(amount, 0, 2 * bank);
    }

    /// Check a spend of up to maxK against the model, then apply it.
    function _mSpent(address owner, uint256 maxK, uint64 round, uint128 got) internal {
        uint256 bank = mBank[owner];
        uint256 k = maxK < bank ? maxK : bank;
        uint64 target = minter.targetRound();
        assertEq(got, k, "spend k");
        assertEq(round, k == 0 ? 0 : target, "spend round");
        mBank[owner] = bank - k;
        if (k > 0) _addDraw(owner, target, k);
    }

    /// A client finds a winning ticket among the published open draws, starting
    /// from a random one (so a later round is sometimes cashed before an earlier
    /// winner, which then loses its win), then withholds it, cashes it, or first
    /// tries a losing ticket. Rivals winning the same round race and lose.
    function settle(uint256 ki, uint256 ci, uint256 mode) external step {
        if (mode % 3 == 0) return _cashAllInOrder(ci);
        uint256 n = openKeys.length;
        uint64 published = minter.drandRound(block.timestamp);
        for (uint256 j = 0; j < n; j++) {
            Key memory key = openKeys[(ki % n + j) % n];
            if (key.round > published || mDraw[key.owner][key.round] == 0) continue;
            uint256 nonce = _firstWin(key.owner, key.round, mDraw[key.owner][key.round], mDiff, SCAN_CAP);
            if (nonce == 0) continue;

            if (mode % 5 == 0 && held.length < MAX_HELD) {
                held.push(Held({owner: key.owner, round: key.round, nonce: nonce}));
                return;
            }
            if (mode % 5 == 1) {
                // A losing ticket (or one past the draw) reverts and leaves the draw.
                _settle(key.owner, key.round, nonce == 1 ? mDraw[key.owner][key.round] + 1 : 1, ci);
            }
            Held[] memory rivals = _rivals(key);
            _settle(key.owner, key.round, nonce, ci);
            for (uint256 r = 0; r < rivals.length; r++) {
                _settle(rivals[r].owner, rivals[r].round, rivals[r].nonce, ci / 2 + r + 1);
            }
            return;
        }
        // No winner published: settling an unpublished round must fail too.
        if (n > 0) {
            Key memory any = openKeys[ki % n];
            _settle(any.owner, any.round, 1, ci);
        }
    }

    /// Every client with a published win cashes it at once, so wins land in
    /// round order: the earliest winning round first, then the next, until
    /// no published open draw holds a winning ticket.
    function _cashAllInOrder(uint256 ci) internal {
        for (uint256 i = 0;; i++) {
            (Key memory key, uint256 nonce) = _earliestWin();
            if (nonce == 0) return;
            _settle(key.owner, key.round, nonce, ci / 2 + i);
            _sweepClosed();
        }
    }

    function _earliestWin() internal view returns (Key memory best, uint256 bestNonce) {
        uint64 published = minter.drandRound(block.timestamp);
        for (uint256 j = 0; j < openKeys.length; j++) {
            Key memory key = openKeys[j];
            uint256 k = mDraw[key.owner][key.round];
            if (key.round > published || k == 0 || (bestNonce > 0 && key.round >= best.round)) continue;
            uint256 nonce = _firstWin(key.owner, key.round, k, mDiff, SCAN_CAP);
            if (nonce == 0) continue;
            best = key;
            bestNonce = nonce;
        }
    }

    /// Cash a withheld win: it lands iff no win on its round or later was
    /// cashed in the meantime.
    function cashHeld(uint256 hi, uint256 ci) external step {
        if (held.length == 0) return;
        uint256 i = hi % held.length;
        Held memory h = held[i];
        held[i] = held[held.length - 1];
        held.pop();
        if (_settle(h.owner, h.round, h.nonce, ci)) heldCashed++;
        else heldLost++;
    }

    /// Try to cash a live draw on a closed round (a lost or never-settled one)
    /// with its best ticket, which would win were the round open.
    function settleClosed(uint256 ki, uint256 ci) external step {
        uint256 n = frozenKeys.length;
        for (uint256 j = 0; j < n; j++) {
            Key memory key = frozenKeys[(ki % n + j) % n];
            uint256 k = mDraw[key.owner][key.round];
            if (k == 0) continue;
            uint256 nonce = _firstWin(key.owner, key.round, k, mDiff, SCAN_CAP);
            _settle(key.owner, key.round, nonce == 0 ? 1 : nonce, ci);
            closedRejected++;
            return;
        }
    }

    function joinPool(uint256 ti, uint256 pi) external step {
        _delegate(actors[SOLO + ti % POOLABLE], address(pools[pi % 2]));
    }

    /// Leave with address(0) or one's own address; both mean solo.
    function leavePool(uint256 ti, uint256 mode) external step {
        address t = actors[SOLO + ti % POOLABLE];
        vm.prank(t);
        minter.setCreditDelegate(mode % 2 == 0 ? address(0) : t);
        mDelegate[t] = address(0);
        assertEq(minter.creditDelegate(t), address(0), "left pool");
    }

    /// Authorize nobody, the keeper, or another trader as spender.
    function setSpender(uint256 ti, uint256 si) external step {
        address t = _actor(ti);
        address s = si % 3 == 0 ? address(0) : si % 3 == 1 ? KEEPER : _actor(ti % N + 1 + si % N);
        _setSpenderTo(t, s);
    }

    /// Mostly a few seconds, sometimes a quiet stretch of up to 10 minutes.
    ///      The fuzzer favours edge values like 0, so the odds are drawn from a
    ///      hash of the input to keep long stretches rare.
    function warp(uint256 dt) external step {
        uint256 r = _mix(dt);
        vm.warp(block.timestamp + (r % 32 == 0 ? _bound(r, 60, 600) : _bound(r, 1, 3)));
    }

    /// Move a perp's mark between 0.5× and 2× of its base; sometimes halt it (0),
    /// and restore it at the next move.
    function setMark(uint256 ai, uint256 px) external step {
        uint32 a = _perp(ai);
        uint256 r = _mix(px);
        // Bounded by 2× a uint64 base mark, so the cast can't truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        _mark(a, r % 10 == 0 && mMark[a] != 0 ? 0 : uint64(baseMark[a] * _bound(r, 50, 200) / 100));
    }

    function _mix(uint256 x) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(x)));
    }

    // ==================================================================
    // Settle, checked against the model
    // ==================================================================

    /// Settle ticket `nonce` of `owner`'s draw on `round` from a random caller,
    /// asserting the outcome (and revert reason) the model predicts. Returns
    /// whether it won.
    function _settle(address owner, uint64 round, uint256 nonce, uint256 ci) internal returns (bool) {
        uint256 k = mDraw[owner][round];
        bytes memory sig = SimDrand.sig(round);
        address caller = _anyone(ci);
        string memory reason = _settleRevertReason(owner, round, nonce, k);
        if (bytes(reason).length > 0) {
            vm.prank(caller);
            vm.expectRevert(bytes(reason));
            minter.settle(owner, round, sig, nonce);
            return false;
        }

        uint128 oldDiff = mDiff;
        uint256 reward = Emission.currentReward(mWinCount);
        uint256 room = token.CAP() - minted;
        if (reward > room) reward = room;
        uint256 callerBefore = token.balanceOf(caller);
        vm.prank(caller);
        assertEq(minter.settle(owner, round, sig, nonce), reward, "reward");

        // Wins are cashed in round order, one per round.
        assertGt(round, mLastWon, "win on a closed round");
        mLastWon = round;
        wonRounds.push(round);
        mWonBy[round] = owner;
        mWonReward[round] = reward;
        mWonDiff[round] = oldDiff;
        if (owner == address(pools[0]) || owner == address(pools[1])) poolWins++;
        wonK += k;
        mDraw[owner][round] = 0;
        minted += reward;
        mBal[owner] += reward;
        mWinCount++;
        if (_mRetarget()) {
            retargets++;
            assertLe(mDiff, uint256(oldDiff) * 4, "retarget above x4");
            assertGe(mDiff, oldDiff / 4, "retarget below /4");
        }
        assertEq(minter.difficulty(), mDiff, "difficulty");
        assertEq(minter.lastWonRound(), round, "lastWonRound");
        if (caller != owner) assertEq(token.balanceOf(caller), callerBefore, "caller was paid");
        return true;
    }

    function _settleRevertReason(address owner, uint64 round, uint256 nonce, uint256 k)
        internal
        view
        returns (string memory)
    {
        if (round <= mLastWon) return "round closed";
        if (k == 0) return "no draw";
        if (nonce < 1 || nonce > k) return "nonce out of range";
        if (round > minter.drandRound(block.timestamp)) return "round not published";
        if (!_wins(owner, round, nonce, mDiff)) return "ticket loses";
        return "";
    }

    /// Up to three other draws on `key`'s round, each with its best ticket (or
    /// ticket 1): they race the cash and must all lose with "round closed".
    function _rivals(Key memory key) internal returns (Held[] memory out) {
        out = new Held[](3);
        uint256 found;
        for (uint256 j = 0; j < openKeys.length && found < 3; j++) {
            Key memory o = openKeys[j];
            if (o.round != key.round || o.owner == key.owner || mDraw[o.owner][o.round] == 0) continue;
            uint256 nonce = _firstWin(o.owner, o.round, mDraw[o.owner][o.round], mDiff, SCAN_CAP);
            if (nonce > 0) racesLost++;
            out[found++] = Held({owner: o.owner, round: o.round, nonce: nonce == 0 ? 1 : nonce});
        }
        assembly ("memory-safe") {
            mstore(out, found)
        }
    }

    /// The minter's retarget, recomputed from the model's own clock: a full
    /// window of wins, or the crash escape once the window has run 4x its
    /// whole target time.
    function _mRetarget() internal returns (bool) {
        uint64 nowT = uint64(block.timestamp);
        uint256 elapsed = nowT > mLastRetarget ? nowT - mLastRetarget : 1;
        uint256 wins = mWinCount - mLastRetargetWin;
        if (wins < WINDOW && elapsed < uint256(WINDOW) * TARGET * 4) return false;
        if (wins < WINDOW) escapes++;
        uint256 expected = wins * TARGET;
        if (elapsed < expected / 4) elapsed = expected / 4;
        if (elapsed > expected * 4) elapsed = expected * 4;
        uint256 next = uint256(mDiff) * expected / elapsed;
        mDiff = uint128(next == 0 ? 1 : next);
        mLastRetarget = nowT;
        mLastRetargetWin = mWinCount;
        return true;
    }

    // ==================================================================
    // Model helpers
    // ==================================================================

    /// The minter's capture of one perp, recomputed: the first touch sets the
    /// baseline and its mark and credits nothing; without a mark the baseline
    /// is held. A priced change records the current mark; a priced unchanged
    /// capture only ever raises the record. The size
    /// by which a change shrinks the held position (all of it on a flip) is
    /// priced at the lower of that record and the current mark, the size by
    /// which it grows (all of the new side on a flip) at the current mark.
    function _mCapture(address m, uint32 a) internal returns (uint256) {
        Slot storage s = mSlot[m][a];
        int64 cur = mPos[m][a];
        uint64 px = mMark[a];
        if (!s.known) {
            s.known = true;
            s.base = cur;
            s.mark = px;
            return 0;
        }
        if (px == 0) return 0;
        if (cur == s.base) {
            if (px > s.mark) s.mark = px;
            return 0;
        }
        uint256 low = s.mark < px ? s.mark : px;
        int256 b = s.base;
        s.base = cur;
        s.mark = px;
        (uint256 closed, uint256 opened) = _mSplit(b, cur);
        return (closed * low + opened * px) / 10_000;
    }

    /// The sizes a change `b` → `c` takes off the old position and adds to it.
    function _mSplit(int256 b, int256 c) internal pure returns (uint256 closed, uint256 opened) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ab = uint256(b > 0 ? b : -b);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ac = uint256(c > 0 ? c : -c);
        if (b * c < 0) return (ab, ac);
        return ac >= ab ? (uint256(0), ac - ab) : (ab - ac, uint256(0));
    }

    function _mCaptureAll(address m, uint32[] memory assets) internal returns (uint256 k) {
        for (uint256 i = 0; i < assets.length; i++) {
            k += _mCapture(m, assets[i]);
        }
    }

    function _addDraw(address owner, uint64 round, uint256 k) internal {
        mDraw[owner][round] += k;
        if (!keySeen[owner][round]) {
            keySeen[owner][round] = true;
            openKeys.push(Key({owner: owner, round: round}));
        }
    }

    /// Move draws whose round a win has closed from the open to the frozen set.
    function _sweepClosed() internal {
        for (uint256 i = openKeys.length; i > 0; i--) {
            Key memory key = openKeys[i - 1];
            if (key.round > mLastWon) continue;
            frozenKeys.push(key);
            frozenSum += mDraw[key.owner][key.round];
            openKeys[i - 1] = openKeys[openKeys.length - 1];
            openKeys.pop();
        }
    }

    function _delegate(address t, address pool) internal {
        vm.prank(t);
        minter.setCreditDelegate(pool);
        mDelegate[t] = pool;
    }

    function _setSpenderTo(address t, address s) internal {
        vm.prank(t);
        minter.setSpender(s);
        mSpender[t] = s;
    }

    function _mark(uint32 a, uint64 px) internal {
        _setMarkPx(a, px);
        mMark[a] = px;
    }

    function _mayspend(address owner, address caller) internal view returns (bool) {
        return caller == owner || (mSpender[owner] != address(0) && caller == mSpender[owner]);
    }

    /// Mostly the owner or its spender, sometimes a stranger.
    function _spendCaller(address owner, uint256 ci) internal view returns (address) {
        if (ci % 5 == 4) return _anyone(ci / 5);
        if (ci % 5 == 3 && mSpender[owner] != address(0)) return mSpender[owner];
        return owner;
    }

    function _anyone(uint256 ci) internal view returns (address) {
        uint256 i = ci % (N + 2);
        return i == N ? KEEPER : i == N + 1 ? OUTSIDER : actors[i];
    }

    function _actor(uint256 i) internal view returns (address) {
        return actors[i % N];
    }

    function _perp(uint256 i) internal pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(i % 3);
    }

    /// A non-empty subset of the three perps.
    function _assets(uint256 mask) internal pure returns (uint32[] memory out) {
        uint256 m = mask % 7 + 1;
        out = new uint32[](3);
        uint256 n;
        for (uint32 a = 0; a < 3; a++) {
            if ((m >> a) & 1 == 1) out[n++] = a;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    // ==================================================================
    // Views for the invariant
    // ==================================================================

    function openKeysLength() external view returns (uint256) {
        return openKeys.length;
    }

    function frozenKeysLength() external view returns (uint256) {
        return frozenKeys.length;
    }

    function wonRoundsLength() external view returns (uint256) {
        return wonRounds.length;
    }

    /// Model count of tracked perps: known with a non-zero baseline.
    function mTracked(address m) external view returns (uint256 n) {
        for (uint32 a = 0; a < 3; a++) {
            if (mSlot[m][a].known && mSlot[m][a].base != 0) n++;
        }
    }

    function actions() external pure returns (bytes4[] memory s) {
        s = new bytes4[](12);
        s[0] = this.trade.selector;
        s[1] = this.capture.selector;
        s[2] = this.spend.selector;
        s[3] = this.settle.selector;
        s[4] = this.cashHeld.selector;
        s[5] = this.settleClosed.selector;
        s[6] = this.joinPool.selector;
        s[7] = this.leavePool.selector;
        s[8] = this.setSpender.selector;
        s[9] = this.warp.selector;
        s[10] = this.setMark.selector;
        s[11] = this.poolSpend.selector;
    }
}

/// @title Many-trader stateful simulation
/// @notice Thousands of random steps by 40 traders and 2 test pools on the
///         production minter (drand stood in for by SimMinter), with the
///         testnet retarget window of 10 wins at a 60 s target. Every
///         transition is checked by the handler against its model; after every
///         step the invariant re-checks the whole state. Heavier runs:
///         FOUNDRY_PROFILE=sim forge test --match-contract ManyTraders.
contract ManyTradersInvariantTest is SimBase {
    uint128 constant GENESIS_DIFFICULTY = 200;

    HypowToken token;
    SimMinter minter;
    SimHandler h;

    function setUp() public {
        _etchPrecompiles();
        (token, minter) = _deploySim(GENESIS_DIFFICULTY, 60, 10);
        h = new SimHandler(minter, token, GENESIS_DIFFICULTY);
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: h.actions()}));
    }

    /// forge-config: default.invariant.runs = 6
    /// forge-config: default.invariant.depth = 3000
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: sim.invariant.runs = 24
    /// forge-config: sim.invariant.depth = 5000
    function invariant_manyTraders() public view {
        _supplyAndWins();
        _creditsConserved();
        _balances();
        _difficultyAndClock();
    }

    /// Supply equals the rewards of the recorded wins and stays under the cap;
    /// one win per round, cashed in increasing round order; wonBy agrees.
    function _supplyAndWins() internal view {
        uint256 n = h.wonRoundsLength();
        assertEq(minter.winCount(), n, "winCount");
        uint256 sum;
        uint64 prev;
        for (uint256 i = 0; i < n; i++) {
            uint64 r = h.wonRounds(i);
            assertGt(r, prev, "wins not in increasing round order");
            prev = r;
            (address owner, uint128 d, uint128 reward) = minter.wonBy(r);
            assertEq(owner, h.mWonBy(r), "wonBy owner");
            assertEq(d, h.mWonDiff(r), "wonBy difficulty");
            assertEq(reward, h.mWonReward(r), "wonBy reward");
            sum += reward;
        }
        assertEq(minter.lastWonRound(), prev, "lastWonRound is the latest win");
        assertEq(token.totalSupply(), sum, "supply != sum of rewards");
        assertEq(token.totalSupply(), h.minted(), "supply != minted");
        assertLe(token.totalSupply(), token.CAP(), "supply above cap");
        assertGt(minter.targetRound(), minter.lastWonRound(), "target round closed");
    }

    /// Every realised cent is in a bank, an open draw, a frozen draw on a closed
    /// round (never touched again), or a cashed win. Each is read from the chain
    /// and matched to the model.
    function _creditsConserved() internal view {
        uint256 sum = h.wonK();
        for (uint256 i = 0; i < h.N(); i++) {
            address a = h.actors(i);
            assertEq(minter.credits(a), h.mBank(a), "bank");
            assertEq(minter.memberAssetsLength(a), h.mTracked(a), "tracked perps");
            assertEq(minter.creditDelegate(a), h.mDelegate(a), "delegate");
            sum += minter.credits(a);
        }
        for (uint256 p = 0; p < 2; p++) {
            address pool = address(h.pools(p));
            assertEq(minter.credits(pool), h.mBank(pool), "pool bank");
            sum += minter.credits(pool);
        }
        assertEq(minter.credits(h.KEEPER()), 0, "keeper banked credits");
        for (uint256 i = 0; i < h.openKeysLength(); i++) {
            (address owner, uint64 round) = h.openKeys(i);
            assertEq(minter.draws(owner, round), h.mDraw(owner, round), "open draw");
            sum += minter.draws(owner, round);
        }
        uint256 frozen;
        for (uint256 i = 0; i < h.frozenKeysLength(); i++) {
            (address owner, uint64 round) = h.frozenKeys(i);
            assertLe(round, minter.lastWonRound(), "frozen draw on an open round");
            assertEq(minter.draws(owner, round), h.mDraw(owner, round), "frozen draw changed");
            frozen += minter.draws(owner, round);
        }
        assertEq(frozen, h.frozenSum(), "frozen draws changed");
        assertEq(sum + frozen, h.captured(), "credits created or lost");
    }

    /// Every holder's balance is exactly its own wins plus pool payouts: rewards
    /// never reach a spender, keeper or settle caller, and all supply is held.
    function _balances() internal view {
        uint256 held;
        for (uint256 i = 0; i < h.N(); i++) {
            address a = h.actors(i);
            assertEq(token.balanceOf(a), h.mBal(a), "trader balance");
            held += token.balanceOf(a);
        }
        for (uint256 p = 0; p < 2; p++) {
            address pool = address(h.pools(p));
            assertEq(token.balanceOf(pool), h.mBal(pool), "pool balance");
            held += token.balanceOf(pool);
        }
        assertEq(token.balanceOf(h.KEEPER()), 0, "keeper was paid");
        assertEq(token.balanceOf(h.OUTSIDER()), 0, "outsider was paid");
        assertEq(held, token.totalSupply(), "supply outside known holders");
    }

    function _difficultyAndClock() internal view {
        assertGe(minter.difficulty(), 1, "difficulty below 1");
        assertEq(minter.difficulty(), h.mDiff(), "difficulty");
        assertEq(minter.lastRetargetTime(), h.mLastRetarget(), "lastRetargetTime");
        assertEq(minter.lastRetargetWinCount(), h.mLastRetargetWin(), "lastRetargetWinCount");
    }

    function afterInvariant() external view {
        uint64 rounds = minter.drandRound(block.timestamp) + 2 - h.firstRound();
        console.log("steps, drand rounds spanned, wins:", h.steps(), rounds, minter.winCount());
        console.log("retargets (crash escapes), difficulty now:", h.retargets(), h.escapes(), minter.difficulty());
        console.log("credits captured, in cashed wins:", h.captured(), h.wonK());
        console.log(
            "races lost, withheld wins cashed, withheld wins lost:", h.racesLost(), h.heldCashed(), h.heldLost()
        );
        console.log("closed-round settles rejected, pool wins:", h.closedRejected(), h.poolWins());
    }
}
