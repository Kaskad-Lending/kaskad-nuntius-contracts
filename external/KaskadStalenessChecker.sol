// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracleSentinel} from "@aave-v3-origin/src/contracts/interfaces/IPriceOracleSentinel.sol";
import {IPoolAddressesProvider} from "@aave-v3-origin/src/contracts/interfaces/IPoolAddressesProvider.sol";
import {IACLManager} from "@aave-v3-origin/src/contracts/interfaces/IACLManager.sol";
import {AggregatorInterface} from "@aave-v3-origin/src/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {IAaveOracle} from "@aave-v3-origin/src/contracts/interfaces/IAaveOracle.sol";
import {IPool} from "@aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {DataTypes} from "@aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol";

interface IKaskadRouter {
    function sender() external view returns (address);
}

/// @title KaskadStalenessChecker
/// @notice Per-asset TEE-price freshness gate. Via KaskadRouter the freshness
///         subject's assets are checked; otherwise all reserves. Unregistered
///         assets revert.
contract KaskadStalenessChecker is IPriceOracleSentinel {
    error NotAdmin();
    error MaxStalenessExceeded(uint256 requested, uint256 maximum);
    error AssetNotRegistered(address asset);
    error LengthMismatch();

    event AssetSet(address indexed asset, bool registered);

    uint256 public constant MAX_STALENESS_CAP = 4 hours;

    IPoolAddressesProvider public immutable override ADDRESSES_PROVIDER;
    IKaskadRouter public immutable router;

    uint256 public maxStaleness;

    mapping(address => bool) public assetRegistered;
    address[] public assets;
    mapping(address => uint256) internal _assetIndex; // 1-based; 0 = absent

    modifier onlyAdmin() {
        if (!IACLManager(ADDRESSES_PROVIDER.getACLManager()).isPoolAdmin(msg.sender)) revert NotAdmin();
        _;
    }

    constructor(IPoolAddressesProvider provider, address _router, uint256 _maxStaleness) {
        if (_maxStaleness > MAX_STALENESS_CAP) revert MaxStalenessExceeded(_maxStaleness, MAX_STALENESS_CAP);
        ADDRESSES_PROVIDER = provider;
        router = IKaskadRouter(_router);
        maxStaleness = _maxStaleness;
    }

    function setAsset(address asset, bool registered) external onlyAdmin {
        _setAsset(asset, registered);
    }

    function setAssets(address[] calldata _assets, bool[] calldata flags) external onlyAdmin {
        if (_assets.length != flags.length) revert LengthMismatch();
        for (uint256 i = 0; i < _assets.length; i++) {
            _setAsset(_assets[i], flags[i]);
        }
    }

    function getAssets() external view returns (address[] memory) {
        return assets;
    }

    function _setAsset(address asset, bool registered) internal {
        if (registered) {
            if (assetRegistered[asset]) return;
            assetRegistered[asset] = true;
            assets.push(asset);
            _assetIndex[asset] = assets.length;
        } else {
            if (!assetRegistered[asset]) return;
            assetRegistered[asset] = false;
            uint256 idx = _assetIndex[asset] - 1;
            uint256 last = assets.length - 1;
            if (idx != last) {
                address moved = assets[last];
                assets[idx] = moved;
                _assetIndex[moved] = idx + 1;
            }
            assets.pop();
            delete _assetIndex[asset];
        }
        emit AssetSet(asset, registered);
    }

    /// @inheritdoc IPriceOracleSentinel
    function isBorrowAllowed() external view override returns (bool) {
        return _checkFreshness();
    }

    /// @inheritdoc IPriceOracleSentinel
    function isLiquidationAllowed() external view override returns (bool) {
        return _checkFreshness();
    }

    /// @notice Per-asset freshness probe; reverts if asset is unregistered.
    function isAssetFresh(address asset) external view returns (bool) {
        return _isAssetFresh(asset, IAaveOracle(ADDRESSES_PROVIDER.getPriceOracle()));
    }

    function _checkFreshness() internal view returns (bool) {
        address user = router.sender();
        IPool pool = IPool(ADDRESSES_PROVIDER.getPool());
        IAaveOracle aaveOracle = IAaveOracle(ADDRESSES_PROVIDER.getPriceOracle());

        if (user != address(0)) {
            return _checkUserAssets(user, pool, aaveOracle);
        }
        return _checkAllAssets(pool, aaveOracle);
    }

    function _checkUserAssets(address user, IPool pool, IAaveOracle aaveOracle) internal view returns (bool) {
        DataTypes.UserConfigurationMap memory userConfig = pool.getUserConfiguration(user);

        if (userConfig.data == 0) return _checkAllAssets(pool, aaveOracle);

        uint256 reservesCount = pool.getReservesCount();
        for (uint256 i = 0; i < reservesCount; i++) {
            if ((userConfig.data >> (i << 1)) & 3 == 0) continue;
            address asset = pool.getReserveAddressById(uint16(i));
            if (asset == address(0)) continue;
            if (!_isAssetFresh(asset, aaveOracle)) return false;
        }
        return true;
    }

    function _checkAllAssets(IPool pool, IAaveOracle aaveOracle) internal view returns (bool) {
        address[] memory reserves = pool.getReservesList();
        for (uint256 i = 0; i < reserves.length; i++) {
            if (!_isAssetFresh(reserves[i], aaveOracle)) return false;
        }
        return true;
    }

    function _isAssetFresh(address asset, IAaveOracle aaveOracle) internal view returns (bool) {
        if (!assetRegistered[asset]) revert AssetNotRegistered(asset);

        address source = aaveOracle.getSourceOfAsset(asset);
        if (source == address(0)) return false;

        try AggregatorInterface(source).latestRoundData() returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
            return block.timestamp <= updatedAt + maxStaleness;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IPriceOracleSentinel
    function setSequencerOracle(address) external onlyAdmin {}

    /// @inheritdoc IPriceOracleSentinel
    function setGracePeriod(uint256 newGracePeriod) external onlyAdmin {
        if (newGracePeriod > MAX_STALENESS_CAP) revert MaxStalenessExceeded(newGracePeriod, MAX_STALENESS_CAP);
        maxStaleness = newGracePeriod;
        emit GracePeriodUpdated(newGracePeriod);
    }

    /// @inheritdoc IPriceOracleSentinel
    function getSequencerOracle() external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IPriceOracleSentinel
    function getGracePeriod() external view returns (uint256) {
        return maxStaleness;
    }
}
