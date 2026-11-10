// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KaskadRouter, IPool} from "../src/KaskadRouter.sol";
import {HemiKaskadRouter} from "../src/HemiKaskadRouter.sol";
import {MockOracle, MockPool, MockWETH, MockAToken, RejectingReceiver} from "./KaskadRouterEth.t.sol";

/// Freshness gate plus the supply and repay wrappers of the sentinel-less Hemi router.
contract HemiKaskadRouterTest is Test {
    HemiKaskadRouter internal router;
    MockOracle internal oracle;
    MockHemiPool internal pool;
    MockHemiWETH internal weth;
    MockAToken internal aToken;
    MockPriceOracle internal prices;
    MockAsset internal token;

    bytes32 internal constant FEED = keccak256("ETH/USD");

    address internal user = address(0xA11CE);
    address internal asset = address(0xA55E7);

    function setUp() public {
        oracle = new MockOracle();
        weth = new MockHemiWETH();
        aToken = new MockAToken();
        prices = new MockPriceOracle();
        token = new MockAsset();
        pool = new MockHemiPool(address(weth), address(aToken), address(new MockHemiProvider(address(prices))));
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

    function _fund(uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(router), type(uint256).max);
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
            address(oracle), abi.encodeCall(MockOracle.updatePrice, (FEED, 1, 2, uint8(3), bytes32(0), bytes("")))
        );
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, asset));
        vm.prank(user);
        router.borrowWithPrices(_one(FEED), asset, 1, 2);
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

    function test_supply_pulls_the_asset_and_supplies_for_the_caller() public {
        _fund(100);
        vm.prank(user);
        router.supplyWithPrices(_one(FEED), address(token), 100);

        assertEq(oracle.calls(), 1);
        assertEq(pool.lastSupplyAsset(), address(token));
        assertEq(pool.lastSupplyOnBehalfOf(), user);
        assertEq(aToken.balanceOf(user), 100);
        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.allowance(address(router), address(pool)), 0);
    }

    function test_supply_reverts_on_a_rejected_price() public {
        _fund(100);
        oracle.setMode(MockOracle.Mode.BadSigner);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.PriceUpdateFailed.selector, FEED));
        vm.prank(user);
        router.supplyWithPrices(_one(FEED), address(token), 100);
    }

    function test_supplyEth_wraps_and_supplies_weth_for_the_caller() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        router.supplyEthWithPrices{value: 1 ether}(_none());

        assertEq(pool.lastSupplyAsset(), address(weth));
        assertEq(pool.lastSupplyOnBehalfOf(), user);
        assertEq(aToken.balanceOf(user), 1 ether);
        assertEq(address(router).balance, 0);
        assertEq(weth.balanceOf(address(router)), 0);
    }

    function test_repay_pays_the_requested_part_at_the_variable_rate() public {
        _fund(100);
        pool.debt().mint(user, 100);
        vm.prank(user);
        router.repayWithPrices(_one(FEED), address(token), 40);

        assertEq(oracle.calls(), 1);
        assertEq(pool.lastRepayOnBehalfOf(), user);
        assertEq(pool.lastRepayRateMode(), 2);
        assertEq(pool.debt().balanceOf(user), 60);
        assertEq(token.balanceOf(user), 60);
    }

    function test_repay_max_pulls_exactly_the_debt() public {
        _fund(150);
        pool.debt().mint(user, 100);
        vm.prank(user);
        router.repayWithPrices(_none(), address(token), type(uint256).max);

        assertEq(pool.debt().balanceOf(user), 0);
        assertEq(token.balanceOf(user), 50);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.allowance(address(router), address(pool)), 0);
    }

    function test_repay_caps_an_overpayment_at_the_debt() public {
        _fund(150);
        pool.debt().mint(user, 100);
        vm.prank(user);
        router.repayWithPrices(_none(), address(token), 130);

        assertEq(pool.debt().balanceOf(user), 0);
        assertEq(token.balanceOf(user), 50);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_repay_reverts_on_a_rejected_price() public {
        _fund(100);
        pool.debt().mint(user, 100);
        oracle.setMode(MockOracle.Mode.BadSigner);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.PriceUpdateFailed.selector, FEED));
        vm.prank(user);
        router.repayWithPrices(_one(FEED), address(token), 40);
    }

    function test_repayEth_refunds_what_exceeds_the_debt() public {
        pool.debt().mint(user, 1 ether);
        vm.deal(user, 1.5 ether);
        vm.prank(user);
        router.repayEthWithPrices{value: 1.5 ether}(_none());

        assertEq(pool.lastRepayAsset(), address(weth));
        assertEq(pool.debt().balanceOf(user), 0);
        assertEq(user.balance, 0.5 ether);
        assertEq(address(router).balance, 0);
        assertEq(weth.balanceOf(address(router)), 0);
    }

    function test_repayEth_keeps_everything_when_the_debt_is_larger() public {
        pool.debt().mint(user, 2 ether);
        vm.deal(user, 1 ether);
        vm.prank(user);
        router.repayEthWithPrices{value: 1 ether}(_none());

        assertEq(pool.debt().balanceOf(user), 1 ether);
        assertEq(user.balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_repayEth_reverts_when_the_refund_is_rejected() public {
        RejectingReceiver receiver = new RejectingReceiver();
        pool.debt().mint(address(receiver), 1 ether);
        vm.deal(address(receiver), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.EthTransferFailed.selector, address(receiver), 1 ether));
        vm.prank(address(receiver));
        router.repayEthWithPrices{value: 2 ether}(_none());
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

contract MockHemiWETH is MockWETH {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockAsset is ERC20 {
    constructor() ERC20("Asset", "AST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDebtToken is ERC20 {
    constructor() ERC20("Variable Debt", "vDEBT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// Pulls funds from the caller like the real pool, so leftovers on the router show up.
contract MockHemiPool is MockPool {
    using SafeERC20 for IERC20;

    MockDebtToken public debt;

    address public lastSupplyAsset;
    address public lastSupplyOnBehalfOf;
    address public lastRepayAsset;
    address public lastRepayOnBehalfOf;
    uint256 public lastRepayRateMode;

    constructor(address _weth, address _aToken, address _provider) MockPool(_weth, _aToken, _provider) {
        debt = new MockDebtToken();
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        lastSupplyAsset = asset;
        lastSupplyOnBehalfOf = onBehalfOf;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        aWeth.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256) {
        lastRepayAsset = asset;
        lastRepayRateMode = rateMode;
        lastRepayOnBehalfOf = onBehalfOf;
        uint256 owed = debt.balanceOf(onBehalfOf);
        uint256 paid = amount < owed ? amount : owed;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), paid);
        debt.burn(onBehalfOf, paid);
        return paid;
    }

    function getReserveData(address) external view override returns (IPool.ReserveDataLegacy memory r) {
        r.aTokenAddress = address(aWeth);
        r.variableDebtTokenAddress = address(debt);
    }
}
