pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "marlinprotocol/P384/Curve384.sol";

// Tests ECDSA input validation and the Q == +/-G joint-ladder branches.
struct TPub { uint256 xhi; uint256 xlo; uint256 yhi; uint256 ylo; }
struct TSig { uint256 mhi; uint256 mlo; uint256 rhi; uint256 rlo; uint256 shi; uint256 slo; }

contract HardenedHarness is Curve384 {
    function hVerify(TPub memory p, TSig memory s) external view returns (bool) {
        return verify(C384Elm(p.xhi, p.xlo, p.yhi, p.ylo), s.mhi, s.mlo, s.rhi, s.rlo, s.shi, s.slo);
    }
    function hMulG(uint256 khi, uint256 klo) external view returns (uint256, uint256, uint256, uint256) {
        C384Elm memory g = C384Elm(gxhi, gxlo, gyhi, gylo);
        cmul(g, khi, klo);
        return (g.xhi, g.xlo, g.yhi, g.ylo);
    }
    function hOinv(uint256 a, uint256 b) external view returns (uint256, uint256) { return oinv(a, b); }
    function hOmul(uint256 a, uint256 b, uint256 c, uint256 d) external view returns (uint256, uint256) { return omul(a, b, c, d); }
    function hOadd(uint256 a, uint256 b, uint256 c, uint256 d) external pure returns (uint256, uint256) { return oadd(a, b, c, d); }
    function hNegGy() external pure returns (uint256, uint256) { return fsub(0, 0, gyhi, gylo); } // p - G.y
    function gx() external pure returns (uint256, uint256) { return (gxhi, gxlo); }
}

contract Curve384HardenedTest is Test {
    HardenedHarness h;

    uint256 constant MASK128 = 0xffffffffffffffffffffffffffffffff;
    uint256 constant NHI = 0xffffffffffffffffffffffffffffffff;
    uint256 constant NLO = 0xffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973;

    function setUp() public { h = new HardenedHarness(); }

    // Reduce a raw seed to a scalar in [1,n).
    function _scalar(uint256 hi, uint256 lo) internal view returns (uint256, uint256) {
        hi &= MASK128;
        (hi, lo) = h.hOadd(hi, lo, 0, 0);
        if (hi == 0 && lo == 0) lo = 1;
        return (hi, lo);
    }

    function _pubG(uint256 hi, uint256 lo) internal view returns (TPub memory) {
        (hi, lo) = _scalar(hi, lo);
        (uint256 x0, uint256 x1, uint256 y0, uint256 y1) = h.hMulG(hi, lo);
        return TPub(x0, x1, y0, y1);
    }

    // Genuine ECDSA-P384 signature over the field ops: r,s in [1,n) by construction.
    function _mkSig(uint256 dhi, uint256 dlo, uint256 khi, uint256 klo, uint256 mhi, uint256 mlo)
        internal view returns (TPub memory pub, TSig memory sig)
    {
        uint256[2] memory d;
        uint256[2] memory k;
        uint256[2] memory m;
        (d[0], d[1]) = _scalar(dhi, dlo);
        (k[0], k[1]) = _scalar(khi, klo);
        (m[0], m[1]) = _scalar(mhi, mlo);
        {
            (uint256 qx0, uint256 qx1, uint256 qy0, uint256 qy1) = h.hMulG(d[0], d[1]);
            pub = TPub(qx0, qx1, qy0, qy1);
        }
        uint256[2] memory r;
        {
            (uint256 rx0, uint256 rx1,,) = h.hMulG(k[0], k[1]);
            (r[0], r[1]) = h.hOadd(rx0, rx1, 0, 0);      // r = R.x mod n
            vm.assume(r[0] == rx0 && r[1] == rx1);       // R.x < n
            vm.assume(!(r[0] == 0 && r[1] == 0));
        }
        uint256[2] memory s;
        {
            (uint256 kih, uint256 kil) = h.hOinv(k[0], k[1]);
            (uint256 rdh, uint256 rdl) = h.hOmul(r[0], r[1], d[0], d[1]);
            (uint256 eh, uint256 el) = h.hOadd(m[0], m[1], rdh, rdl);
            (s[0], s[1]) = h.hOmul(kih, kil, eh, el);
            vm.assume(!(s[0] == 0 && s[1] == 0));
        }
        sig = TSig(m[0], m[1], r[0], r[1], s[0], s[1]);
    }

    // Genuine signature forced to s'=1 so s=n+1 is a well-formed (hi<2^128) malleable representative.
    function _mkSigS1(uint256 dSeed, uint256 kSeed) internal view returns (TPub memory pub, TSig memory sig) {
        (uint256 dh, uint256 dl) = _scalar(dSeed >> 128, dSeed);
        (uint256 kh, uint256 kl) = _scalar(kSeed >> 128, kSeed);
        {
            (uint256 qx0, uint256 qx1, uint256 qy0, uint256 qy1) = h.hMulG(dh, dl);
            pub = TPub(qx0, qx1, qy0, qy1);
        }
        uint256 rh; uint256 rl;
        {
            (uint256 rx0, uint256 rx1,,) = h.hMulG(kh, kl);
            (rh, rl) = h.hOadd(rx0, rx1, 0, 0);
            vm.assume(rh == rx0 && rl == rx1);
            vm.assume(!(rh == 0 && rl == 0));
        }
        uint256 mh; uint256 ml;
        {
            (uint256 rdh, uint256 rdl) = h.hOmul(rh, rl, dh, dl);            // r*d
            (uint256 negh, uint256 negl) = h.hOmul(rdh, rdl, NHI, NLO - 1);  // -(r*d) = (n-1)*(r*d)
            (mh, ml) = h.hOadd(kh, kl, negh, negl);                          // m = k - r*d => s'=1
        }
        sig = TSig(mh, ml, rh, rl, 0, 1);
    }

    // F3: Reject r=s=0.
    function test_zeroSig_rejected() public view {
        TPub memory Q = _pubG(0, 12345);
        assertFalse(h.hVerify(Q, TSig(0xdead, 0xbeef, 0, 0, 0, 0)), "zero-sig must be rejected");
    }

    // F3: r=0 (s valid) and s=0 (r valid) both rejected.
    function test_partial_zero_rejected() public view {
        TPub memory Q = _pubG(0, 7);
        assertFalse(h.hVerify(Q, TSig(9, 9, 0, 0, 0, 5)), "r=0 rejected");
        assertFalse(h.hVerify(Q, TSig(9, 9, 0, 5, 0, 0)), "s=0 rejected");
    }

    // F2: r>=n, s>=n and out-of-word hi rejected.
    function test_out_of_range_rejected() public view {
        TPub memory Q = _pubG(0, 7);
        assertFalse(h.hVerify(Q, TSig(9, 9, NHI, NLO, 0, 5)), "r=n rejected");
        assertFalse(h.hVerify(Q, TSig(9, 9, 0, 5, NHI, NLO)), "s=n rejected");
        assertFalse(h.hVerify(Q, TSig(9, 9, MASK128 + 1, 0, 0, 5)), "r hi>=2^128 rejected");
    }

    // F1: Reject the off-curve key (2,0).
    function test_offCurve_2_0_rejected() public view {
        assertFalse(h.hVerify(TPub(0, 2, 0, 0), TSig(0, 0, 0, 2, 0, 2)), "off-curve pub (2,0) rejected");
    }

    // F1 (gqInf-misfire class): pub with the generator's x but y=1 is off-curve -> rejected for any sig.
    function test_offCurve_genX_rejected() public view {
        (uint256 gxhi, uint256 gxlo) = h.gx();
        assertFalse(h.hVerify(TPub(gxhi, gxlo, 0, 1), TSig(9, 9, 0, 5, 0, 7)), "(gx,1) off-curve rejected");
    }

    // F1: Reject the crafted (G.x,1) joint-ladder vector.
    function test_a0b_gqInf_amplifier_dead() public view {
        (uint256 gxhi, uint256 gxlo) = h.gx();
        (uint256 ivh, uint256 ivl) = h.hOinv(0, uint256(1) << 200);
        (uint256 shi, uint256 slo) = h.hOmul(gxhi, gxlo, ivh, ivl);
        (uint256 mhi, uint256 mlo) = h.hOmul(0, (uint256(1) << 200) + 1, shi, slo);
        assertFalse(h.hVerify(TPub(gxhi, gxlo, 0, 1), TSig(mhi, mlo, gxhi, gxlo, shi, slo)), "a0b amplifier dead");
    }

    // F2: s-malleability. Canonical s'=1 accepted; the in-domain representative s=n+1 rejected.
    function testFuzz_sMalleability_rejected(uint256 dSeed, uint256 kSeed) public view {
        (TPub memory pub, TSig memory sig) = _mkSigS1(dSeed, kSeed);
        assertTrue(h.hVerify(pub, sig), "canonical s'=1 accepted");
        TSig memory mal = TSig(sig.mhi, sig.mlo, sig.rhi, sig.rlo, NHI, NLO + 1); // s = n+1
        assertFalse(h.hVerify(pub, mal), "s=n+1 must be rejected");
    }

    // Accept generated valid signatures.
    function testFuzz_accepts_genuine(uint256 dhi, uint256 dlo, uint256 khi, uint256 klo, uint256 mhi, uint256 mlo)
        public view
    {
        (TPub memory pub, TSig memory sig) = _mkSig(dhi, dlo, khi, klo, mhi, mlo);
        assertTrue(h.hVerify(pub, sig), "genuine sig must verify");
    }

    // Legit Q==G path (private key 1): pub=G exercises the cdbl precompute branch.
    function test_genuine_G_verifies() public view {
        (TPub memory pub, TSig memory sig) = _mkSig(0, 1, 0, 987654321, 0, 424242);
        (uint256 gxhi, uint256 gxlo) = h.gx();
        assertEq(pub.xhi, gxhi, "pub is G.x");
        assertEq(pub.xlo, gxlo, "pub is G.x");
        assertTrue(h.hVerify(pub, sig), "genuine sig for pub=G verifies");
    }

    // Legit Q==-G path (private key n-1): pub=-G exercises the gqInf precompute branch.
    function test_genuine_negG_verifies() public view {
        (TPub memory pub, TSig memory sig) = _mkSig(NHI, NLO - 1, 0, 123456789, 0, 777);
        (uint256 gxhi, uint256 gxlo) = h.gx();
        (uint256 ngyh, uint256 ngyl) = h.hNegGy();
        assertEq(pub.xhi, gxhi, "pub is -G (x = G.x)");
        assertEq(pub.xlo, gxlo, "pub is -G (x = G.x)");
        assertEq(pub.yhi, ngyh, "pub is -G (y = p - G.y)");
        assertEq(pub.ylo, ngyl, "pub is -G (y = p - G.y)");
        assertTrue(h.hVerify(pub, sig), "genuine sig for pub=-G verifies");
    }
}
