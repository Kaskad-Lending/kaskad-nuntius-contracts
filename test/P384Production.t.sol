// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Curve384} from "marlinprotocol/P384/Curve384.sol";
import {Curve384Affine} from "./ref/Curve384Affine.sol";

contract P384ProductionHarness is Curve384 {
    function mulShamir(uint256 uhi, uint256 ulo, C384Elm memory q, uint256 vhi, uint256 vlo)
        external view returns (C384Elm memory)
    {
        return _mulShamir(uhi, ulo, q, vhi, vlo);
    }

    function verifySignature(
        C384Elm memory q,
        uint256 mhi, uint256 mlo,
        uint256 rhi, uint256 rlo,
        uint256 shi, uint256 slo
    ) external view returns (bool) {
        return verify(q, mhi, mlo, rhi, rlo, shi, slo);
    }
}

contract P384ProductionTest is Test {
    P384ProductionHarness internal production;
    Curve384Affine internal affine;

    uint256 internal constant NHI = 0xffffffffffffffffffffffffffffffff;
    uint256 internal constant NLO = 0xffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973;
    uint256 internal constant PHI = 0xffffffffffffffffffffffffffffffff;
    uint256 internal constant PLO = 0xfffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff;

    function setUp() public {
        production = new P384ProductionHarness();
        affine = new Curve384Affine();
    }

    function _key(uint256 multiple, bool negative) internal view returns (Curve384.C384Elm memory q) {
        Curve384Affine.C384Elm memory point = affine.t_cmul(affine.gen(), 0, multiple);
        q = Curve384.C384Elm(point.xhi, point.xlo, point.yhi, point.ylo);
        if (negative) (q.yhi, q.ylo) = affine.fsub(0, 0, q.yhi, q.ylo);
    }

    function _assertSame(Curve384.C384Elm memory actual, Curve384Affine.C384Elm memory expected)
        internal pure
    {
        assertEq(actual.xhi, expected.xhi, "xhi");
        assertEq(actual.xlo, expected.xlo, "xlo");
        assertEq(actual.yhi, expected.yhi, "yhi");
        assertEq(actual.ylo, expected.ylo, "ylo");
    }

    function _assertSmallShamir(uint256 multiple, bool negative, uint256 u, uint256 v, uint256 expected)
        internal view
    {
        _assertSame(
            production.mulShamir(0, u, _key(multiple, negative), 0, v),
            affine.t_cmul(affine.gen(), 0, expected)
        );
    }

    function test_shamir_Q2G_collision_doublesTo4G() public view {
        _assertSmallShamir(2, false, 2, 1, 4);
    }

    function test_shamir_QNeg2G_collision_isInfinity() public view {
        _assertSmallShamir(2, true, 2, 1, 0);
    }

    function test_shamir_QNeg2G_recoversAfterInfinity() public view {
        _assertSmallShamir(2, true, 5, 2, 1);
    }

    function test_shamir_QG_precomputeDouble_is4G() public view {
        _assertSmallShamir(1, false, 3, 1, 4);
    }

    function test_shamir_QNeg3G_jointAdd_isInfinity() public view {
        _assertSmallShamir(3, true, 3, 1, 0);
    }

    function test_shamir_QNegG_equalScalars_isInfinity() public view {
        _assertSame(
            production.mulShamir(NHI, NLO - 2, _key(1, true), NHI, NLO - 2),
            affine.t_cmul(affine.gen(), 0, 0)
        );
    }

    function test_shamir_QNegG_adjacentScalars_isG() public view {
        _assertSame(
            production.mulShamir(NHI, NLO - 1, _key(1, true), NHI, NLO - 2),
            affine.gen()
        );
    }

    function test_verify_zeroDigest_acceptsG() public view {
        Curve384.C384Elm memory g = _key(1, false);
        assertTrue(production.verifySignature(g, 0, 0, g.xhi, g.xlo, g.xhi, g.xlo));
    }

    function test_verify_orderDigest_acceptsG() public view {
        Curve384.C384Elm memory g = _key(1, false);
        assertTrue(production.verifySignature(g, NHI, NLO, g.xhi, g.xlo, g.xhi, g.xlo));
    }

    function test_verify_trueInfinity_rejected() public view {
        Curve384.C384Elm memory g = _key(1, false);
        _assertSame(production.mulShamir(NHI, NLO - 1, g, 0, 1), affine.t_cmul(affine.gen(), 0, 0));
        assertFalse(production.verifySignature(g, NHI, NLO - 1, 0, 1, 0, 1));
    }

    function test_verify_xAtOrAboveOrder_accepts() public view {
        // m=0, r=s=2 gives R=Q with R.x=n+2, hence r=R.x mod n=2.
        Curve384.C384Elm memory q = Curve384.C384Elm(
            NHI,
            NLO + 2,
            0x674db71d55d1948b3c7d4c562474ad13,
            0x7465f9605bc7c67cb9fab6bf9f3ca2ef87d56a8d920568aa26f7eaf13ee70a45
        );
        _assertSame(
            production.mulShamir(0, 0, q, 0, 1),
            Curve384Affine.C384Elm(q.xhi, q.xlo, q.yhi, q.ylo)
        );
        assertTrue(production.verifySignature(q, 0, 0, 0, 2, 0, 2));
    }

    function test_verify_noncanonicalX_rejected() public view {
        Curve384.C384Elm memory q = Curve384.C384Elm(
            0,
            2,
            0x8cdeadbbd04911a3c1931e26df3fa643,
            0x9dca9c7eb286fbd46fc319f0e2bb780232baf57825fc0c1912ada2fefe84024c
        );
        assertTrue(production.verifySignature(q, 0, 0, 0, 2, 0, 2), "canonical x=2");
        q.xhi = PHI;
        q.xlo = PLO + 2;
        assertFalse(production.verifySignature(q, 0, 0, 0, 2, 0, 2), "noncanonical x=p+2");
    }

    function test_verify_outOfWidthY_rejected() public view {
        Curve384.C384Elm memory q = _key(1, false);
        q.yhi += uint256(1) << 128;
        assertFalse(production.verifySignature(q, 0, 0, q.xhi, q.xlo, q.xhi, q.xlo));
    }

    function test_verify_outOfWidthX_rejected() public view {
        Curve384.C384Elm memory q = _key(1, false);
        uint256 rhi = q.xhi;
        q.xhi += uint256(1) << 128;
        assertFalse(production.verifySignature(q, 0, 0, rhi, q.xlo, rhi, q.xlo));
    }

    function test_verify_xEqualsFieldPrime_rejected() public view {
        Curve384.C384Elm memory q = _key(1, false);
        q.xhi = PHI;
        q.xlo = PLO;
        assertFalse(production.verifySignature(q, 0, 0, 0, 1, 0, 1));
    }

    function test_verify_yEqualsFieldPrime_rejected() public view {
        Curve384.C384Elm memory q = _key(1, false);
        q.yhi = PHI;
        q.ylo = PLO;
        assertFalse(production.verifySignature(q, 0, 0, q.xhi, q.xlo, q.xhi, q.xlo));
    }
}
