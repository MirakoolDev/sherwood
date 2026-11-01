// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SherwoodArena, IArenaRouter, IDiceEntropy} from "src/SherwoodArena.sol";
import {HookrRouterAdapter, IHookrRouter, IHookrRules} from "src/HookrRouterAdapter.sol";
import {ArenaDice} from "./helpers/SherwoodArenaFixture.sol";

/// HookrRouter as the adapter sees it: takes exactly msg.value as the exact input, pays the token at a
/// fixed rate to the recipient, and can send part of the input back unspent. Records the last swap.
contract MockHookrRouter {
    MockERC20 public immutable token;
    uint256 public rate = 20_000_000; // tokens per ETH
    uint256 public refundBps;
    IHookrRouter.Swap public last;
    uint256 public lastValue;

    error InvalidSwap();
    error Slippage();

    constructor(MockERC20 t) {
        token = t;
    }

    function setRefundBps(uint256 bps) external {
        refundBps = bps;
    }

    function swap(IHookrRouter.Swap calldata s, address, uint256[] calldata)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (s.amountBound == 0 || s.recipient == address(0) || block.timestamp > s.deadline) revert InvalidSwap();
        if (msg.value != uint256(uint128(-s.amountSpecified))) revert InvalidSwap();
        last = s;
        lastValue = msg.value;
        uint256 unspent = (msg.value * refundBps) / 10_000;
        amountIn = msg.value - unspent;
        amountOut = amountIn * rate;
        if (amountOut < s.amountBound) revert Slippage();
        token.mint(s.recipient, amountOut);
        if (unspent > 0) {
            (bool ok,) = msg.sender.call{value: unspent}("");
            require(ok, "refund");
        }
    }
}

/// HookrRules' claims: ETH credited to a beneficiary, taken with claimTo.
contract MockHookrRules {
    mapping(address => uint256) public credited;

    error NothingToClaim();

    function credit(address who) external payable {
        credited[who] += msg.value;
    }

    function claimable(Currency, address who) external view returns (uint256) {
        return credited[who];
    }

    function claimTo(Currency, address to) external returns (uint256 amount) {
        amount = credited[msg.sender];
        if (amount == 0) revert NothingToClaim();
        credited[msg.sender] = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "claim send");
    }
}

/// Hookr's buy queue: holds the pot's share and pays it to its fixed recipient on payCreator().
/// Modes: 0 pays (or NothingDue), 1 reverts ClaimOutOfGas, 2 burns all the gas it's given.
contract MockTaxQueue {
    address public immutable recipient;
    uint256 public mode;

    error NothingDue();
    error ClaimOutOfGas(uint256 available, uint256 required);

    constructor(address r) {
        recipient = r;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function payCreator() external returns (uint256 amount) {
        if (mode == 1) revert ClaimOutOfGas(gasleft(), 512_936);
        if (mode == 2) {
            while (true) {}
        }
        amount = address(this).balance;
        if (amount == 0) revert NothingDue();
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "pay");
    }

    receive() external payable {}
}

/// The arena on Hookr: moves through HookrRouterAdapter, the buy tax pulled from the queue, the trader
/// share of arb recapture claimed into the pot. Launch settings: no play fee (the 6.25% tax funds the pot).
contract SherwoodArenaHookrTest is Test {
    event PotFunded(uint256 indexed round, uint256 amount, bool fromSell);

    uint256 internal constant GENESIS = 1_791_835_200;
    uint24 internal constant DYNAMIC_FEE = 8_388_608;
    int24 internal constant TICK_SPACING = 200;
    address internal constant ROOT = 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc;

    MockERC20 internal pfwa;
    MockHookrRouter internal hookr;
    MockHookrRules internal rules;
    HookrRouterAdapter internal adapter;
    SherwoodArena internal game;
    MockTaxQueue internal queue;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(GENESIS + 1);
        pfwa = new MockERC20("PFWA", "PFWA", 18);
        hookr = new MockHookrRouter(pfwa);
        rules = new MockHookrRules();
        adapter = new HookrRouterAdapter(
            IHookrRouter(address(hookr)), IHookrRules(address(rules)), address(pfwa), DYNAMIC_FEE, TICK_SPACING, ROOT
        );
        game = new SherwoodArena(
            address(pfwa),
            IArenaRouter(address(adapter)),
            IDiceEntropy(address(new ArenaDice())),
            makeAddr("provider"),
            owner,
            GENESIS,
            0,
            false, 20 hours
        );
        adapter.bindArena(address(game));
        queue = new MockTaxQueue(address(game));
    }

    function _play(address who, uint256 amount, uint256 minOut) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        game.play{value: amount}(0, minOut, address(0));
    }

    // ── The swap ────────────────────────────────────────────────────────────────

    function test_moveIsOneExactInputBuyOnTheHookrPool() public {
        _play(alice, 0.01 ether, 0);
        (
            ,
            bool zeroForOne,
            int128 amountSpecified,
            uint128 amountBound,
            uint160 sqrtPriceLimitX96,
            address recipient,
            uint256 deadline
        ) = hookr.last();
        assertEq(hookr.lastValue(), 0.01 ether);
        assertTrue(zeroForOne, "ETH in");
        assertEq(amountSpecified, -int128(0.01 ether), "exact input");
        assertEq(amountBound, 1, "Hookr refuses a zero bound");
        assertEq(sqrtPriceLimitX96, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(recipient, alice, "the token goes straight to the player");
        assertEq(deadline, block.timestamp);
        assertEq(pfwa.balanceOf(alice), 0.01 ether * 20_000_000);
        assertEq(game.points(0, alice), 10);
        assertEq(game.bought(0, alice), 0.01 ether * 20_000_000);
    }

    function test_theSwapUsesThePoolKey() public view {
        (Currency c0, Currency c1, uint24 fee, int24 ts, address hooks) = _key();
        assertEq(Currency.unwrap(c0), address(0));
        assertEq(Currency.unwrap(c1), address(pfwa));
        assertEq(fee, DYNAMIC_FEE);
        assertEq(ts, TICK_SPACING);
        assertEq(hooks, ROOT);
    }

    function _key() internal view returns (Currency, Currency, uint24, int24, address) {
        (Currency c0, Currency c1, uint24 fee, int24 ts, address hooks) =
            (adapter.poolKey().currency0, adapter.poolKey().currency1, adapter.poolKey().fee, adapter.poolKey().tickSpacing, address(adapter.poolKey().hooks));
        return (c0, c1, fee, ts, hooks);
    }

    function test_thePlayersMinOutIsTheBound() public {
        _play(alice, 0.01 ether, 150_000 ether);
        (,,, uint128 amountBound,,,) = hookr.last();
        assertEq(amountBound, 150_000 ether);
    }

    function test_tooLittleOutRevertsTheMove() public {
        vm.deal(alice, 0.01 ether);
        vm.prank(alice);
        vm.expectRevert(MockHookrRouter.Slippage.selector);
        game.play{value: 0.01 ether}(0, 300_000 ether, address(0));
    }

    function test_unspentInputRevertsTheMove() public {
        hookr.setRefundBps(1000);
        vm.deal(alice, 0.01 ether);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.PartialFill.selector);
        game.play{value: 0.01 ether}(0, 0, address(0));
    }

    function test_onlyTheArenaBuysThroughTheAdapter() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(HookrRouterAdapter.NotArena.selector);
        adapter.buy{value: 0.01 ether}(1, alice);
    }

    function test_theArenaIsBoundOnceByTheDeployer() public {
        vm.expectRevert(HookrRouterAdapter.AlreadyBound.selector);
        adapter.bindArena(alice);
        HookrRouterAdapter fresh = new HookrRouterAdapter(
            IHookrRouter(address(hookr)), IHookrRules(address(rules)), address(pfwa), DYNAMIC_FEE, TICK_SPACING, ROOT
        );
        vm.prank(alice);
        vm.expectRevert(HookrRouterAdapter.NotDeployer.selector);
        fresh.bindArena(alice);
    }

    function test_strayEthToTheAdapterIsRefused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(adapter).call{value: 0.1 ether}("");
        assertFalse(ok);
    }

    // ── The trader share of arb recapture ───────────────────────────────────────

    function test_tradeShareIsClaimedIntoTheLivePot() public {
        rules.credit{value: 0.001534 ether}(address(adapter));
        assertEq(adapter.tradeShareClaimable(), 0.001534 ether);
        vm.expectEmit(true, false, false, true, address(game));
        emit PotFunded(0, 0.001534 ether, false);
        vm.prank(bob); // anyone
        assertEq(adapter.claimTradeShare(), 0.001534 ether);
        assertEq(game.pot(0), 0.001534 ether);
        assertEq(address(game).balance, 0.001534 ether);
    }

    function test_claimingNothingReverts() public {
        vm.expectRevert(MockHookrRules.NothingToClaim.selector);
        adapter.claimTradeShare();
    }

    // ── The buy tax ─────────────────────────────────────────────────────────────

    function _setQueue() internal {
        vm.prank(owner);
        game.setTaxQueue(address(queue));
    }

    function test_aMovePullsTheWaitingTaxIntoTheLivePot() public {
        _setQueue();
        vm.deal(address(queue), 0.0015 ether);
        vm.expectEmit(true, false, false, true, address(game));
        emit PotFunded(0, 0.0015 ether, false);
        _play(alice, 0.01 ether, 0);
        assertEq(game.pot(0), 0.0015 ether);
        assertEq(address(queue).balance, 0);
        assertEq(address(game).balance, 0.0015 ether, "the move's ETH all went to the swap");
    }

    function test_nothingOwedDoesNotStopAMove() public {
        _setQueue();
        _play(alice, 0.01 ether, 0);
        assertEq(game.points(0, alice), 10);
        assertEq(game.pot(0), 0);
    }

    function test_aFailingQueueDoesNotStopAMove() public {
        _setQueue();
        vm.deal(address(queue), 0.0015 ether);
        queue.setMode(1);
        _play(alice, 0.01 ether, 0);
        assertEq(game.points(0, alice), 10);
        assertEq(address(queue).balance, 0.0015 ether, "left for the next pull");
    }

    function test_aQueueThatBurnsItsGasDoesNotStopAMove() public {
        _setQueue();
        queue.setMode(2);
        vm.deal(alice, 0.01 ether);
        vm.prank(alice);
        game.play{value: 0.01 ether}(0, 0, address(0));
        assertEq(game.points(0, alice), 10);
    }

    function test_anyoneCanPullTax() public {
        _setQueue();
        vm.deal(address(queue), 0.0007 ether);
        vm.prank(bob);
        game.pullTax();
        assertEq(game.pot(0), 0.0007 ether);
    }

    function test_settlingPullsTaxIntoTheLiveRound() public {
        _setQueue();
        _play(alice, 0.01 ether, 0);
        vm.deal(address(queue), 0.002 ether);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        game.settle(0, 100);
        assertEq(game.pot(1), 0.002 ether, "tax that lands after round 0 ended is round 1's");
    }

    function test_taxQueueIsSetOnceByTheOwner() public {
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.setTaxQueue(address(queue));
        _setQueue();
        assertEq(game.taxQueue(), address(queue));
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.TaxQueueAlreadySet.selector);
        game.setTaxQueue(alice);
    }

    function test_noQueueNoPull() public {
        vm.deal(address(queue), 0.001 ether);
        _play(alice, 0.01 ether, 0);
        game.pullTax();
        assertEq(address(queue).balance, 0.001 ether);
        assertEq(game.pot(0), 0);
    }
}
