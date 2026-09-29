// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {HypowToken} from "../src/HypowToken.sol";
import {HypowMinter} from "../src/HypowMinter.sol";
import {IHypowToken} from "../src/interfaces/IHypowToken.sol";

/// @notice Hypow deployment.
///
///         Token and minter reference each other immutably. We resolve the
///         circular dependency by predicting the minter's address with
///         `vm.computeCreateAddress`, deploying the token with that as the
///         minter parameter, then deploying the minter — which lands at the
///         predicted address and references the just-deployed token.
contract Deploy is Script {
    function run() external returns (HypowToken token, HypowMinter minter) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        // Genesis parameters, defaulting to mainnet's; env overrides them.
        // Difficulty starts at the floor (1) and climbs via retargeting as miners
        // arrive — a high genesis would stall the chain, since the first retarget
        // only fires after the first win.
        uint128 genesisDifficulty = uint128(vm.envOr("GENESIS_DIFFICULTY", uint256(1)));
        uint64 targetInterval = uint64(vm.envOr("TARGET_INTERVAL_SECONDS", uint256(60)));
        uint32 retargetWindow = uint32(vm.envOr("RETARGET_WINDOW", uint256(2016)));

        vm.startBroadcast(deployerPk);

        uint256 nonce = vm.getNonce(deployer);
        address predictedMinter = vm.computeCreateAddress(deployer, nonce + 1);

        token = new HypowToken(predictedMinter);
        minter = new HypowMinter(IHypowToken(address(token)), genesisDifficulty, targetInterval, retargetWindow);

        require(address(minter) == predictedMinter, "minter address mismatch");
        require(token.minter() == address(minter), "token minter mismatch");

        vm.stopBroadcast();
    }
}
