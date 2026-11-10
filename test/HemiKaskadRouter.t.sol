// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KaskadRouter} from "../src/KaskadRouter.sol";
import {HemiKaskadRouter} from "../src/HemiKaskadRouter.sol";
import {MockOracle, MockPool, MockWETH, MockAToken} from "./KaskadRouterEth.t.sol";

/// Freshness gate of the sentinel-less Hemi router.
contract HemiKaskadRouterTest is Test {
    HemiKaskadRouter internal router;
    MockOracle internal oracle;
    MockPool internal pool;
    MockWETH internal weth;
    MockPriceOracle internal prices;

    address internal user = address(0xA11CE);
    address internal asset = address(0xA55E7);

    function setUp() public {
        oracle = new MockOracle();
        weth = new MockWETH();
        prices = new MockPriceOracle();
        pool = new MockPool(address(weth), address(new MockAToken()), address(new MockHemiProvider(address(prices))));
        router = new HemiKaskadRouter(address(oracle), address(pool), address(weth));
        vm.deal(address(weth), 100 ether);
    }

    function _none() internal pure returns (KaskadRouter.PriceUpdate[] memory) {
        return new KaskadRouter.PriceUpdate[](0);
    }

    function _one(bytes32 id) internal pure returns (KaskadRouter.PriceUpdate[] memory p) {
        p = new KaskadRouter.PriceUpdate[](1);
        p[0] = KaskadRouter.PriceUpdate(id, 1, 2, 3, bytes32(0), "");
    }

    function test_borrow_passes_with_a_priced_asset() public {
        vm.prank(user);
        router.borrowWithPrices(_none(), address(weth), 1 ether, 2);
        assertEq(pool.lastBorrowOnBehalfOf(), user);
        assertEq(weth.balanceOf(user), 1 ether);
    }

    function test_borrow_reverts_on_zero_price() public {
        prices.setMode(MockPriceOracle.Mode.Zero);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, asset));
        vm.prank(user);
        router.borrowWithPrices(_none(), asset, 1, 2);
    }

    function test_borrow_reverts_when_the_price_source_reverts() public {
        prices.setMode(MockPriceOracle.Mode.Revert);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, asset));
        vm.prank(user);
        router.borrowWithPrices(_none(), asset, 1, 2);
    }

    function test_borrow_gate_reads_the_borrowed_asset() public {
        vm.expectCall(address(prices), abi.encodeCall(MockPriceOracle.getAssetPrice, (address(weth))));
        vm.prank(user);
        router.borrowWithPrices(_none(), address(weth), 1, 2);
    }

    function test_borrow_pushes_prices_before_the_gate() public {
        prices.setMode(MockPriceOracle.Mode.Revert);
        vm.expectCall(
            address(oracle),
            abi.encodeCall(MockOracle.updatePrice, (bytes32("a"), 1, 2, uint8(3), bytes32(0), bytes("")))
        );
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, asset));
        vm.prank(user);
        router.borrowWithPrices(_one(bytes32("a")), asset, 1, 2);
    }

    function test_borrowEth_pays_out_native_with_a_priced_weth() public {
        vm.prank(user);
        router.borrowEthWithPrices(_none(), 2 ether, 2);
        assertEq(user.balance, 2 ether);
        assertEq(pool.lastBorrowAsset(), address(weth));
    }

    function test_borrowEth_reverts_when_weth_is_stale() public {
        prices.setMode(MockPriceOracle.Mode.Revert);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, address(weth)));
        vm.prank(user);
        router.borrowEthWithPrices(_none(), 1 ether, 2);
    }
}

contract MockPriceOracle {
    enum Mode {
        Priced,
        Zero,
        Revert
    }

    error StalePublication();

    Mode public mode;

    function setMode(Mode m) external {
        mode = m;
    }

    function getAssetPrice(address) external view returns (uint256) {
        if (mode == Mode.Revert) revert StalePublication();
        return mode == Mode.Zero ? 0 : 1e8;
    }
}

/// No sentinel getter: a call to it would revert the borrow.
contract MockHemiProvider {
    address internal priceOracle;

    constructor(address p) {
        priceOracle = p;
    }

    function getPriceOracle() external view returns (address) {
        return priceOracle;
    }
}
