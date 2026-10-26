// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { Curve384 } from "marlinprotocol/P384/Curve384.sol";
import { Curve384Jac } from "./harness/Curve384Jac.sol";

/// Exercises Jacobian collisions and infinity transitions near multiples of the group order.
contract P384JacobianEdgeTest is Test {
    Curve384Jac internal jac;

    // Generator
    uint256 constant gxhi = 0xaa87ca22be8b05378eb1c71ef320ad74;
    uint256 constant gxlo = 0x6e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7;
    uint256 constant gyhi = 0x3617de4a96262c6f5d9e98bf9292dc29;
    uint256 constant gylo = 0xf8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f;
    // -G.y = p - G.y
    uint256 constant neg_gyhi = 0xc9e821b569d9d390a26167406d6d23d6;
    uint256 constant neg_gylo = 0x70be242d765eb831625ceec4a0f473ef59f4e30e2817e6285bce2846f15f1a0;
    // 2G
    uint256 constant x2ghi = 0x8d999057ba3d2d969260045c55b97f0;
    uint256 constant x2glo = 0x89025959a6f434d651d207d19fb96e9e4fe0e86ebe0e64f85b96a9c75295df61;
    uint256 constant y2ghi = 0x8e80f1fa5b1b3cedb7bfe8dffd6dba74;
    uint256 constant y2glo = 0xb275d875bc6cc43e904e505f256ab4255ffd43e94d39e22d61501e700a940e80;

    // group order n and multiples, as (rhi:rlo) 512-bit scalars
    uint256 constant n_hi   = 0xffffffffffffffffffffffffffffffff;
    uint256 constant n_lo   = 0xffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973;

    function setUp() public { jac = new Curve384Jac(); }

    function _g() internal pure returns (Curve384.C384Elm memory) {
        return Curve384.C384Elm(gxhi, gxlo, gyhi, gylo);
    }
    function _mul(uint256 rhi, uint256 rlo) internal view returns (Curve384.C384Elm memory) {
        return jac.t_cmul(_g(), rhi, rlo);
    }
    function _eq(Curve384.C384Elm memory r, uint256 xh, uint256 xl, uint256 yh, uint256 yl, string memory tag) internal pure {
        assertEq(r.xhi, xh, string.concat(tag, ".xhi"));
        assertEq(r.xlo, xl, string.concat(tag, ".xlo"));
        assertEq(r.yhi, yh, string.concat(tag, ".yhi"));
        assertEq(r.ylo, yl, string.concat(tag, ".ylo"));
    }

    /// k = n  ->  O. Final add sees acc == -Q (prefix == n-1): H==0, r!=0 branch.
    function test_k_equals_n_is_O() public view {
        _eq(_mul(n_hi, n_lo), 0, 0, 0, 0, "n*G");
    }

    /// k = n+2 -> 2G. Final add sees acc == Q (prefix == n+1 ≡ 1): H==0, r==0 -> _jdbl.
    function test_k_equals_n_plus_2_is_2G() public view {
        _eq(_mul(n_hi, n_lo + 2), x2ghi, x2glo, y2ghi, y2glo, "(n+2)*G");
    }

    /// k = n+1 -> G (control near the wrap).
    function test_k_equals_n_plus_1_is_G() public view {
        _eq(_mul(n_hi, n_lo + 1), gxhi, gxlo, gyhi, gylo, "(n+1)*G");
    }

    /// k = n-1 -> -G (control near the wrap).
    function test_k_equals_n_minus_1_is_negG() public view {
        _eq(_mul(n_hi, n_lo - 1), gxhi, gxlo, neg_gyhi, neg_gylo, "(n-1)*G");
    }

    /// k = 2n -> O. acc passes through O mid-ladder (prefix == n) then must re-lift.
    function test_k_equals_2n_is_O() public view {
        uint256 rhi = (n_hi << 1) | (n_lo >> 255);
        uint256 rlo = n_lo << 1;
        _eq(_mul(rhi, rlo), 0, 0, 0, 0, "2n*G");
    }

    /// k = 2n+1 -> G (mid-ladder O then a trailing add).
    function test_k_equals_2n_plus_1_is_G() public view {
        uint256 rhi = (n_hi << 1) | (n_lo >> 255);
        uint256 rlo = (n_lo << 1) + 1;
        _eq(_mul(rhi, rlo), gxhi, gxlo, gyhi, gylo, "(2n+1)*G");
    }

    /// k = 3n -> O; k = 3n+2 -> 2G. rhi has bits above 2^128 set.
    function test_k_equals_3n_paths() public view {
        // 3n = n + 2n via 512-bit add
        uint256 twoHi = (n_hi << 1) | (n_lo >> 255);
        uint256 twoLo = n_lo << 1;
        (uint256 threeHi, uint256 threeLo) = _add512(n_hi, n_lo, twoHi, twoLo);
        _eq(_mul(threeHi, threeLo), 0, 0, 0, 0, "3n*G");
        (uint256 h2, uint256 l2) = _add512(threeHi, threeLo, 0, 2);
        _eq(_mul(h2, l2), x2ghi, x2glo, y2ghi, y2glo, "(3n+2)*G");
    }

    function _add512(uint256 ah, uint256 al, uint256 bh, uint256 bl) internal pure returns (uint256 rh, uint256 rl) {
        unchecked {
            rl = al + bl;
            rh = ah + bh + (rl < al ? 1 : 0);
        }
    }
}
