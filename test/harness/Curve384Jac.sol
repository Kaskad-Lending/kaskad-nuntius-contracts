// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import { Curve384 } from "marlinprotocol/P384/Curve384.sol";

/// Exposes the patched (Jacobian) Curve384 internals for differential testing.
contract Curve384Jac is Curve384 {
    function t_cmul(C384Elm memory a, uint256 rhi, uint256 rlo)
        external view returns (C384Elm memory)
    {
        cmul(a, rhi, rlo);
        return a;
    }

    function t_cadd(C384Elm memory a, C384Elm memory b)
        external view returns (C384Elm memory)
    {
        cadd(a, b);
        return a;
    }

    function t_cdbl(C384Elm memory a)
        external view returns (C384Elm memory)
    {
        cdbl(a);
        return a;
    }

    function t_verify(
        C384Elm memory pub,
        uint256 mhi, uint256 mlo,
        uint256 rhi, uint256 rlo,
        uint256 shi, uint256 slo
    ) external view returns (bool) {
        return verify(pub, mhi, mlo, rhi, rlo, shi, slo);
    }

    function gen() external pure returns (C384Elm memory) {
        return C384Elm({ xhi: gxhi, xlo: gxlo, yhi: gyhi, ylo: gylo });
    }
}
