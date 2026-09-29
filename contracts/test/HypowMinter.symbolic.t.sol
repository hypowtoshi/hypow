// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HypowMinter} from "../src/HypowMinter.sol";
import {IHypowToken} from "../src/interfaces/IHypowToken.sol";
import {L1Read} from "../src/lib/L1Read.sol";
import {Emission} from "../src/lib/Emission.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";
import {MockMintableToken} from "./mocks/MockMintableToken.sol";
import {Drand} from "./utils/Drand.sol";

/// @dev Shared Halmos setup: etched precompile mocks with a symbolic-friendly
///      perp at assets 0 and 1, and time fixed so spends target Drand.ROUND_0.
abstract contract SymbolicBase is Test {
    uint32 constant ASSET = 0;
    uint32 constant ASSET2 = 1;

    function _etch() internal {
        MockPrecompiles template = new MockPrecompiles();
        vm.etch(L1Read.POSITION2, address(template).code);
        vm.etch(L1Read.MARK_PX, address(template).code);
        vm.etch(L1Read.PERP_ASSET_INFO, address(template).code);
        _setPerp(ASSET);
        _setPerp(ASSET2);
        vm.warp(Drand.timeTargeting(Drand.ROUND_0));
    }

    function _setPerp(uint32 asset) internal {
        MockPrecompiles(L1Read.PERP_ASSET_INFO)
            .setPerpAssetInfo(
                asset,
                L1Read.PerpAssetInfo({
                    coin: "PERP", marginTableId: 0, szDecimals: 8, maxLeverage: 50, onlyIsolated: false
                })
            );
    }

    function _setPos(address u, uint32 asset, int64 szi) internal {
        MockPrecompiles(L1Read.POSITION2)
            .setPosition(
                u, asset, L1Read.Position({szi: szi, entryNtl: 0, isolatedRawUsd: 0, leverage: 1, isIsolated: false})
            );
    }

    function _setMark(uint32 asset, uint64 mark) internal {
        MockPrecompiles(L1Read.MARK_PX).setMarkPx(asset, mark);
    }

    function _one(uint32 a0) internal pure returns (uint32[] memory a) {
        a = new uint32[](1);
        a[0] = a0;
    }

    function _two(uint32 a0, uint32 a1) internal pure returns (uint32[] memory a) {
        a = new uint32[](2);
        a[0] = a0;
        a[1] = a1;
    }

    function _min(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }

    /// Credit for `base` → `cur` under the split rule, in uint256: the size the
    /// change takes off the base position (all of it when the sign flips) at
    /// `low`, and the size it adds (all of the new side on a flip) at `mark`.
    function _split(int64 base, int64 cur, uint64 low, uint64 mark) internal pure returns (uint256) {
        uint256 ab = _mag(base);
        uint256 ac = _mag(cur);
        if ((base > 0 && cur < 0) || (base < 0 && cur > 0)) {
            return (ab * uint256(low) + ac * uint256(mark)) / 10_000;
        }
        return ab > ac ? (ab - ac) * uint256(low) / 10_000 : (ac - ab) * uint256(mark) / 10_000;
    }

    function _mag(int64 x) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x >= 0 ? uint256(int256(x)) : uint256(-int256(x));
    }

    /// Realised volume of the leg `base` → `cur` at `mark`, in uint256 (no
    /// saturation), mirroring _deltaCents. |szi| < 2^63 and mark < 2^64
    /// keep the product/1e4 below 2^114, so the contract never saturates here.
    function _realised(int64 base, int64 cur, uint64 mark) internal pure returns (uint256) {
        int256 raw = int256(cur) - int256(base);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absDelta = raw >= 0 ? uint256(raw) : uint256(-raw);
        return absDelta * uint256(mark) / 10_000;
    }
}

/// @title HypowMinter symbolic proofs (Halmos) — capture / credit accounting
/// @notice Symbolic verification of the surface where a member's HyperCore
///         position is read and turned into credits. The HyperCore reads are
///         driven through the etched mocks with SYMBOLIC return values, so each
///         property holds for every position and price.
///
///         Headline: two-sided EXACTNESS. A capture credits exactly
///         |Δszi|·price/1e4 since the last baseline, neither more nor less, and
///         the bank (or the pool's bank) grows by exactly the returned amount.
///         The price is the current mark for a change from a zero baseline, and
///         the lower of the current mark and the mark stored by the slot's last
///         priced capture otherwise; a close is never credited above the mark at
///         the last capture. The v5 first-touch rule is pinned too: a first
///         capture credits nothing and baselines at the current position,
///         whatever it is.
///
///         Not covered here: szDecimals is fixed (the divisor is
///         szDecimals-independent by construction), and the markPx scaling
///         identity is a HyperCore property validated against the live precompile.
///
///         `capture` never touches the token, so the token↔minter wiring is left
///         unconfigured.
contract HypowMinterSymbolic is SymbolicBase {
    HypowMinter minter;
    address constant MEMBER = address(0xA1);
    address constant POOL = address(0xB1);

    function setUp() public {
        _etch();
        minter = new HypowMinter(IHypowToken(address(0xdead)), type(uint128).max, 60, 2016);
    }

    /// Register `asset` flat so the next capture credits from zero.
    function _registerFlat(uint32 asset) internal {
        _setPos(MEMBER, asset, 0);
        vm.prank(MEMBER);
        minter.capture(MEMBER, _one(asset));
    }

    /// First touch credits nothing for ANY position and mark, baselines at the
    /// current position, stores the mark iff a position is held, and tracks the
    /// asset iff the position is non-zero.
    function checkFirstTouchCreditsNothing(int64 szi, uint64 mark) public {
        _setPos(MEMBER, ASSET, szi);
        _setMark(ASSET, mark);
        vm.prank(MEMBER);
        uint128 credited = minter.capture(MEMBER, _one(ASSET));

        assert(credited == 0);
        assert(minter.credits(MEMBER) == 0);
        (int64 base, bool known, uint64 stored) = minter.memberSlots(MEMBER, ASSET);
        assert(known);
        assert(base == szi);
        assert(stored == (szi != 0 ? mark : 0));
        assert(minter.memberAssetsLength(MEMBER) == (szi != 0 ? 1 : 0));
    }

    /// After a flat registration, the open is credited exactly from zero and the
    /// bank grows by exactly the returned amount.
    function checkOpenAfterFlatRegistrationExact(int64 szi, uint64 mark) public {
        _registerFlat(ASSET);
        _setPos(MEMBER, ASSET, szi);
        _setMark(ASSET, mark);
        vm.prank(MEMBER);
        uint128 credited = minter.capture(MEMBER, _one(ASSET));

        assert(uint256(credited) == _realised(0, szi, mark));
        assert(minter.credits(MEMBER) == credited);
    }

    /// A moving position from a non-zero baseline credits exactly the part it
    /// takes off the baseline at min(mark0, mark1) plus the part it adds at
    /// mark1 (a flip closes all of szi0 and opens all of szi1), for ANY mark
    /// stored at the baseline and ANY current mark. A priced change stores
    /// mark1; a priced unchanged capture stores max(mark0, mark1). A zero
    /// current mark credits nothing and keeps baseline and mark. The baseline is
    /// concrete and the new position symbolic, sweeping the delta across both
    /// signs (an unchanged position included): a symbolic stored-then-reloaded
    /// baseline inside nonlinear arithmetic times out for no added coverage (the
    /// zero-baseline case is proven above).
    function checkCaptureCreditExactSecondTouch(int64 szi1, uint64 mark0, uint64 mark1) public {
        int64 szi0 = 500_000_000;
        _setPos(MEMBER, ASSET, szi0);
        _setMark(ASSET, mark0);
        vm.prank(MEMBER);
        minter.capture(MEMBER, _one(ASSET)); // baseline szi0 at mark0, no credit
        uint128 bankBefore = minter.credits(MEMBER);

        _setPos(MEMBER, ASSET, szi1);
        _setMark(ASSET, mark1);
        vm.prank(MEMBER);
        uint128 credited = minter.capture(MEMBER, _one(ASSET));

        assert(uint256(minter.credits(MEMBER)) == uint256(bankBefore) + uint256(credited));
        if (mark1 == 0) {
            assert(credited == 0);
            _assertSlot(szi0, mark0);
        } else {
            assert(uint256(credited) == _split(szi0, szi1, _min(mark0, mark1), mark1));
            _assertSlot(szi1, szi1 == szi0 && mark0 > mark1 ? mark0 : mark1);
        }
    }

    function _assertSlot(int64 szi, uint64 mark) internal view {
        (int64 base,, uint64 stored) = minter.memberSlots(MEMBER, ASSET);
        assert(base == szi && stored == mark);
    }

    /// The attack's bound: a position whose last capture read mark0, closed
    /// and captured at ANY later mark1, solo or through the member's pool, is
    /// credited exactly |szi|·min(mark0, mark1)/1e4, so never above the last
    /// capture's mark, into exactly one bank. The last capture here is the held
    /// first touch; that every priced capture stores its mark the same way is
    /// proven in the second-touch proof. The position is concrete (see there);
    /// both marks are symbolic.
    function checkCloseNeverAboveLastCaptureMark(uint64 mark0, uint64 mark1, bool pooled) public {
        vm.assume(mark1 != 0);
        int64 szi = -700_000_000;
        address dest = pooled ? POOL : MEMBER;
        if (pooled) {
            vm.prank(MEMBER);
            minter.setCreditDelegate(POOL);
        }
        _setPos(MEMBER, ASSET, szi);
        _setMark(ASSET, mark0);
        vm.prank(dest);
        minter.capture(MEMBER, _one(ASSET)); // held first touch: stores mark0

        _setPos(MEMBER, ASSET, 0);
        _setMark(ASSET, mark1);
        vm.prank(dest);
        uint128 closed = minter.capture(MEMBER, _one(ASSET));

        // Exact at the lower mark. The bound follows, since |szi|·p/1e4 is
        // monotone in p; asserting it directly asks the solver to prove that
        // monotonicity over symbolic products and times out.
        assert(uint256(closed) == _realised(szi, 0, _min(mark0, mark1)));
        assert(minter.credits(dest) == closed);
        assert(minter.credits(pooled ? MEMBER : POOL) == 0);
        assert(minter.memberAssetsLength(MEMBER) == 0);
    }

    /// One call over two assets credits the exact sum of both legs.
    function checkCaptureMultiAssetExact(int64 sziA, int64 sziB, uint64 markA, uint64 markB) public {
        _registerFlat(ASSET);
        _registerFlat(ASSET2);
        _setPos(MEMBER, ASSET, sziA);
        _setMark(ASSET, markA);
        _setPos(MEMBER, ASSET2, sziB);
        _setMark(ASSET2, markB);
        vm.prank(MEMBER);
        uint128 credited = minter.capture(MEMBER, _two(ASSET, ASSET2));

        uint256 sum = _realised(0, sziA, markA) + _realised(0, sziB, markB);
        assert(uint256(credited) == sum);
        assert(uint256(minter.credits(MEMBER)) == sum);
    }

    /// Closing one of two tracked assets swap-removes exactly it, keeps its slot
    /// known at a zero baseline, and a re-open is tracked again.
    function checkEvictOnCloseKeepsSlotKnown(int64 sziA, int64 sziB) public {
        vm.assume(sziA != 0 && sziB != 0);
        _setPos(MEMBER, ASSET, sziA);
        _setMark(ASSET, 1_000);
        _setPos(MEMBER, ASSET2, sziB);
        _setMark(ASSET2, 1_000);
        vm.prank(MEMBER);
        minter.capture(MEMBER, _two(ASSET, ASSET2));
        assert(minter.memberAssetsLength(MEMBER) == 2);

        _setPos(MEMBER, ASSET, 0);
        vm.prank(MEMBER);
        minter.capture(MEMBER, _one(ASSET));
        assert(minter.memberAssetsLength(MEMBER) == 1);
        assert(minter.memberAssets(MEMBER, 0) == ASSET2);
        (int64 base, bool known,) = minter.memberSlots(MEMBER, ASSET);
        assert(known && base == 0);

        _setPos(MEMBER, ASSET, sziA);
        vm.prank(MEMBER);
        minter.capture(MEMBER, _one(ASSET));
        assert(minter.memberAssetsLength(MEMBER) == 2);
    }

    /// A flat first touch never grows the tracked list (anti-spam).
    function checkFlatRegistrationNotTracked(uint32 asset) public {
        _setPerp(asset);
        _setPos(MEMBER, asset, 0);
        vm.prank(MEMBER);
        minter.capture(MEMBER, _one(asset));
        assert(minter.memberAssetsLength(MEMBER) == 0);
    }

    /// For ANY caller, spender setting and position, untrack never changes any
    /// bank, and succeeds iff the caller is the owner or their spender; on
    /// success the asset leaves the list and its baseline is forgotten.
    function checkUntrackNeverChangesCredits(address caller, address allowed, int64 szi) public {
        vm.assume(szi != 0);
        _registerFlat(ASSET);
        _setPos(MEMBER, ASSET, int64(1e9));
        _setMark(ASSET, 1_000);
        vm.prank(MEMBER);
        minter.capture(MEMBER, _one(ASSET)); // banks, tracks
        _setPos(MEMBER, ASSET, szi); // uncaptured volume
        vm.prank(MEMBER);
        minter.setSpender(allowed);
        uint128 bank = minter.credits(MEMBER);
        uint128 callerBank = minter.credits(caller);

        vm.prank(caller);
        (bool ok,) = address(minter).call(abi.encodeCall(minter.untrack, (MEMBER, ASSET)));
        assert(ok == (caller == MEMBER || (allowed != address(0) && caller == allowed)));
        assert(minter.credits(MEMBER) == bank);
        assert(minter.credits(caller) == callerBank);
        if (ok) {
            (, bool known,) = minter.memberSlots(MEMBER, ASSET);
            assert(!known);
            assert(minter.memberAssetsLength(MEMBER) == 0);
        }
    }

    /// For ANY caller and ANY spender setting, a solo capture succeeds iff the
    /// caller is the member or the member's spender, exactly the spend rule. A
    /// refused capture changes nothing: no credit, no baseline, no tracking.
    function checkSoloCaptureOnlyOwnerOrSpender(address caller, address allowed, int64 szi, uint64 mark) public {
        vm.prank(MEMBER);
        minter.setSpender(allowed);
        _setPos(MEMBER, ASSET, szi);
        _setMark(ASSET, mark);
        vm.prank(caller);
        (bool ok,) = address(minter).call(abi.encodeCall(minter.capture, (MEMBER, _one(ASSET))));
        assert(ok == (caller == MEMBER || (allowed != address(0) && caller == allowed)));
        if (!ok) {
            (, bool known,) = minter.memberSlots(MEMBER, ASSET);
            assert(!known);
            assert(minter.memberAssetsLength(MEMBER) == 0);
        }
        assert(minter.credits(MEMBER) == 0 && minter.credits(caller) == 0);
    }

    /// A pooled member's volume can only be captured by the pool.
    function checkPooledCaptureOnlyPool(address caller, int64 szi, uint64 mark) public {
        vm.assume(caller != POOL);
        vm.prank(MEMBER);
        minter.setCreditDelegate(POOL);
        _setPos(MEMBER, ASSET, szi);
        _setMark(ASSET, mark);
        vm.prank(caller);
        (bool ok,) = address(minter).call(abi.encodeCall(minter.capture, (MEMBER, _one(ASSET))));
        assert(!ok);
    }

    /// The pool's capture credits exactly `credits[pool] += k` and leaves the
    /// member's bank untouched.
    function checkPooledCaptureCreditsPoolBank(int64 szi, uint64 mark) public {
        vm.prank(MEMBER);
        minter.setCreditDelegate(POOL);
        _setPos(MEMBER, ASSET, 0);
        vm.prank(POOL);
        minter.capture(MEMBER, _one(ASSET));

        _setPos(MEMBER, ASSET, szi);
        _setMark(ASSET, mark);
        uint128 poolBefore = minter.credits(POOL);
        vm.prank(POOL);
        uint128 credited = minter.capture(MEMBER, _one(ASSET));

        uint256 realised = _realised(0, szi, mark);
        assert(uint256(credited) == realised);
        assert(uint256(minter.credits(POOL)) == uint256(poolBefore) + realised);
        assert(minter.credits(MEMBER) == 0);
        assert(minter.draws(POOL, Drand.ROUND_0) == 0);
    }
}

/// @dev Stands in for the drand pairing check, which Halmos cannot execute (no
///      concrete modexp). It treats every signature as verified and derives the
///      seed exactly as the real verifier does. So these proofs cover everything
///      in settle EXCEPT signature validity, which the unit tests check against
///      committed real evmnet signatures (accept, and reject mutated / wrong-round
///      / off-curve / non-canonical inputs).
contract SettleHarness is HypowMinter {
    constructor(IHypowToken t) HypowMinter(t, 1, 60, 2016) {}

    function _verifiedSeed(uint64, bytes calldata signature) internal pure override returns (bytes32) {
        return keccak256(signature);
    }
}

/// @title HypowMinter settle/spend symbolic proofs (Halmos)
/// @notice No mint without a live draw, the reward goes to the owner, the nonce
///         range is enforced, a round mints at most once, a closed round never
///         mints nor takes a draw, and spend debits exactly what it commits.
///
///         Emission.currentReward runs PRBMath exp(), which explodes symbolically,
///         so every successful settle is the genesis one (winCount 0), where the
///         reward is the constant R0.
///         Where a proof needs a second round, it warps the clock one round on. Difficulty is 1 so a ticket's hash is below
///         the target and the win path is reachable. Hash-filter enforcement at
///         higher difficulty and the retarget are covered by fuzz tests.
contract HypowMinterSettleSymbolic is SymbolicBase {
    MockMintableToken token;
    SettleHarness minter;
    address constant OWNER = address(0xA1);
    address constant RIVAL = address(0xA2);
    uint64 constant ROUND = Drand.ROUND_0;
    uint256 constant ACCUM = 1e11; // szi 1e9 · mark 1e6 / 1e4
    bytes SIG;

    function setUp() public {
        _etch();
        _setMark(ASSET, 1e6);
        token = new MockMintableToken();
        minter = new SettleHarness(IHypowToken(address(token)));
        token.setMinter(address(minter));
        SIG = Drand.SIG_0;
        _fundAndSpend(OWNER);
        _fundAndSpend(RIVAL);
    }

    /// Bank ACCUM credits for `who` (flat registration, then open) and spend them
    /// all into a draw on the round the clock targets.
    function _fundAndSpend(address who) internal {
        _setPos(who, ASSET, 0);
        vm.prank(who);
        minter.capture(who, _one(ASSET));
        _setPos(who, ASSET, int64(1e9));
        vm.prank(who);
        minter.capture(who, _one(ASSET));
        vm.prank(who);
        (, uint128 k) = minter.spend(who, type(uint128).max);
        require(k == ACCUM, "accum");
    }

    /// A win mints exactly R0 to the draw's owner, never the caller, records the
    /// win, closes its round, deletes the draw, and advances winCount by one.
    function checkSettleMintsToOwnerNotCaller(address caller) public {
        vm.assume(caller != OWNER);
        vm.prank(caller);
        minter.settle(OWNER, ROUND, SIG, 1);

        uint256 r = Emission.currentReward(0);
        assert(token.balanceOf(OWNER) == r);
        assert(token.balanceOf(caller) == 0);
        assert(token.totalSupply() == r);
        assert(minter.winCount() == 1);
        assert(minter.lastWonRound() == ROUND);
        (address winner, uint128 d, uint128 reward) = minter.wonBy(ROUND);
        assert(winner == OWNER && d == 1 && reward == r);
        assert(minter.draws(OWNER, ROUND) == 0);
    }

    /// No mint without a draw: settling any (owner, round) that holds no draw
    /// reverts, whatever the nonce and signature.
    function checkNoMintWithoutDraw(address owner, uint64 round, uint256 nonce) public {
        vm.assume(!((owner == OWNER || owner == RIVAL) && round == ROUND));
        (bool ok,) = address(minter).call(abi.encodeCall(minter.settle, (owner, round, SIG, nonce)));
        assert(!ok);
        assert(token.totalSupply() == 0);
    }

    /// Only tickets 1..k exist.
    function checkSettleNonceOutOfRangeReverts(uint256 nonce) public {
        vm.assume(nonce == 0 || nonce > ACCUM);
        (bool ok,) = address(minter).call(abi.encodeCall(minter.settle, (OWNER, ROUND, SIG, nonce)));
        assert(!ok);
        assert(token.totalSupply() == 0);
    }

    /// At most one mint per round: once ROUND is won, neither the winner
    /// re-settling nor the rival's live draw on the same round can mint, for any
    /// nonce.
    function checkAtMostOneMintPerRound(uint256 nonce, bool rival) public {
        minter.settle(OWNER, ROUND, SIG, 1);
        uint256 supply = token.totalSupply();

        (bool ok,) = address(minter).call(abi.encodeCall(minter.settle, (rival ? RIVAL : OWNER, ROUND, SIG, nonce)));
        assert(!ok);
        assert(token.totalSupply() == supply);
        assert(minter.winCount() == 1);
    }

    /// No settle on a closed round: after a win on ROUND + 1 is cashed, settling
    /// ANY owner's draw on ANY round up to ROUND + 1 reverts, for any nonce. That
    /// includes OWNER's and RIVAL's draws on ROUND, which would otherwise win.
    function checkNoSettleOnClosedRound(address owner, uint64 round, uint256 nonce) public {
        vm.assume(round <= ROUND + 1);
        vm.warp(Drand.timeTargeting(ROUND + 1));
        address later = address(0xA3);
        _fundAndSpend(later);
        minter.settle(later, ROUND + 1, SIG, 1);
        uint256 supply = token.totalSupply();

        (bool ok,) = address(minter).call(abi.encodeCall(minter.settle, (owner, round, SIG, nonce)));
        assert(!ok);
        assert(token.totalSupply() == supply);
        assert(minter.lastWonRound() == ROUND + 1);
    }

    /// No draw on a closed round: after a win on ROUND + 1, a spend at ANY block
    /// timestamp whose target is at or below it (a lagging clock) reverts, for
    /// any amount, and the bank keeps its credits.
    function checkNoDrawOnClosedRound(uint256 t, uint128 maxK) public {
        vm.warp(Drand.timeTargeting(ROUND + 1));
        address later = address(0xA3);
        _fundAndSpend(later);
        minter.settle(later, ROUND + 1, SIG, 1);

        address who = address(0xA4);
        _setPos(who, ASSET, 0);
        vm.prank(who);
        minter.capture(who, _one(ASSET));
        _setPos(who, ASSET, int64(1e9));
        vm.prank(who);
        minter.capture(who, _one(ASSET));

        vm.assume(maxK > 0);
        vm.assume(t >= minter.DRAND_GENESIS() && minter.drandRound(t) + minter.ROUND_LEAD() <= ROUND + 1);
        vm.warp(t);
        vm.prank(who);
        (bool ok,) = address(minter).call(abi.encodeCall(minter.spend, (who, maxK)));
        assert(!ok);
        assert(minter.credits(who) == ACCUM);
    }

    /// Spend debits the bank by exactly k = min(maxK, bank) and grows the
    /// owner's draw on the target round by exactly k.
    function checkSpendDebitsExactly(uint128 maxK) public {
        address who = address(0xA3);
        _setPos(who, ASSET, 0);
        vm.prank(who);
        minter.capture(who, _one(ASSET));
        _setPos(who, ASSET, int64(1e9));
        vm.prank(who);
        minter.capture(who, _one(ASSET));
        uint128 bank = minter.credits(who);

        vm.prank(who);
        (, uint128 k) = minter.spend(who, maxK);
        uint128 expected = maxK < bank ? maxK : bank;
        assert(k == expected);
        assert(minter.credits(who) == bank - expected);
        assert(minter.draws(who, ROUND) == expected);
    }

    /// For ANY caller and ANY spender setting (address(0) being the default and
    /// the revoked state), spend succeeds iff the caller is the owner or the
    /// spender the owner authorized. A refused spend leaves the bank untouched.
    function checkOnlyOwnerOrSpenderCanSpend(address caller, address allowed) public {
        _setPos(OWNER, ASSET, int64(2e9)); // fresh volume for spend's capture to bank
        vm.prank(OWNER);
        minter.setSpender(allowed);
        vm.prank(caller);
        (bool ok,) = address(minter).call(abi.encodeCall(minter.spend, (OWNER, uint128(1))));
        assert(ok == (caller == OWNER || (allowed != address(0) && caller == allowed)));
        if (!ok) assert(minter.credits(OWNER) == 0);
    }
}
