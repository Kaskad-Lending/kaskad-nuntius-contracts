// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Curve384 } from "marlinprotocol/P384/Curve384.sol";
import { Curve384Affine } from "./ref/Curve384Affine.sol";
import { Curve384Jac } from "./harness/Curve384Jac.sol";
import { CertManagerMock } from "nitro-prover/mock/CertManagerMock.sol";

/// Differential multiplication checks and fixed AWS Nitro certificate vectors.
contract P384JacobianTest is Test {
    Curve384Affine internal ref;
    Curve384Jac internal jac;
    CertManagerMock internal cm;

    function setUp() public {
        ref = new Curve384Affine();
        jac = new Curve384Jac();
        // warp before constructing: CertManager verifies the root CA at deploy time.
        vm.warp(1708930774);
        cm = new CertManagerMock();
    }

    // ── helpers ─────────────────────────────────────────────────────────

    // Deterministic pseudo-random scalar (hi < 2^128, lo < 2^256) => value < 2^384.
    function _scalar(uint256 seed, uint256 tag) internal pure returns (uint256 hi, uint256 lo) {
        hi = uint256(keccak256(abi.encode(seed, tag, uint8(1)))) >> 128;
        lo = uint256(keccak256(abi.encode(seed, tag, uint8(2))));
    }

    function _refMul(uint256 xhi, uint256 xlo, uint256 yhi, uint256 ylo, uint256 rhi, uint256 rlo)
        internal view returns (uint256, uint256, uint256, uint256)
    {
        Curve384Affine.C384Elm memory p = ref.t_cmul(Curve384Affine.C384Elm(xhi, xlo, yhi, ylo), rhi, rlo);
        return (p.xhi, p.xlo, p.yhi, p.ylo);
    }

    function _jacMul(uint256 xhi, uint256 xlo, uint256 yhi, uint256 ylo, uint256 rhi, uint256 rlo)
        internal view returns (uint256, uint256, uint256, uint256)
    {
        Curve384.C384Elm memory p = jac.t_cmul(Curve384.C384Elm(xhi, xlo, yhi, ylo), rhi, rlo);
        return (p.xhi, p.xlo, p.yhi, p.ylo);
    }

    function _assertSame(
        uint256 axhi, uint256 axlo, uint256 ayhi, uint256 aylo,
        uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo
    ) internal pure {
        assertEq(axhi, bxhi, "xhi");
        assertEq(axlo, bxlo, "xlo");
        assertEq(ayhi, byhi, "yhi");
        assertEq(aylo, bylo, "ylo");
    }

    // valid point P = k0 * G via the reference
    function _point(uint256 k0hi, uint256 k0lo)
        internal view returns (uint256, uint256, uint256, uint256)
    {
        Curve384Affine.C384Elm memory g = ref.gen();
        return _refMul(g.xhi, g.xlo, g.yhi, g.ylo, k0hi, k0lo);
    }

    // ── differential: scalar multiplication ─────────────────────────────

    /// Jacobian cmul == affine cmul for a random valid point and random scalar.
    function testFuzz_cmul_matchesReference(uint256 seed) public view {
        (uint256 k0hi, uint256 k0lo) = _scalar(seed, 0);
        if (k0hi == 0 && k0lo == 0) k0lo = 1;
        (uint256 pxhi, uint256 pxlo, uint256 pyhi, uint256 pylo) = _point(k0hi, k0lo);

        (uint256 khi, uint256 klo) = _scalar(seed, 1);
        (uint256 axhi, uint256 axlo, uint256 ayhi, uint256 aylo) = _refMul(pxhi, pxlo, pyhi, pylo, khi, klo);
        (uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo) = _jacMul(pxhi, pxlo, pyhi, pylo, khi, klo);
        _assertSame(axhi, axlo, ayhi, aylo, bxhi, bxlo, byhi, bylo);
    }

    /// Jacobian cmul == affine cmul when multiplying the generator directly.
    function testFuzz_cmul_generator(uint256 seed) public view {
        Curve384Affine.C384Elm memory g = ref.gen();
        (uint256 khi, uint256 klo) = _scalar(seed, 7);
        (uint256 axhi, uint256 axlo, uint256 ayhi, uint256 aylo) = _refMul(g.xhi, g.xlo, g.yhi, g.ylo, khi, klo);
        (uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo) = _jacMul(g.xhi, g.xlo, g.yhi, g.ylo, khi, klo);
        _assertSame(axhi, axlo, ayhi, aylo, bxhi, bxlo, byhi, bylo);
    }

    /// cmul by 0 is the point at infinity, represented as (0,0) in both impls.
    function test_cmul_zero() public view {
        Curve384Affine.C384Elm memory g = ref.gen();
        (uint256 axhi, uint256 axlo, uint256 ayhi, uint256 aylo) = _refMul(g.xhi, g.xlo, g.yhi, g.ylo, 0, 0);
        (uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo) = _jacMul(g.xhi, g.xlo, g.yhi, g.ylo, 0, 0);
        assertEq(axhi, 0); assertEq(axlo, 0); assertEq(ayhi, 0); assertEq(aylo, 0);
        _assertSame(axhi, axlo, ayhi, aylo, bxhi, bxlo, byhi, bylo);
    }

    /// cmul by 1 returns the point itself.
    function test_cmul_one() public view {
        Curve384Affine.C384Elm memory g = ref.gen();
        (uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo) = _jacMul(g.xhi, g.xlo, g.yhi, g.ylo, 0, 1);
        assertEq(bxhi, g.xhi); assertEq(bxlo, g.xlo); assertEq(byhi, g.yhi); assertEq(bylo, g.ylo);
    }

    /// cmul by small scalars 1..12 matches the reference (covers the low-bit paths).
    function test_cmul_small_scalars() public view {
        Curve384Affine.C384Elm memory g = ref.gen();
        for (uint256 k = 1; k <= 12; k++) {
            (uint256 axhi, uint256 axlo, uint256 ayhi, uint256 aylo) = _refMul(g.xhi, g.xlo, g.yhi, g.ylo, 0, k);
            (uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo) = _jacMul(g.xhi, g.xlo, g.yhi, g.ylo, 0, k);
            _assertSame(axhi, axlo, ayhi, aylo, bxhi, bxlo, byhi, bylo);
        }
    }

    /// cmul by 2 equals a single doubling.
    function test_cmul_two_equals_double() public view {
        (uint256 pxhi, uint256 pxlo, uint256 pyhi, uint256 pylo) = _point(0, 0x9e3779b97f4a7c15);
        Curve384.C384Elm memory dbl = jac.t_cdbl(Curve384.C384Elm(pxhi, pxlo, pyhi, pylo));
        (uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo) = _jacMul(pxhi, pxlo, pyhi, pylo, 0, 2);
        _assertSame(dbl.xhi, dbl.xlo, dbl.yhi, dbl.ylo, bxhi, bxlo, byhi, bylo);
    }

    /// A high-word scalar (bits above 2^256) is handled identically.
    function testFuzz_cmul_highword(uint256 seed) public view {
        (uint256 k0hi, uint256 k0lo) = _scalar(seed, 3);
        if (k0hi == 0 && k0lo == 0) k0lo = 1;
        (uint256 pxhi, uint256 pxlo, uint256 pyhi, uint256 pylo) = _point(k0hi, k0lo);

        // force rhi >= 2^128: a full 512-bit scalar whose high word itself exceeds 128 bits
        uint256 khi = uint256(keccak256(abi.encode(seed, "hi"))) | (uint256(1) << 200);
        uint256 klo = uint256(keccak256(abi.encode(seed, "lo")));
        (uint256 axhi, uint256 axlo, uint256 ayhi, uint256 aylo) = _refMul(pxhi, pxlo, pyhi, pylo, khi, klo);
        (uint256 bxhi, uint256 bxlo, uint256 byhi, uint256 bylo) = _jacMul(pxhi, pxlo, pyhi, pylo, khi, klo);
        _assertSame(axhi, axlo, ayhi, aylo, bxhi, bxlo, byhi, bylo);
    }

    // ── differential: full ECDSA verify path ────────────────────────────

    /// ref.verify and jac.verify agree for random inputs against a valid pubkey.
    function testFuzz_verify_agrees(uint256 seed) public view {
        (uint256 dhi, uint256 dlo) = _scalar(seed, 5);
        if (dhi == 0 && dlo == 0) dlo = 1;
        (uint256 pxhi, uint256 pxlo, uint256 pyhi, uint256 pylo) = _point(dhi, dlo);

        uint256 mhi = uint256(keccak256(abi.encode(seed, "m1"))) >> 128;
        uint256 mlo = uint256(keccak256(abi.encode(seed, "m2")));
        uint256 rhi = uint256(keccak256(abi.encode(seed, "r1"))) >> 128;
        uint256 rlo = uint256(keccak256(abi.encode(seed, "r2")));
        uint256 shi = uint256(keccak256(abi.encode(seed, "s1"))) >> 128;
        uint256 slo = uint256(keccak256(abi.encode(seed, "s2")));
        if (shi == 0 && slo == 0) slo = 1;

        bool a = ref.t_verify(Curve384Affine.C384Elm(pxhi, pxlo, pyhi, pylo), mhi, mlo, rhi, rlo, shi, slo);
        bool b = jac.t_verify(Curve384.C384Elm(pxhi, pxlo, pyhi, pylo), mhi, mlo, rhi, rlo, shi, slo);
        assertEq(a, b, "verify verdict diverged");
    }

    // ── real-vector: AWS Nitro certificate ──────────────────────────────

    // Fixed AWS Nitro certificate and parent public key from upstream CertManager tests.
    function _realCert() internal pure returns (bytes memory) {
        return hex"3082027e30820203a0030201020210018d1c7ef94eb1100000000065dc36d8300a06082a8648ce3d04030330818f310b30090603550406130255533113301106035504080c0a57617368696e67746f6e3110300e06035504070c0753656174746c65310f300d060355040a0c06416d617a6f6e310c300a060355040b0c03415753313a303806035504030c31692d30646632333766303431386665623431652e61702d736f7574682d312e6177732e6e6974726f2d656e636c61766573301e170d3234303232363036353933335a170d3234303232363039353933365a308194310b30090603550406130255533113301106035504080c0a57617368696e67746f6e3110300e06035504070c0753656174746c65310f300d060355040a0c06416d617a6f6e310c300a060355040b0c03415753313f303d06035504030c36692d30646632333766303431386665623431652d656e63303138643163376566393465623131302e61702d736f7574682d312e6177733076301006072a8648ce3d020106052b8104002203620004eb09f84282efd096cbe7964dbe67070bae5e8086bc1188f3f7cf79a6095d85898f61660bc9a5c0ad9a56a6141420c6eef5d74446d7124d944676c1d9cf2b3cd46dec6f13056c634b01d1b9fe309c222f34a56247ceb037a56b7adcd428f0df6aa31d301b300c0603551d130101ff04023000300b0603551d0f0404030206c0300a06082a8648ce3d0403030369003066023100fea3f5cfaf969d75e7b9583ce3313e994df0baee848f11f7be2fd1a7629f69b303ef73cd28cca11c207da137222a63c6023100d34de845696123850a2e379acc1968377e236d495c75ab10380fd93941cb4abf61bacb503027315471a58a12612943ff";
    }

    function _realParentPubKey() internal pure returns (bytes memory) {
        return hex"046baba8f1e9aa967fe7e3fa54b89138cc89dda5be11a1b52df080d94178e30105e76f08b75aa6caebefe8963366bb6dd0a22b33c6dc689a99448a0a16d2a7225e7d48941ee8f8b2b0523f77127dbfacc2866008a8bb9082b20a0f71a1e4eb0ede";
    }

    /// The patched curve verifies a real AWS Nitro P-384 certificate signature.
    function test_realCert_verifies() public view {
        cm.t_verifyCert(_realCert(), _realParentPubKey());
    }

    /// A single flipped signature byte is rejected.
    function test_realCert_tamperedSig_rejected() public {
        bytes memory cert = _realCert();
        // flip a byte inside the trailing ECDSA signature (last bytes of the DER).
        cert[cert.length - 1] ^= 0xff;
        vm.expectRevert();
        cm.t_verifyCert(cert, _realParentPubKey());
    }

    /// A wrong parent public key is rejected.
    function test_realCert_wrongPubKey_rejected() public {
        bytes memory pk = _realParentPubKey();
        pk[50] ^= 0xff; // Corrupt a Y-coordinate byte.
        vm.expectRevert();
        cm.t_verifyCert(_realCert(), pk);
    }
}
