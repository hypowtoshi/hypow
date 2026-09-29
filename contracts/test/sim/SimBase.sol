// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HypowToken} from "../../src/HypowToken.sol";
import {HypowMinter} from "../../src/HypowMinter.sol";
import {IHypowToken} from "../../src/interfaces/IHypowToken.sol";
import {MinterBase} from "../utils/MinterBase.sol";

/// @dev The production minter with drand stood in for, as in the Halmos
///      SettleHarness, because real signatures exist only for four fixture
///      rounds and a simulation spans thousands. Every round has exactly one
///      valid "signature" (SimDrand.sig), usable only once the round is
///      published (round <= drandRound(now)), and the seed is derived from it
///      exactly as the real verifier does. Everything else is production code.
contract SimMinter is HypowMinter {
    constructor(IHypowToken t, uint128 diff, uint64 interval, uint32 window) HypowMinter(t, diff, interval, window) {}

    function _verifiedSeed(uint64 round, bytes calldata signature) internal view override returns (bytes32) {
        require(round <= drandRound(block.timestamp), "round not published");
        require(keccak256(signature) == keccak256(SimDrand.sig(round)), "bad drand signature");
        return keccak256(signature);
    }
}

library SimDrand {
    function sig(uint64 round) internal pure returns (bytes memory) {
        return abi.encodePacked(keccak256(abi.encode("hypow-sim-drand", round)));
    }

    function seed(uint64 round) internal pure returns (bytes32) {
        return keccak256(sig(round));
    }
}

/// @notice Shared harness for the simulation suites: SimMinter deployment,
///         a deterministic PRNG, and the off-chain miner's nonce search.
abstract contract SimBase is MinterBase {
    uint256 internal _rng;

    function _deploySim(uint128 diff, uint64 interval, uint32 window) internal returns (HypowToken t, SimMinter m) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new HypowToken(predicted);
        m = new SimMinter(IHypowToken(address(t)), diff, interval, window);
        require(address(m) == predicted, "minter address mismatch");
    }

    /// Address number `i` of the series starting at `base` (small constants).
    function _addr(uint256 base, uint256 i) internal pure returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(base + i));
    }

    function _rand() internal returns (uint256) {
        _rng = uint256(keccak256(abi.encode(_rng)));
        return _rng;
    }

    function _randBelow(uint256 n) internal returns (uint256) {
        return _rand() % n;
    }

    /// Whether ticket `nonce` of `owner`'s draw on `round` wins at `diff`.
    function _wins(address owner, uint64 round, uint256 nonce, uint128 diff) internal pure returns (bool) {
        return uint256(keccak256(abi.encode(SimDrand.seed(round), owner, nonce))) < type(uint256).max / uint256(diff);
    }

    /// The smallest ticket in 1..min(k, cap) of `owner`'s draw on `round` that
    /// wins at difficulty `diff`, or 0. What a miner's client searches for once
    /// the round is published.
    function _firstWin(address owner, uint64 round, uint256 k, uint128 diff, uint256 cap)
        internal
        pure
        returns (uint256 n)
    {
        bytes32 s = SimDrand.seed(round);
        uint256 target = type(uint256).max / uint256(diff);
        uint256 last = k < cap ? k : cap;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, s)
            mstore(add(p, 32), and(owner, 0xffffffffffffffffffffffffffffffffffffffff))
            let found := 0
            for { n := 1 } iszero(gt(n, last)) { n := add(n, 1) } {
                mstore(add(p, 64), n)
                if lt(keccak256(p, 96), target) {
                    found := 1
                    break
                }
            }
            if iszero(found) { n := 0 }
        }
    }
}
