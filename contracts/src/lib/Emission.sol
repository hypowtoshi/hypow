// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UD60x18, ud, exp} from "@prb/math/src/UD60x18.sol";

/// @notice Continuous exponential decay reward function for Hypow emission.
///         R(n) = R₀ · e^(−λn), with R₀ / λ = S_max = 21B.
///
///         Parameters (whitepaper §4.1):
///           R₀     = 12,721.6  tokens per coinbase   (12,721.6 · 1e18 wei)
///           λ      = 6.058e-7  decay constant per mine
///           S_max  = 21 · 10⁹  cap, in tokens
library Emission {
    /// @dev Genesis reward, in token wei (18 decimals).
    uint256 internal constant R0_WEI = 12_721_600_000_000_000_000_000;

    /// @dev λ in UD60x18 fixed-point form: 6.058e-7 · 1e18 = 605_800_000_000.
    uint256 internal constant LAMBDA_UD60x18 = 605_800_000_000;

    /// @dev Cap, in token wei.
    uint256 internal constant CAP_WEI = 21_000_000_000 * 1e18;

    /// @dev Upper bound on the exp() input we'll evaluate. exp(133.084) overflows UD60x18.
    ///      We cut off at a smaller margin to keep the math clean. The reward will already be
    ///      negligible at any mine count that pushes λn past ~60 (=6.6e7 mines), so this is
    ///      well past the useful range of the curve.
    uint256 internal constant LN_MAX_INPUT_UD60x18 = 60 * 1e18;

    /// @notice Current reward for the next coinbase, given the global mine counter n.
    /// @dev Computes R0 · e^(−λn) = R0 / e^(λn) using PRBMath UD60x18.
    function currentReward(uint256 n) internal pure returns (uint256) {
        if (n == 0) return R0_WEI;

        // λn in UD60x18 form. Mine counts up to ~uint128.max keep this within uint256.
        uint256 lambdaN = LAMBDA_UD60x18 * n;
        if (lambdaN >= LN_MAX_INPUT_UD60x18) return 0;

        UD60x18 expLn = exp(ud(lambdaN));
        UD60x18 r0 = ud(R0_WEI);
        UD60x18 reward = r0.div(expLn);
        return reward.unwrap();
    }
}
