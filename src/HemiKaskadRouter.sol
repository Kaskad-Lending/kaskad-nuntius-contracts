// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KaskadRouter} from "./KaskadRouter.sol";

interface IHemiAddressesProvider {
    function getPriceOracle() external view returns (address);
}

interface IHemiPriceOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IHemiPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
}

interface IHemiWETH {
    function deposit() external payable;
}

/// @title HemiKaskadRouter
/// @notice KaskadRouter for markets without a price-oracle sentinel and with
///         prices pushed only by users. The borrowed asset is fresh when the
///         pool's price oracle returns a non-zero price. Supply and repay go
///         through the router too: the rewards hook inside the token mint or
///         burn prices the whole market and is dropped when a price is stale.
contract HemiKaskadRouter is KaskadRouter {
    using SafeERC20 for IERC20;

    uint256 private constant VARIABLE_RATE = 2;

    constructor(address _oracle, address _pool, address _weth) KaskadRouter(_oracle, _pool, _weth) {}

    function _requireFreshAsset(address asset) internal view override {
        address priceOracle = IHemiAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle();
        try IHemiPriceOracle(priceOracle).getAssetPrice(asset) returns (uint256 price) {
            if (price == 0) revert StaleAsset(asset);
        } catch {
            revert StaleAsset(asset);
        }
    }

    /// @notice Supply `asset` for the caller. Requires asset.approve(router)
    ///         upfront; the rewards hook needs a price for every reserve.
    function supplyWithPrices(PriceUpdate[] calldata prices, address asset, uint256 amount) external nonReentrant {
        _pushPrices(prices);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _supply(asset, amount, msg.sender);
    }

    /// @notice Wrap the attached ETH and supply it as WETH for the caller.
    function supplyEthWithPrices(PriceUpdate[] calldata prices) external payable nonReentrant {
        _pushPrices(prices);
        IHemiWETH(address(weth)).deposit{value: msg.value}();
        _supply(address(weth), msg.value, msg.sender);
    }

    /// @notice Repay the caller's variable debt in `asset`, capped at the debt;
    ///         `type(uint256).max` repays it in full. Requires asset.approve(router).
    function repayWithPrices(PriceUpdate[] calldata prices, address asset, uint256 amount) external nonReentrant {
        _pushPrices(prices);
        uint256 payment = _cappedAtDebt(asset, amount, msg.sender);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), payment);
        _repay(asset, payment, msg.sender);
    }

    /// @notice Repay the caller's WETH debt with the attached ETH; whatever
    ///         exceeds the debt is sent back.
    function repayEthWithPrices(PriceUpdate[] calldata prices) external payable nonReentrant {
        _pushPrices(prices);
        uint256 payment = _cappedAtDebt(address(weth), msg.value, msg.sender);
        IHemiWETH(address(weth)).deposit{value: payment}();
        _repay(address(weth), payment, msg.sender);

        uint256 refund = msg.value - payment;
        if (refund == 0) return;
        (bool ok,) = msg.sender.call{value: refund}("");
        if (!ok) revert EthTransferFailed(msg.sender, refund);
    }

    function _supply(address asset, uint256 amount, address onBehalfOf) private {
        IERC20(asset).forceApprove(address(pool), amount);
        IHemiPool(address(pool)).supply(asset, amount, onBehalfOf, 0);
    }

    function _repay(address asset, uint256 amount, address onBehalfOf) private {
        IERC20(asset).forceApprove(address(pool), amount);
        IHemiPool(address(pool)).repay(asset, amount, VARIABLE_RATE, onBehalfOf);
    }

    /// @dev The pool reads the same debt-token balance, so a payment capped
    ///      here is taken in full and nothing is left on the router.
    function _cappedAtDebt(address asset, uint256 amount, address user) private view returns (uint256) {
        uint256 debt = IERC20(pool.getReserveData(asset).variableDebtTokenAddress).balanceOf(user);
        return amount < debt ? amount : debt;
    }
}
