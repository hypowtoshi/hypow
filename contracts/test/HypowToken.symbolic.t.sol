// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HypowToken} from "../src/HypowToken.sol";

/// @title HypowToken symbolic proofs (Halmos)
/// @notice Exhaustive symbolic verification of the token's safety properties:
///         the supply cap, the sole-minter authorization, value conservation
///         under transfer, and allowance accounting. Run with:
///             uvx --from halmos halmos --match-contract HypowTokenSymbolic
///
///         Halmos reads uninitialized storage as concrete zero (EVM semantics),
///         so arbitrary pre-state (existing balances, supply, allowances) is
///         established by replaying the only operations that can create it —
///         mint and approve — over symbolic amounts. Every reachable state is
///         therefore one the contract could actually reach.
contract HypowTokenSymbolic is Test {
    HypowToken token;
    address constant MINTER = address(0xBEEF);

    function setUp() public {
        token = new HypowToken(MINTER);
    }

    // ------------------------------------------------------------------
    // Mint authorization and cap
    // ------------------------------------------------------------------

    /// Only the immutable minter can ever mint.
    function checkMintOnlyMinter(address caller, address to, uint256 amount) public {
        vm.assume(caller != MINTER);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeCall(token.mint, (to, amount)));
        assert(!ok);
    }

    /// totalSupply never exceeds CAP, for any prior supply reached by a previous mint.
    function checkMintCapNeverExceeded(address a, uint256 pre, address to, uint256 amount) public {
        vm.assume(a != address(0));
        vm.startPrank(MINTER);
        (bool ok0,) = address(token).call(abi.encodeCall(token.mint, (a, pre)));
        vm.assume(ok0); // reach an arbitrary prior supply
        (bool ok1,) = address(token).call(abi.encodeCall(token.mint, (to, amount)));
        vm.stopPrank();
        if (ok1) assert(token.totalSupply() <= token.CAP());
    }

    /// A successful mint increments supply and the recipient's balance by exactly
    /// `amount`, and touches no other account.
    function checkMintExactAccounting(address to, uint256 amount, address other) public {
        vm.assume(to != address(0));
        vm.assume(other != to);

        uint256 supplyBefore = token.totalSupply();
        uint256 balToBefore = token.balanceOf(to);
        uint256 balOtherBefore = token.balanceOf(other);

        vm.prank(MINTER);
        (bool ok,) = address(token).call(abi.encodeCall(token.mint, (to, amount)));
        vm.assume(ok);

        assert(token.totalSupply() == supplyBefore + amount);
        assert(token.balanceOf(to) == balToBefore + amount);
        assert(token.balanceOf(other) == balOtherBefore);
    }

    /// Minting to the zero address always reverts (no supply leaks to the void),
    /// for any amount — the `to != address(0)` check precedes the amount==0
    /// early-return, so even a zero-amount mint to address(0) reverts.
    function checkMintToZeroReverts(uint256 amount) public {
        vm.prank(MINTER);
        (bool ok,) = address(token).call(abi.encodeCall(token.mint, (address(0), amount)));
        assert(!ok);
    }

    // ------------------------------------------------------------------
    // Transfer value conservation
    // ------------------------------------------------------------------

    /// transfer conserves total value: the sender+recipient balance sum is
    /// unchanged, totalSupply is unchanged, and an uninvolved account is untouched.
    function checkTransferConserves(
        address from,
        address to,
        address other,
        uint256 seedFrom,
        uint256 seedTo,
        uint256 seedOther,
        uint256 value
    ) public {
        vm.assume(from != to);
        vm.assume(other != from && other != to);
        vm.assume(to != address(0));
        _seed(from, seedFrom);
        _seed(to, seedTo);
        _seed(other, seedOther);

        uint256 supplyBefore = token.totalSupply();
        uint256 pairBefore = token.balanceOf(from) + token.balanceOf(to);
        uint256 otherBefore = token.balanceOf(other);

        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, value)));
        vm.assume(ok);

        assert(token.balanceOf(from) + token.balanceOf(to) == pairBefore);
        assert(token.totalSupply() == supplyBefore);
        assert(token.balanceOf(other) == otherBefore);
    }

    /// A transfer of more than the sender holds always reverts. `to` is held
    /// non-zero so the revert is attributable to insufficiency, not the
    /// zero-address guard (which would mask a removed balance check).
    function checkTransferInsufficientReverts(address from, address to, uint256 seed, uint256 value) public {
        vm.assume(to != address(0));
        _seed(from, seed);
        vm.assume(value > token.balanceOf(from));
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, value)));
        assert(!ok);
    }

    /// Self-transfer (from == to) preserves the balance — the aliased-slot case
    /// the two-party conservation proof excludes, and the classic spot for a
    /// stale-cached-balance mint bug.
    function checkSelfTransferConserves(address acct, uint256 seed, uint256 value) public {
        _seed(acct, seed);
        uint256 balBefore = token.balanceOf(acct);
        vm.prank(acct);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (acct, value)));
        vm.assume(ok);
        assert(token.balanceOf(acct) == balBefore);
    }

    // ------------------------------------------------------------------
    // Allowance accounting
    // ------------------------------------------------------------------

    /// approve sets the allowance to exactly the requested value.
    function checkApproveSets(address spender, uint256 value) public {
        vm.prank(address(0xCAFE));
        token.approve(spender, value);
        assert(token.allowance(address(0xCAFE), spender) == value);
    }

    /// approve REPLACES the allowance rather than accumulating: a second approve
    /// sets the exact new value irrespective of any prior allowance (the standard
    /// ERC-20 overwrite semantic — guards against a `+=` regression).
    function checkApproveOverwrites(address spender, uint256 prior, uint256 value) public {
        address owner = address(0xCAFE);
        vm.prank(owner);
        token.approve(spender, prior);
        vm.prank(owner);
        token.approve(spender, value);
        assert(token.allowance(owner, spender) == value);
    }

    /// transferFrom decrements a finite allowance by exactly `value`, and leaves
    /// an infinite (type(uint256).max) allowance untouched.
    function checkTransferFromAllowance(
        address from,
        address to,
        address spender,
        uint256 seed,
        uint256 allow,
        uint256 value
    ) public {
        vm.assume(from != to);
        vm.assume(to != address(0));
        _seed(from, seed);

        vm.prank(from);
        token.approve(spender, allow);

        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (from, to, value)));
        vm.assume(ok);

        uint256 after_ = token.allowance(from, spender);
        if (allow == type(uint256).max) {
            assert(after_ == type(uint256).max);
        } else {
            assert(after_ == allow - value);
        }
    }

    // ------------------------------------------------------------------
    // Helper
    // ------------------------------------------------------------------

    /// Establish an arbitrary balance for `who` via the only path that can create
    /// one — a mint by the authorized minter. Assumes success so the symbolic
    /// pre-state stays within reachable (cap-respecting) states.
    function _seed(address who, uint256 amount) internal {
        vm.assume(who != address(0));
        vm.prank(MINTER);
        (bool ok,) = address(token).call(abi.encodeCall(token.mint, (who, amount)));
        vm.assume(ok);
    }
}
