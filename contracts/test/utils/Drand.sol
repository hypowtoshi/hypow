// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Real drand evmnet test vectors, fetched from
///         https://api.drand.sh/v2/beacons/evmnet/info and
///         https://api.drand.sh/v2/beacons/evmnet/rounds/<n>.
///         Signatures are the 64-byte G1 point x‖y exactly as the API serves it.
library Drand {
    bytes internal constant PUBLIC_KEY =
        hex"07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b3820557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b";

    uint64 internal constant ROUND_0 = 10_000_000;
    bytes internal constant SIG_0 =
        hex"2c7b65b5acfe55256910ca71cf0a0fa71ac34c2a1167f86a22930a03e70ebec00f7a530796e7ee38600b06da0390634a9b154e3eebc3b323dde2111e1c8ebdf3";
    bytes internal constant SIG_1 =
        hex"0d23588d3b2457cf1e7a823d0781c3cf67216f7e2500e0048dd82d88b5dbe6c5227d5ed98879a9abd1dda134cb4cc8240284429913029ce22de1a6aa9d548ea9";
    bytes internal constant SIG_2 =
        hex"04edcf1080e8c3c542251b0439384fb67fdf559813fbfa9a14a3a49a63e8f3af17e79ae47a98f834043501463cf3676d0c681031d62d8204b635095590258ef5";
    bytes internal constant SIG_3 =
        hex"00a6811e9880bc99c3f130140f332ca0e4faade2d187896c0272b7d05d27271d2997197cf37eed8d84fc5293f80a2d0c56e1fc2285317db33d1671f86e7c4d22";

    uint256 internal constant GENESIS = 1727521075;

    /// @notice Signature of round ROUND_0 + i, i in 0..3.
    function sig(uint256 i) internal pure returns (bytes memory) {
        if (i == 0) return SIG_0;
        if (i == 1) return SIG_1;
        if (i == 2) return SIG_2;
        if (i == 3) return SIG_3;
        revert("no fixture");
    }

    /// @notice A timestamp at which a spend targets `round` (latest published
    ///         round is round − 2).
    function timeTargeting(uint64 round) internal pure returns (uint256) {
        return GENESIS + (uint256(round) - 3) * 3;
    }
}
