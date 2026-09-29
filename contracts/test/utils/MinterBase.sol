// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HypowToken} from "../../src/HypowToken.sol";
import {HypowMinter} from "../../src/HypowMinter.sol";
import {IHypowToken} from "../../src/interfaces/IHypowToken.sol";
import {L1Read} from "../../src/lib/L1Read.sol";
import {MockPrecompiles} from "../mocks/MockPrecompiles.sol";
import {Drand} from "./Drand.sol";

/// @notice Shared harness for the minter, pool and invariant suites: etched
///         L1Read precompile mocks, deployment with the token↔minter address
///         prediction, and the credit / ticket helpers every suite needs.
abstract contract MinterBase is Test {
    uint32 constant PERP_BTC = 0;
    uint32 constant PERP_ETH = 1;

    // Hyperliquid's markPx precompile returns price × 10^(6 − szDecimals).
    //   BTC, szDecimals=8: $100,000 → 1_000.   ETH, szDecimals=4: $3,000 → 300_000.
    uint64 constant BTC_MARK = 1_000;
    uint64 constant ETH_MARK = 300_000;

    /// A 1e6 BTC szi move at BTC_MARK realises 1e6 · 1_000 / 1e4 = 100_000 cents.
    int64 constant LOT = 1_000_000;
    uint128 constant LOT_CENTS = 100_000;

    function _etchPrecompiles() internal {
        MockPrecompiles template = new MockPrecompiles();
        vm.etch(L1Read.POSITION2, address(template).code);
        vm.etch(L1Read.MARK_PX, address(template).code);
        vm.etch(L1Read.PERP_ASSET_INFO, address(template).code);
        _setPerpAssetInfo(PERP_BTC, 8);
        _setPerpAssetInfo(PERP_ETH, 4);
        _setMarkPx(PERP_BTC, BTC_MARK);
        _setMarkPx(PERP_ETH, ETH_MARK);
        // Spends made now target round ROUND_0, whose real signature is a fixture.
        vm.warp(Drand.timeTargeting(Drand.ROUND_0));
    }

    function _deploy(uint128 diff, uint32 window) internal returns (HypowToken t, HypowMinter m) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        t = new HypowToken(predicted);
        m = new HypowMinter(IHypowToken(address(t)), diff, 60, window);
        require(address(m) == predicted, "minter address mismatch");
    }

    // ----- L1Read mock setters -----

    function _setPosition(address user, uint32 perp, int64 szi) internal {
        MockPrecompiles(L1Read.POSITION2)
            .setPosition(
                user, perp, L1Read.Position({szi: szi, entryNtl: 0, isolatedRawUsd: 0, leverage: 1, isIsolated: false})
            );
    }

    function _setMarkPx(uint32 asset, uint64 px) internal {
        MockPrecompiles(L1Read.MARK_PX).setMarkPx(asset, px);
    }

    function _setPerpAssetInfo(uint32 perp, uint8 szDecimals) internal {
        _setPerpAssetInfo(perp, szDecimals, 50);
    }

    function _setPerpAssetInfo(uint32 perp, uint8 szDecimals, uint8 maxLeverage) internal {
        MockPrecompiles(L1Read.PERP_ASSET_INFO)
            .setPerpAssetInfo(
                perp,
                L1Read.PerpAssetInfo({
                    coin: "PERP",
                    marginTableId: 0,
                    szDecimals: szDecimals,
                    maxLeverage: maxLeverage,
                    onlyIsolated: false
                })
            );
    }

    /// Make `precompile`'s read of `asset` fail, burning its forwarded gas.
    function _setReverting(address precompile, uint32 asset, bool r) internal {
        MockPrecompiles(precompile).setReverting(asset, r);
    }

    // ----- API ergonomics -----

    function _a(uint32 a0) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](1);
        arr[0] = a0;
    }

    function _a(uint32 a0, uint32 a1) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](2);
        arr[0] = a0;
        arr[1] = a1;
    }

    /// Set `member`'s BTC position and capture it (solo: banks into credits).
    function _trade(HypowMinter m, address member, int64 szi) internal returns (uint128 k) {
        _setPosition(member, PERP_BTC, szi);
        vm.prank(member);
        k = m.capture(member, _a(PERP_BTC));
    }

    /// Spend as `owner`, the one caller every bank accepts without setup.
    function _spend(HypowMinter m, address owner, uint128 maxK) internal returns (uint64 round, uint128 k) {
        vm.prank(owner);
        return m.spend(owner, maxK);
    }

    /// Register BTC flat for `member`, then open LOT: banks LOT_CENTS.
    function _earnLot(HypowMinter m, address member) internal {
        _trade(m, member, 0);
        _trade(m, member, LOT);
    }

    /// First ticket in 1..k that wins for `owner` on the fixture round at the
    /// minter's current difficulty.
    function _winningNonce(HypowMinter m, address owner, uint64 round, uint256 k) internal view returns (uint256) {
        bytes32 seed = keccak256(Drand.sig(round - Drand.ROUND_0));
        uint256 target = type(uint256).max / uint256(m.difficulty());
        for (uint256 n = 1; n <= k; n++) {
            if (uint256(keccak256(abi.encode(seed, owner, n))) < target) return n;
        }
        revert("no winning nonce");
    }

    function _sig(uint64 round) internal pure returns (bytes memory) {
        return Drand.sig(round - Drand.ROUND_0);
    }
}
