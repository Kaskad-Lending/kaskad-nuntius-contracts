// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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

/// Router against live Hemi Sepolia with signed nuntius prices.
/// Run: HEMI_ROUTER_FORK_TESTS=true HEMI_PRICES_JSON="$(curl -s https://nuntius.kaskad.live/prices)" forge test --match-path 'test/hemi/*'
contract HemiKaskadRouterForkTest is Test {
    address private constant REGISTRY = 0xaa756d70edea36F834B982E03A79EE59835d0d1A;
    address private constant POOL = 0xf3E62b03e8DEd32B7000A1800460C92803f9E798;
    address private constant AAVE_ORACLE = 0xa210FB1F6AF21066675e208e57F282eb770Ac70e;
    address private constant WETH = 0x0C8aFD1b58aa2A5bAd2414B861D8A7fF898eDC3A;
    address private constant USDC = 0xD47971C7F5B1067d25cd45d30b2c9eb60de96443;
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

    function test_supply_needs_no_prices() public {
        vm.startPrank(user);
        IWETH9(WETH).deposit{value: 0.1 ether}();
        IHemiPoolActions(POOL).supply(WETH, 0.1 ether, user, 0);
        vm.stopPrank();
        assertGe(IERC20(aWeth).balanceOf(user), 0.6 ether - 1);
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

    function test_repay_needs_no_prices() public {
        _borrowUsdc(100e6);
        vm.warp(block.timestamp + PUBLICATION_AGE + 1);
        deal(USDC, user, 101e6);
        vm.startPrank(user);
        IERC20(USDC).approve(POOL, type(uint256).max);
        IHemiPoolActions(POOL).repay(USDC, type(uint256).max, 2, user);
        vm.stopPrank();
        assertEq(IERC20(_variableDebt(USDC)).balanceOf(user), 0);
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

    /// Keeps ETH/USD and USDC/USD from the nuntius `/prices` payload.
    function _loadSignedPrices(string memory json) private {
        for (uint256 i; vm.keyExistsJson(json, _at(i, "")); ++i) {
            bytes32 id = vm.parseJsonBytes32(json, _at(i, ".asset_id"));
            if (id != keccak256("ETH/USD") && id != keccak256("USDC/USD")) continue;
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
        assertEq(signed.length, 2, "ETH/USD and USDC/USD signed prices");
    }

    function _at(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".prices[", vm.toString(i), "]", field);
    }
}
