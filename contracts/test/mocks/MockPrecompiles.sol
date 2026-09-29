// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {L1Read} from "../../src/lib/L1Read.sol";

/// @notice Storage + handler for the L1Read precompile addresses used by
///         HypowMinter. Tests `vm.etch` this contract's runtime code at each
///         precompile address and seed state via the public setters.
///
///         Each etched address has its own storage. The fallback dispatcher
///         routes by `address(this)` so a single contract serves all addresses.
contract MockPrecompiles {
    mapping(bytes32 => L1Read.Position) public positions;
    mapping(uint32 => uint64) public markPrices;
    mapping(uint32 => L1Read.PerpAssetInfo) public assetInfos;
    /// @dev Per-address (so per-precompile) set of asset ids whose read fails,
    ///      mimicking live HyperEVM on an asset id that no longer exists. Like
    ///      mainnet, a failed read burns ALL the gas it was forwarded.
    mapping(uint32 => bool) public reverting;

    function setPosition(address user, uint32 perp, L1Read.Position calldata pos) external {
        positions[keccak256(abi.encode(user, perp))] = pos;
    }

    function setMarkPx(uint32 asset, uint64 px) external {
        markPrices[asset] = px;
    }

    function setReverting(uint32 asset, bool r) external {
        reverting[asset] = r;
    }

    function setPerpAssetInfo(uint32 perp, L1Read.PerpAssetInfo calldata info) external {
        assetInfos[perp] = info;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        if (address(this) == L1Read.POSITION2) {
            (address user, uint32 perp) = abi.decode(input, (address, uint32));
            _failIfReverting(perp);
            return abi.encode(positions[keccak256(abi.encode(user, perp))]);
        }
        if (address(this) == L1Read.MARK_PX) {
            uint32 asset = abi.decode(input, (uint32));
            _failIfReverting(asset);
            return abi.encode(markPrices[asset]);
        }
        if (address(this) == L1Read.PERP_ASSET_INFO) {
            uint32 perp = abi.decode(input, (uint32));
            return abi.encode(assetInfos[perp]);
        }
        revert("MockPrecompiles: unsupported precompile");
    }

    /// @dev INVALID consumes all remaining gas, as a failed mainnet read does.
    function _failIfReverting(uint32 asset) internal view {
        if (reverting[asset]) {
            assembly {
                invalid()
            }
        }
    }
}
