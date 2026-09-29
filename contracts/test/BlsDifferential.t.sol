// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HypowToken} from "../src/HypowToken.sol";
import {HypowMinter} from "../src/HypowMinter.sol";
import {IHypowToken} from "../src/interfaces/IHypowToken.sol";
import {BLS} from "bls-solidity/libraries/BLS.sol";
import {ModexpInverse, ModexpSqrt} from "bls-solidity/libraries/ModExp.sol";
import {Drand} from "./utils/Drand.sol";
import {MinterBase} from "./utils/MinterBase.sol";

/// @dev The minter's drand check, exactly as `settle` runs it.
contract SeedHarness is HypowMinter {
    constructor() HypowMinter(IHypowToken(address(1)), 1, 60, 2016) {}

    function verifiedSeed(uint64 round, bytes calldata signature) external view returns (bytes32) {
        return _verifiedSeed(round, signature);
    }
}

/// @dev External entry points into the library, so every vector is one call.
contract BlsProbe {
    function hashToField(bytes memory dst, bytes memory message) external pure returns (uint256[2] memory) {
        return BLS.hashToField(dst, message);
    }

    function hashToPoint(bytes memory dst, bytes memory message) external view returns (uint256, uint256) {
        BLS.PointG1 memory p = BLS.hashToPoint(dst, message);
        return (p.x, p.y);
    }

    function mapToPoint(uint256 u) external view returns (uint256[2] memory) {
        return BLS.mapToPoint(u);
    }

    /// The minter's check with the key, DST and message as parameters. `key` is
    /// a G2 point in drand's byte order x1‖x0‖y1‖y0.
    function verify(bytes memory key, bytes memory dst, bytes memory message, bytes memory sig)
        external
        view
        returns (bool)
    {
        BLS.PointG1 memory s = BLS.g1Unmarshal(sig);
        if (!BLS.isValidPointG1(s)) return false;
        (bool pairingOk, bool callOk) = BLS.verifySingle(s, BLS.g2Unmarshal(key), BLS.hashToPoint(dst, message));
        return pairingOk && callOk;
    }
}

/// @notice Differential regression tests for the drand BLS verifier
///         (bls-solidity BLS.sol, pinned 11af179), from the v5 delta audit. The
///         vectors in test/bls-vectors were exported by the audit's reference
///         tool, which ran drand's own kyber code (v1.3.2), gnark-crypto
///         (v0.21.0) and an RFC 9380 transcription side by side and refused to
///         export any vector they disagreed on. rounds.json holds 66 real evmnet
///         rounds fetched on 2026-09-25. The tool and its live ffi fuzzers are
///         not committed, so CI needs no ffi or network; see contracts/AUDIT.md.
///
///         The invalid-input tests pin the strict parsing that keeps each round
///         to one seed: drand's Go verifier accepts x + p, y + p and trailing
///         bytes, and a minter that did would let a settler grind the seed.
contract BlsDifferentialTest is Test {
    uint256 constant P = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    bytes constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";
    string constant DIR = "test/bls-vectors/";

    SeedHarness harness;
    BlsProbe probe;

    function setUp() public {
        harness = new SeedHarness();
        probe = new BlsProbe();
    }

    // ------------------------------------------------------------------
    // Vector loading
    // ------------------------------------------------------------------

    function _realRounds() internal view returns (uint64[] memory rounds, bytes[] memory sigs) {
        string memory json = vm.readFile(string.concat(DIR, "rounds.json"));
        uint256[] memory r = vm.parseJsonUintArray(json, ".round");
        sigs = vm.parseJsonBytesArray(json, ".sig");
        rounds = new uint64[](r.length);
        for (uint256 i; i < r.length; i++) {
            rounds[i] = uint64(r[i]);
        }
    }

    function _xy(bytes memory sig) internal pure returns (uint256 x, uint256 y) {
        (x, y) = abi.decode(sig, (uint256, uint256));
    }

    function _msg(uint64 round) internal pure returns (bytes memory) {
        return abi.encodePacked(keccak256(abi.encodePacked(round)));
    }

    // ------------------------------------------------------------------
    // (2) Real evmnet rounds through the minter's verification path
    // ------------------------------------------------------------------

    /// Every real round the references accepted verifies in the minter and
    /// yields keccak256(signature) as its seed.
    function test_realRoundsVerifyInMinter() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        uint256 gasMax;
        for (uint256 i; i < rounds.length; i++) {
            uint256 g0 = gasleft();
            bytes32 seed = harness.verifiedSeed(rounds[i], sigs[i]);
            uint256 used = g0 - gasleft();
            if (used > gasMax) gasMax = used;
            assertEq(seed, keccak256(sigs[i]), string.concat("round ", vm.toString(rounds[i])));
        }
        emit log_named_uint("real evmnet rounds verified", rounds.length);
        emit log_named_uint("max gas for one verification (incl. call)", gasMax);
    }

    /// A real signature verifies for its own round only: the full cross matrix.
    function test_realSignaturesRejectedOnEveryOtherRound() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        uint256 checked;
        for (uint256 i; i < sigs.length; i++) {
            for (uint256 j; j < rounds.length; j++) {
                if (i == j) continue;
                vm.expectRevert(bytes("bad drand signature"));
                harness.verifiedSeed(rounds[j], sigs[i]);
                checked++;
            }
        }
        emit log_named_uint("cross-round pairs rejected", checked);
    }

    function test_realRoundSeedsAreDistinct() public view {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        for (uint256 i; i < sigs.length; i++) {
            for (uint256 j = i + 1; j < sigs.length; j++) {
                assertTrue(rounds[i] != rounds[j], "duplicate round in fixture");
                assertTrue(keccak256(sigs[i]) != keccak256(sigs[j]), "two rounds share a seed");
            }
        }
    }

    // ------------------------------------------------------------------
    // (3) hash_to_field / map_to_curve / hash_to_curve against the references
    // ------------------------------------------------------------------

    function test_hashToFieldMatchesReference() public {
        string memory json = vm.readFile(string.concat(DIR, "h2c.json"));
        bytes[] memory dst = vm.parseJsonBytesArray(json, ".dst");
        bytes[] memory message = vm.parseJsonBytesArray(json, ".msg");
        bytes32[] memory u0 = vm.parseJsonBytes32Array(json, ".u0");
        bytes32[] memory u1 = vm.parseJsonBytes32Array(json, ".u1");
        for (uint256 i; i < dst.length; i++) {
            uint256[2] memory u = probe.hashToField(dst[i], message[i]);
            assertEq(u[0], uint256(u0[i]), string.concat("u0, vector ", vm.toString(i)));
            assertEq(u[1], uint256(u1[i]), string.concat("u1, vector ", vm.toString(i)));
        }
        emit log_named_uint("hash_to_field vectors matched", dst.length);
    }

    function test_hashToPointMatchesReference() public {
        string memory json = vm.readFile(string.concat(DIR, "h2c.json"));
        bytes[] memory dst = vm.parseJsonBytesArray(json, ".dst");
        bytes[] memory message = vm.parseJsonBytesArray(json, ".msg");
        bytes32[] memory x = vm.parseJsonBytes32Array(json, ".x");
        bytes32[] memory y = vm.parseJsonBytes32Array(json, ".y");
        uint256 maxLen;
        for (uint256 i; i < dst.length; i++) {
            (uint256 px, uint256 py) = probe.hashToPoint(dst[i], message[i]);
            assertEq(px, uint256(x[i]), string.concat("x, vector ", vm.toString(i)));
            assertEq(py, uint256(y[i]), string.concat("y, vector ", vm.toString(i)));
            if (message[i].length > maxLen) maxLen = message[i].length;
        }
        emit log_named_uint("hash_to_curve vectors matched", dst.length);
        emit log_named_uint("longest message (bytes)", maxLen);
    }

    function test_mapToPointMatchesReference() public {
        string memory json = vm.readFile(string.concat(DIR, "map.json"));
        bytes32[] memory u = vm.parseJsonBytes32Array(json, ".u");
        bytes32[] memory x = vm.parseJsonBytes32Array(json, ".x");
        bytes32[] memory y = vm.parseJsonBytes32Array(json, ".y");
        uint256[] memory branch = vm.parseJsonUintArray(json, ".branch");
        uint256[4] memory perBranch;
        for (uint256 i; i < u.length; i++) {
            uint256[2] memory p = probe.mapToPoint(uint256(u[i]));
            assertEq(p[0], uint256(x[i]), string.concat("x, vector ", vm.toString(i)));
            assertEq(p[1], uint256(y[i]), string.concat("y, vector ", vm.toString(i)));
            perBranch[branch[i]]++;
        }
        emit log_named_uint("map_to_curve vectors matched", u.length);
        emit log_named_uint("  via x1", perBranch[1]);
        emit log_named_uint("  via x2", perBranch[2]);
        emit log_named_uint("  via x3", perBranch[3]);
    }

    /// Inputs hash_to_field can never produce are refused, not reduced.
    function test_mapToPointRejectsUnreducedElement() public {
        vm.expectRevert(abi.encodeWithSelector(BLS.InvalidFieldElement.selector, P));
        probe.mapToPoint(P);
        vm.expectRevert(abi.encodeWithSelector(BLS.InvalidFieldElement.selector, type(uint256).max));
        probe.mapToPoint(type(uint256).max);
    }

    function _modexp(uint256 base, uint256 exponent) internal view returns (uint256) {
        (bool ok, bytes memory out) =
            address(5).staticcall(abi.encodePacked(uint256(32), uint256(32), uint256(32), base, exponent, P));
        require(ok, "modexp");
        return abi.decode(out, (uint256));
    }

    function _assertChains(uint256 a) internal view {
        assertEq(ModexpInverse.run(a), _modexp(a, P - 2), "inverse chain");
        assertEq(ModexpSqrt.run(a), _modexp(a, (P + 1) / 4), "sqrt chain");
    }

    /// The hand-generated addition chains behind the map's inverse and square
    /// root compute exactly a^(p−2) and a^((p+1)/4), per the modexp precompile.
    function testFuzz_additionChainsMatchModexp(uint256 a) public view {
        _assertChains(bound(a, 0, P - 1));
    }

    function test_additionChainsMatchModexpOnEdges() public view {
        uint256[7] memory edges = [uint256(0), 1, 2, P - 1, P - 2, (P - 1) / 2, (P + 1) / 2];
        for (uint256 i; i < edges.length; i++) {
            _assertChains(edges[i]);
        }
    }

    // ------------------------------------------------------------------
    // (4) Invalid signatures
    // ------------------------------------------------------------------

    function test_rejectsWrongLengths() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        uint16[9] memory lengths = [uint16(0), 1, 31, 32, 63, 65, 96, 127, 128];
        for (uint256 k; k < lengths.length; k++) {
            bytes memory b = new bytes(lengths[k]);
            for (uint256 i; i < b.length; i++) {
                b[i] = sigs[0][i % 64];
            }
            vm.expectRevert(bytes("Invalid G1 bytes length"));
            harness.verifiedSeed(rounds[0], b);
        }
        // The real signature with anything appended, which drand's own Go
        // verifier would accept (it ignores trailing bytes).
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        harness.verifiedSeed(rounds[0], abi.encodePacked(sigs[0], uint8(0)));
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        harness.verifiedSeed(rounds[0], abi.encodePacked(sigs[0], sigs[0]));
    }

    function test_rejectsPointAtInfinityEncoding() public {
        (uint64[] memory rounds,) = _realRounds();
        for (uint256 i; i < rounds.length; i++) {
            vm.expectRevert(bytes("signature not on G1"));
            harness.verifiedSeed(rounds[i], new bytes(64));
        }
    }

    /// x + p and y + p name the same point as x and y. drand's Go verifier
    /// accepts them; the minter must not, or one round would have several seeds.
    function test_rejectsNonCanonicalCoordinates() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        for (uint256 i; i < rounds.length; i++) {
            (uint256 x, uint256 y) = _xy(sigs[i]);
            bytes[7] memory bad = [
                abi.encodePacked(x + P, y),
                abi.encodePacked(x, y + P),
                abi.encodePacked(x + P, y + P),
                abi.encodePacked(P, y),
                abi.encodePacked(x, P),
                abi.encodePacked(type(uint256).max, y),
                abi.encodePacked(x, type(uint256).max)
            ];
            for (uint256 k; k < bad.length; k++) {
                vm.expectRevert(bytes("signature not on G1"));
                harness.verifiedSeed(rounds[i], bad[k]);
            }
        }
    }

    function test_rejectsOffCurvePoints() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        for (uint256 i; i < rounds.length; i++) {
            (uint256 x, uint256 y) = _xy(sigs[i]);
            vm.expectRevert(bytes("signature not on G1"));
            harness.verifiedSeed(rounds[i], abi.encodePacked(x, addmod(y, 1, P)));
            vm.expectRevert(bytes("signature not on G1"));
            harness.verifiedSeed(rounds[i], abi.encodePacked(addmod(x, 1, P), y));
            vm.expectRevert(bytes("signature not on G1"));
            harness.verifiedSeed(rounds[i], abi.encodePacked(y, x));
        }
    }

    /// −σ is on the curve and differs only in the sign of y.
    function test_rejectsNegatedSignatures() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        for (uint256 i; i < rounds.length; i++) {
            (uint256 x, uint256 y) = _xy(sigs[i]);
            BLS.PointG1 memory neg = BLS.PointG1(x, P - y);
            assertTrue(BLS.isValidPointG1(neg));
            vm.expectRevert(bytes("bad drand signature"));
            harness.verifiedSeed(rounds[i], abi.encodePacked(neg.x, neg.y));
        }
    }

    /// Valid curve points built from the signature, the message point and the
    /// generator: none is σ, so the pairing refuses every one.
    function test_rejectsRelatedCurvePoints() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        for (uint256 i; i < rounds.length; i++) {
            (uint256 x, uint256 y) = _xy(sigs[i]);
            BLS.PointG1 memory sig = BLS.PointG1(x, y);
            BLS.PointG1 memory h = BLS.hashToPoint(DST, _msg(rounds[i]));
            BLS.PointG1[] memory pts = new BLS.PointG1[](7);
            pts[0] = BLS.scalarMulG1Point(sig, 2);
            pts[1] = BLS.addG1Points(sig, BLS.PointG1(1, 2));
            pts[2] = BLS.scalarMulG1Point(sig, 3);
            pts[3] = h;
            pts[4] = BLS.negate(h);
            pts[5] = BLS.PointG1(1, 2);
            pts[6] = BLS.PointG1(1, P - 2);
            for (uint256 k; k < pts.length; k++) {
                assertTrue(BLS.isValidPointG1(pts[k]));
                vm.expectRevert(bytes("bad drand signature"));
                harness.verifiedSeed(rounds[i], abi.encodePacked(pts[k].x, pts[k].y));
            }
        }
    }

    /// Flipping any one of the 512 bits of a real signature is refused.
    function test_rejectsEveryBitFlip() public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        for (uint256 i; i < 4; i++) {
            for (uint256 bit; bit < 512; bit++) {
                bytes memory b = bytes.concat(sigs[i]);
                b[bit / 8] ^= bytes1(uint8(2 ** (bit % 8)));
                vm.expectRevert();
                harness.verifiedSeed(rounds[i], b);
            }
        }
    }

    /// A key other than evmnet's: signatures in evmnet's exact format, on
    /// evmnet's message for the round, under evmnet's DST. Refused by the
    /// minter; accepted by the same library code under the foreign key, which
    /// shows the refusal comes from the key and nothing else. The near-misses
    /// (another DST; the unhashed round) are refused by both.
    function test_rejectsForeignKeySignatures() public {
        string memory json = vm.readFile(string.concat(DIR, "foreign.json"));
        bytes memory pub = vm.parseJsonBytes(json, ".pub");
        bytes memory altDst = vm.parseJsonBytes(json, ".altDst");
        uint256[] memory rounds = vm.parseJsonUintArray(json, ".round");
        bytes[] memory sigs = vm.parseJsonBytesArray(json, ".sig");
        bytes[] memory altSigs = vm.parseJsonBytesArray(json, ".altDstSig");
        bytes[] memory rawSigs = vm.parseJsonBytesArray(json, ".rawMsgSig");
        for (uint256 i; i < rounds.length; i++) {
            uint64 round = uint64(rounds[i]);
            bytes memory m = _msg(round);

            assertTrue(probe.verify(pub, DST, m, sigs[i]), "foreign sig valid under foreign key");
            assertFalse(probe.verify(Drand.PUBLIC_KEY, DST, m, sigs[i]), "foreign sig under evmnet key");
            vm.expectRevert(bytes("bad drand signature"));
            harness.verifiedSeed(round, sigs[i]);

            assertTrue(probe.verify(pub, altDst, m, altSigs[i]), "alt-DST sig valid under its DST");
            assertFalse(probe.verify(pub, DST, m, altSigs[i]), "alt-DST sig under evmnet DST");
            vm.expectRevert(bytes("bad drand signature"));
            harness.verifiedSeed(round, altSigs[i]);

            assertTrue(probe.verify(pub, DST, abi.encodePacked(round), rawSigs[i]), "raw-round sig valid on raw msg");
            assertFalse(probe.verify(pub, DST, m, rawSigs[i]), "raw-round sig on hashed msg");
            vm.expectRevert(bytes("bad drand signature"));
            harness.verifiedSeed(round, rawSigs[i]);
        }
    }

    /// No 64 bytes other than the round's signature are accepted.
    function testFuzz_rejectsArbitrary64Bytes(bytes32 a, bytes32 b, uint256 which) public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        which = bound(which, 0, rounds.length - 1);
        bytes memory candidate = abi.encodePacked(a, b);
        vm.assume(keccak256(candidate) != keccak256(sigs[which]));
        vm.expectRevert();
        harness.verifiedSeed(rounds[which], candidate);
    }

    /// Random valid G1 points k·G are refused as signatures.
    function testFuzz_rejectsRandomCurvePoints(uint256 k, uint256 which) public {
        (uint64[] memory rounds, bytes[] memory sigs) = _realRounds();
        which = bound(which, 0, rounds.length - 1);
        k = bound(k, 1, 21888242871839275222246405745257275088548364400416034343698204186575808495616);
        BLS.PointG1 memory pt = BLS.scalarMulG1Base(k);
        vm.assume(keccak256(abi.encodePacked(pt.x, pt.y)) != keccak256(sigs[which]));
        vm.expectRevert(bytes("bad drand signature"));
        harness.verifiedSeed(rounds[which], abi.encodePacked(pt.x, pt.y));
    }
}

/// @notice The same real rounds, end to end through spend and settle.
contract BlsDifferentialSettleTest is MinterBase {
    address constant TRADER = address(0xA1A1);

    function test_realRoundsSettle() public {
        _etchPrecompiles();
        string memory json = vm.readFile("test/bls-vectors/rounds.json");
        uint256[] memory rounds = vm.parseJsonUintArray(json, ".round");
        bytes[] memory sigs = vm.parseJsonBytesArray(json, ".sig");
        uint256 settled;
        for (uint256 i; i < rounds.length; i++) {
            uint64 round = uint64(rounds[i]);
            if (round < 3) continue; // no timestamp targets rounds 1–2
            vm.warp(Drand.timeTargeting(round));
            (HypowToken t, HypowMinter m) = _deploy(1, 2016);
            _earnLot(m, TRADER);
            (uint64 target,) = _spend(m, TRADER, type(uint128).max);
            assertEq(target, round);
            uint256 reward = m.settle(TRADER, round, sigs[i], 1);
            assertGt(reward, 0);
            assertEq(t.balanceOf(TRADER), reward);
            settled++;
        }
        emit log_named_uint("real rounds settled end to end", settled);
    }
}
