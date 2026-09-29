// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice HyperEVM L1 read precompile addresses and minimal interfaces.
///         Full schemas live in the project-root `L1Read.sol` reference file.
///         Listed here are only the precompiles HypowMinter actually reads.
///
///         IMPORTANT: scaling and exact return shapes are documented at
///         Hyperliquid → for-developers → hyperevm. Validate against that
///         reference and a live HyperEVM testnet before deployment.
library L1Read {
    address constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address constant PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address constant POSITION2 = 0x0000000000000000000000000000000000000813;

    /// @dev Forward-looking constants — present at the L1Read precompile range but
    ///      unused by HypowMinter v1. Listed here for v1.1 (spot) and reference.
    address constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address constant SPOT_PX = 0x0000000000000000000000000000000000000808;
    address constant BBO = 0x000000000000000000000000000000000000080e;

    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    /// @dev Unified-asset position read. Supports HIP-3 perps that share Hyperliquid's
    ///      asset-id space with canonical perps.
    function position2(address user, uint32 perp) internal view returns (Position memory pos) {
        bool ok;
        (ok, pos) = tryPosition2(user, perp);
        require(ok, "precompile position2");
    }

    /// @dev Gas forwarded to a position / markPx read. A FAILED read on HyperEVM
    ///      mainnet consumes all the gas it is given (measured: a 50k stipend
    ///      burned ~50.9k), so an uncapped call on a dead asset leaves the caller
    ///      only 1/64 of its gas and a second dead asset runs it out. Measured
    ///      successful reads cost ~9.4k (position) and ~3.9k (markPx); 30k keeps
    ///      3x headroom over the costlier one while bounding a dead read.
    uint256 constant READ_GAS = 30_000;

    /// @dev Non-reverting variants. The live precompiles revert for asset ids that
    ///      don't exist, so a tracked asset that later disappears (e.g. a removed
    ///      HIP-3 market) must be skippable rather than brick every read of it.
    function tryPosition2(address user, uint32 perp) internal view returns (bool ok, Position memory pos) {
        bytes memory ret;
        (ok, ret) = POSITION2.staticcall{gas: READ_GAS}(abi.encode(user, perp));
        if (ok) pos = abi.decode(ret, (Position));
    }

    function tryMarkPx(uint32 asset) internal view returns (bool ok, uint64 px) {
        bytes memory ret;
        (ok, ret) = MARK_PX.staticcall{gas: READ_GAS}(abi.encode(asset));
        if (ok) px = abi.decode(ret, (uint64));
    }

    function perpAssetInfo(uint32 perp) internal view returns (PerpAssetInfo memory) {
        (bool ok, bytes memory ret) = PERP_ASSET_INFO.staticcall(abi.encode(perp));
        require(ok, "precompile perpAssetInfo");
        return abi.decode(ret, (PerpAssetInfo));
    }
}
