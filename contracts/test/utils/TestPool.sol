// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HypowMinter} from "../../src/HypowMinter.sol";

/// @title TestPool
/// @notice Test-only pool. Its one purpose is proving the minter's credit
///         delegation hook end to end with a real contract as the delegate:
///         members delegate to it, it captures them into its bank on the
///         minter, spends that bank, and anyone can settle its draws so a win
///         mints to it. It never pays members and has no payout policy. It is
///         not a reference design and is never deployed on mainnet.
///
///         Pools are left to the community. A real pool must decide who may
///         trigger a member's capture (its timing is a lever) and must pay each
///         win by the credits actually drawn, not the credits contributed: the
///         v5 delta audit showed a PPLNS window over contributed credits lets a
///         later contributor take the wins of an earlier contribution still
///         sitting in the bank.
contract TestPool {
    HypowMinter public immutable minter;

    constructor(HypowMinter _minter) {
        minter = _minter;
    }

    /// @notice Capture `member`'s realised volume into this pool's bank. Only
    ///         the delegate may capture a delegated member, so this is the one
    ///         path by which the bank fills. Permissionless: this pool has no
    ///         policy about who drives its members.
    function contribute(address member, uint32[] calldata assets) external returns (uint128 k) {
        require(minter.creditDelegate(member) == address(this), "not delegated here");
        return minter.capture(member, assets);
    }

    /// @notice Spend up to `maxK` of this pool's bank into a draw on the
    ///         current target round, as any owner spends.
    function spend(uint128 maxK) external returns (uint64 round, uint128 k) {
        return minter.spend(address(this), maxK);
    }
}
