// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HypowToken} from "../src/HypowToken.sol";
import {HypowMinter} from "../src/HypowMinter.sol";
import {Drand} from "./utils/Drand.sol";
import {MinterBase} from "./utils/MinterBase.sol";
import {TestPool} from "./utils/TestPool.sol";

/// @notice The minter's credit-delegation hook, end to end with a real contract
///         as the delegate: the production minter with real drand fixtures at
///         difficulty 1, and two members delegated to a TestPool.
contract TestPoolTest is MinterBase {
    HypowToken token;
    HypowMinter minter;
    TestPool pool;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant STRANGER = address(0xBAD);
    uint64 constant R0 = Drand.ROUND_0;

    function setUp() public {
        _etchPrecompiles();
        (token, minter) = _deploy(1, 2016);
        pool = new TestPool(minter);
        _join(ALICE);
        _join(BOB);
    }

    /// Delegate to the pool and register BTC flat through it, so the member's
    /// next open counts in full.
    function _join(address member) internal {
        vm.prank(member);
        minter.setCreditDelegate(address(pool));
        _setPosition(member, PERP_BTC, 0);
        pool.contribute(member, _a(PERP_BTC));
    }

    /// Move `member`'s BTC position to `szi` and contribute it.
    function _open(address member, int64 szi) internal returns (uint128) {
        _setPosition(member, PERP_BTC, szi);
        return pool.contribute(member, _a(PERP_BTC));
    }

    function test_contributionsFillThePoolsBank() public {
        assertEq(_open(ALICE, LOT), LOT_CENTS);
        assertEq(_open(BOB, -2 * LOT), 2 * LOT_CENTS);
        _setPosition(ALICE, PERP_BTC, 2 * LOT);
        vm.expectEmit(address(minter));
        emit HypowMinter.Captured(ALICE, address(pool), LOT_CENTS);
        pool.contribute(ALICE, _a(PERP_BTC));

        assertEq(minter.credits(address(pool)), 4 * LOT_CENTS, "both members' volume in the pool's bank");
        assertEq(minter.credits(ALICE), 0, "member bank untouched");
        assertEq(minter.credits(BOB), 0, "member bank untouched");
    }

    function test_contributeRevertsIfNotDelegatedHere() public {
        _setPosition(STRANGER, PERP_BTC, LOT);
        vm.expectRevert(bytes("not delegated here"));
        pool.contribute(STRANGER, _a(PERP_BTC));

        vm.prank(STRANGER);
        minter.setCreditDelegate(address(0xD00D));
        vm.expectRevert(bytes("not delegated here"));
        pool.contribute(STRANGER, _a(PERP_BTC));
    }

    /// While delegated, neither the member nor anyone else can capture the
    /// member into a bank, and the member's own spend captures nothing: the
    /// pool alone takes the volume.
    function test_delegatedMemberCannotCaptureOrSpendSolo() public {
        _open(ALICE, LOT); // tracked, so a solo spend would capture it
        _setPosition(ALICE, PERP_BTC, 2 * LOT);
        vm.prank(ALICE);
        vm.expectRevert(bytes("pooled capture by pool only"));
        minter.capture(ALICE, _a(PERP_BTC));
        vm.prank(STRANGER);
        vm.expectRevert(bytes("pooled capture by pool only"));
        minter.capture(ALICE, _a(PERP_BTC));

        (, uint128 k) = _spend(minter, ALICE, type(uint128).max);
        assertEq(k, 0, "the member's spend captured nothing");
        assertEq(minter.credits(ALICE), 0);

        assertEq(pool.contribute(ALICE, _a(PERP_BTC)), LOT_CENTS, "the pool still takes the full volume");
        assertEq(minter.credits(address(pool)), 2 * LOT_CENTS);
    }

    /// The bank is the pool's: a member or a stranger can't spend it, and the
    /// pool spends it like any owner.
    function test_onlyThePoolSpendsItsBank() public {
        _open(ALICE, LOT);
        _open(BOB, LOT);
        vm.prank(STRANGER);
        vm.expectRevert(bytes("not spender"));
        minter.spend(address(pool), 1);
        vm.prank(ALICE);
        vm.expectRevert(bytes("not spender"));
        minter.spend(address(pool), 1);

        (uint64 round, uint128 k) = pool.spend(type(uint128).max);
        assertEq(round, R0);
        assertEq(k, 2 * LOT_CENTS);
        assertEq(minter.draws(address(pool), R0), 2 * LOT_CENTS);
        assertEq(minter.credits(address(pool)), 0);
    }

    /// Anyone may settle the pool's draw; the reward mints to the pool, and
    /// wonBy records the pool as the winner at the ticket's difficulty.
    function test_poolWinMintsToThePool() public {
        _open(ALICE, LOT);
        _open(BOB, LOT);
        pool.spend(type(uint128).max);

        vm.prank(STRANGER);
        uint256 reward = minter.settle(address(pool), R0, _sig(R0), 1);
        assertGt(reward, 0);
        assertEq(token.balanceOf(address(pool)), reward);
        assertEq(token.balanceOf(STRANGER), 0, "the caller is not paid");
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB), 0, "the minter pays the pool, not members");
        (address owner, uint128 d, uint128 r) = minter.wonBy(R0);
        assertEq(owner, address(pool));
        assertEq(d, 1);
        assertEq(r, reward);
    }

    /// Leaving sends later volume back to the member's own bank; what the pool
    /// already captured stays in the pool's bank.
    function test_leavingSendsLaterVolumeToTheMember() public {
        _open(ALICE, LOT);
        vm.prank(ALICE);
        minter.setCreditDelegate(address(0));
        _setPosition(ALICE, PERP_BTC, 3 * LOT);
        vm.expectRevert(bytes("not delegated here"));
        pool.contribute(ALICE, _a(PERP_BTC));

        vm.prank(ALICE);
        assertEq(minter.capture(ALICE, _a(PERP_BTC)), 2 * LOT_CENTS, "solo capture from the pool's last baseline");
        assertEq(minter.credits(ALICE), 2 * LOT_CENTS);
        assertEq(minter.credits(address(pool)), LOT_CENTS);
    }

    /// Joining by EIP-712 signature, submitted by anyone, hands the pool the
    /// member's capture exactly as a direct join does.
    function test_joinBySigThenContribute() public {
        uint256 pk = 0xC0DE;
        address member = vm.addr(pk);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(minter.SET_CREDIT_DELEGATE_TYPEHASH(), member, address(pool), uint256(0), deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", minter.DOMAIN_SEPARATOR(), structHash)));

        vm.prank(STRANGER);
        minter.setCreditDelegateBySig(member, address(pool), 0, deadline, abi.encodePacked(r, s, v));
        assertEq(minter.creditDelegate(member), address(pool));

        _setPosition(member, PERP_BTC, 0);
        pool.contribute(member, _a(PERP_BTC));
        assertEq(_open(member, LOT), LOT_CENTS);
        assertEq(minter.credits(address(pool)), LOT_CENTS);
    }

    /// The pool draws on two consecutive rounds, both of which win.
    function _twoPoolDraws() internal {
        _open(ALICE, LOT);
        pool.spend(LOT_CENTS / 2); // R0
        vm.warp(block.timestamp + minter.DRAND_PERIOD());
        pool.spend(type(uint128).max); // R0 + 1
    }

    /// Control for the test below: settled in round order, both wins mint.
    function test_poolWinsSettledInOrderBothMint() public {
        _twoPoolDraws();
        minter.settle(address(pool), R0, _sig(R0), 1);
        minter.settle(address(pool), R0 + 1, _sig(R0 + 1), 1);
        assertEq(minter.winCount(), 2);
    }

    /// Accepted by design (a cashed win closes its round and all earlier
    /// rounds): a stranger who settles the pool's later win first closes the
    /// pool's earlier winning draw. Keepers must settle every win promptly and
    /// in ascending round order.
    function test_laterPoolWinSettledFirstClosesItsEarlierWin() public {
        _twoPoolDraws();
        vm.prank(STRANGER);
        minter.settle(address(pool), R0 + 1, _sig(R0 + 1), 1);
        vm.expectRevert(bytes("round closed"));
        minter.settle(address(pool), R0, _sig(R0), 1);
        assertEq(minter.winCount(), 1);
    }
}
