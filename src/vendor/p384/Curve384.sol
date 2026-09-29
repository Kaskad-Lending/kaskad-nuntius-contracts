pragma solidity 0.8.24;
// pragma experimental ABIEncoderV2;

import "./LibMath.sol";
import "./FieldP384.sol";
import "./FieldO384.sol";

// NIST-P384 / secp384r1 curve
contract Curve384 is FieldO384, FieldP384 {
    struct C384Elm {
        uint256 xhi;
        uint256 xlo;
        uint256 yhi;
        uint256 ylo;
    }

    // Jacobian projective point (X:Y:Z) => affine (X/Z^2, Y/Z^3). Z==0 is the
    // point at infinity. Used only inside cmul to avoid a per-op field inversion.
    struct _JPoint {
        uint256 xhi; uint256 xlo;
        uint256 yhi; uint256 ylo;
        uint256 zhi; uint256 zlo;
    }

    // Scratch for _jdbl (dbl-2007-bl). Memory-resident to stay under the stack limit.
    struct _JDblScratch {
        uint256 xxhi; uint256 xxlo; // X^2
        uint256 yyhi; uint256 yylo; // Y^2
        uint256 y4hi; uint256 y4lo; // Y^4
        uint256 zzhi; uint256 zzlo; // Z^2
        uint256 shi;  uint256 slo;  // S
        uint256 mhi;  uint256 mlo;  // M
        uint256 thi;  uint256 tlo;  // T = X3
    }

    // Scratch for _jaddAffine (madd-2007-bl).
    struct _JAddScratch {
        uint256 z1z1hi; uint256 z1z1lo;
        uint256 u2hi;   uint256 u2lo;
        uint256 s2hi;   uint256 s2lo;
        uint256 hhi;    uint256 hlo;
        uint256 hhhi;   uint256 hhlo;
        uint256 ihi;    uint256 ilo;
        uint256 jhi;    uint256 jlo;
        uint256 rrhi;   uint256 rrlo;
        uint256 vhi;    uint256 vlo;
    }

    // Curve parameters
    uint256 constant cahi = 0xffffffffffffffffffffffffffffffff;
    uint256 constant calo = 0xfffffffffffffffffffffffffffffffeffffffff0000000000000000fffffffc;
    uint256 constant cbhi = 0xb3312fa7e23ee7e4988e056be3f82d19;
    uint256 constant cblo = 0x181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef;
    
    // Generator
    uint256 constant gxhi = 0xaa87ca22be8b05378eb1c71ef320ad74;
    uint256 constant gxlo = 0x6e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7;
    uint256 constant gyhi = 0x3617de4a96262c6f5d9e98bf9292dc29;
    uint256 constant gylo = 0xf8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f;
    
    // Assignment: a' = b
    function cset(C384Elm memory a, C384Elm memory b)
        internal pure
    {
        a.xhi = b.xhi;
        a.xlo = b.xlo;
        a.yhi = b.yhi;
        a.ylo = b.ylo;
    }
    
    // In place addition: a' = a + b
    function cadd(C384Elm memory a, C384Elm memory b)
        internal view
    {
        // 817 010 gas
        
        uint256 lhi;
        uint256 llo;
        uint256 thi;
        uint256 tlo;
        
        // l = (ay - by) / (ax - bx)
        (lhi, llo) = FieldP384.fsub(a.yhi, a.ylo, b.yhi, b.ylo);
        (thi, tlo) = FieldP384.fsub(a.xhi, a.xlo, b.xhi, b.xlo);
        (thi, tlo) = FieldP384.finv(thi, tlo);
        (lhi, llo) = FieldP384.fmul(lhi, llo, thi, tlo);
        
        // x = l * l - ax - bx
        (thi, tlo) = FieldP384.fsqr(lhi, llo);
        (thi, tlo) = FieldP384.fsub(thi, tlo, a.xhi, a.xlo);
        (thi, tlo) = FieldP384.fsub(thi, tlo, b.xhi, b.xlo);
        a.xhi = thi;
        a.xlo = tlo;
        
        // y = l * (bx - x) - by
        (thi, tlo) = FieldP384.fsub(b.xhi, b.xlo, a.xhi, a.xlo);
        (thi, tlo) = FieldP384.fmul(thi, tlo, lhi, llo);
        (thi, tlo) = FieldP384.fsub(thi, tlo, b.yhi, b.ylo);
        a.yhi = thi;
        a.ylo = tlo;
    }
    
    // In place double: a' = a + a
    function cdbl(C384Elm memory a)
        internal view
    {
        // 1 490 576 gas
        uint256 lhi;
        uint256 llo;
        uint256 thi;
        uint256 tlo;
        uint256 xhi;
        uint256 xlo;
        
        // l = (3 * ax * ax + ca) / (2 * ay)
        (lhi, llo) = FieldP384.fmul(0, 3, a.xhi, a.xlo);
        (lhi, llo) = FieldP384.fmul(lhi, llo, a.xhi, a.xlo);
        (lhi, llo) = FieldP384.fadd(lhi, llo, cahi, calo);
        
        (thi, tlo) = FieldP384.fadd(a.yhi, a.ylo, a.yhi, a.ylo);
        (thi, tlo) = FieldP384.finv(thi, tlo);
        (lhi, llo) = FieldP384.fmul(lhi, llo, thi, tlo);
        
        // x = l * l - ax - ax
        (thi, tlo) = FieldP384.fsqr(lhi, llo);
        (thi, tlo) = FieldP384.fsub(thi, tlo, a.xhi, a.xlo);
        (thi, tlo) = FieldP384.fsub(thi, tlo, a.xhi, a.xlo);
        xhi = thi;
        xlo = tlo;
        
        // y = l * (ax - x) - ay
        (thi, tlo) = FieldP384.fsub(a.xhi, a.xlo, xhi, xlo);
        (thi, tlo) = FieldP384.fmul(thi, tlo, lhi, llo);
        (thi, tlo) = FieldP384.fsub(thi, tlo, a.yhi, a.ylo);
        a.xhi = xhi;
        a.xlo = xlo;
        a.yhi = thi;
        a.ylo = tlo;
    }
    
    // In place Jacobian double: P' = 2P (dbl-2007-bl, general a). No inversion.
    function _jdbl(_JPoint memory P)
        internal view
    {
        if (P.zhi == 0 && P.zlo == 0) return; // 2*O = O

        _JDblScratch memory d;
        (d.xxhi, d.xxlo) = FieldP384.fsqr(P.xhi, P.xlo);        // XX = X^2
        (d.yyhi, d.yylo) = FieldP384.fsqr(P.yhi, P.ylo);        // YY = Y^2
        (d.y4hi, d.y4lo) = FieldP384.fsqr(d.yyhi, d.yylo);      // YYYY = Y^4
        (d.zzhi, d.zzlo) = FieldP384.fsqr(P.zhi, P.zlo);        // ZZ = Z^2

        // S = 2 * ((X + YY)^2 - XX - YYYY)
        (d.shi, d.slo) = FieldP384.fadd(P.xhi, P.xlo, d.yyhi, d.yylo);
        (d.shi, d.slo) = FieldP384.fsqr(d.shi, d.slo);
        (d.shi, d.slo) = FieldP384.fsub(d.shi, d.slo, d.xxhi, d.xxlo);
        (d.shi, d.slo) = FieldP384.fsub(d.shi, d.slo, d.y4hi, d.y4lo);
        (d.shi, d.slo) = FieldP384.fadd(d.shi, d.slo, d.shi, d.slo);

        // M = 3*XX + a*ZZ^2      (a = ca)
        (d.mhi, d.mlo) = FieldP384.fsqr(d.zzhi, d.zzlo);        // Z^4
        (d.mhi, d.mlo) = FieldP384.fmul(cahi, calo, d.mhi, d.mlo);
        {
            uint256 t3hi; uint256 t3lo;
            (t3hi, t3lo) = FieldP384.fadd(d.xxhi, d.xxlo, d.xxhi, d.xxlo);
            (t3hi, t3lo) = FieldP384.fadd(t3hi, t3lo, d.xxhi, d.xxlo);
            (d.mhi, d.mlo) = FieldP384.fadd(d.mhi, d.mlo, t3hi, t3lo);
        }

        // T = M^2 - 2*S      (= X3)
        (d.thi, d.tlo) = FieldP384.fsqr(d.mhi, d.mlo);
        {
            uint256 s2hi; uint256 s2lo;
            (s2hi, s2lo) = FieldP384.fadd(d.shi, d.slo, d.shi, d.slo);
            (d.thi, d.tlo) = FieldP384.fsub(d.thi, d.tlo, s2hi, s2lo);
        }

        // Z3 = (Y + Z)^2 - YY - ZZ   (reads original Y, Z)
        {
            uint256 z3hi; uint256 z3lo;
            (z3hi, z3lo) = FieldP384.fadd(P.yhi, P.ylo, P.zhi, P.zlo);
            (z3hi, z3lo) = FieldP384.fsqr(z3hi, z3lo);
            (z3hi, z3lo) = FieldP384.fsub(z3hi, z3lo, d.yyhi, d.yylo);
            (z3hi, z3lo) = FieldP384.fsub(z3hi, z3lo, d.zzhi, d.zzlo);
            P.zhi = z3hi; P.zlo = z3lo;
        }

        // Y3 = M*(S - T) - 8*YYYY
        {
            uint256 y3hi; uint256 y3lo;
            (y3hi, y3lo) = FieldP384.fsub(d.shi, d.slo, d.thi, d.tlo);
            (y3hi, y3lo) = FieldP384.fmul(d.mhi, d.mlo, y3hi, y3lo);
            uint256 e8hi; uint256 e8lo;
            (e8hi, e8lo) = FieldP384.fadd(d.y4hi, d.y4lo, d.y4hi, d.y4lo);
            (e8hi, e8lo) = FieldP384.fadd(e8hi, e8lo, e8hi, e8lo);
            (e8hi, e8lo) = FieldP384.fadd(e8hi, e8lo, e8hi, e8lo);
            (y3hi, y3lo) = FieldP384.fsub(y3hi, y3lo, e8hi, e8lo);
            P.yhi = y3hi; P.ylo = y3lo;
        }

        P.xhi = d.thi; P.xlo = d.tlo;
    }

    // In place mixed add: P' = P + Q, Q affine (qx, qy) (madd-2007-bl). No inversion.
    function _jaddAffine(
        _JPoint memory P,
        uint256 qxhi, uint256 qxlo,
        uint256 qyhi, uint256 qylo)
        internal view
    {
        if (P.zhi == 0 && P.zlo == 0) {
            // O + Q = Q  (lift Q to Jacobian with Z = 1)
            P.xhi = qxhi; P.xlo = qxlo;
            P.yhi = qyhi; P.ylo = qylo;
            P.zhi = 0;    P.zlo = 1;
            return;
        }

        _JAddScratch memory s;
        (s.z1z1hi, s.z1z1lo) = FieldP384.fsqr(P.zhi, P.zlo);                        // Z1Z1 = Z1^2
        (s.u2hi, s.u2lo) = FieldP384.fmul(qxhi, qxlo, s.z1z1hi, s.z1z1lo);          // U2 = X2*Z1Z1
        (s.s2hi, s.s2lo) = FieldP384.fmul(P.zhi, P.zlo, s.z1z1hi, s.z1z1lo);        // Z1^3
        (s.s2hi, s.s2lo) = FieldP384.fmul(qyhi, qylo, s.s2hi, s.s2lo);              // S2 = Y2*Z1^3
        (s.hhi, s.hlo) = FieldP384.fsub(s.u2hi, s.u2lo, P.xhi, P.xlo);              // H = U2 - X1
        (s.rrhi, s.rrlo) = FieldP384.fsub(s.s2hi, s.s2lo, P.yhi, P.ylo);            // S2 - Y1
        (s.rrhi, s.rrlo) = FieldP384.fadd(s.rrhi, s.rrlo, s.rrhi, s.rrlo);          // r = 2*(S2 - Y1)

        if (s.hhi == 0 && s.hlo == 0) {
            if (s.rrhi == 0 && s.rrlo == 0) {
                _jdbl(P); // P == Q
                return;
            }
            // P == -Q  =>  P + Q = O
            P.xhi = 0; P.xlo = 0; P.yhi = 0; P.ylo = 0; P.zhi = 0; P.zlo = 0;
            return;
        }

        (s.hhhi, s.hhlo) = FieldP384.fsqr(s.hhi, s.hlo);                            // HH = H^2
        (s.ihi, s.ilo) = FieldP384.fadd(s.hhhi, s.hhlo, s.hhhi, s.hhlo);            // 2*HH
        (s.ihi, s.ilo) = FieldP384.fadd(s.ihi, s.ilo, s.ihi, s.ilo);               // I = 4*HH
        (s.jhi, s.jlo) = FieldP384.fmul(s.hhi, s.hlo, s.ihi, s.ilo);               // J = H*I
        (s.vhi, s.vlo) = FieldP384.fmul(P.xhi, P.xlo, s.ihi, s.ilo);               // V = X1*I

        // X3 = r^2 - J - 2*V
        uint256 x3hi; uint256 x3lo;
        {
            (x3hi, x3lo) = FieldP384.fsqr(s.rrhi, s.rrlo);
            (x3hi, x3lo) = FieldP384.fsub(x3hi, x3lo, s.jhi, s.jlo);
            uint256 v2hi; uint256 v2lo;
            (v2hi, v2lo) = FieldP384.fadd(s.vhi, s.vlo, s.vhi, s.vlo);
            (x3hi, x3lo) = FieldP384.fsub(x3hi, x3lo, v2hi, v2lo);
        }

        // Y3 = r*(V - X3) - 2*Y1*J
        uint256 y3hi; uint256 y3lo;
        {
            (y3hi, y3lo) = FieldP384.fsub(s.vhi, s.vlo, x3hi, x3lo);
            (y3hi, y3lo) = FieldP384.fmul(s.rrhi, s.rrlo, y3hi, y3lo);
            uint256 y1jhi; uint256 y1jlo;
            (y1jhi, y1jlo) = FieldP384.fmul(P.yhi, P.ylo, s.jhi, s.jlo);
            (y1jhi, y1jlo) = FieldP384.fadd(y1jhi, y1jlo, y1jhi, y1jlo);
            (y3hi, y3lo) = FieldP384.fsub(y3hi, y3lo, y1jhi, y1jlo);
        }

        // Z3 = (Z1 + H)^2 - Z1Z1 - HH
        uint256 z3hi; uint256 z3lo;
        {
            (z3hi, z3lo) = FieldP384.fadd(P.zhi, P.zlo, s.hhi, s.hlo);
            (z3hi, z3lo) = FieldP384.fsqr(z3hi, z3lo);
            (z3hi, z3lo) = FieldP384.fsub(z3hi, z3lo, s.z1z1hi, s.z1z1lo);
            (z3hi, z3lo) = FieldP384.fsub(z3hi, z3lo, s.hhhi, s.hhlo);
        }

        P.xhi = x3hi; P.xlo = x3lo;
        P.yhi = y3hi; P.ylo = y3lo;
        P.zhi = z3hi; P.zlo = z3lo;
    }

    // In place multiply a' = a * r  (affine in, affine out; identity => (0,0)).
    // Left-to-right double-and-add in Jacobian coords: one inversion at the end
    // instead of one per point op. The scalar is (rhi:rlo), rhi the high 256 bits.
    function cmul(C384Elm memory a, uint256 rhi, uint256 rlo)
        internal view
    {
        _JPoint memory acc; // all-zero => Z == 0 => point at infinity

        for (uint256 word = 0; word < 2; word++) {
            uint256 bits = word == 0 ? rhi : rlo;
            for (uint256 i = 256; i > 0; ) {
                i--;
                _jdbl(acc);
                if (((bits >> i) & 1) == 1) {
                    _jaddAffine(acc, a.xhi, a.xlo, a.yhi, a.ylo);
                }
            }
        }

        // Convert back to affine. Infinity maps to (0,0) to match the previous
        // affine cmul's result for r == 0.
        if (acc.zhi == 0 && acc.zlo == 0) {
            a.xhi = 0; a.xlo = 0; a.yhi = 0; a.ylo = 0;
            return;
        }

        uint256 zihi; uint256 zilo;
        (zihi, zilo) = FieldP384.finv(acc.zhi, acc.zlo);           // Z^-1
        uint256 zi2hi; uint256 zi2lo;
        (zi2hi, zi2lo) = FieldP384.fsqr(zihi, zilo);               // Z^-2
        (a.xhi, a.xlo) = FieldP384.fmul(acc.xhi, acc.xlo, zi2hi, zi2lo); // x = X*Z^-2
        (zi2hi, zi2lo) = FieldP384.fmul(zi2hi, zi2lo, zihi, zilo); // Z^-3
        (a.yhi, a.ylo) = FieldP384.fmul(acc.yhi, acc.ylo, zi2hi, zi2lo); // y = Y*Z^-3
    }
    
    // ECDSA-P384 verify, hardened + Strauss-Shamir. Rejects r,s outside [1,n) and any pub that is
    // O or off-curve, then computes u*G + v*Q in one shared-doubling ladder (2-bit joint window over
    // {O,G,Q,G+Q}) and compares R.x mod n to r. The guards are mandatory: without them the joint
    // ladder accepts off-curve, zero and s-malleable signatures.
    function verify(
        C384Elm memory pub,
        uint256 mhi, uint256 mlo,
        uint256 rhi, uint256 rlo,
        uint256 shi, uint256 slo)
        internal view
        returns (bool)
    {
        if (!_inRange(rhi, rlo)) return false;
        if (!_inRange(shi, slo)) return false;
        if (!_onCurve(pub)) return false;

        uint256 uhi; uint256 ulo;
        uint256 vhi; uint256 vlo;
        (shi, slo) = FieldO384.oinv(shi, slo);            // s^-1 mod n
        (uhi, ulo) = FieldO384.omul(mhi, mlo, shi, slo);  // u = m/s mod n
        (vhi, vlo) = FieldO384.omul(rhi, rlo, shi, slo);  // v = r/s mod n
        C384Elm memory R = _mulShamir(uhi, ulo, pub, vhi, vlo);
        (uint256 rxhi, uint256 rxlo) = FieldO384.oadd(R.xhi, R.xlo, 0, 0); // R.x mod n (R.x < p < 2n)
        return rxhi == rhi && rxlo == rlo;                // R == O => rx = 0 != r (r >= 1), rejected
    }

    // 1 <= (hi,lo) < n. A 48-byte-parsed scalar has hi < 2^128 <= ohi; a larger hi is off the
    // COSE/DER path and rejected here.
    function _inRange(uint256 hi, uint256 lo) private pure returns (bool) {
        if (hi == 0 && lo == 0) return false;
        if (hi > ohi) return false;
        if (hi < ohi) return true;
        return lo < olo;
    }

    // Canonical nonzero public key with y^2 == x^3 + a*x + b (mod p).
    function _onCurve(C384Elm memory q) private view returns (bool) {
        if (q.xhi > phi || (q.xhi == phi && q.xlo >= plo)) return false;
        if (q.yhi > phi || (q.yhi == phi && q.ylo >= plo)) return false;
        if (q.xhi == 0 && q.xlo == 0 && q.yhi == 0 && q.ylo == 0) return false;
        (uint256 y2h, uint256 y2l) = FieldP384.fsqr(q.yhi, q.ylo);
        (uint256 th, uint256 tl) = FieldP384.fsqr(q.xhi, q.xlo);
        (th, tl) = FieldP384.fmul(th, tl, q.xhi, q.xlo);
        (uint256 ah, uint256 al) = FieldP384.fmul(cahi, calo, q.xhi, q.xlo);
        (th, tl) = FieldP384.fadd(th, tl, ah, al);
        (th, tl) = FieldP384.fadd(th, tl, cbhi, cblo);
        return y2h == th && y2l == tl;
    }

    // Affine u*G + v*Q via a Strauss-Shamir joint ladder, same "O => (0,0)" convention as cmul.
    // Reuses _jdbl/_jaddAffine/cadd/cdbl unchanged; verify enforces an on-curve Q upstream.
    function _mulShamir(
        uint256 uhi, uint256 ulo,   // scalar for the fixed generator G
        C384Elm memory Q,           // variable base (public key)
        uint256 vhi, uint256 vlo)   // scalar for Q
        internal view
        returns (C384Elm memory out)
    {
        // Joint-table entry that is not O/G/Q: GQ = G + Q. gqInf marks G + Q == O (Q == -G).
        bool gqInf = false;
        C384Elm memory GQ;
        if (Q.xhi == gxhi && Q.xlo == gxlo) {
            if (Q.yhi == gyhi && Q.ylo == gylo) {          // Q == G => G + Q = 2G
                GQ.xhi = gxhi; GQ.xlo = gxlo; GQ.yhi = gyhi; GQ.ylo = gylo;
                cdbl(GQ);
            } else {
                // x == G.x, y != G.y. Set gqInf only for Q == -G exactly; anything else is
                // off-curve (verify rejects it upstream) and must not collapse Q out of the ladder.
                (uint256 nyh, uint256 nyl) = FieldP384.fsub(0, 0, gyhi, gylo); // -G.y = p - G.y
                if (Q.yhi == nyh && Q.ylo == nyl) {
                    gqInf = true;
                } else {
                    GQ.xhi = gxhi; GQ.xlo = gxlo; GQ.yhi = gyhi; GQ.ylo = gylo;
                    cadd(GQ, Q);
                }
            }
        } else {
            GQ.xhi = gxhi; GQ.xlo = gxlo; GQ.yhi = gyhi; GQ.ylo = gylo;
            cadd(GQ, Q);                                    // generic affine G + Q (G.x != Q.x)
        }

        _JPoint memory acc;                                // all-zero => Z==0 => point at infinity
        for (uint256 word = 0; word < 2; word++) {
            uint256 ub = word == 0 ? uhi : ulo;
            uint256 vb = word == 0 ? vhi : vlo;
            for (uint256 i = 256; i > 0; ) {
                i--;
                _jdbl(acc);
                _stepShamir(acc, ((ub >> i) & 1) | (((vb >> i) & 1) << 1), Q, GQ, gqInf);
            }
        }

        if (acc.zhi == 0 && acc.zlo == 0) {
            return out;                                    // out zero-initialised (0,0,0,0)
        }
        uint256 zihi; uint256 zilo;
        (zihi, zilo) = FieldP384.finv(acc.zhi, acc.zlo);                     // Z^-1
        uint256 zi2hi; uint256 zi2lo;
        (zi2hi, zi2lo) = FieldP384.fsqr(zihi, zilo);                         // Z^-2
        (out.xhi, out.xlo) = FieldP384.fmul(acc.xhi, acc.xlo, zi2hi, zi2lo); // x = X*Z^-2
        (zi2hi, zi2lo) = FieldP384.fmul(zi2hi, zi2lo, zihi, zilo);           // Z^-3
        (out.yhi, out.ylo) = FieldP384.fmul(acc.yhi, acc.ylo, zi2hi, zi2lo); // y = Y*Z^-3
    }

    // One joint-window step: add the table entry selected by (u_bit | v_bit<<1). Extracted from the
    // loop to stay under the stack limit without via_ir.
    function _stepShamir(
        _JPoint memory acc, uint256 sel,
        C384Elm memory Q, C384Elm memory GQ, bool gqInf)
        internal view
    {
        if (sel == 1) {
            _jaddAffine(acc, gxhi, gxlo, gyhi, gylo);          // + G
        } else if (sel == 2) {
            _jaddAffine(acc, Q.xhi, Q.xlo, Q.yhi, Q.ylo);      // + Q
        } else if (sel == 3 && !gqInf) {
            _jaddAffine(acc, GQ.xhi, GQ.xlo, GQ.yhi, GQ.ylo);  // + (G+Q); gqInf => +O => skip
        }
    }

    function double(
        C384Elm memory a)
        internal view
        returns (C384Elm memory)
    {
        cdbl(a);
        return a;
    }
}
