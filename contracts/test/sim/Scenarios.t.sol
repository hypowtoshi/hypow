// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {HypowToken} from "../../src/HypowToken.sol";
import {SimBase, SimMinter, SimDrand} from "./SimBase.sol";

/// @notice Directed long-run mining scenarios on the production minter (drand
///         stood in for by SimMinter). Each tick is 6 s, so the round a tick's
///         spends target is published at the next tick: every trader moves its
///         position, spends its whole bank, and the previous tick's round is
///         settled. Every trader's client settles its win as soon as the round is
///         out; when several draws win the same round, a random one lands first
///         and the rest revert as orphans. Retargets use the testnet window of 10
///         wins at a 60 s target.
///
///         Shares are compared against each trader's expected share, Σ k/D over
///         its draws, so difficulty moves between rounds don't bias the check.
///         Run with -vv for the logged summaries.
contract SimScenariosTest is SimBase {
    uint32 constant ASSET = PERP_BTC;
    /// At this mark one szi unit realises one cent.
    uint64 constant MARK = 10_000;
    /// Positions start here and wander by one tick's volume, so they never
    /// close and the asset stays tracked (spend captures it).
    int64 constant P0 = 1e15;
    uint64 constant TICK = 6;
    uint64 constant TARGET = 60;
    uint32 constant WINDOW = 10;

    struct Trader {
        address addr;
        uint256 weight;
        int64 pos;
        bool up;
        uint256 wins;
        /// Σ k·1e18/D over the trader's draws: its expected wins, unnormalised.
        uint256 expect;
    }

    /// One retarget: a full window of wins, or a crash escape with fewer.
    struct Window {
        uint64 elapsed;
        uint64 wins;
        uint128 oldDiff;
        uint128 newDiff;
    }

    HypowToken token;
    SimMinter minter;
    Trader[] ts;
    Window[] windows;
    uint64 pendingRound;
    uint256 totalWins;
    uint256 orphans;
    uint256 expectTotal;
    uint256 startTime;

    function _begin(uint128 genesisDiff, uint256 seed) internal {
        _etchPrecompiles();
        _setMarkPx(ASSET, MARK);
        (token, minter) = _deploySim(genesisDiff, TARGET, WINDOW);
        _rng = seed;
        startTime = block.timestamp;
    }

    function _addTrader(address a, uint256 weight) internal returns (uint256 i) {
        _setPosition(a, ASSET, P0);
        vm.prank(a);
        minter.capture(a, _a(ASSET)); // registers the baseline, credits nothing
        i = ts.length;
        ts.push(Trader({addr: a, weight: weight, pos: P0, up: i % 2 == 0, wins: 0, expect: 0}));
    }

    /// One 6 s tick at `loadBps` of each trader's weight (10_000 = 1×).
    ///
    ///      A whole scenario is one call frame, whose memory is never freed, and
    ///      memory gas is quadratic. Nothing a tick allocates outlives it (all
    ///      state is in storage), so the tick hands its memory back on exit.
    ///      Without this, tens of thousands of ticks grow memory to tens of MB and
    ///      the scenario breaks down on memory gas.
    function _tick(uint256 loadBps) internal {
        uint256 freeMem;
        assembly ("memory-safe") {
            freeMem := mload(0x40)
        }
        _tickBody(loadBps);
        assembly ("memory-safe") {
            mstore(0x40, freeMem)
        }
    }

    function _tickBody(uint256 loadBps) internal {
        vm.warp(block.timestamp + TICK);
        _settlePending();
        uint128 d = minter.difficulty();
        for (uint256 i = 0; i < ts.length; i++) {
            Trader storage t = ts[i];
            // Uniform in [w/2, 3w/2], whose mean is exactly w for even w; at
            // least one cent so every trader draws.
            uint256 w = t.weight * loadBps / 10_000;
            uint256 v = w / 2 + _randBelow(w + 1);
            if (v == 0) v = 1;
            // forge-lint: disable-next-line(unsafe-typecast)
            t.pos = t.up ? t.pos + int64(int256(v)) : t.pos - int64(int256(v));
            t.up = !t.up;
            _setPosition(t.addr, ASSET, t.pos);
            vm.prank(t.addr);
            (uint64 round, uint128 k) = minter.spend(t.addr, type(uint128).max);
            assertEq(k, v, "spend k");
            pendingRound = round;
            uint256 e = uint256(k) * 1e18 / d;
            t.expect += e;
            expectTotal += e;
        }
    }

    function _settlePending() internal {
        uint64 round = pendingRound;
        if (round == 0) return;
        uint128 d = minter.difficulty();
        uint256[] memory idx = new uint256[](ts.length);
        uint256[] memory nonce = new uint256[](ts.length);
        uint256 nw;
        for (uint256 i = 0; i < ts.length; i++) {
            uint256 k = minter.draws(ts[i].addr, round);
            uint256 n = _firstWin(ts[i].addr, round, k, d, k);
            if (n == 0) continue;
            idx[nw] = i;
            nonce[nw] = n;
            nw++;
        }
        if (nw == 0) return;

        uint256 first = _randBelow(nw);
        bytes memory sig = SimDrand.sig(round);
        for (uint256 j = 0; j < nw; j++) {
            uint256 w = (first + j) % nw;
            Trader storage t = ts[idx[w]];
            if (j > 0) {
                vm.expectRevert(bytes("round closed"));
                minter.settle(t.addr, round, sig, nonce[w]);
                orphans++;
                continue;
            }
            uint64 lastRetarget = minter.lastRetargetTime();
            uint64 lastRetargetWin = minter.lastRetargetWinCount();
            minter.settle(t.addr, round, sig, nonce[w]);
            t.wins++;
            totalWins++;
            if (minter.lastRetargetWinCount() != lastRetargetWin) {
                windows.push(
                    Window({
                        elapsed: uint64(block.timestamp) - lastRetarget,
                        wins: minter.winCount() - lastRetargetWin,
                        oldDiff: d,
                        newDiff: minter.difficulty()
                    })
                );
            }
        }
    }

    function _runUntilWins(uint256 wins, uint256 loadBps) internal {
        uint256 goal = totalWins + wins;
        while (totalWins < goal) {
            _tick(loadBps);
        }
    }

    /// Expected wins of trader `i` ×1e6: its share of Σ k/D times all wins.
    function _expected(uint256 i) internal view returns (uint256) {
        return totalWins * ts[i].expect * 1e6 / expectTotal;
    }

    /// Pearson χ² ×1e6 of observed wins against expected, over traders [from, to).
    function _chi2(uint256 from, uint256 to) internal view returns (uint256 x) {
        for (uint256 i = from; i < to; i++) {
            uint256 e = _expected(i);
            uint256 dev = _absDiff(ts[i].wins * 1e6, e);
            x += dev * dev / e;
        }
    }

    /// |observed − expected| ≤ z·sqrt(expected) (Poisson sigma), all ×1e6.
    function _assertWithinSigma(uint256 observed1e6, uint256 expected1e6, uint256 z, string memory err) internal pure {
        uint256 dev = _absDiff(observed1e6, expected1e6);
        assertLe(dev * dev, z * z * expected1e6 * 1e6, err);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _logRun() internal view {
        uint256 elapsed = block.timestamp - startTime;
        console.log("wins, orphaned would-be wins:", totalWins, orphans);
        console.log("simulated s, mean win interval s:", elapsed, elapsed / totalWins);
        console.log("retargets, final difficulty:", windows.length, minter.difficulty());
    }

    // ------------------------------------------------------------------
    // (a) Many equal traders: each one's block share tracks its volume share.
    // ------------------------------------------------------------------

    function test_sim_equalTradersShareTracksVolume() public {
        uint256 n = 20;
        _begin(8_000, 1);
        for (uint256 i = 0; i < n; i++) {
            _addTrader(_addr(0x1000, i), 20);
        }
        _runUntilWins(800, 10_000);

        uint256 minW = type(uint256).max;
        uint256 maxW;
        for (uint256 i = 0; i < n; i++) {
            if (ts[i].wins < minW) minW = ts[i].wins;
            if (ts[i].wins > maxW) maxW = ts[i].wins;
            _assertWithinSigma(ts[i].wins * 1e6, _expected(i), 5, "trader outside 5 sigma");
        }
        uint256 chi2 = _chi2(0, n);
        console.log("(a) equal traders:", n);
        _logRun();
        console.log("expected wins per trader x100:", _expected(0) / 1e4);
        console.log("per-trader wins min / max:", minW, maxW);
        console.log("chi2 x1000 (19 dof; p=0.001 critical 43820):", chi2 / 1e3);
        assertLt(chi2, 43_820_000, "win shares diverge from volume shares");
    }

    // ------------------------------------------------------------------
    // (b) One whale with half the volume, twenty small traders the other half.
    // ------------------------------------------------------------------

    function test_sim_whaleAndSmallTraders() public {
        uint256 n = 20;
        _begin(8_000, 2);
        _addTrader(address(0xFA1E), 20 * n);
        for (uint256 i = 0; i < n; i++) {
            _addTrader(_addr(0x2000, i), 20);
        }
        _runUntilWins(800, 10_000);

        uint256 smallWins;
        uint256 smallExpected;
        for (uint256 i = 1; i <= n; i++) {
            smallWins += ts[i].wins;
            smallExpected += _expected(i);
            _assertWithinSigma(ts[i].wins * 1e6, _expected(i), 5, "small trader outside 5 sigma");
        }
        uint256 whaleExpected = _expected(0);
        uint256 smallChi2 = _chi2(1, n + 1);
        console.log("(b) one whale + small traders:", n);
        _logRun();
        console.log(
            "whale volume share bps, win share bps:", whaleExpected / (totalWins * 100), ts[0].wins * 1e4 / totalWins
        );
        console.log("whale wins, expected x100:", ts[0].wins, whaleExpected / 1e4);
        console.log("small traders total wins, expected x100:", smallWins, smallExpected / 1e4);
        console.log("small chi2 x1000 (19 dof; p=0.001 critical 43820):", smallChi2 / 1e3);
        // The whale's wins are binomial(W, ~1/2), sigma = sqrt(W)/2; 5 sigma.
        uint256 sigma1e6 = _sqrt(totalWins * 1e12) / 2;
        assertLe(_absDiff(ts[0].wins * 1e6, whaleExpected), 5 * sigma1e6, "whale share off its volume share");
        assertLt(smallChi2, 43_820_000, "small shares diverge from volume shares");
    }

    // ------------------------------------------------------------------
    // (c) Sybil: the same volume as one address or split over ten.
    // ------------------------------------------------------------------

    function test_sim_sybilSplitGainsNothing() public {
        uint256 honest = 5;
        uint256 sybils = 10;
        _begin(3_000, 3);
        for (uint256 i = 0; i < honest; i++) {
            _addTrader(_addr(0x3000, i), 20);
        }
        uint256 single = _addTrader(address(0x5111), 20);
        uint256 firstSybil = ts.length;
        for (uint256 i = 0; i < sybils; i++) {
            _addTrader(_addr(0x5200, i), 2);
        }
        _runUntilWins(1_200, 10_000);

        uint256 sybilWins;
        uint256 sybilExpected;
        for (uint256 i = firstSybil; i < ts.length; i++) {
            sybilWins += ts[i].wins;
            sybilExpected += _expected(i);
        }
        uint256 singleWins = ts[single].wins;
        uint256 honestWins;
        for (uint256 i = 0; i < honest; i++) {
            honestWins += ts[i].wins;
        }
        // Independent Poisson counts with equal means: their difference has
        // sigma sqrt(single + split).
        uint256 sigma100 = _sqrt((singleWins + sybilWins) * 1e4);
        console.log("(c) sybil: 5 honest traders, one address, the same volume split over", sybils);
        _logRun();
        console.log("single address wins, expected x100:", singleWins, _expected(single) / 1e4);
        console.log("split addresses total wins, expected x100:", sybilWins, sybilExpected / 1e4);
        console.log("mean honest trader wins x100:", honestWins * 100 / honest);
        console.log("sigma of (split - single) x100:", sigma100);
        assertLe(sybilWins * 100, singleWins * 100 + 4 * sigma100, "splitting beat one address");
        assertLe(singleWins * 100, sybilWins * 100 + 4 * sigma100, "splitting lost more than chance");
        _assertWithinSigma(sybilWins * 1e6, sybilExpected, 5, "split wins off their volume share");
    }

    // ------------------------------------------------------------------
    // (d) Load ramp ×16 then crash back: difficulty tracks the win interval,
    //     and the crash escape cuts the crash's slow windows short.
    // ------------------------------------------------------------------

    function test_sim_loadRampAndCrashRetarget() public {
        uint256 n = 10;
        uint256 weight = 20;
        _begin(2_000, 4);
        for (uint256 i = 0; i < n; i++) {
            _addTrader(_addr(0x4000, i), weight);
        }

        // Baseline at 1× load.
        _runUntilWins(100, 10_000);
        uint256 baseEnd = windows.length;
        // Ramp 1× → 16× over 30 simulated minutes, then hold at 16×.
        for (uint256 t = 0; t < 300; t++) {
            _tick(10_000 + 150_000 * t / 300);
        }
        uint256 rampEnd = windows.length;
        _runUntilWins(100, 160_000);
        uint256 peakEnd = windows.length;
        // Crash back to 1× and hold.
        _runUntilWins(100, 10_000);
        uint256 crashEnd = windows.length;

        console.log("(d) load ramp x16 then crash, traders:", n);
        _logRun();
        console.log("window | phase | wins | mean win interval s, difficulty before, after");
        uint256 fastest = type(uint256).max;
        uint256 slowest;
        uint256 recovery;
        uint256 crashEscapes;
        for (uint256 w = 0; w < windows.length; w++) {
            Window memory x = windows[w];
            uint256 interval = x.elapsed / x.wins;
            string memory phase = w < baseEnd ? "base" : w < rampEnd ? "ramp" : w < peakEnd ? "peak" : "crash";
            console.log(
                string.concat(vm.toString(w), " | ", phase, " | ", vm.toString(x.wins), " | ", vm.toString(interval)),
                x.oldDiff,
                x.newDiff
            );
            // An escape fires only after 4x a whole window's target time, and
            // always divides by exactly 4.
            if (x.wins < WINDOW) {
                assertGe(x.elapsed, uint256(WINDOW) * TARGET * 4, "escape before 4x window time");
                assertEq(x.newDiff, x.oldDiff / 4, "escape is not /4");
                if (w >= peakEnd) crashEscapes++;
            }
            // The clamp: at most ×4 either way per retarget.
            assertLe(x.newDiff, uint256(x.oldDiff) * 4, "retarget above x4");
            assertGe(x.newDiff, x.oldDiff / 4, "retarget below /4");
            if (w >= baseEnd && w < peakEnd && interval < fastest) fastest = interval;
            if (w >= peakEnd && interval > slowest) slowest = interval;
            if (w >= peakEnd && recovery == 0 && interval <= 2 * TARGET) recovery = w - peakEnd + 1;
        }

        // The load changes pushed the win interval well off target...
        assertLt(fastest, TARGET / 2, "ramp never sped wins up");
        assertGt(slowest, TARGET * 4, "crash never slowed wins down");
        // ...a 16× crash needs at least two ×4 clamped steps down; the window
        // the crash lands in and noise on the peak difficulty add up to two...
        console.log("windows until the interval is back under 2x target after the crash:", recovery);
        console.log("crash escapes after the crash:", crashEscapes);
        assertGt(crashEscapes, 0, "the crash never triggered the escape");
        assertGt(recovery, 0, "never recovered after the crash");
        assertLe(recovery, 5, "slow recovery after the crash");
        // ...and once each phase settles, difficulty sits at the level that
        // gives one win per 60 s at that load, and so does the interval.
        _assertSettled(baseEnd, n * weight, "baseline");
        _assertSettled(peakEnd, n * weight * 16, "peak");
        _assertSettled(crashEnd, n * weight, "after crash");
    }

    /// Over the six windows ending at `end`: the mean win interval is within 2×
    /// of target, and the mean difficulty within 2× of the one that yields a win
    /// per 60 s for `ticketsPerTick`. That D* solves 1 − e^(−T/D) = TICK/TARGET
    /// (a round has a win iff any of its tickets wins), so D* = T / 0.10536.
    /// Six windows average out the ~30% per-window noise of a 10-win window.
    function _assertSettled(uint256 end, uint256 ticketsPerTick, string memory phase) internal view {
        uint256 elapsed;
        uint256 wins;
        uint256 diffSum;
        for (uint256 w = end - 6; w < end; w++) {
            elapsed += windows[w].elapsed;
            wins += windows[w].wins;
            diffSum += windows[w].newDiff;
        }
        uint256 interval = elapsed / wins;
        uint256 meanDiff = diffSum / 6;
        uint256 ideal = ticketsPerTick * 100_000 / 10_536;
        console.log(
            string.concat(phase, ": mean interval s, mean difficulty, ideal difficulty"), interval, meanDiff, ideal
        );
        assertGe(interval, TARGET / 2, string.concat(phase, ": interval far below target"));
        assertLe(interval, TARGET * 2, string.concat(phase, ": interval far above target"));
        assertGe(meanDiff * 2, ideal, string.concat(phase, ": difficulty far below ideal"));
        assertLe(meanDiff, ideal * 2, string.concat(phase, ": difficulty far above ideal"));
    }
}

