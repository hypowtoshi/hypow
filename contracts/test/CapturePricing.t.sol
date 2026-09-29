// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HypowToken} from "../src/HypowToken.sol";
import {HypowMinter} from "../src/HypowMinter.sol";
import {MinterBase} from "./utils/MinterBase.sol";
import {TestPool} from "./utils/TestPool.sol";

/// @notice Capture pricing at the lower of two marks. The part of a change
///         that reduces the baseline position (a close, a partial close, a
///         flip's closing leg) is valued at min(mark at the slot's last priced
///         capture, current mark); the part that increases it (an open, an add,
///         a flip's opening leg) at the current mark.
///
///         These tests read only credits and capture's return, never the slot
///         layout, so they also compile against a minter without the rule, which
///         is how their negative controls are run.
contract CapturePricingTest is MinterBase {
    HypowToken token;
    HypowMinter minter;

    address constant TRADER = address(0xA1A1);
    address constant RIVAL = address(0xB1B1);
    address constant STRANGER = address(0xC9C9);

    function setUp() public {
        _etchPrecompiles();
        (token, minter) = _deploy(1, 2016);
    }

    function _mark(uint64 px) internal {
        _setMarkPx(PERP_BTC, px);
    }

    /// Register flat, then open `szi` at the current mark and capture it.
    function _open(address member, int64 szi) internal {
        _trade(minter, member, 0);
        _trade(minter, member, szi);
    }

    // ------------------------------------------------------------------
    // The HIP-3 halt-and-ramp attack
    // ------------------------------------------------------------------

    /// A deployer's wash pair opens at P and is captured, closes at P without a
    /// capture, then the deployer ramps the empty market to 10P. The closes are
    /// credited at P, not 10P.
    function test_washCloseCapturedAfterRampIsCreditedAtOpenMark() public {
        _open(TRADER, LOT);
        _open(RIVAL, -LOT);
        _setPosition(TRADER, PERP_BTC, 0);
        _setPosition(RIVAL, PERP_BTC, 0);
        _mark(10 * BTC_MARK);

        vm.prank(TRADER);
        assertEq(minter.capture(TRADER, _a(PERP_BTC)), LOT_CENTS, "long close at P");
        vm.prank(RIVAL);
        assertEq(minter.capture(RIVAL, _a(PERP_BTC)), LOT_CENTS, "short close at P");
        assertEq(minter.credits(TRADER) + minter.credits(RIVAL), 4 * LOT_CENTS, "honest round trip, not 22 lots");
    }

    /// haltTrading settles both legs to zero at the mark with no fee. The halted
    /// market's mark keeps moving under the deployer's updates (seen live on
    /// testnet), here 232 steps of +1%, to about 10x. Captured at the top, and
    /// again after the asset is recycled, the settlement legs earn the open mark.
    function test_haltSettledLegsCapturedAfterRampAreCreditedAtOpenMark() public {
        _open(TRADER, LOT);
        _open(RIVAL, -LOT);
        _setPosition(TRADER, PERP_BTC, 0);
        _setPosition(RIVAL, PERP_BTC, 0);
        uint64 px = BTC_MARK;
        for (uint256 i = 0; i < 232; i++) {
            px = px * 101 / 100;
        }
        _mark(px);
        assertGt(px, 9 * BTC_MARK);

        uint128 k = _trade(minter, TRADER, 0) + _trade(minter, RIVAL, 0);
        assertEq(k, 2 * LOT_CENTS, "settlement legs at the open mark");
        assertEq(minter.memberAssetsLength(TRADER) + minter.memberAssetsLength(RIVAL), 0, "both evicted");
    }

    /// The attacker's usual shield (delegating the wash accounts so nobody else
    /// can capture them early) changes nothing: pooled captures follow the rule.
    function test_selfDelegatedWashCloseIsCreditedAtOpenMark() public {
        address sink = address(0x5111);
        vm.prank(TRADER);
        minter.setCreditDelegate(sink);
        _setPosition(TRADER, PERP_BTC, 0);
        vm.prank(sink);
        minter.capture(TRADER, _a(PERP_BTC));
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.prank(sink);
        minter.capture(TRADER, _a(PERP_BTC));

        _setPosition(TRADER, PERP_BTC, 0);
        _mark(10 * BTC_MARK);
        vm.prank(sink);
        assertEq(minter.capture(TRADER, _a(PERP_BTC)), LOT_CENTS);
        assertEq(minter.credits(sink), 2 * LOT_CENTS);
    }

    // ------------------------------------------------------------------
    // Honest paths
    // ------------------------------------------------------------------

    function test_priceUpBetweenCapturesCreditsAtPreviousMark() public {
        _open(TRADER, LOT);
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), LOT_CENTS);
    }

    function test_priceDownBetweenCapturesCreditsAtCurrentMark() public {
        _open(TRADER, LOT);
        _mark(BTC_MARK / 2);
        assertEq(_trade(minter, TRADER, 0), LOT_CENTS / 2);
    }

    function test_partialCloseCreditsAtLowerMark() public {
        _open(TRADER, 2 * LOT);
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, LOT), LOT_CENTS);
    }

    /// An add increases the position, so it is priced like an open: at the
    /// current mark, not capped by the held position's stored mark.
    function test_addCreditsAtCurrentMark() public {
        _open(TRADER, LOT);
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 3 * LOT), 4 * LOT_CENTS);
    }

    /// Review regression: 99 lots added at 2P to 1 lot captured at P are all
    /// credited at 2P, not at the old mark.
    function test_largeAddAfterRallyCreditsAtCurrentMark() public {
        _open(TRADER, LOT);
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 100 * LOT), 99 * 2 * LOT_CENTS);
    }

    /// Review regression: a capture at a dip (the owner's own) caps only what
    /// the position later closes; 99 lots added after the price recovers are
    /// credited at the recovered mark.
    function test_addAfterCaptureAtDipCreditsAtCurrentMark() public {
        _open(TRADER, LOT);
        _mark(BTC_MARK / 2);
        _trade(minter, TRADER, LOT); // unchanged capture at the dip: stores P/2
        _mark(BTC_MARK);
        assertEq(_trade(minter, TRADER, 100 * LOT), 99 * LOT_CENTS);
    }

    /// A flip closes the old side at the lower mark and opens the new side at
    /// the current mark.
    function test_flipCreditsCloseAtLowerMarkOpenAtCurrent() public {
        _open(TRADER, LOT);
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, -3 * LOT), LOT_CENTS + 3 * 2 * LOT_CENTS);
    }

    /// With the price down, both legs of a flip take the current mark.
    function test_flipAfterDropCreditsAtCurrentMark() public {
        _open(TRADER, LOT);
        _mark(BTC_MARK / 2);
        assertEq(_trade(minter, TRADER, -3 * LOT), 4 * LOT_CENTS / 2);
    }

    function test_openFromFlatCreditsAtCurrentMark() public {
        _trade(minter, TRADER, 0);
        _mark(3 * BTC_MARK);
        assertEq(_trade(minter, TRADER, LOT), 3 * LOT_CENTS);
    }

    /// A close leaves the slot at zero; the re-open is a fresh open, priced at
    /// the current mark, not capped by the closed position's stale mark.
    function test_reopenAfterEvictionCreditsAtCurrentMark() public {
        _open(TRADER, LOT);
        _trade(minter, TRADER, 0);
        _mark(3 * BTC_MARK);
        assertEq(_trade(minter, TRADER, LOT), 3 * LOT_CENTS);
    }

    /// A first touch of a held position stores its mark: the close is capped by
    /// it, so a position registered before a ramp can't close at the top.
    function test_heldFirstTouchCapsCloseAtRegistrationMark() public {
        _trade(minter, TRADER, LOT);
        _mark(10 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), LOT_CENTS);
    }

    /// Untrack forgets the stored mark with the baseline; the re-registration
    /// stores the mark of that moment, which caps the later close.
    function test_untrackThenRetrackCapsAtReRegistrationMark() public {
        _open(TRADER, LOT);
        vm.prank(TRADER);
        minter.untrack(TRADER, PERP_BTC);
        _mark(2 * BTC_MARK);
        vm.prank(TRADER);
        assertEq(minter.capture(TRADER, _a(PERP_BTC)), 0, "re-registration credits nothing");
        _mark(3 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), 2 * LOT_CENTS, "close at the re-registration mark");
    }

    /// A capture of an unchanged position refreshes the stored mark, so the
    /// close pays at the latest capture's mark, not the open's.
    function test_unchangedCaptureRefreshesStoredMark() public {
        _open(TRADER, LOT);
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, LOT), 0);
        _mark(3 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), 2 * LOT_CENTS);
    }

    /// spend's capture of tracked assets refreshes and applies the cap too.
    function test_spendCaptureAppliesAndRefreshesTheCap() public {
        _open(TRADER, LOT);
        _mark(2 * BTC_MARK);
        _spend(minter, TRADER, 0); // unchanged: refreshes to 2P
        _mark(3 * BTC_MARK);
        _setPosition(TRADER, PERP_BTC, 0);
        _spend(minter, TRADER, 0);
        assertEq(minter.credits(TRADER), LOT_CENTS + 2 * LOT_CENTS, "open at P, close at 2P");
    }

    /// A capture with no price refreshes nothing: the outage's 0 never becomes
    /// the cap.
    function test_outageCaptureDoesNotRefreshStoredMark() public {
        _open(TRADER, LOT);
        _mark(0);
        assertEq(_trade(minter, TRADER, LOT), 0);
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), LOT_CENTS);
    }

    /// A position registered while its market has no price stores 0, so a close
    /// captured before any priced capture of it earns nothing.
    function test_heldFirstTouchWithoutPriceEarnsNothingOnClose() public {
        _mark(0);
        _trade(minter, TRADER, LOT);
        _mark(BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), 0);
        assertEq(minter.memberAssetsLength(TRADER), 0, "still evicted");
    }

    /// A pool's contribution of its member follows the same rule.
    function test_poolContributionCreditsAtLowerMark() public {
        TestPool pool = new TestPool(minter);
        vm.prank(TRADER);
        minter.setCreditDelegate(address(pool));
        _setPosition(TRADER, PERP_BTC, 0);
        pool.contribute(TRADER, _a(PERP_BTC));
        _setPosition(TRADER, PERP_BTC, LOT);
        pool.contribute(TRADER, _a(PERP_BTC));
        _mark(2 * BTC_MARK);
        _setPosition(TRADER, PERP_BTC, 0);
        assertEq(pool.contribute(TRADER, _a(PERP_BTC)), LOT_CENTS);
        assertEq(minter.credits(address(pool)), 2 * LOT_CENTS);
        assertEq(minter.credits(TRADER), 0);
    }

    // ------------------------------------------------------------------
    // The stored mark: an unchanged capture may only raise it; a change
    // stores the current mark
    // ------------------------------------------------------------------

    function _cap(address member) internal returns (uint128) {
        vm.prank(member);
        return minter.capture(member, _a(PERP_BTC));
    }

    /// An honest miner's own capture during a dip, with the position unchanged,
    /// doesn't lower the cap: the close at the recovered mark pays in full.
    function test_ownUnchangedCaptureAtDipDoesNotLowerCap() public {
        _open(TRADER, LOT);
        _mark(BTC_MARK / 2);
        assertEq(_cap(TRADER), 0);
        _mark(BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), LOT_CENTS);
    }

    /// Review M1: the halt-and-ramp stays capped, with unchanged captures along
    /// the way.
    function test_haltAndRampStillCappedWithUnchangedCaptures() public {
        _open(TRADER, LOT);
        _open(RIVAL, -LOT);
        _cap(TRADER);
        _setPosition(TRADER, PERP_BTC, 0);
        _setPosition(RIVAL, PERP_BTC, 0);
        _mark(10 * BTC_MARK);
        assertEq(_cap(TRADER), LOT_CENTS);
        assertEq(_cap(RIVAL), LOT_CENTS);
    }

    /// Review M3: an unchanged capture at 3P while held lifts the cap to 3P,
    /// and a later unchanged capture at P keeps it. Before the max rule the
    /// holder reached the same cap by not capturing at P. Margined: the
    /// position was held through the rise.
    function test_heldRiseLiftsCapAndLaterDipKeepsIt() public {
        _open(TRADER, LOT);
        _mark(3 * BTC_MARK);
        _cap(TRADER);
        _mark(BTC_MARK);
        _cap(TRADER);
        _setPosition(TRADER, PERP_BTC, 0);
        _mark(3 * BTC_MARK);
        assertEq(_cap(TRADER), 3 * LOT_CENTS);
    }

    /// Review M5: a held first touch with no price stores 0, and a later priced
    /// unchanged capture lifts it.
    function test_unpricedFirstTouchLiftedByUnchangedCapture() public {
        _mark(0);
        _trade(minter, TRADER, LOT);
        _mark(BTC_MARK);
        _cap(TRADER);
        assertEq(_trade(minter, TRADER, 0), LOT_CENTS);
    }

    // ------------------------------------------------------------------
    // Strangers can't pick the mark
    // ------------------------------------------------------------------

    /// Capture is limited to the owner or its spender, so a stranger can't
    /// capture a held position at a dip to cap its next close there. The close
    /// pays at the owner's own last capture mark.
    function test_strangerCannotCaptureAtDipToCapClose() public {
        _open(TRADER, LOT);
        _mark(BTC_MARK / 2);
        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.capture(TRADER, _a(PERP_BTC));
        _mark(2 * BTC_MARK);
        assertEq(_trade(minter, TRADER, 0), LOT_CENTS, "close at the owner's last capture mark, not the dip");
    }
}

/// @notice Why a changed capture stores the current mark and never the max.
contract CapturePricingLeftoverTest is MinterBase {
    HypowMinter minter;
    address constant TRADER = address(0xA1A1);
    int64 constant UNIT = 1;

    function setUp() public {
        _etchPrecompiles();
        (, minter) = _deploy(1, 2016);
    }

    /// Review X: one unit is held through a 10x rise, so an unchanged capture
    /// lifts its cap to 10P. The price falls back, a lot is added and captured
    /// at P, then closed uncaptured, and the market is ramped with the one unit
    /// held. The lot's close must pay at P, not at the old 10P.
    function test_tinyLeftoverCantCarryOldHighCapOntoNewLot() public {
        _trade(minter, TRADER, 0);
        _trade(minter, TRADER, UNIT);
        _setMarkPx(PERP_BTC, 10 * BTC_MARK);
        _trade(minter, TRADER, UNIT);
        _setMarkPx(PERP_BTC, BTC_MARK);
        _trade(minter, TRADER, LOT + UNIT);
        _setPosition(TRADER, PERP_BTC, UNIT);
        _setMarkPx(PERP_BTC, 10 * BTC_MARK);
        vm.prank(TRADER);
        assertEq(minter.capture(TRADER, _a(PERP_BTC)), LOT_CENTS, "the lot filled at P closes at P");
    }
}
