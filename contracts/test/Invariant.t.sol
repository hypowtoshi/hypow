// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HypowToken} from "../src/HypowToken.sol";
import {HypowMinter} from "../src/HypowMinter.sol";
import {L1Read} from "../src/lib/L1Read.sol";
import {MockPrecompiles} from "./mocks/MockPrecompiles.sol";
import {Drand} from "./utils/Drand.sol";
import {MinterBase} from "./utils/MinterBase.sol";
import {TestPool} from "./utils/TestPool.sol";

/// @dev Drives random move / close / delegation-switch / spend / clock / settle
///      / pool spend actions on a fixed member set plus a TestPool, keeping its
///      own tally of realised volume under the v5 first-touch rule (a member's
///      first capture of an asset credits nothing), of the part contributed to
///      the pool, and of every win. Every member authorizes KEEPER, which makes
///      all member spends.
///
///      Difficulty is 1, so every live draw wins. The clock only moves forward,
///      one drand round at a time, and a round is settled only once the clock
///      targets a later one (in production it must be published first, which is
///      stricter). Only the four fixture rounds have signatures, so draws on
///      later rounds simply stay pending.
contract Handler is Test {
    HypowMinter public minter;
    TestPool public pool;
    uint32 constant PERP_BTC = 0;
    uint64 constant BTC_MARK = 1_000;
    address constant KEEPER = address(0xB0B0);
    uint64 public constant FIRST_ROUND = Drand.ROUND_0;
    /// The clock stops once spends target this round.
    uint64 public constant LAST_ROUND = Drand.ROUND_0 + 5;

    address[3] public members;
    mapping(address => bool) public known;
    mapping(address => int64) public lastSzi;
    uint256 public netVolumeCents;
    uint256 public pooledCents;
    uint256 public poolRewards;
    /// Pooled credits consumed by the pool's cashed wins.
    uint256 public poolWonCents;

    /// Credits consumed by cashed wins (their draws are deleted).
    uint256 public wonCents;
    uint256 public minted;
    mapping(uint64 => uint256) public mintsOnRound;
    uint64 public maxWonRound;
    bool public lastWonRoundDecreased;

    constructor(HypowMinter _m, TestPool _p) {
        minter = _m;
        pool = _p;
        members[0] = address(0xA1);
        members[1] = address(0xA2);
        members[2] = address(0xA3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(members[i]);
            minter.setSpender(KEEPER);
        }
    }

    modifier monotone() {
        uint64 before = minter.lastWonRound();
        _;
        if (minter.lastWonRound() < before) lastWonRoundDecreased = true;
    }

    function moveAndCapture(uint256 mi, int64 newSzi) external monotone {
        _move(members[mi % 3], int64(bound(int256(newSzi), -1_000_000, 1_000_000)));
    }

    /// bound() practically never lands on exactly 0, so closes get their own action.
    function closeAndCapture(uint256 mi) external monotone {
        _move(members[mi % 3], 0);
    }

    function toggleDelegate(uint256 mi) external monotone {
        address member = members[mi % 3];
        address dest = minter.creditDelegate(member) == address(0) ? address(pool) : address(0);
        vm.prank(member);
        minter.setCreditDelegate(dest);
    }

    function spend(uint256 mi, uint128 maxK) external monotone {
        vm.prank(KEEPER);
        minter.spend(members[mi % 3], maxK);
    }

    function advanceRound() external monotone {
        if (minter.targetRound() < LAST_ROUND) vm.warp(block.timestamp + minter.DRAND_PERIOD());
    }

    /// Cash ticket 1 of a member's or the pool's draw on a fixture round. It wins
    /// iff the draw exists and the round is open.
    function settle(uint256 oi, uint256 ri) external monotone {
        address owner = oi % 4 == 3 ? address(pool) : members[oi % 4];
        // ri % 4 < 4, so the cast can't truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 round = FIRST_ROUND + uint64(ri % 4);
        if (round >= minter.targetRound()) return;
        uint128 k = minter.draws(owner, round);
        try minter.settle(owner, round, Drand.sig(round - FIRST_ROUND), 1) returns (uint256 reward) {
            wonCents += k;
            minted += reward;
            if (owner == address(pool)) {
                poolRewards += reward;
                poolWonCents += k;
            }
            mintsOnRound[round]++;
            if (round > maxWonRound) maxWonRound = round;
        } catch {}
    }

    /// Spend some or all of the pool's bank.
    function poolSpend(uint128 maxK) external monotone {
        pool.spend(maxK);
    }

    function _move(address member, int64 newSzi) internal {
        MockPrecompiles(L1Read.POSITION2)
            .setPosition(
                member,
                PERP_BTC,
                L1Read.Position({szi: newSzi, entryNtl: 0, isolatedRawUsd: 0, leverage: 1, isIsolated: false})
            );
        uint32[] memory assets = new uint32[](1);
        assets[0] = PERP_BTC;
        bool pooled = minter.creditDelegate(member) != address(0);
        if (!pooled) {
            vm.prank(member);
            minter.capture(member, assets);
        } else {
            pool.contribute(member, assets);
        }

        if (known[member]) {
            int64 base = lastSzi[member];
            // Sign-guarded by the comparison, so the cast is non-negative.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absD = newSzi >= base ? uint256(int256(newSzi - base)) : uint256(int256(base - newSzi));
            netVolumeCents += absD * BTC_MARK / 10_000;
            if (pooled) pooledCents += absD * BTC_MARK / 10_000;
        }
        known[member] = true;
        lastSzi[member] = newSzi;
    }

    function memberAt(uint256 i) external view returns (address) {
        return members[i % 3];
    }
}

contract InvariantTest is MinterBase {
    HypowToken token;
    HypowMinter minter;
    TestPool pool;
    Handler handler;

    function setUp() public {
        _etchPrecompiles();
        (token, minter) = _deploy(1, 2016);
        pool = new TestPool(minter);
        handler = new Handler(minter, pool);
        targetContract(address(handler));
    }

    /// Conservation: every realised cent sits in exactly one place, a bank (a
    /// member's or the pool's), a draw on some round, or a cashed win.
    function invariant_creditsConserveRealisedVolume() public view {
        uint256 sum = handler.wonCents() + minter.credits(address(pool));
        for (uint64 r = handler.FIRST_ROUND(); r <= handler.LAST_ROUND(); r++) {
            sum += minter.draws(address(pool), r);
            for (uint256 i = 0; i < 3; i++) {
                sum += minter.draws(handler.memberAt(i), r);
            }
        }
        for (uint256 i = 0; i < 3; i++) {
            sum += minter.credits(handler.memberAt(i));
        }
        assertEq(sum, handler.netVolumeCents());
    }

    /// Every pooled credit sits in the pool's bank, one of its draws, or one of
    /// its cashed wins.
    function invariant_pooledVolumeStaysWithThePool() public view {
        uint256 sum = handler.poolWonCents() + minter.credits(address(pool));
        for (uint64 r = handler.FIRST_ROUND(); r <= handler.LAST_ROUND(); r++) {
            sum += minter.draws(address(pool), r);
        }
        assertEq(sum, handler.pooledCents());
    }

    /// Every reward the pool won was minted to the pool, and to nobody else.
    function invariant_poolHoldsItsRewards() public view {
        assertEq(token.balanceOf(address(pool)), handler.poolRewards());
    }

    /// lastWonRound only increases, and always equals the latest round cashed.
    function invariant_lastWonRoundOnlyIncreases() public view {
        assertFalse(handler.lastWonRoundDecreased());
        assertEq(minter.lastWonRound(), handler.maxWonRound());
    }

    /// At most one mint per round, and nothing is minted outside a win.
    function invariant_atMostOneMintPerRound() public view {
        for (uint64 r = handler.FIRST_ROUND(); r <= handler.LAST_ROUND(); r++) {
            assertLe(handler.mintsOnRound(r), 1);
        }
        assertEq(token.totalSupply(), handler.minted());
    }

    /// The round a spend would join right now is always open.
    function invariant_targetRoundIsOpen() public view {
        assertGt(minter.targetRound(), minter.lastWonRound());
    }

    /// Eviction tracks live positions: BTC is tracked iff the member's last
    /// captured position is non-zero.
    function invariant_trackedAssetsMatchOpenPositions() public view {
        for (uint256 i = 0; i < 3; i++) {
            address m = handler.memberAt(i);
            uint256 expected = handler.lastSzi(m) != 0 ? 1 : 0;
            assertEq(minter.memberAssetsLength(m), expected);
        }
    }
}
