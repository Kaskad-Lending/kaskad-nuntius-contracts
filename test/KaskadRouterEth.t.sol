// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/KaskadRouter.sol";

/// Covers the router surface added for direct-Pool actions: standalone
/// `pushPrices` plus the native-ETH borrow and withdraw wrappers.
contract KaskadRouterEthTest is Test {
    KaskadRouter internal router;
    MockOracle internal oracle;
    MockPool internal pool;
    MockWETH internal weth;
    MockAToken internal aWeth;
    MockSentinel internal sentinel;

    address internal user = address(0xA11CE);

    function setUp() public {
        oracle = new MockOracle();
        weth = new MockWETH();
        aWeth = new MockAToken();
        sentinel = new MockSentinel();
        pool = new MockPool(address(weth), address(aWeth), address(new MockProvider(address(sentinel))));
        router = new KaskadRouter(address(oracle), address(pool), address(weth));

        vm.deal(address(weth), 100 ether);
        vm.deal(user, 0);
    }

    function _none() internal pure returns (KaskadRouter.PriceUpdate[] memory) {
        return new KaskadRouter.PriceUpdate[](0);
    }

    function _one(bytes32 id) internal pure returns (KaskadRouter.PriceUpdate[] memory p) {
        p = new KaskadRouter.PriceUpdate[](1);
        p[0] = KaskadRouter.PriceUpdate(id, 1, 2, 3, bytes32(0), "");
    }

    /// @dev The mock's own counter rolls back with a revert, so reverting paths
    /// assert the forwarded call instead.
    function _expectPush(bytes32 id) internal {
        vm.expectCall(
            address(oracle), abi.encodeCall(MockOracle.updatePrice, (id, 1, 2, uint8(3), bytes32(0), bytes("")))
        );
    }

    // ── pushPrices ────────────────────────────────────────────────────────

    function test_pushPrices_forwards_every_update() public {
        KaskadRouter.PriceUpdate[] memory p = new KaskadRouter.PriceUpdate[](2);
        p[0] = KaskadRouter.PriceUpdate(bytes32("a"), 1, 2, 3, bytes32(0), "");
        p[1] = KaskadRouter.PriceUpdate(bytes32("b"), 4, 5, 6, bytes32(0), "");
        vm.prank(user);
        router.pushPrices(p);
        assertEq(oracle.calls(), 2);
    }

    function test_pushPrices_skips_already_fresh_prices() public {
        oracle.setMode(MockOracle.Mode.Stale);
        _expectPush(bytes32("a"));
        vm.prank(user);
        router.pushPrices(_one(bytes32("a")));
    }

    function test_pushPrices_reverts_on_any_other_oracle_error() public {
        oracle.setMode(MockOracle.Mode.BadSigner);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.PriceUpdateFailed.selector, bytes32("a")));
        vm.prank(user);
        router.pushPrices(_one(bytes32("a")));
    }

    function test_pushPrices_leaves_no_transient_sender() public {
        vm.prank(user);
        router.pushPrices(_one(bytes32("a")));
        assertEq(router.sender(), address(0), "sentinel must fall back to all-reserves");
    }

    // ── borrowEthWithPrices ───────────────────────────────────────────────

    function test_borrowEth_pays_out_native_and_debits_the_caller() public {
        vm.prank(user);
        router.borrowEthWithPrices(_none(), 3 ether, 2);

        assertEq(user.balance, 3 ether, "caller received ETH");
        assertEq(address(router).balance, 0, "router keeps nothing");
        assertEq(pool.lastBorrowOnBehalfOf(), user, "debt sits with the caller");
        assertEq(pool.lastBorrowAsset(), address(weth));
        assertEq(pool.lastBorrowRateMode(), 2);
    }

    function test_borrowEth_is_gated_on_weth_freshness() public {
        sentinel.setFresh(false);
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, address(weth)));
        vm.prank(user);
        router.borrowEthWithPrices(_none(), 1 ether, 2);
    }

    function test_borrowEth_pushes_prices_before_the_freshness_gate() public {
        sentinel.setFresh(false);
        _expectPush(bytes32("a"));
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.StaleAsset.selector, address(weth)));
        vm.prank(user);
        router.borrowEthWithPrices(_one(bytes32("a")), 1 ether, 2);
    }

    function test_borrowEth_reverts_when_the_caller_rejects_eth() public {
        RejectingReceiver r = new RejectingReceiver();
        vm.expectRevert(abi.encodeWithSelector(KaskadRouter.EthTransferFailed.selector, address(r), 1 ether));
        vm.prank(address(r));
        router.borrowEthWithPrices(_none(), 1 ether, 2);
    }

    // ── withdrawEthWithPrices ─────────────────────────────────────────────

    function test_withdrawEth_pulls_atokens_and_pays_out_native() public {
        aWeth.mint(user, 5 ether);
        vm.startPrank(user);
        aWeth.approve(address(router), 5 ether);
        router.withdrawEthWithPrices(_none(), 2 ether);
        vm.stopPrank();

        assertEq(user.balance, 2 ether);
        assertEq(aWeth.balanceOf(user), 3 ether, "only the requested amount is pulled");
        assertEq(pool.lastWithdrawTo(), address(router), "router unwraps before paying out");
    }

    function test_withdrawEth_max_takes_the_whole_atoken_balance() public {
        aWeth.mint(user, 4 ether);
        vm.startPrank(user);
        aWeth.approve(address(router), type(uint256).max);
        router.withdrawEthWithPrices(_none(), type(uint256).max);
        vm.stopPrank();

        assertEq(user.balance, 4 ether);
        assertEq(aWeth.balanceOf(user), 0);
    }

    function test_withdrawEth_pays_out_what_the_pool_actually_returned() public {
        aWeth.mint(user, 5 ether);
        pool.setWithdrawHaircut(1 ether);
        vm.startPrank(user);
        aWeth.approve(address(router), 5 ether);
        router.withdrawEthWithPrices(_none(), 3 ether);
        vm.stopPrank();

        assertEq(user.balance, 2 ether, "pool return value wins over the request");
        assertEq(address(router).balance, 0);
    }

    function test_withdrawEth_is_not_blocked_by_stale_prices() public {
        sentinel.setFresh(false);
        aWeth.mint(user, 1 ether);
        vm.startPrank(user);
        aWeth.approve(address(router), 1 ether);
        router.withdrawEthWithPrices(_none(), 1 ether);
        vm.stopPrank();
        assertEq(user.balance, 1 ether, "exit stays open");
    }

    // ── receive ───────────────────────────────────────────────────────────

    function test_receive_rejects_eth_from_anyone_but_weth() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "stray ETH is rejected");
        assertEq(address(router).balance, 0);
    }
}

// ── mocks ─────────────────────────────────────────────────────────────────

contract MockOracle {
    enum Mode {
        Ok,
        Stale,
        BadSigner
    }

    error StalePrice(uint256 provided, uint256 current);
    error SignerNotRegistered(address signer);

    Mode public mode;
    uint256 public calls;

    function setMode(Mode m) external {
        mode = m;
    }

    function updatePrice(bytes32, uint256, uint256, uint8, bytes32, bytes calldata) external {
        calls++;
        if (mode == Mode.Stale) revert StalePrice(1, 2);
        if (mode == Mode.BadSigner) revert SignerNotRegistered(address(0));
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth payout failed");
    }
}

contract MockAToken is ERC20 {
    constructor() ERC20("Aave WETH", "aWETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockSentinel {
    bool internal fresh = true;

    function setFresh(bool f) external {
        fresh = f;
    }

    function isAssetFresh(address) external view returns (bool) {
        return fresh;
    }
}

contract MockProvider {
    address internal sentinel;

    constructor(address s) {
        sentinel = s;
    }

    function getPriceOracleSentinel() external view returns (address) {
        return sentinel;
    }
}

contract MockPool is IPool {
    MockWETH internal weth;
    MockAToken internal aWeth;
    address internal provider;
    uint256 internal withdrawHaircut;

    address public lastBorrowAsset;
    address public lastBorrowOnBehalfOf;
    uint256 public lastBorrowRateMode;
    address public lastWithdrawTo;

    constructor(address _weth, address _aWeth, address _provider) {
        weth = MockWETH(_weth);
        aWeth = MockAToken(_aWeth);
        provider = _provider;
    }

    function setWithdrawHaircut(uint256 h) external {
        withdrawHaircut = h;
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return provider;
    }

    function borrow(address asset, uint256 amount, uint256 rateMode, uint16, address onBehalfOf) external {
        lastBorrowAsset = asset;
        lastBorrowRateMode = rateMode;
        lastBorrowOnBehalfOf = onBehalfOf;
        weth.mint(msg.sender, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        lastWithdrawTo = to;
        uint256 paid = amount - withdrawHaircut;
        aWeth.burn(msg.sender, amount);
        weth.mint(to, paid);
        return paid;
    }

    function liquidationCall(address, address, address, uint256, bool) external {}

    function getReserveData(address) external view returns (ReserveDataLegacy memory r) {
        r.aTokenAddress = address(aWeth);
    }
}

contract RejectingReceiver {
    receive() external payable {
        revert("no eth");
    }
}
