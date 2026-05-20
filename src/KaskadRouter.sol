// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IKaskadPriceOracle {
    function updatePrice(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8 numSources,
        bytes32 sourcesHash,
        bytes calldata signature
    ) external;

    error StalePrice(uint256 provided, uint256 current);
}

interface IPool {
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
    function ADDRESSES_PROVIDER() external view returns (address);

    struct ReserveDataLegacy {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }
    function getReserveData(address asset) external view returns (ReserveDataLegacy memory);
}

interface IPoolAddressesProvider {
    function getPriceOracleSentinel() external view returns (address);
}

interface IKaskadStalenessChecker {
    function isAssetFresh(address asset) external view returns (bool);
}

/// @title KaskadRouter
/// @notice Atomic price-update + Aave action in one TX. onBehalfOf is always
///         msg.sender. The freshness subject (caller for borrow/withdraw,
///         liquidatee for liquidation) is recorded in transient storage so
///         the sentinel checks the right portfolio.
contract KaskadRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IKaskadPriceOracle public immutable oracle;
    IPool public immutable pool;

    bytes32 private constant SENDER_SLOT = keccak256("KaskadRouter.sender");

    struct PriceUpdate {
        bytes32 assetId;
        uint256 price;
        uint256 timestamp;
        uint8 numSources;
        bytes32 sourcesHash;
        bytes signature;
    }

    error PriceUpdateFailed(bytes32 assetId);
    error StaleAsset(address asset);

    constructor(address _oracle, address _pool) {
        oracle = IKaskadPriceOracle(_oracle);
        pool = IPool(_pool);
    }

    function sender() external view returns (address s) {
        bytes32 slot = SENDER_SLOT;
        assembly {
            s := tload(slot)
        }
    }

    modifier withSender(address who) {
        bytes32 slot = SENDER_SLOT;
        assembly {
            tstore(slot, who)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    /// @dev Skips StalePrice (already fresh on-chain); reverts on any other oracle error.
    function _pushPrices(PriceUpdate[] calldata prices) internal {
        for (uint256 i = 0; i < prices.length; i++) {
            try oracle.updatePrice(
                prices[i].assetId,
                prices[i].price,
                prices[i].timestamp,
                prices[i].numSources,
                prices[i].sourcesHash,
                prices[i].signature
            ) {}
            catch (bytes memory reason) {
                if (bytes4(reason) == IKaskadPriceOracle.StalePrice.selector) continue;
                revert PriceUpdateFailed(prices[i].assetId);
            }
        }
    }

    /// @dev Aave's in-band sentinel iterates `userConfig`, which does not yet
    ///      include the asset being borrowed — gate it explicitly.
    function _requireFreshAsset(address asset) internal view {
        address sentinel = IPoolAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracleSentinel();
        if (!IKaskadStalenessChecker(sentinel).isAssetFresh(asset)) revert StaleAsset(asset);
    }

    /// @notice Borrow `asset`. Requires debtToken.approveDelegation upfront.
    function borrowWithPrices(PriceUpdate[] calldata prices, address asset, uint256 amount, uint256 interestRateMode)
        external
        nonReentrant
        withSender(msg.sender)
    {
        _pushPrices(prices);
        _requireFreshAsset(asset);
        pool.borrow(asset, amount, interestRateMode, 0, msg.sender);
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraw `asset`. No freshness gate — user exit must not be
    ///         blocked. aToken derived from the reserve, never the caller.
    function withdrawWithPrices(PriceUpdate[] calldata prices, address asset, uint256 amount)
        external
        nonReentrant
        withSender(msg.sender)
    {
        _pushPrices(prices);

        address aToken = pool.getReserveData(asset).aTokenAddress;
        uint256 pullAmount = amount == type(uint256).max ? IERC20(aToken).balanceOf(msg.sender) : amount;
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), pullAmount);

        pool.withdraw(asset, pullAmount, msg.sender);
    }

    /// @notice Liquidate `user`. Liquidator approves debtAsset upfront.
    function liquidateWithPrices(
        PriceUpdate[] calldata prices,
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external nonReentrant withSender(user) {
        _pushPrices(prices);

        address seizedAsset =
            receiveAToken ? pool.getReserveData(collateralAsset).aTokenAddress : collateralAsset;

        // Snapshot BEFORE pulling the liquidator's deposit — refund is the
        // liquidation delta only, donations and unused remainder both flow
        // back to the caller correctly.
        uint256 preSeized = IERC20(seizedAsset).balanceOf(address(this));
        uint256 preDebt = IERC20(debtAsset).balanceOf(address(this));

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);
        IERC20(debtAsset).forceApprove(address(pool), debtToCover);

        pool.liquidationCall(collateralAsset, debtAsset, user, debtToCover, receiveAToken);

        if (seizedAsset != debtAsset) {
            uint256 postSeized = IERC20(seizedAsset).balanceOf(address(this));
            if (postSeized > preSeized) {
                IERC20(seizedAsset).safeTransfer(msg.sender, postSeized - preSeized);
            }
        }

        uint256 postDebt = IERC20(debtAsset).balanceOf(address(this));
        if (postDebt > preDebt) {
            IERC20(debtAsset).safeTransfer(msg.sender, postDebt - preDebt);
        }
    }
}
