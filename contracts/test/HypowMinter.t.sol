// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HypowToken} from "../src/HypowToken.sol";
import {HypowMinter} from "../src/HypowMinter.sol";
import {IHypowToken} from "../src/interfaces/IHypowToken.sol";
import {Emission} from "../src/lib/Emission.sol";
import {L1Read} from "../src/lib/L1Read.sol";
import {MockSmallCapToken} from "./mocks/MockSmallCapToken.sol";
import {Drand} from "./utils/Drand.sol";
import {MinterBase} from "./utils/MinterBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {BLS} from "bls-solidity/libraries/BLS.sol";

/// @dev Exposes the drand verifier so fixtures can be checked in isolation.
contract VerifierHarness is HypowMinter {
    constructor(IHypowToken t) HypowMinter(t, 1, 60, 2016) {}

    function verifiedSeed(uint64 round, bytes calldata signature) external view returns (bytes32) {
        return _verifiedSeed(round, signature);
    }

    function drandKey() external pure returns (BLS.PointG2 memory) {
        return _drandKey();
    }
}

contract HypowMinterTest is MinterBase {
    HypowToken token;
    HypowMinter minter;

    address constant TRADER = address(0xA1A1);
    address constant RIVAL = address(0xB1B1);
    address constant STRANGER = address(0xC9C9);
    address constant POOL = address(0xD1D1);

    uint64 constant R0 = Drand.ROUND_0;

    /// When setUp deploys; every retarget test deploys its own minter then too.
    uint256 deployedAt;

    function setUp() public {
        _etchPrecompiles();
        deployedAt = block.timestamp;
        // Genesis difficulty 1: every ticket wins, so win paths need no search.
        (token, minter) = _deploy(1, 2016);
        sigDeadline = block.timestamp + 1 hours;
    }

    function _draw(address owner, uint64 round) internal view returns (uint128) {
        return minter.draws(owner, round);
    }

    function _slot(address member, uint32 asset) internal view returns (int64 szi, bool known) {
        (szi, known,) = minter.memberSlots(member, asset);
    }

    function _markOf(address member, uint32 asset) internal view returns (uint64 mark) {
        (,, mark) = minter.memberSlots(member, asset);
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_constructorWiring() public view {
        assertEq(address(minter.token()), address(token));
        assertEq(token.minter(), address(minter));
        assertEq(minter.difficulty(), 1);
        assertEq(minter.winCount(), 0);
        assertEq(minter.lastWonRound(), 0);
        assertEq(minter.lastRetargetTime(), deployedAt);
    }

    /// The hardcoded key is exactly the live evmnet key and a valid G2 point.
    function test_drandKeyMatchesEvmnetAndIsOnG2() public {
        VerifierHarness h = new VerifierHarness(IHypowToken(address(token)));
        BLS.PointG2 memory key = h.drandKey();
        assertEq(BLS.g2Marshal(key), Drand.PUBLIC_KEY);
        assertTrue(BLS.isValidPointG2(key));
    }

    // ------------------------------------------------------------------
    // Capture: first touch, flat registration, re-open
    // ------------------------------------------------------------------

    function test_firstTouchBaselinesAtCurrentAndCreditsNothing() public {
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.expectEmit(address(minter));
        emit HypowMinter.AssetRegistered(TRADER, PERP_BTC, LOT);
        vm.prank(TRADER);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC));

        assertEq(k, 0, "held position before first capture is not credited");
        assertEq(minter.credits(TRADER), 0);
        (int64 szi, bool known) = _slot(TRADER, PERP_BTC);
        assertEq(szi, LOT);
        assertTrue(known);
        assertEq(minter.memberAssetsLength(TRADER), 1, "a held position is tracked");
        assertEq(minter.memberAssets(TRADER, 0), PERP_BTC);
    }

    function test_tradingAfterFirstTouchIsCredited() public {
        _trade(minter, TRADER, LOT);
        uint128 k = _trade(minter, TRADER, 3 * LOT);
        assertEq(k, 2 * LOT_CENTS);
        assertEq(minter.credits(TRADER), 2 * LOT_CENTS);
    }

    function test_flatFirstTouchRegistersButDoesNotTrack() public {
        _trade(minter, TRADER, 0);
        (int64 szi, bool known) = _slot(TRADER, PERP_BTC);
        assertTrue(known, "flat asset registered");
        assertEq(szi, 0);
        assertEq(minter.memberAssetsLength(TRADER), 0, "flat registration is not tracked");

        uint128 k = _trade(minter, TRADER, LOT);
        assertEq(k, LOT_CENTS, "first open after flat registration counts in full");
        assertEq(minter.memberAssetsLength(TRADER), 1, "open position now tracked");
    }

    function test_closeEvictsAndKeepsSlotKnownAtZero() public {
        _earnLot(minter, TRADER);
        _setPosition(TRADER, PERP_BTC, 0);
        vm.expectEmit(address(minter));
        emit HypowMinter.AssetUntracked(TRADER, PERP_BTC);
        vm.prank(TRADER);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC));

        assertEq(k, LOT_CENTS, "the close is volume");
        assertEq(minter.memberAssetsLength(TRADER), 0);
        (int64 szi, bool known) = _slot(TRADER, PERP_BTC);
        assertTrue(known, "slot stays known after close");
        assertEq(szi, 0);
    }

    function test_reopenAfterCloseCreditsFromZero() public {
        _earnLot(minter, TRADER);
        _trade(minter, TRADER, 0);
        uint128 k = _trade(minter, TRADER, -LOT);
        assertEq(k, LOT_CENTS, "re-open credited from zero");
        assertEq(minter.memberAssetsLength(TRADER), 1);
        assertEq(minter.credits(TRADER), 3 * LOT_CENTS);
    }

    function test_heldFirstTouchThenCloseCreditsTheClose() public {
        _trade(minter, TRADER, LOT); // baseline LOT, no credit
        uint128 k = _trade(minter, TRADER, 0);
        assertEq(k, LOT_CENTS);
        assertEq(minter.memberAssetsLength(TRADER), 0);
    }

    /// The slot's mark: set at a held first touch, raised (never lowered) by an
    /// unchanged capture, set to the current mark by a changed capture, and
    /// forgotten with the baseline by untrack.
    function test_slotMarkFollowsCaptureRule() public {
        _trade(minter, TRADER, LOT);
        assertEq(_markOf(TRADER, PERP_BTC), BTC_MARK, "held first touch");
        _setMarkPx(PERP_BTC, 2 * BTC_MARK);
        _trade(minter, TRADER, LOT);
        assertEq(_markOf(TRADER, PERP_BTC), 2 * BTC_MARK, "unchanged capture at a higher mark raises it");
        _setMarkPx(PERP_BTC, BTC_MARK);
        _trade(minter, TRADER, LOT);
        assertEq(_markOf(TRADER, PERP_BTC), 2 * BTC_MARK, "unchanged capture at a lower mark keeps it");
        _setMarkPx(PERP_BTC, 3 * BTC_MARK);
        _trade(minter, TRADER, 2 * LOT);
        assertEq(_markOf(TRADER, PERP_BTC), 3 * BTC_MARK, "changed capture stores the current mark");
        _setMarkPx(PERP_BTC, BTC_MARK);
        _trade(minter, TRADER, LOT);
        assertEq(_markOf(TRADER, PERP_BTC), BTC_MARK, "even a lower one");
        vm.prank(TRADER);
        minter.untrack(TRADER, PERP_BTC);
        assertEq(_markOf(TRADER, PERP_BTC), 0, "untrack forgets it");
    }

    function test_captureAccumulatesAbsoluteValue() public {
        _earnLot(minter, TRADER); // +1 lot
        _trade(minter, TRADER, -LOT); // 2 lots
        _trade(minter, TRADER, LOT); // 2 lots
        assertEq(minter.credits(TRADER), 5 * LOT_CENTS);
    }

    function test_unchangedPositionCreditsNothing() public {
        _earnLot(minter, TRADER);
        assertEq(_trade(minter, TRADER, LOT), 0);
    }

    function test_multiAssetCaptureSumsLegs() public {
        _setPosition(TRADER, PERP_BTC, 0);
        _setPosition(TRADER, PERP_ETH, 0);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC, PERP_ETH));
        _setPosition(TRADER, PERP_BTC, LOT);
        _setPosition(TRADER, PERP_ETH, 10_000); // 1 ETH at szDecimals 4 → $3,000
        vm.prank(TRADER);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC, PERP_ETH));
        assertEq(k, LOT_CENTS + 300_000);
        assertEq(minter.memberAssetsLength(TRADER), 2);
    }

    function test_closingOneAssetEvictsOnlyIt() public {
        _setPosition(TRADER, PERP_BTC, LOT);
        _setPosition(TRADER, PERP_ETH, 10_000);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC, PERP_ETH));
        _setPosition(TRADER, PERP_BTC, 0);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC, PERP_ETH));
        assertEq(minter.memberAssetsLength(TRADER), 1);
        assertEq(minter.memberAssets(TRADER, 0), PERP_ETH, "survivor swapped into slot 0");
    }

    /// Only the owner or the owner's spender may capture a solo member, as
    /// only they may spend: a stranger's capture could only pick the mark that
    /// prices the owner's volume, or register assets the owner never chose.
    function test_strangerSoloCaptureReverts() public {
        _trade(minter, TRADER, 0);
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.capture(TRADER, _a(PERP_BTC));
        (int64 szi,) = _slot(TRADER, PERP_BTC);
        assertEq(szi, 0, "baseline untouched");
        assertEq(minter.credits(TRADER), 0);
    }

    /// A stranger can't register a flat or held asset for someone else either.
    function test_strangerFirstTouchReverts() public {
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.capture(TRADER, _a(PERP_BTC));
        (, bool known) = _slot(TRADER, PERP_BTC);
        assertFalse(known);
        assertEq(minter.memberAssetsLength(TRADER), 0);
    }

    function test_ownerSoloCaptureCreditsOwnBank() public {
        _trade(minter, TRADER, 0);
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.prank(TRADER);
        assertEq(minter.capture(TRADER, _a(PERP_BTC)), LOT_CENTS);
        assertEq(minter.credits(TRADER), LOT_CENTS);
    }

    /// The authorized spender (the miner's key) captures into the owner's bank,
    /// never its own; revoking it revokes capture too.
    function test_spenderSoloCaptureCreditsOwnerBank() public {
        vm.prank(TRADER);
        minter.setSpender(RIVAL);
        _setPosition(TRADER, PERP_BTC, 0);
        vm.prank(RIVAL);
        minter.capture(TRADER, _a(PERP_BTC));
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.prank(RIVAL);
        assertEq(minter.capture(TRADER, _a(PERP_BTC)), LOT_CENTS);
        assertEq(minter.credits(TRADER), LOT_CENTS, "credits land in the owner's bank");
        assertEq(minter.credits(RIVAL), 0);

        vm.prank(TRADER);
        minter.setSpender(address(0));
        vm.prank(RIVAL);
        vm.expectRevert(bytes("not spender"));
        minter.capture(TRADER, _a(PERP_BTC));
    }

    function test_captureEmitsCaptured() public {
        _trade(minter, TRADER, 0);
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.expectEmit(address(minter));
        emit HypowMinter.Captured(TRADER, TRADER, LOT_CENTS);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC));
    }

    function test_captureRevertsOnZeroMember() public {
        vm.expectRevert(bytes("member zero"));
        minter.capture(address(0), _a(PERP_BTC));
    }

    function test_captureRevertsOnNonPerp() public {
        _setPerpAssetInfo(10_000, 0, 0); // zeroed struct, as the precompile returns for spot
        vm.expectRevert(bytes("not a perp"));
        vm.prank(TRADER);
        minter.capture(TRADER, _a(10_000));
    }

    function test_captureRevertsOnLargeSzDecimals() public {
        _setPerpAssetInfo(5, 25);
        vm.expectRevert(bytes("szDecimals too large"));
        vm.prank(TRADER);
        minter.capture(TRADER, _a(5));
    }

    function test_captureAcceptsBoundarySzDecimals() public {
        _setPerpAssetInfo(5, 24);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(5));
        (, bool known) = _slot(TRADER, 5);
        assertTrue(known);
    }

    /// HyperEVM numbers a builder-deployed perp dex·10000 + index, so every
    /// dex, however many are deployed, must be capturable.
    function test_captureAcceptsHIP3StyleHighAssetId() public {
        uint32 hip3 = 2_670_000; // dex 267, a live testnet market
        _setPerpAssetInfo(hip3, 2);
        _setMarkPx(hip3, BTC_MARK);
        _setPosition(TRADER, hip3, 0);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(hip3));
        _setPosition(TRADER, hip3, LOT);
        vm.prank(TRADER);
        uint128 k = minter.capture(TRADER, _a(hip3));
        assertEq(k, LOT_CENTS);
    }

    /// A capture during a price outage credits nothing and holds the baseline,
    /// so the next good read credits the full delta.
    function _assertOutageHoldsBaseline(function() internal breakPrice, function() internal fixPrice) internal {
        _earnLot(minter, TRADER);
        _setPosition(TRADER, PERP_BTC, 3 * LOT);
        breakPrice();
        vm.prank(TRADER);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC));
        assertEq(k, 0, "no price, no credit");
        (int64 szi,) = _slot(TRADER, PERP_BTC);
        assertEq(szi, LOT, "baseline held through the outage");
        assertEq(_markOf(TRADER, PERP_BTC), BTC_MARK, "stored mark held through the outage");

        fixPrice();
        vm.prank(TRADER);
        k = minter.capture(TRADER, _a(PERP_BTC));
        assertEq(k, 2 * LOT_CENTS, "full delta credited at the next good read");
        assertEq(minter.credits(TRADER), 3 * LOT_CENTS);
    }

    function _zeroMark() internal {
        _setMarkPx(PERP_BTC, 0);
    }

    function _restoreMark() internal {
        _setMarkPx(PERP_BTC, BTC_MARK);
    }

    function _failMark() internal {
        _setReverting(L1Read.MARK_PX, PERP_BTC, true);
    }

    function _unfailMark() internal {
        _setReverting(L1Read.MARK_PX, PERP_BTC, false);
    }

    function test_zeroMarkHoldsBaseline() public {
        _assertOutageHoldsBaseline(_zeroMark, _restoreMark);
    }

    function test_failedMarkReadHoldsBaseline() public {
        _assertOutageHoldsBaseline(_failMark, _unfailMark);
    }

    function test_closeDuringOutageStaysTrackedUntilPriced() public {
        _earnLot(minter, TRADER);
        _setPosition(TRADER, PERP_BTC, 0);
        _zeroMark();
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC));
        assertEq(minter.memberAssetsLength(TRADER), 1, "unpriced close is not evicted");
        (int64 szi,) = _slot(TRADER, PERP_BTC);
        assertEq(szi, LOT);

        _restoreMark();
        (, uint128 k) = _spend(minter, TRADER, 0);
        assertEq(k, 0);
        assertEq(minter.credits(TRADER), 2 * LOT_CENTS, "spend's capture credits the close");
        assertEq(minter.memberAssetsLength(TRADER), 0, "evicted once priced");
    }

    function test_openDuringOutageIsNotTrackedUntilPriced() public {
        _trade(minter, TRADER, 0);
        _setPosition(TRADER, PERP_BTC, LOT);
        _zeroMark();
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC));
        assertEq(minter.memberAssetsLength(TRADER), 0, "unpriced open is not tracked");

        _restoreMark();
        vm.prank(TRADER);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC));
        assertEq(k, LOT_CENTS);
        assertEq(minter.memberAssetsLength(TRADER), 1);
    }

    function test_explicitCaptureOfUnreadableAssetReverts() public {
        _earnLot(minter, TRADER);
        _setReverting(L1Read.POSITION2, PERP_BTC, true);
        vm.expectRevert(bytes("precompile position2"));
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC));
    }

    // ------------------------------------------------------------------
    // Capture: pooled
    // ------------------------------------------------------------------

    /// Once delegated, neither a stranger, nor the owner, nor the owner's
    /// spender can capture the member solo: only the pool can.
    function test_pooledCaptureOnlyByPool() public {
        vm.startPrank(TRADER);
        minter.setSpender(RIVAL);
        minter.setCreditDelegate(POOL);
        vm.stopPrank();
        address[3] memory callers = [STRANGER, TRADER, RIVAL];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(bytes("pooled capture by pool only"));
            minter.capture(TRADER, _a(PERP_BTC));
        }
    }

    function test_pooledCaptureCreditsPoolBank() public {
        vm.prank(TRADER);
        minter.setCreditDelegate(POOL);
        _setPosition(TRADER, PERP_BTC, 0);
        vm.prank(POOL);
        minter.capture(TRADER, _a(PERP_BTC));
        _setPosition(TRADER, PERP_BTC, LOT);

        vm.expectEmit(address(minter));
        emit HypowMinter.Captured(TRADER, POOL, LOT_CENTS);
        vm.prank(POOL);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC));

        assertEq(k, LOT_CENTS);
        assertEq(minter.credits(POOL), LOT_CENTS, "credits go to the pool's bank");
        assertEq(minter.credits(TRADER), 0, "member bank untouched");
        assertEq(_draw(POOL, R0), 0, "no draw until the pool spends");
    }

    /// The pool spends its bank as an ordinary owner.
    function test_poolSpendsItsBank() public {
        vm.prank(TRADER);
        minter.setCreditDelegate(POOL);
        _setPosition(TRADER, PERP_BTC, 0);
        vm.prank(POOL);
        minter.capture(TRADER, _a(PERP_BTC));
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.prank(POOL);
        minter.capture(TRADER, _a(PERP_BTC));

        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.spend(POOL, 1);
        (uint64 round, uint128 k) = _spend(minter, POOL, 30_000);
        assertEq(round, R0);
        assertEq(k, 30_000);
        assertEq(_draw(POOL, R0), 30_000);
        assertEq(minter.credits(POOL), LOT_CENTS - 30_000);
    }

    function test_zeroPooledCaptureCreditsNothing() public {
        vm.prank(TRADER);
        minter.setCreditDelegate(POOL);
        vm.prank(POOL);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC));
        assertEq(k, 0);
        assertEq(minter.credits(POOL), 0);
    }

    function test_switchingDelegationRedirectsOnlyLaterVolume() public {
        _earnLot(minter, TRADER); // banked solo
        vm.prank(TRADER);
        minter.setCreditDelegate(POOL);
        _setPosition(TRADER, PERP_BTC, 3 * LOT);
        vm.prank(POOL);
        minter.capture(TRADER, _a(PERP_BTC));

        assertEq(minter.credits(TRADER), LOT_CENTS, "earlier credits stay in the bank");
        assertEq(minter.credits(POOL), 2 * LOT_CENTS, "delta since the last baseline goes to the pool");
    }

    function test_setCreditDelegateSelfMeansSolo() public {
        vm.prank(TRADER);
        minter.setCreditDelegate(TRADER);
        assertEq(minter.creditDelegate(TRADER), address(0));
    }

    function test_setCreditDelegateEmitsAndBumpsNonce() public {
        vm.expectEmit(address(minter));
        emit HypowMinter.CreditDelegated(TRADER, POOL);
        vm.prank(TRADER);
        minter.setCreditDelegate(POOL);
        assertEq(minter.creditDelegate(TRADER), POOL);
        assertEq(minter.nonces(TRADER), 1);
    }

    // ------------------------------------------------------------------
    // Spend
    // ------------------------------------------------------------------

    function test_spendByOwner() public {
        _earnLot(minter, TRADER);
        vm.expectEmit(address(minter));
        emit HypowMinter.Spent(TRADER, R0, LOT_CENTS, LOT_CENTS);
        (uint64 round, uint128 k) = _spend(minter, TRADER, type(uint128).max);

        assertEq(round, R0);
        assertEq(k, LOT_CENTS);
        assertEq(minter.credits(TRADER), 0);
        uint128 dk = _draw(TRADER, R0);
        assertEq(dk, LOT_CENTS);
    }

    /// Without an authorized spender, nobody but the owner can spend the bank,
    /// so no stranger decides when the owner's savings go into a draw.
    function test_strangerSpendRevertsByDefault() public {
        _earnLot(minter, TRADER);
        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.spend(TRADER, 1);
        assertEq(minter.credits(TRADER), LOT_CENTS);
    }

    function test_authorizedSpender() public {
        _earnLot(minter, TRADER);
        vm.expectEmit(address(minter));
        emit HypowMinter.SpenderSet(TRADER, RIVAL);
        vm.prank(TRADER);
        minter.setSpender(RIVAL);

        vm.prank(RIVAL);
        minter.spend(TRADER, 1);
        uint128 dk = _draw(TRADER, R0);
        assertEq(dk, 1, "draw belongs to the owner, not the spender");
        uint128 rk = _draw(RIVAL, R0);
        assertEq(rk, 0);

        _spend(minter, TRADER, 1);
        assertEq(minter.credits(TRADER), LOT_CENTS - 2, "the owner keeps spending");

        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.spend(TRADER, 1);
    }

    function test_revokeSpender() public {
        _earnLot(minter, TRADER);
        vm.prank(TRADER);
        minter.setSpender(RIVAL);
        vm.prank(TRADER);
        minter.setSpender(address(0));

        vm.prank(RIVAL);
        vm.expectRevert(bytes("not spender"));
        minter.spend(TRADER, 1);
        _spend(minter, TRADER, 1);
        assertEq(minter.credits(TRADER), LOT_CENTS - 1, "address(0) leaves the owner alone");
    }

    function test_spendCapturesTrackedAssetsFirst() public {
        _trade(minter, TRADER, LOT); // tracked, baseline LOT
        _setPosition(TRADER, PERP_BTC, 2 * LOT); // not yet captured
        (, uint128 k) = _spend(minter, TRADER, type(uint128).max);
        assertEq(k, LOT_CENTS, "fresh volume banked and spent in one tx");
    }

    function test_spendCaptureEvictsClosedAsset() public {
        _earnLot(minter, TRADER);
        _setPosition(TRADER, PERP_BTC, 0);
        (, uint128 k) = _spend(minter, TRADER, type(uint128).max);
        assertEq(k, 2 * LOT_CENTS);
        assertEq(minter.memberAssetsLength(TRADER), 0);
    }

    function test_spendSkipsUnreadableTrackedAsset() public {
        _setPosition(TRADER, PERP_BTC, 0);
        _setPosition(TRADER, PERP_ETH, 0);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC, PERP_ETH));
        _setPosition(TRADER, PERP_BTC, LOT);
        _setPosition(TRADER, PERP_ETH, 10_000);
        vm.prank(TRADER);
        minter.capture(TRADER, _a(PERP_BTC, PERP_ETH));
        _setPosition(TRADER, PERP_ETH, 20_000);
        _setReverting(L1Read.POSITION2, PERP_BTC, true);

        (, uint128 k) = _spend(minter, TRADER, type(uint128).max);
        assertEq(k, LOT_CENTS + 300_000 + 300_000, "dead BTC skipped, ETH still captured");
        (int64 szi,) = _slot(TRADER, PERP_BTC);
        assertEq(szi, LOT, "unreadable slot untouched");
        assertEq(_markOf(TRADER, PERP_BTC), BTC_MARK, "unreadable slot's mark untouched");
    }

    /// A failed mainnet read burns all the gas it is forwarded, so dead tracked
    /// assets must not starve the rest of the spend. Dead ids sit first in the
    /// list, the worst case: uncapped, each would leave only 1/64 of the gas.
    function test_spendWithDeadTrackedAssetsFitsGasLimit() public {
        uint32 dead1 = 2;
        uint32 dead2 = 3;
        _setPerpAssetInfo(dead1, 8);
        _setPerpAssetInfo(dead2, 8);
        uint32[] memory all = new uint32[](4);
        (all[0], all[1], all[2], all[3]) = (dead1, dead2, PERP_BTC, PERP_ETH);
        _setPosition(TRADER, dead1, LOT);
        _setPosition(TRADER, dead2, LOT);
        _setPosition(TRADER, PERP_BTC, LOT);
        _setPosition(TRADER, PERP_ETH, 10_000);
        vm.prank(TRADER);
        minter.capture(TRADER, all); // first touch: all four tracked, no credit
        assertEq(minter.memberAssetsLength(TRADER), 4);

        _setPosition(TRADER, PERP_BTC, 2 * LOT);
        _setPosition(TRADER, PERP_ETH, 20_000);
        _setReverting(L1Read.POSITION2, dead1, true);
        _setReverting(L1Read.POSITION2, dead2, true);

        vm.prank(TRADER);
        (, uint128 k) = minter.spend{gas: 2_000_000}(TRADER, type(uint128).max);
        assertEq(k, LOT_CENTS + 300_000, "live assets captured past two dead ones");
    }

    // ------------------------------------------------------------------
    // Untrack
    // ------------------------------------------------------------------

    /// Untracking forgets the baseline without crediting anything: the volume
    /// since the last capture is forfeited, and the next touch re-baselines at
    /// the current position with no credit.
    function test_untrackRemovesAndRebaselines() public {
        _earnLot(minter, TRADER); // tracked, baseline LOT
        _setPosition(TRADER, PERP_BTC, 3 * LOT); // not yet captured

        vm.expectEmit(address(minter));
        emit HypowMinter.AssetUntracked(TRADER, PERP_BTC);
        vm.prank(TRADER);
        minter.untrack(TRADER, PERP_BTC);
        assertEq(minter.memberAssetsLength(TRADER), 0);
        (int64 szi, bool known) = _slot(TRADER, PERP_BTC);
        assertFalse(known, "baseline forgotten");
        assertEq(szi, 0);
        assertEq(minter.credits(TRADER), LOT_CENTS, "nothing credited");

        vm.prank(TRADER);
        uint128 k = minter.capture(TRADER, _a(PERP_BTC));
        assertEq(k, 0, "the next touch re-baselines with no credit");
        (szi, known) = _slot(TRADER, PERP_BTC);
        assertEq(szi, 3 * LOT);
        assertEq(minter.memberAssetsLength(TRADER), 1, "tracked again");
        assertEq(_trade(minter, TRADER, 4 * LOT), LOT_CENTS, "trading after it counts");
    }

    function test_untrackByStrangerReverts() public {
        _earnLot(minter, TRADER);
        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.untrack(TRADER, PERP_BTC);
        assertEq(minter.memberAssetsLength(TRADER), 1);
    }

    function test_untrackBySpender() public {
        _earnLot(minter, TRADER);
        vm.prank(TRADER);
        minter.setSpender(RIVAL);
        vm.prank(RIVAL);
        minter.untrack(TRADER, PERP_BTC);
        assertEq(minter.memberAssetsLength(TRADER), 0);
    }

    /// Only a tracked asset can be untracked: not one registered flat, nor one
    /// never seen.
    function test_untrackUntrackedReverts() public {
        _trade(minter, TRADER, 0);
        vm.startPrank(TRADER);
        vm.expectRevert(bytes("not tracked"));
        minter.untrack(TRADER, PERP_BTC);
        vm.expectRevert(bytes("not tracked"));
        minter.untrack(TRADER, PERP_ETH);
        vm.stopPrank();
    }

    /// Dead markets stay tracked forever through spend, which skips them; the
    /// owner untracks them and spend's loop shrinks to the live assets.
    function test_untrackDeadMarketsShrinksSpend() public {
        uint32 dead1 = 2;
        uint32 dead2 = 3;
        _setPerpAssetInfo(dead1, 8);
        _setPerpAssetInfo(dead2, 8);
        uint32[] memory all = new uint32[](3);
        (all[0], all[1], all[2]) = (dead1, dead2, PERP_BTC);
        _setPosition(TRADER, dead1, LOT);
        _setPosition(TRADER, dead2, LOT);
        _setPosition(TRADER, PERP_BTC, LOT);
        vm.prank(TRADER);
        minter.capture(TRADER, all);
        _setReverting(L1Read.POSITION2, dead1, true);
        _setReverting(L1Read.POSITION2, dead2, true);

        _spend(minter, TRADER, 0);
        assertEq(minter.memberAssetsLength(TRADER), 3, "spend skips dead markets but keeps them");
        vm.startPrank(TRADER);
        uint256 g = gasleft();
        minter.spend{gas: 2_000_000}(TRADER, 0);
        uint256 withDead = g - gasleft();
        minter.untrack(TRADER, dead1);
        minter.untrack(TRADER, dead2);
        g = gasleft();
        minter.spend(TRADER, 0);
        uint256 withoutDead = g - gasleft();
        vm.stopPrank();

        assertEq(minter.memberAssetsLength(TRADER), 1);
        assertEq(minter.memberAssets(TRADER, 0), PERP_BTC);
        assertLt(withoutDead, withDead, "spend no longer pays for dead markets");
        _setPosition(TRADER, PERP_BTC, 2 * LOT);
        (, uint128 k) = _spend(minter, TRADER, type(uint128).max);
        assertEq(k, LOT_CENTS, "the live asset is still captured");
    }

    function test_spendPartialAndClamped() public {
        _earnLot(minter, TRADER);
        (, uint128 k1) = _spend(minter, TRADER, 30_000);
        assertEq(k1, 30_000);
        assertEq(minter.credits(TRADER), LOT_CENTS - 30_000);
        (, uint128 k2) = _spend(minter, TRADER, type(uint128).max);
        assertEq(k2, LOT_CENTS - 30_000, "maxK above the bank clamps");
        uint128 dk = _draw(TRADER, R0);
        assertEq(dk, LOT_CENTS, "same-round spends accumulate");
    }

    function test_spendZeroIsNoop() public {
        (uint64 round, uint128 k) = _spend(minter, TRADER, type(uint128).max);
        assertEq(round, 0);
        assertEq(k, 0);
        _earnLot(minter, TRADER);
        (round, k) = _spend(minter, TRADER, 0);
        assertEq(round, 0);
        assertEq(k, 0);
        assertEq(minter.credits(TRADER), LOT_CENTS);
    }

    function test_delegatedOwnerSpendsOnlyTheOldBank() public {
        _earnLot(minter, TRADER);
        vm.prank(TRADER);
        minter.setCreditDelegate(POOL);
        _setPosition(TRADER, PERP_BTC, 5 * LOT); // pool-bound volume, not yet captured
        (, uint128 k) = _spend(minter, TRADER, type(uint128).max);
        assertEq(k, LOT_CENTS, "spend does not capture a delegated owner's volume");
        (int64 szi,) = _slot(TRADER, PERP_BTC);
        assertEq(szi, LOT, "baseline left for the pool's capture");
    }

    function test_targetRoundIsTwoAheadOfLatest() public view {
        assertEq(minter.drandRound(Drand.GENESIS), 1);
        assertEq(minter.drandRound(Drand.GENESIS + 2), 1);
        assertEq(minter.drandRound(Drand.GENESIS + 3), 2);
        assertEq(minter.targetRound(), minter.drandRound(block.timestamp) + 2);
        assertEq(minter.targetRound(), R0);
    }

    function test_spendTargetsRoundByTimestamp() public {
        _earnLot(minter, TRADER);
        _spend(minter, TRADER, 10);
        vm.warp(block.timestamp + 3);
        (uint64 round,) = _spend(minter, TRADER, 20);
        assertEq(round, R0 + 1);
        uint128 k0 = _draw(TRADER, R0);
        uint128 k1 = _draw(TRADER, R0 + 1);
        assertEq(k0, 10);
        assertEq(k1, 20);
    }

    // ------------------------------------------------------------------
    // Spend permission by signature
    // ------------------------------------------------------------------

    uint256 constant OWNER_PK = 0xA11CE;

    /// Signed permission changes in these tests are valid for an hour.
    uint256 sigDeadline;

    function _signSetSpender(uint256 pk, address owner, address newSpender, uint256 nonce, bytes32 domain)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(minter.SET_SPENDER_TYPEHASH(), owner, newSpender, nonce, sigDeadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _signSetDelegate(uint256 pk, address owner, address pool, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(minter.SET_CREDIT_DELEGATE_TYPEHASH(), owner, pool, nonce, sigDeadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", minter.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _domain(uint256 chainId, address verifying) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HypowMinter"),
                keccak256("5"),
                chainId,
                verifying
            )
        );
    }

    function test_domainSeparatorMatchesEip712() public view {
        assertEq(minter.DOMAIN_SEPARATOR(), _domain(block.chainid, address(minter)));
    }

    /// The app's setup: the owner signs, anyone submits, the gas key spends.
    function test_setSpenderBySig() public {
        address owner = vm.addr(OWNER_PK);
        _earnLot(minter, owner);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        vm.prank(STRANGER);
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
        assertEq(minter.spender(owner), RIVAL);
        assertEq(minter.nonces(owner), 1);

        vm.prank(RIVAL);
        minter.spend(owner, 1);
        assertEq(minter.credits(owner), LOT_CENTS - 1);
    }

    function test_revokeSpenderBySig() public {
        address owner = vm.addr(OWNER_PK);
        _earnLot(minter, owner);
        minter.setSpenderBySig(
            owner, RIVAL, 0, sigDeadline, _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR())
        );
        minter.setSpenderBySig(
            owner,
            address(0),
            1,
            sigDeadline,
            _signSetSpender(OWNER_PK, owner, address(0), 1, minter.DOMAIN_SEPARATOR())
        );
        assertEq(minter.spender(owner), address(0));

        vm.prank(RIVAL);
        vm.expectRevert(bytes("not spender"));
        minter.spend(owner, 1);
    }

    function test_setSpenderBySigReplayReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
        vm.expectRevert(bytes("bad nonce"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
    }

    function test_directChangeInvalidatesPendingSig() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        vm.prank(owner);
        minter.setSpender(STRANGER);
        vm.expectRevert(bytes("bad nonce"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
    }

    function test_setSpenderBySigWrongChainReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, _domain(block.chainid + 1, address(minter)));
        vm.expectRevert(bytes("bad signature"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
    }

    function test_setSpenderBySigWrongContractReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, _domain(block.chainid, address(token)));
        vm.expectRevert(bytes("bad signature"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
    }

    function test_setSpenderBySigWrongSignerReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(0xB0B, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        vm.expectRevert(bytes("bad signature"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
    }

    function test_setSpenderBySigTamperedFieldReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        vm.expectRevert(bytes("bad signature"));
        minter.setSpenderBySig(owner, STRANGER, 0, sigDeadline, sig);
    }

    function test_setSpenderBySigRejectsHighS() public {
        address owner = vm.addr(OWNER_PK);
        bytes32 structHash = keccak256(abi.encode(minter.SET_SPENDER_TYPEHASH(), owner, RIVAL, uint256(0), sigDeadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(OWNER_PK, keccak256(abi.encodePacked("\x19\x01", minter.DOMAIN_SEPARATOR(), structHash)));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory twin = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(bytes("signature s too high"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, twin);
    }

    function test_setSpenderBySigRejectsBadLength() public {
        vm.expectRevert(bytes("bad signature length"));
        minter.setSpenderBySig(vm.addr(OWNER_PK), RIVAL, 0, sigDeadline, new bytes(64));
    }

    function test_setCreditDelegateBySigSharesNonce() public {
        address owner = vm.addr(OWNER_PK);
        minter.setSpenderBySig(
            owner, RIVAL, 0, sigDeadline, _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR())
        );
        bytes memory stale = _signSetDelegate(OWNER_PK, owner, POOL, 0);
        vm.expectRevert(bytes("bad nonce"));
        minter.setCreditDelegateBySig(owner, POOL, 0, sigDeadline, stale);

        minter.setCreditDelegateBySig(owner, POOL, 1, sigDeadline, _signSetDelegate(OWNER_PK, owner, POOL, 1));
        assertEq(minter.creditDelegate(owner), POOL);
        assertEq(minter.nonces(owner), 2);
    }

    function test_setSpenderBySigExpiredReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        vm.warp(sigDeadline + 1);
        vm.expectRevert(bytes("signature expired"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
    }

    function test_setSpenderBySigValidAtDeadline() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        vm.warp(sigDeadline);
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline, sig);
        assertEq(minter.spender(owner), RIVAL);
    }

    function test_setSpenderBySigExtendedDeadlineReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetSpender(OWNER_PK, owner, RIVAL, 0, minter.DOMAIN_SEPARATOR());
        vm.expectRevert(bytes("bad signature"));
        minter.setSpenderBySig(owner, RIVAL, 0, sigDeadline + 1, sig);
    }

    function test_setCreditDelegateBySigExpiredReverts() public {
        address owner = vm.addr(OWNER_PK);
        bytes memory sig = _signSetDelegate(OWNER_PK, owner, POOL, 0);
        vm.warp(sigDeadline + 1);
        vm.expectRevert(bytes("signature expired"));
        minter.setCreditDelegateBySig(owner, POOL, 0, sigDeadline, sig);
    }

    // ------------------------------------------------------------------
    // drand verification (real evmnet fixtures)
    // ------------------------------------------------------------------

    function test_drandFixturesVerify() public {
        VerifierHarness h = new VerifierHarness(IHypowToken(address(token)));
        for (uint256 i = 0; i < 4; i++) {
            bytes memory sig = Drand.sig(i);
            assertEq(h.verifiedSeed(R0 + uint64(i), sig), keccak256(sig));
        }
    }

    function test_drandRejectsSignatureForOtherRound() public {
        VerifierHarness h = new VerifierHarness(IHypowToken(address(token)));
        vm.expectRevert(bytes("bad drand signature"));
        h.verifiedSeed(R0 + 1, Drand.sig(0));
    }

    function test_drandRejectsMutatedSignature() public {
        VerifierHarness h = new VerifierHarness(IHypowToken(address(token)));
        bytes memory sig = Drand.sig(0);
        sig[63] ^= 0x01;
        vm.expectRevert(bytes("signature not on G1"));
        h.verifiedSeed(R0, sig);
    }

    function test_drandRejectsValidPointThatIsNotTheSignature() public {
        VerifierHarness h = new VerifierHarness(IHypowToken(address(token)));
        // The G1 generator (1, 2) is on the curve but is not drand's signature.
        vm.expectRevert(bytes("bad drand signature"));
        h.verifiedSeed(R0, abi.encodePacked(uint256(1), uint256(2)));
    }

    function test_drandRejectsNonCanonicalCoordinates() public {
        VerifierHarness h = new VerifierHarness(IHypowToken(address(token)));
        // x + p is the same field element as x but a different byte string, so it
        // would yield a different seed for the same round. It must be rejected.
        uint256 p = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        (uint256 x, uint256 y) = abi.decode(Drand.sig(3), (uint256, uint256));
        vm.expectRevert(bytes("signature not on G1"));
        h.verifiedSeed(R0 + 3, abi.encodePacked(x + p, y));
    }

    function test_drandRejectsWrongLength() public {
        VerifierHarness h = new VerifierHarness(IHypowToken(address(token)));
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        h.verifiedSeed(R0, abi.encodePacked(Drand.sig(0), uint8(0)));
    }

    // ------------------------------------------------------------------
    // Settle
    // ------------------------------------------------------------------

    function _spendLot(address owner) internal {
        _earnLot(minter, owner);
        _spend(minter, owner, type(uint128).max);
    }

    function test_settleWinMintsToOwnerNotCaller() public {
        _spendLot(TRADER);
        uint256 r0 = Emission.currentReward(0);
        vm.expectEmit(address(minter));
        emit HypowMinter.Won(TRADER, R0, 0, 1, r0, STRANGER);
        vm.prank(STRANGER);
        uint256 reward = minter.settle(TRADER, R0, _sig(R0), 1);

        assertEq(reward, r0);
        assertEq(token.balanceOf(TRADER), r0);
        assertEq(token.balanceOf(STRANGER), 0);
        assertEq(minter.winCount(), 1);
        assertEq(minter.lastWonRound(), R0);
        assertEq(_draw(TRADER, R0), 0, "draw deleted");
        (address owner, uint128 wonDifficulty, uint128 wonReward) = minter.wonBy(R0);
        assertEq(owner, TRADER);
        assertEq(wonDifficulty, 1);
        assertEq(wonReward, r0);
    }

    function test_settleBadSignatureReverts() public {
        _spendLot(TRADER);
        vm.expectRevert(bytes("bad drand signature"));
        minter.settle(TRADER, R0, _sig(R0 + 1), 1);
        bytes memory sig = _sig(R0);
        sig[0] ^= 0x01;
        vm.expectRevert(bytes("signature not on G1"));
        minter.settle(TRADER, R0, sig, 1);
    }

    function test_settleLosingTicketRevertsAndKeepsDraw() public {
        (token, minter) = _deploy(type(uint128).max, 2016);
        _spendLot(TRADER);
        vm.expectRevert(bytes("ticket loses"));
        minter.settle(TRADER, R0, _sig(R0), 1);
        uint128 dk = _draw(TRADER, R0);
        assertEq(dk, LOT_CENTS, "a losing nonce must not void the draw's other tickets");
        assertEq(minter.winCount(), 0);
    }

    function test_settleNonceOutOfRange() public {
        _spendLot(TRADER);
        vm.expectRevert(bytes("nonce out of range"));
        minter.settle(TRADER, R0, _sig(R0), 0);
        vm.expectRevert(bytes("nonce out of range"));
        minter.settle(TRADER, R0, _sig(R0), uint256(LOT_CENTS) + 1);
        minter.settle(TRADER, R0, _sig(R0), LOT_CENTS); // top of range is a valid ticket
    }

    function test_settleWithoutDrawReverts() public {
        vm.expectRevert(bytes("no draw"));
        minter.settle(TRADER, R0, _sig(R0), 1);
    }

    function test_settleTwiceReverts() public {
        _spendLot(TRADER);
        minter.settle(TRADER, R0, _sig(R0), 1);
        vm.expectRevert(bytes("round closed"));
        minter.settle(TRADER, R0, _sig(R0), 1);
    }

    /// Bank a lot for `owner` and spend it on `round`.
    function _spendOn(address owner, uint64 round) internal {
        vm.warp(Drand.timeTargeting(round));
        _spendLot(owner);
        assertEq(_draw(owner, round), LOT_CENTS);
    }

    /// A win on R closes R and every earlier round, and nothing later: tickets on
    /// R+1 and R+2 bought before the win still win and mint afterwards.
    function test_winClosesItsRoundAndEarlierOnly() public {
        address carol = address(0xE1E1);
        _spendOn(TRADER, R0);
        _spendOn(RIVAL, R0 + 1);
        _spendOn(carol, R0 + 2);
        _spendOn(STRANGER, R0 + 3);

        vm.expectEmit(address(minter));
        emit HypowMinter.Won(RIVAL, R0 + 1, 0, 1, Emission.currentReward(0), address(this));
        minter.settle(RIVAL, R0 + 1, _sig(R0 + 1), 1);
        assertEq(minter.lastWonRound(), R0 + 1);

        vm.expectRevert(bytes("round closed"));
        minter.settle(TRADER, R0, _sig(R0), 1);
        vm.expectRevert(bytes("round closed"));
        minter.settle(RIVAL, R0 + 1, _sig(R0 + 1), 1);

        minter.settle(carol, R0 + 2, _sig(R0 + 2), 1);
        minter.settle(STRANGER, R0 + 3, _sig(R0 + 3), 1);
        assertEq(minter.winCount(), 3);
        assertEq(minter.lastWonRound(), R0 + 3);
        assertEq(token.balanceOf(carol), Emission.currentReward(1));
        assertEq(token.balanceOf(STRANGER), Emission.currentReward(2));
        assertEq(token.balanceOf(TRADER), 0, "the closed round's ticket never mints");
    }

    /// A ticket bought before a win on an earlier round survives it.
    function test_ticketSurvivesWinOnEarlierRound() public {
        _spendOn(TRADER, R0);
        _spendOn(RIVAL, R0 + 1);
        minter.settle(TRADER, R0, _sig(R0), 1);
        minter.settle(RIVAL, R0 + 1, _sig(R0 + 1), 1);
        assertEq(token.balanceOf(RIVAL), Emission.currentReward(1));
    }

    /// Two winners on one round: the first to cash takes it, the second is orphaned.
    function test_secondWinnerOnSameRoundReverts() public {
        _spendLot(TRADER);
        _spendLot(RIVAL);
        minter.settle(TRADER, R0, _sig(R0), 1);
        vm.expectRevert(bytes("round closed"));
        minter.settle(RIVAL, R0, _sig(R0), 1);
        assertEq(minter.winCount(), 1);
    }

    /// Cashing out of order: a win on R+1 cashed first closes R, so the slower
    /// winner on R loses theirs.
    function test_laterRoundCashedFirstClosesEarlierRound() public {
        _spendOn(TRADER, R0);
        _spendOn(RIVAL, R0 + 1);
        minter.settle(RIVAL, R0 + 1, _sig(R0 + 1), 1);
        vm.expectRevert(bytes("round closed"));
        minter.settle(TRADER, R0, _sig(R0), 1);
    }

    /// With realistic timing (a round is cashed only once published, two rounds
    /// behind the target), a spend after a win always lands on an open round.
    function test_spendAfterWinTargetsOpenRound() public {
        _spendLot(TRADER);
        vm.warp(Drand.timeTargeting(R0 + 2)); // R0 is now the latest published round
        minter.settle(TRADER, R0, _sig(R0), 1);

        _earnLot(minter, RIVAL);
        (uint64 round,) = _spend(minter, RIVAL, type(uint128).max);
        assertEq(round, R0 + 2);
        assertGt(round, minter.lastWonRound());
        minter.settle(RIVAL, R0 + 2, _sig(R0 + 2), 1);
        assertEq(token.balanceOf(RIVAL), Emission.currentReward(1));
    }

    /// A block timestamp lagging far enough that the target is at or below the
    /// last won round: spend reverts and the bank keeps its credits, instead of
    /// burning them into a draw that can never settle.
    function test_spendOnClosedTargetRevertsAndKeepsBank() public {
        _spendOn(TRADER, R0 + 1);
        minter.settle(TRADER, R0 + 1, _sig(R0 + 1), 1);
        _earnLot(minter, RIVAL);

        uint64[2] memory lagged = [R0 + 1, R0];
        for (uint256 i = 0; i < lagged.length; i++) {
            vm.warp(Drand.timeTargeting(lagged[i]));
            assertLe(minter.targetRound(), minter.lastWonRound());
            vm.prank(RIVAL);
            vm.expectRevert(bytes("round closed"));
            minter.spend(RIVAL, type(uint128).max);
        }
        assertEq(minter.credits(RIVAL), LOT_CENTS);
    }

    /// Settle wins iff keccak256(seed, owner, nonce) < max/difficulty, across the
    /// whole difficulty range, with the seed from a real verified signature.
    function testFuzz_settleWinsIffTicketBelowTarget(uint128 d, uint256 nonce) public {
        d = uint128(bound(d, 1, type(uint128).max));
        (token, minter) = _deploy(d, 2016);
        _spendLot(TRADER);
        nonce = bound(nonce, 1, LOT_CENTS);

        bytes32 h = keccak256(abi.encode(keccak256(_sig(R0)), TRADER, nonce));
        bool wins = uint256(h) < type(uint256).max / uint256(d);
        if (!wins) vm.expectRevert(bytes("ticket loses"));
        minter.settle(TRADER, R0, _sig(R0), nonce);
        assertEq(minter.winCount(), wins ? 1 : 0);
    }

    /// Over many draws at a fixed difficulty, the share of winning tickets matches
    /// 1/D within a generous bound (a loose statistical sanity check of the ticket
    /// hash, using the real seeds of all four fixture rounds).
    function test_ticketWinRateMatchesDifficulty() public pure {
        uint256 d = 64;
        uint256 target = type(uint256).max / d;
        uint256 wins;
        uint256 trials;
        for (uint256 i = 0; i < 4; i++) {
            bytes32 seed = keccak256(Drand.sig(i));
            for (uint256 n = 1; n <= 4096; n++) {
                if (uint256(keccak256(abi.encode(seed, address(0xA1A1), n))) < target) wins++;
                trials++;
            }
        }
        // Expected 256 wins; binomial sd ≈ 15.9, so ±5 sd is [176, 336].
        assertGt(wins, 176);
        assertLt(wins, 336);
        assertEq(trials, 16_384);
    }

    // ------------------------------------------------------------------
    // Emission and cap
    // ------------------------------------------------------------------

    function test_rewardFollowsEmissionByWinIndex() public {
        _spendLot(TRADER);
        minter.settle(TRADER, R0, _sig(R0), 1);
        vm.warp(Drand.timeTargeting(R0 + 1));
        _trade(minter, TRADER, 2 * LOT);
        _spend(minter, TRADER, type(uint128).max);
        minter.settle(TRADER, R0 + 1, _sig(R0 + 1), 1);
        assertEq(token.balanceOf(TRADER), Emission.currentReward(0) + Emission.currentReward(1));
        assertLt(Emission.currentReward(1), Emission.currentReward(0));
    }

    function test_settleClampsRewardAtCap() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockSmallCapToken small = new MockSmallCapToken(predicted, 1e18);
        minter = new HypowMinter(IHypowToken(address(small)), 1, 60, 2016);
        require(address(minter) == predicted, "address mismatch");

        _spendLot(TRADER);
        assertEq(minter.settle(TRADER, R0, _sig(R0), 1), 1e18, "clamped to the remaining cap");
        vm.warp(Drand.timeTargeting(R0 + 1));
        _trade(minter, TRADER, 2 * LOT);
        _spend(minter, TRADER, type(uint128).max);
        assertEq(minter.settle(TRADER, R0 + 1, _sig(R0 + 1), 1), 0, "cap exhausted: the win still counts");

        assertEq(small.totalSupply(), small.CAP());
        assertEq(minter.winCount(), 2);
        (address owner,, uint128 reward) = minter.wonBy(R0 + 1);
        assertEq(owner, TRADER);
        assertEq(reward, 0);
    }

    // ------------------------------------------------------------------
    // Difficulty retargeting (v4's rule on a block.timestamp clock, plus the
    // crash escape). Window 2 at 60 s: a full window's target is 120 s, and
    // the escape fires once a window has run 480 s.
    // ------------------------------------------------------------------

    /// One win on `m`, settled `secs` seconds after deployment, on the round
    /// after the last won one (a fixture round, so at most four wins per test):
    /// bank a lot, spend it, cash the first winning ticket. The spend needs the
    /// time that targets the round; settle doesn't read the clock except to
    /// retarget, so the warp to the settle time is free. Alternates the
    /// position so every call realises a lot.
    function _winOnce(HypowMinter m, uint64 secs) internal {
        uint64 round = m.lastWonRound() == 0 ? R0 : m.lastWonRound() + 1;
        vm.warp(Drand.timeTargeting(round));
        (int64 szi, bool known,) = m.memberSlots(TRADER, PERP_BTC);
        if (!known) _trade(m, TRADER, 0);
        _trade(m, TRADER, szi == 0 ? LOT : int64(0));
        (, uint128 k) = _spend(m, TRADER, type(uint128).max);
        vm.warp(deployedAt + secs);
        m.settle(TRADER, round, _sig(round), _winningNonce(m, TRADER, round, k));
    }

    function test_retargetDoesNotFireBeforeWindow() public {
        (, HypowMinter m) = _deploy(1, 2);
        _winOnce(m, 60);
        assertEq(m.difficulty(), 1);
        assertEq(m.lastRetargetTime(), deployedAt);
    }

    function test_retargetTightensWhenWinsAreFast() public {
        (, HypowMinter m) = _deploy(100, 2);
        _winOnce(m, 1);
        vm.recordLogs();
        _winOnce(m, 2);
        assertEq(m.difficulty(), 400, "clamped at 4x up");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool emitted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == HypowMinter.DifficultyRetargeted.selector) {
                assertEq(logs[i].data, abi.encode(uint128(100), uint128(400)));
                emitted = true;
            }
        }
        assertTrue(emitted, "DifficultyRetargeted emitted");
        assertEq(m.lastRetargetTime(), deployedAt + 2);
        (, uint128 wonDifficulty,) = m.wonBy(m.lastWonRound());
        assertEq(wonDifficulty, 100, "the win publishes the difficulty it was priced at");
    }

    function test_retargetLoosensWhenWinsAreSlow() public {
        (, HypowMinter m) = _deploy(100, 2);
        _winOnce(m, 200);
        _winOnce(m, 400);
        assertEq(m.difficulty(), 30, "100 * 120 / 400");
    }

    function test_retargetClampedAt4xDown() public {
        (, HypowMinter m) = _deploy(100, 2);
        _winOnce(m, 400);
        _winOnce(m, 10_000);
        assertEq(m.difficulty(), 25);
    }

    /// Wins at the normal pace, then volume crashes: the first win after the
    /// window has run 4x its whole target time retargets at once, ÷4, and
    /// starts a fresh window. A second escape needs another full 4x.
    function test_crashEscapeRetargetsEarly() public {
        (, HypowMinter m) = _deploy(100, 4); // window target 240 s, escape at 960 s
        _winOnce(m, 60);
        _winOnce(m, 960); // win 2 of 4
        assertEq(m.difficulty(), 25, "escape: /4 at once");
        assertEq(m.lastRetargetTime(), deployedAt + 960);
        assertEq(m.lastRetargetWinCount(), 2, "a fresh window starts at the escape");

        _winOnce(m, 960 + 959);
        assertEq(m.difficulty(), 25, "just under another 4x window time: no escape");
        _winOnce(m, 960 + 960);
        assertEq(m.difficulty(), 6, "second escape after another full 4x");
        assertEq(m.lastRetargetWinCount(), 4);
    }

    /// An elapsed just under the threshold does not fire; at the threshold it does.
    function test_crashEscapeThreshold() public {
        (, HypowMinter m) = _deploy(100, 4);
        _winOnce(m, 959);
        assertEq(m.difficulty(), 100);
        assertEq(m.lastRetargetWinCount(), 0);
        _winOnce(m, 960);
        assertEq(m.difficulty(), 25);
        assertEq(m.lastRetargetWinCount(), 2);
    }

    /// After an escape, the next regular retarget comes a full window of wins
    /// later, not at the next multiple of the window.
    function test_windowRestartsAfterEscape() public {
        (, HypowMinter m) = _deploy(100, 2);
        _winOnce(m, 480); // win 1: escape, 100 → 25
        assertEq(m.difficulty(), 25);
        _winOnce(m, 490); // win 2: one win into the new window
        assertEq(m.difficulty(), 25, "no retarget at the old window boundary");
        _winOnce(m, 500); // win 3: new window full, 20 s for 2 wins → clamped x4
        assertEq(m.difficulty(), 100);
        assertEq(m.lastRetargetWinCount(), 3);
    }

    function test_retargetFloorsToOneNotZero() public {
        (, HypowMinter m) = _deploy(1, 2);
        _winOnce(m, 1);
        _winOnce(m, 100_000);
        assertEq(m.difficulty(), 1);
    }

    /// A timestamp at or behind the last retarget counts as one second elapsed,
    /// so the clamp holds: 4x up, never a division by zero.
    function test_retargetTreatsStalledClockAsOneSecond() public {
        (, HypowMinter m) = _deploy(100, 2);
        _winOnce(m, 1);
        _winOnce(m, 0);
        assertEq(m.difficulty(), 400);
        assertEq(m.lastRetargetTime(), deployedAt);
    }

    function test_retargetFiresEveryWindow() public {
        (, HypowMinter m) = _deploy(4, 2);
        _winOnce(m, 60);
        _winOnce(m, 120); // on target: unchanged, but the clock resets
        assertEq(m.difficulty(), 4);
        assertEq(m.lastRetargetTime(), deployedAt + 120);
        _winOnce(m, 121);
        assertEq(m.difficulty(), 4, "mid-window: no retarget");
        _winOnce(m, 122);
        assertEq(m.difficulty(), 16, "second window fast: 4x up");
    }

    /// At a full-window boundary that is not an escape, the retargeted
    /// difficulty is exactly v4's formula, for any win times, and stays within
    /// [d/4, 4d], never zero.
    function testFuzz_retargetStaysWithinClamp(uint64 first, uint64 gap) public {
        first = uint64(bound(first, 0, 479));
        gap = uint64(bound(gap, 1, 10_000_000));
        (, HypowMinter m) = _deploy(100, 2);
        _winOnce(m, first);
        assertEq(m.difficulty(), 100, "no escape before 480 s");
        _winOnce(m, first + gap);
        uint256 d1 = m.difficulty();

        uint256 elapsed = uint256(first) + gap;
        uint256 targetElapsed = 2 * 60;
        if (elapsed < targetElapsed / 4) elapsed = targetElapsed / 4;
        if (elapsed > targetElapsed * 4) elapsed = targetElapsed * 4;
        uint256 expected = 100 * targetElapsed / elapsed;
        assertEq(d1, expected == 0 ? 1 : expected, "retarget formula");
        assertGe(d1, 25);
        assertLe(d1, 400);
    }
}
