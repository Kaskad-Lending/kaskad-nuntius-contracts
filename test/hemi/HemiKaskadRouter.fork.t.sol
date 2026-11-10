// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KaskadRouter, IPool} from "../../src/KaskadRouter.sol";
import {HemiKaskadRouter} from "../../src/HemiKaskadRouter.sol";

interface IHemiPoolActions {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
}

interface IHemiAaveOracleRead {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
}

interface ICreditDelegation {
    function approveDelegation(address delegatee, uint256 amount) external;
}

interface IHemiStrategyRead {
    function userEpochState(address user)
        external
        view
        returns (uint256, uint256 supplierBase, uint256, uint64, uint64, uint64, bool, bool);
}

/// Router against live Hemi Sepolia with signed nuntius prices.
/// Run: HEMI_ROUTER_FORK_TESTS=true HEMI_PRICES_JSON="$(curl -s https://nuntius.kaskad.live/prices)" forge test --match-path 'test/hemi/*'
contract HemiKaskadRouterForkTest is Test {
    address private constant REGISTRY = 0xaa756d70edea36F834B982E03A79EE59835d0d1A;
    address private constant POOL = 0xf3E62b03e8DEd32B7000A1800460C92803f9E798;
    address private constant AAVE_ORACLE = 0xa210FB1F6AF21066675e208e57F282eb770Ac70e;
    address private constant WETH = 0x0C8aFD1b58aa2A5bAd2414B861D8A7fF898eDC3A;
    address private constant USDC = 0xD47971C7F5B1067d25cd45d30b2c9eb60de96443;
    address private constant STRATEGY = 0xa1c3765FF960333f9192837367227216d6D9eb73;
    bytes32 private constant HOOK_FAILED = keccak256("ActivityTrackerHookFailed(address,bytes)");
    uint256 private constant RESERVE_FEEDS = 5;
    uint256 private constant PUBLICATION_AGE = 180;

    HemiKaskadRouter private router;
    KaskadRouter.PriceUpdate[] private signed;
    uint256 private usdcPrice;
    address private user;
    address private aWeth;

    function setUp() public {
        if (!vm.envOr("HEMI_ROUTER_FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr("HEMI_RPC_URL", string("https://testnet.rpc.hemi.network/rpc")));
        assertEq(block.chainid, 743111);
        router = new HemiKaskadRouter(REGISTRY, POOL, WETH);
        aWeth = IPool(POOL).getReserveData(WETH).aTokenAddress;
        _loadSignedPrices(vm.envString("HEMI_PRICES_JSON"));

        user = makeAddr("hemi-user");
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        IWETH9(WETH).deposit{value: 0.5 ether}();
        IERC20(WETH).approve(POOL, type(uint256).max);
        IHemiPoolActions(POOL).supply(WETH, 0.5 ether, user, 0);
        vm.stopPrank();

        // Push any on-chain publication past the source's age limit.
        vm.warp(block.timestamp + PUBLICATION_AGE + 1);
    }

    function test_prices_are_stale_before_the_push() public {
        vm.expectRevert();
        IHemiAaveOracleRead(AAVE_ORACLE).getAssetPrice(USDC);
    }

    function test_direct_supply_with_stale_prices_drops_the_rewards_hook() public {
        vm.startPrank(user);
        IWETH9(WETH).deposit{value: 0.1 ether}();
        vm.recordLogs();
        IHemiPoolActions(POOL).supply(WETH, 0.1 ether, user, 0);
        vm.stopPrank();
        assertGe(IERC20(aWeth).balanceOf(user), 0.6 ether - 1);
        assertTrue(_hookFailed());
    }

    function test_supply_eth_with_prices_tracks_a_first_time_supplier() public {
        address supplier = makeAddr("hemi-router-supplier");
        vm.deal(supplier, 1 ether);
        vm.recordLogs();
        vm.prank(supplier);
        router.supplyEthWithPrices{value: 0.5 ether}(signed);

        assertFalse(_hookFailed());
        assertGe(IERC20(aWeth).balanceOf(supplier), 0.5 ether - 1);
        assertGt(_supplierBase(supplier), 0);
        assertEq(address(router).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
    }

    function test_supply_with_prices_runs_the_rewards_hook() public {
        address aUsdc = IPool(POOL).getReserveData(USDC).aTokenAddress;
        deal(USDC, user, 1_000e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.supplyWithPrices(signed, USDC, 1_000e6);
        vm.stopPrank();

        assertFalse(_hookFailed());
        assertGe(IERC20(aUsdc).balanceOf(user), 1_000e6 - 1);
        assertEq(IERC20(USDC).balanceOf(user), 0);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
    }

    function test_supply_without_prices_still_supplies_but_drops_the_rewards_hook() public {
        address aUsdc = IPool(POOL).getReserveData(USDC).aTokenAddress;
        deal(USDC, user, 1_000e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.supplyWithPrices(new KaskadRouter.PriceUpdate[](0), USDC, 1_000e6);
        vm.stopPrank();

        assertGe(IERC20(aUsdc).balanceOf(user), 1_000e6 - 1);
        assertTrue(_hookFailed());
    }

    function test_borrow_without_prices_reverts_stale_asset() public {
        _delegate(USDC);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, USDC));
        vm.prank(user);
        router.borrowWithPrices(new KaskadRouter.PriceUpdate[](0), USDC, 100e6, 2);
    }

    function test_borrow_with_prices_in_one_tx() public {
        _borrowUsdc(100e6);
        assertEq(IERC20(USDC).balanceOf(user), 100e6);
        assertGe(IERC20(_variableDebt(USDC)).balanceOf(user), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
    }

    function test_borrow_eth_with_prices() public {
        _delegate(WETH);
        uint256 before = user.balance;
        vm.prank(user);
        router.borrowEthWithPrices(signed, 0.01 ether, 2);
        assertEq(user.balance, before + 0.01 ether);
        assertGe(IERC20(_variableDebt(WETH)).balanceOf(user), 0.01 ether);
    }

    function test_withdraw_without_debt_needs_no_prices() public {
        vm.startPrank(user);
        IERC20(aWeth).approve(address(router), type(uint256).max);
        router.withdrawWithPrices(new KaskadRouter.PriceUpdate[](0), WETH, 0.1 ether);
        vm.stopPrank();
        assertEq(IERC20(WETH).balanceOf(user), 0.1 ether);
    }

    function test_withdraw_eth_without_debt_needs_no_prices() public {
        uint256 before = user.balance;
        vm.startPrank(user);
        IERC20(aWeth).approve(address(router), type(uint256).max);
        router.withdrawEthWithPrices(new KaskadRouter.PriceUpdate[](0), 0.1 ether);
        vm.stopPrank();
        assertEq(user.balance, before + 0.1 ether);
    }

    function test_withdraw_with_debt_reuses_prices_already_pushed() public {
        _borrowUsdc(100e6);
        vm.startPrank(user);
        IERC20(aWeth).approve(address(router), type(uint256).max);
        router.withdrawWithPrices(signed, WETH, 0.1 ether);
        vm.stopPrank();
        assertEq(IERC20(WETH).balanceOf(user), 0.1 ether);
    }

    function test_withdraw_with_debt_fails_closed_on_stale_prices() public {
        _borrowUsdc(100e6);
        vm.warp(block.timestamp + PUBLICATION_AGE + 1);
        vm.startPrank(user);
        IERC20(aWeth).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.withdrawWithPrices(new KaskadRouter.PriceUpdate[](0), WETH, 0.1 ether);
        vm.stopPrank();
    }

    function test_direct_repay_with_stale_prices_drops_the_rewards_hook() public {
        _borrowUsdc(100e6);
        vm.warp(block.timestamp + PUBLICATION_AGE + 1);
        deal(USDC, user, 101e6);
        vm.startPrank(user);
        IERC20(USDC).approve(POOL, type(uint256).max);
        vm.recordLogs();
        IHemiPoolActions(POOL).repay(USDC, type(uint256).max, 2, user);
        vm.stopPrank();
        assertEq(IERC20(_variableDebt(USDC)).balanceOf(user), 0);
        assertTrue(_hookFailed());
    }

    function test_repay_with_prices_clears_the_debt_and_runs_the_hook() public {
        _borrowUsdc(100e6);
        uint256 debt = IERC20(_variableDebt(USDC)).balanceOf(user);
        deal(USDC, user, 150e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.repayWithPrices(signed, USDC, type(uint256).max);
        vm.stopPrank();

        assertFalse(_hookFailed());
        assertEq(IERC20(_variableDebt(USDC)).balanceOf(user), 0);
        assertEq(IERC20(USDC).balanceOf(user), 150e6 - debt);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
    }

    function test_repay_without_debt_reverts_and_keeps_the_funds() public {
        deal(USDC, user, 10e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.repayWithPrices(signed, USDC, 10e6);
        vm.expectRevert();
        router.repayEthWithPrices{value: 0.01 ether}(signed);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(user), 10e6);
    }

    function test_repay_eth_with_prices_refunds_the_excess() public {
        _delegate(WETH);
        vm.prank(user);
        router.borrowEthWithPrices(signed, 0.01 ether, 2);
        uint256 debt = IERC20(_variableDebt(WETH)).balanceOf(user);
        uint256 before = user.balance;
        vm.recordLogs();
        vm.prank(user);
        router.repayEthWithPrices{value: 0.02 ether}(signed);

        assertFalse(_hookFailed());
        assertEq(IERC20(_variableDebt(WETH)).balanceOf(user), 0);
        assertEq(user.balance, before - debt);
        assertEq(address(router).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
    }

    function test_push_prices_reads_through_aave() public {
        router.pushPrices(signed);
        assertEq(IHemiAaveOracleRead(AAVE_ORACLE).getAssetPrice(USDC), usdcPrice);
        assertGt(IHemiAaveOracleRead(AAVE_ORACLE).getAssetPrice(WETH), 0);
    }

    function _borrowUsdc(uint256 amount) private {
        _delegate(USDC);
        vm.prank(user);
        router.borrowWithPrices(signed, USDC, amount, 2);
    }

    function _delegate(address asset) private {
        ICreditDelegation debt = ICreditDelegation(_variableDebt(asset));
        vm.prank(user);
        debt.approveDelegation(address(router), type(uint256).max);
    }

    function _variableDebt(address asset) private view returns (address) {
        return IPool(POOL).getReserveData(asset).variableDebtTokenAddress;
    }

    function _supplierBase(address account) private view returns (uint256 supplierBase) {
        (, supplierBase,,,,,,) = IHemiStrategyRead(STRATEGY).userEpochState(account);
    }

    /// Reads the logs recorded since the last `vm.recordLogs()`.
    function _hookFailed() private view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == HOOK_FAILED) return true;
        }
        return false;
    }

    /// Keeps the feed of every reserve from the nuntius `/prices` payload: the
    /// rewards hook prices the whole market.
    function _loadSignedPrices(string memory json) private {
        for (uint256 i; vm.keyExistsJson(json, _at(i, "")); ++i) {
            bytes32 id = vm.parseJsonBytes32(json, _at(i, ".asset_id"));
            if (!_isReserveFeed(id)) continue;
            KaskadRouter.PriceUpdate memory p = KaskadRouter.PriceUpdate({
                assetId: id,
                price: vm.parseUint(vm.parseJsonString(json, _at(i, ".price"))),
                timestamp: vm.parseJsonUint(json, _at(i, ".timestamp")),
                numSources: uint8(vm.parseJsonUint(json, _at(i, ".num_sources"))),
                sourcesHash: vm.parseJsonBytes32(json, _at(i, ".sources_hash")),
                signature: vm.parseJsonBytes(json, _at(i, ".signature"))
            });
            // Must stay inside the observation window after the setUp warp.
            assertGe(p.timestamp + 300, block.timestamp + PUBLICATION_AGE + 1, "signed price too old");
            if (id == keccak256("USDC/USD")) usdcPrice = p.price;
            signed.push(p);
        }
        assertEq(signed.length, RESERVE_FEEDS, "a signed price per reserve feed");
    }

    function _isReserveFeed(bytes32 id) private pure returns (bool) {
        return id == keccak256("ETH/USD") || id == keccak256("USDC/USD") || id == keccak256("USDT/USD")
            || id == keccak256("BTC/USD") || id == keccak256("HEMI/USD");
    }

    function _at(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".prices[", vm.toString(i), "]", field);
    }
}
