// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HypowMinter} from "../src/HypowMinter.sol";
import {IHypowToken} from "../src/interfaces/IHypowToken.sol";
import {SymbolicBase} from "./HypowMinter.symbolic.t.sol";
import {TestPool} from "./utils/TestPool.sol";

/// @title Delegation hook symbolic proof (Halmos), with a contract delegate
/// @notice The minter-side proofs in HypowMinter.symbolic.t.sol use an EOA as
///         the pool. This one drives the same hook through a real contract:
///         two members delegated to a TestPool, contributed in turn, for ANY
///         position of the second.
contract TestPoolSymbolic is SymbolicBase {
    HypowMinter minter;
    TestPool pool;
    address constant M1 = address(0xA1);
    address constant M2 = address(0xA2);
    uint64 constant MARK = 1e5;

    function setUp() public {
        _etch();
        _setMark(ASSET, MARK);
        minter = new HypowMinter(IHypowToken(address(0xdead)), type(uint128).max, 60, 2016);
        pool = new TestPool(minter);
        _join(M1);
        _join(M2);
    }

    /// Delegate to the pool and register the asset flat through it.
    function _join(address member) internal {
        vm.prank(member);
        minter.setCreditDelegate(address(pool));
        _setPos(member, ASSET, 0);
        pool.contribute(member, _one(ASSET));
    }

    /// Each contribution returns exactly the member's realised volume and adds
    /// exactly that to the pool's bank; no member's own bank moves.
    function checkContributeBanksExact(int64 szi) public {
        _setPos(M2, ASSET, 1e3);
        uint128 first = pool.contribute(M2, _one(ASSET));
        _setPos(M1, ASSET, szi);
        uint128 k = pool.contribute(M1, _one(ASSET));

        assert(uint256(first) == _realised(0, 1e3, MARK));
        assert(uint256(k) == _realised(0, szi, MARK));
        assert(uint256(minter.credits(address(pool))) == uint256(first) + k);
        assert(minter.credits(M1) == 0 && minter.credits(M2) == 0);
    }
}
