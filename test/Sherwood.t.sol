// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Sherwood, IDiceEntropy} from "../src/Sherwood.sol";

/// Stand-in for Dice Protocol: records requests and lets the test reveal them.
contract MockDice {
    uint128 public fee = 25_000_000_000_000; // 0.000025 ETH, as on Robinhood Chain

    function setFee(uint128 next) external {
        fee = next;
    }
    uint64 public nextSequence = 1;
    mapping(uint64 => address) public requester;

    function getFeeV2(address, uint32) external view returns (uint128) {
        return fee;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64 sequence) {
        require(msg.value >= fee, "fee");
        sequence = nextSequence++;
        requester[sequence] = msg.sender;
    }

    function reveal(uint64 sequence, bytes32 random) external {
        Sherwood(payable(requester[sequence]))._entropyCallback(sequence, address(0), random);
    }

    function refundRequest(address, uint64 sequence) external {
        (bool ok,) = requester[sequence].call{value: fee}("");
        require(ok);
    }

    receive() external payable {}
}

/// A Dice that refuses every request, as if paused or out of randomness.
contract BrokenDice {
    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 25_000_000_000_000;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64) {
        revert("paused");
    }
}

contract SherwoodTest is Test, Deployers {
    Sherwood hook;
    MockERC20 pfwaToken;
    MockDice dice;
    PoolKey gameKey;
    PoolKey buybackKey;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        vm.warp(1_760_000_000); // a fixed mid-day timestamp
        deployFreshManagerAndRouters();
        pfwaToken = new MockERC20("PFWA", "PFWA", 18);
        pfwaToken.mint(address(this), 1e30);
        pfwaToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        dice = new MockDice();

        address hookAddr = address(FLAGS | (uint160(0x4444) << 144));
        deployCodeTo(
            "Sherwood.sol:Sherwood",
            abi.encode(manager, Currency.wrap(address(pfwaToken)), IDiceEntropy(address(dice)), address(1), owner),
            hookAddr
        );
        hook = Sherwood(payable(hookAddr));

        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        Currency pfwa = Currency.wrap(address(pfwaToken));
        vm.prank(owner);
        (gameKey,) = initPool(eth, pfwa, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        _addLiquidity(gameKey);
        (buybackKey,) = initPool(eth, pfwa, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        _addLiquidity(buybackKey);
    }

    function _addLiquidity(PoolKey memory key) internal {
        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 500 ether}(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 100e18, salt: 0}), ""
        );
    }

    function _buy(address who, uint256 amount, Sherwood.Move move) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        swapRouter.swap{value: amount}(
            gameKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(move))
        );
    }

    function _buyRef(address who, uint256 amount, Sherwood.Move move, address ref) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        swapRouter.swap{value: amount}(
            gameKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(move), ref)
        );
    }

    function _sell(address who, uint256 pfwaIn) internal {
        pfwaToken.mint(who, pfwaIn);
        vm.startPrank(who, who);
        pfwaToken.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            gameKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(pfwaIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _day() internal view returns (uint256) {
        return hook.currentDay();
    }

    // ── Buying and points ───────────────────────────────────────────────────────

    function test_buyScoresByBuySizeAndFundsPot() public {
        _buy(alice, 0.025 ether, Sherwood.Move.BUY);
        assertEq(hook.points(_day(), alice), 25);
        assertEq(hook.pot(_day()), 0.00125 ether); // 5% of 0.025
        assertEq(address(hook).balance, 0.00125 ether);
    }

    function test_pointsCapAt100PerBuy() public {
        _buy(alice, 0.5 ether, Sherwood.Move.BUY);
        assertEq(hook.points(_day(), alice), 100);
    }

    function test_belowMinimumScoresNothingButPaysFee() public {
        _buy(alice, 0.0009 ether, Sherwood.Move.BUY);
        assertEq(hook.points(_day(), alice), 0);
        assertEq(hook.pot(_day()), 0.000045 ether);
    }

    function test_noHookDataIsPlainBuy() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        swapRouter.swap{value: 0.01 ether}(
            gameKey,
            SwapParams({zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.points(_day(), alice), 10);
    }

    function test_buyerReceivesPfwaForEthAfterFee() public {
        uint256 before = pfwaToken.balanceOf(alice);
        _buy(alice, 0.1 ether, Sherwood.Move.BUY);
        uint256 got = pfwaToken.balanceOf(alice) - before;
        // At ~1:1 the buyer gets a little under 0.095 PFWA (5% pot fee, 0.3% LP fee, price impact).
        assertGt(got, 0.0945 ether);
        assertLt(got, 0.095 ether);
    }

    function test_exactOutputReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            gameKey,
            SwapParams({zeroForOne: true, amountSpecified: 0.01 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ── Moves ───────────────────────────────────────────────────────────────────

    function test_stealTakes20PercentOfPreviousPlayer() public {
        _buy(alice, 0.05 ether, Sherwood.Move.BUY); // alice 50
        _buy(bob, 0.01 ether, Sherwood.Move.STEAL); // bob 10 + 22% of 50 = 11 stolen
        assertEq(hook.points(_day(), alice), 39);
        assertEq(hook.points(_day(), bob), 21);
    }

    function test_fullSizeStealTakes40Percent() public {
        _buy(alice, 0.1 ether, Sherwood.Move.BUY); // alice 100
        _buy(bob, 0.1 ether, Sherwood.Move.STEAL); // bob 100 + 40
        assertEq(hook.points(_day(), alice), 60);
        assertEq(hook.points(_day(), bob), 140);
    }

    function test_fullSizeRobinHoodMoves33Percent() public {
        _buy(alice, 0.1 ether, Sherwood.Move.BUY); // alice 100, leader
        _buy(bob, 0.002 ether, Sherwood.Move.BUY); // bob 2
        _buy(carol, 0.1 ether, Sherwood.Move.ROBIN_HOOD); // carol ties alice at 100; alice stays #1 and loses 33 to bob
        assertEq(hook.points(_day(), alice), 67);
        assertEq(hook.points(_day(), bob), 35);
        assertEq(hook.points(_day(), carol), 100);
    }

    function test_scaledBpsRange() public view {
        assertEq(hook.scaledBps(hook.ROBIN_BPS_MIN(), hook.ROBIN_BPS_MAX(), 100), 3300);
        assertEq(hook.scaledBps(hook.STEAL_BPS_MIN(), hook.STEAL_BPS_MAX(), 1), 2020);
        assertEq(hook.scaledBps(hook.FLIP_WIN_BPS_MIN(), hook.FLIP_WIN_BPS_MAX(), 500), 30_000);
    }

    function test_stealOnYourselfDoesNothingExtra() public {
        _buy(alice, 0.05 ether, Sherwood.Move.BUY);
        _buy(alice, 0.01 ether, Sherwood.Move.STEAL);
        assertEq(hook.points(_day(), alice), 60);
    }

    function test_robinHoodMovesLeaderPointsToLowestRecent() public {
        _buy(alice, 0.1 ether, Sherwood.Move.BUY); // alice 100, leader
        _buy(bob, 0.002 ether, Sherwood.Move.BUY); // bob 2
        _buy(carol, 0.01 ether, Sherwood.Move.ROBIN_HOOD); // carol 10 → 12.3%: 12 of alice's go to lowest recent (bob)
        assertEq(hook.points(_day(), alice), 88);
        assertEq(hook.points(_day(), bob), 14);
        assertEq(hook.points(_day(), carol), 10);
    }

    function test_robinHoodFindsNewLeaderAfterLeaderLosesPoints() public {
        _buy(alice, 0.1 ether, Sherwood.Move.BUY); // alice 100
        _buy(bob, 0.09 ether, Sherwood.Move.BUY); // bob 90
        _buy(carol, 0.01 ether, Sherwood.Move.BUY); // carol 10
        _buy(dave, 0.005 ether, Sherwood.Move.BUY); // dave 5
        _sell(alice, 0.001 ether); // alice wiped → bob is the real leader
        _buy(carol, 0.001 ether, Sherwood.Move.ROBIN_HOOD); // 9 of bob's 90 → lowest recent (alice at 0)
        assertEq(hook.points(_day(), bob), 81);
        assertEq(hook.points(_day(), alice), 9);
    }

    function test_flipWinDoublesPoints() public {
        _buy(alice, 0.03 ether, Sherwood.Move.BUY);
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP); // bob stakes 20 → wins 2.2x
        assertEq(hook.points(_day(), bob), 0);
        dice.reveal(1, bytes32(uint256(2))); // even → win
        assertEq(hook.points(_day(), bob), 44);
    }

    function test_fullSizeFlipWinPaysTriple() public {
        _buy(alice, 0.03 ether, Sherwood.Move.BUY);
        _buy(bob, 0.1 ether, Sherwood.Move.FLIP); // 100-point stake → 3x
        dice.reveal(1, bytes32(uint256(2)));
        assertEq(hook.points(_day(), bob), 300);
    }

    function test_flipLossGoesNegativeAndPaysPreviousPlayer() public {
        _buy(alice, 0.03 ether, Sherwood.Move.BUY);
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // odd → lose
        assertEq(hook.points(_day(), bob), -20);
        assertEq(hook.points(_day(), alice), 50);
    }

    function test_flipLossComesOffExistingPoints() public {
        _buy(alice, 0.01 ether, Sherwood.Move.BUY); // alice 10
        _buy(bob, 0.03 ether, Sherwood.Move.BUY); // bob 30
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP); // previous is bob himself → loss goes nowhere
        dice.reveal(1, bytes32(uint256(5)));
        assertEq(hook.points(_day(), bob), 10);
    }

    function test_sellLeavesNegativeScore() public {
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // bob -20
        _sell(bob, 0.001 ether);
        assertEq(hook.points(_day(), bob), -20);
    }

    function test_stealFromNegativePlayerTakesNothing() public {
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // bob -20, alice 30
        _buy(carol, 0.005 ether, Sherwood.Move.BUY);
        _buy(dave, 0.01 ether, Sherwood.Move.BUY); // previous for the next steal is dave
        _buy(bob, 0.001 ether, Sherwood.Move.BUY); // bob -19, now the previous player
        _buy(carol, 0.001 ether, Sherwood.Move.STEAL); // 20% of a negative score → nothing
        assertEq(hook.points(_day(), carol), 6);
        assertEq(hook.points(_day(), bob), -19);
    }

    function test_negativePlayersNeverPlace() public {
        uint256 day = _day();
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // bob -20
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);
        (, address[3] memory top,,,) = hook.result(day);
        assertEq(top[0], alice);
        assertEq(top[1], address(0));
    }

    function test_flipPaysDiceFeeFromPot() public {
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        assertEq(hook.pot(_day()), 0.001 ether - 0.000025 ether);
        assertEq(address(dice).balance, 0.000025 ether);
    }

    function test_unrevealedFlipExpiresAsPlainBuy() public {
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        vm.expectRevert(Sherwood.FlipNotExpired.selector);
        hook.expireFlip(1);
        vm.warp(block.timestamp + 10 minutes);
        hook.expireFlip(1);
        assertEq(hook.points(_day(), bob), 20);
        dice.reveal(1, bytes32(uint256(2))); // a late reveal does nothing
        assertEq(hook.points(_day(), bob), 20);
    }

    function test_flipScoresAsBuyWhenDiceRefuses() public {
        BrokenDice broken = new BrokenDice();
        vm.etch(address(dice), address(broken).code); // swap in a Dice that reverts
        uint256 potBefore = hook.pot(_day());
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP); // must not revert
        assertEq(hook.points(_day(), bob), 20); // scored as a plain buy
        assertEq(hook.pot(_day()) - potBefore, 0.001 ether); // no Dice fee taken
    }

    function test_onlyDiceCanDeliverRandomness() public {
        vm.expectRevert(Sherwood.NotDice.selector);
        hook._entropyCallback(1, address(0), bytes32(0));
    }

    // ── Selling ─────────────────────────────────────────────────────────────────

    function test_sellWipesPointsAndFundsPot() public {
        _buy(alice, 0.05 ether, Sherwood.Move.BUY);
        uint256 potBefore = hook.pot(_day());
        _sell(alice, 0.01 ether);
        assertEq(hook.points(_day(), alice), 0);
        assertGt(hook.pot(_day()), potBefore); // 5% of the ETH paid out
    }

    // ── Settlement ──────────────────────────────────────────────────────────────

    function test_settleSplitsPotAndWinnersClaim() public {
        uint256 day = _day();
        _buy(alice, 0.1 ether, Sherwood.Move.BUY); // 100
        _buy(bob, 0.05 ether, Sherwood.Move.BUY); // 50
        _buy(carol, 0.02 ether, Sherwood.Move.BUY); // 20
        _buy(dave, 0.01 ether, Sherwood.Move.BUY); // 10
        uint256 total = hook.pot(day);

        vm.expectRevert(Sherwood.DayNotOver.selector);
        hook.settle(day, 100);

        vm.warp((day + 1) * 1 days + 15 minutes);
        assertTrue(hook.settle(day, 100));
        (bool settled, address[3] memory top,, uint256[3] memory prize,) = hook.result(day);
        assertTrue(settled);
        assertEq(top[0], alice);
        assertEq(top[1], bob);
        assertEq(top[2], carol);
        assertEq(prize[0], total * 50 / 100);
        assertEq(prize[1], total * 20 / 100);
        assertEq(prize[2], total * 10 / 100);
        assertEq(hook.buybackReserve(), total * 10 / 100);
        assertEq(hook.pot(day + 1), total - prize[0] - prize[1] - prize[2] - total * 10 / 100);

        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(day);
        assertEq(alice.balance - before, prize[0]);
        vm.prank(alice);
        vm.expectRevert(Sherwood.NothingToClaim.selector);
        hook.claim(day);
        vm.prank(dave);
        vm.expectRevert(Sherwood.NothingToClaim.selector);
        hook.claim(day);
    }

    function test_settleInBatches() public {
        uint256 day = _day();
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        _buy(bob, 0.03 ether, Sherwood.Move.BUY);
        _buy(carol, 0.02 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 15 minutes);
        assertFalse(hook.settle(day, 2));
        assertTrue(hook.settle(day, 2));
        (, address[3] memory top,,,) = hook.result(day);
        assertEq(top[0], bob);
        assertEq(top[1], carol);
        assertEq(top[2], alice);
    }

    function test_unawardedSharesRollOverWhenFewerThanThreePlayers() public {
        uint256 day = _day();
        _buy(alice, 0.02 ether, Sherwood.Move.BUY);
        uint256 total = hook.pot(day);
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);
        // alice 50%, buyback 10%, the rest (40%) rolls into the next day
        assertEq(hook.pot(day + 1), total - total * 50 / 100 - total * 10 / 100);
    }

    function test_unclaimedPrizesSweepAfterSevenDays() public {
        uint256 day = _day();
        _buy(alice, 0.02 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);
        (,,, uint256[3] memory prize,) = hook.result(day);
        vm.expectRevert(Sherwood.ClaimWindowOpen.selector);
        hook.sweepUnclaimed(day);
        vm.warp(hook.claimDeadline(day) + 1); // 7 days after settlement
        uint256 today = hook.currentDay();
        uint256 potBefore = hook.pot(today);
        hook.sweepUnclaimed(day);
        assertEq(hook.pot(today) - potBefore, prize[0]);
        vm.prank(alice);
        vm.expectRevert(Sherwood.ClaimWindowClosed.selector);
        hook.claim(day);
    }

    function test_flipRevealedAfterSettlementIsIgnored() public {
        uint256 day = _day();
        _buy(alice, 0.02 ether, Sherwood.Move.BUY);
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.expireFlip(1); // settlement waits for this; the flip scores as a plain buy
        hook.settle(day, 100);
        dice.reveal(1, bytes32(uint256(2))); // Dice reveals late: nothing changes
        assertEq(hook.points(day, bob), 20);
    }

    // ── Buyback ─────────────────────────────────────────────────────────────────

    function test_buybackSwapsInOtherPoolAndBurns() public {
        uint256 day = _day();
        _buy(alice, 0.1 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);
        uint256 reserve = hook.buybackReserve();
        assertGt(reserve, 0);

        vm.expectRevert(Sherwood.NotOperator.selector);
        hook.buybackAndBurn(reserve, 0);

        vm.prank(owner);
        hook.setBuybackPool(buybackKey);
        uint256 deadBefore = pfwaToken.balanceOf(DEAD);
        vm.prank(owner);
        hook.buybackAndBurn(reserve, 1);
        assertGt(pfwaToken.balanceOf(DEAD), deadBefore);
        assertEq(hook.buybackReserve(), 0);
    }

    function test_buybackPoolCannotBeTheGamePool() public {
        vm.prank(owner);
        vm.expectRevert(Sherwood.BadBuybackPool.selector);
        hook.setBuybackPool(gameKey);
    }

    function test_buybackPoolIsSetOnce() public {
        vm.prank(owner);
        hook.setBuybackPool(buybackKey);
        vm.prank(owner);
        vm.expectRevert(Sherwood.PoolAlreadySet.selector);
        hook.setBuybackPool(buybackKey);
    }

    function test_recentPlayersMostRecentFirst() public {
        _buy(alice, 0.001 ether, Sherwood.Move.BUY);
        _buy(bob, 0.001 ether, Sherwood.Move.BUY);
        _buy(carol, 0.001 ether, Sherwood.Move.BUY);
        address[] memory r = hook.recentPlayers(_day());
        assertEq(r.length, 3);
        assertEq(r[0], carol);
        assertEq(r[2], alice);
        for (uint256 i; i < 12; ++i) _buy(dave, 0.001 ether, Sherwood.Move.BUY);
        assertEq(hook.recentPlayers(_day()).length, 10);
    }

    function test_onlyOneGamePool() public {
        vm.expectRevert();
        initPool(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(pfwaToken)), IHooks(address(hook)), 500, SQRT_PRICE_1_1);
    }

    function test_fundPotSeedsTodayAndFutureDays() public {
        uint256 day = _day();
        hook.fundPot{value: 0.1 ether}(day);
        hook.fundPot{value: 0.2 ether}(day + 3);
        assertEq(hook.pot(day), 0.1 ether);
        assertEq(hook.pot(day + 3), 0.2 ether);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(Sherwood.DayPassed.selector);
        hook.fundPot{value: 1}(day);
    }

    function test_plainEthTransferLandsInTodaysPot() public {
        (bool ok,) = address(hook).call{value: 0.05 ether}("");
        assertTrue(ok);
        assertEq(hook.pot(_day()), 0.05 ether);
    }

    function test_seededPotPaysTheWinner() public {
        hook.fundPot{value: 1 ether}(_day());
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        uint256 total = hook.pot(_day());
        vm.warp((_day() + 1) * 1 days + 16 minutes);
        hook.settle(_day() - 1, 100);
        (, , , uint256[3] memory prize, ) = hook.result(_day() - 1);
        assertEq(prize[0], total * 50 / 100);
    }

    // ── Holding rules ───────────────────────────────────────────────────────

    function test_buysAreRecordedPerDay() public {
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        assertGt(hook.bought(_day(), alice), 0);
        assertEq(hook.bought(_day(), alice), pfwaToken.balanceOf(alice));
    }

    function test_winnerMustHoldThatDaysBuysToClaim() public {
        uint256 day = _day();
        _buy(alice, 0.05 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);
        uint256 held = pfwaToken.balanceOf(alice);

        vm.prank(alice);
        pfwaToken.transfer(bob, held); // "sold" somewhere else
        vm.prank(alice);
        vm.expectRevert(Sherwood.MustHoldToClaim.selector);
        hook.claim(day);

        vm.prank(bob);
        pfwaToken.transfer(alice, held); // bought back
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(day);
        assertGt(alice.balance, before);
    }

    function test_holderBonusForKeepingYesterdaysBuys() public {
        uint256 day = _day();
        _buy(alice, 0.01 ether, Sherwood.Move.BUY); // 10
        assertFalse(hook.holderBonusActive(day, alice));
        vm.warp((day + 1) * 1 days + 1);
        assertTrue(hook.holderBonusActive(day + 1, alice));
        _buy(alice, 0.01 ether, Sherwood.Move.BUY); // 10 x 1.25
        assertEq(hook.points(day + 1, alice), 12);
        _buy(bob, 0.1 ether, Sherwood.Move.BUY); // no history: plain 100
        assertEq(hook.points(day + 1, bob), 100);
    }

    function test_holderBonusMaxesAt125Points() public {
        uint256 day = _day();
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 1);
        _buy(alice, 0.1 ether, Sherwood.Move.BUY);
        assertEq(hook.points(day + 1, alice), 125);
    }

    function test_noHolderBonusAfterSellingYesterdaysBuys() public {
        uint256 day = _day();
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        uint256 held = pfwaToken.balanceOf(alice);
        vm.prank(alice);
        pfwaToken.transfer(bob, held / 2);
        vm.warp((day + 1) * 1 days + 1);
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        assertEq(hook.points(day + 1, alice), 10);
    }

    function test_holderBonusNeedsYesterdaysPlay() public {
        uint256 day = _day();
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        vm.warp((day + 2) * 1 days + 1); // skipped a day
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        assertEq(hook.points(day + 2, alice), 10);
    }

    function test_holderBonusDoesNotRaiseStealShare() public {
        uint256 day = _day();
        _buy(bob, 0.01 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 1);
        _buy(alice, 0.05 ether, Sherwood.Move.BUY); // alice 50
        _buy(bob, 0.01 ether, Sherwood.Move.STEAL); // bob 12 with bonus; steal share from his 10-point size: 22% of 50 = 11
        assertEq(hook.points(day + 1, alice), 39);
        assertEq(hook.points(day + 1, bob), 23);
    }

    // ── Audit fixes ─────────────────────────────────────────────────────────

    function test_buyStoppedByPriceLimitReverts() public {
        // Scored on the declared ETH, so a buy must spend all of it (audit H-1).
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert();
        swapRouter.swap{value: 0.1 ether}(
            gameKey,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(Sherwood.Move.BUY))
        );
        assertEq(hook.points(_day(), alice), 0);
    }

    function test_settleWaitsForPendingFlips() public {
        // A reveal between settlement batches would change scores already ranked (audit M-1).
        uint256 day = _day();
        _buy(alice, 0.1 ether, Sherwood.Move.BUY);
        _buy(bob, 0.06 ether, Sherwood.Move.BUY);
        _buy(alice, 0.1 ether, Sherwood.Move.FLIP);
        assertEq(hook.pendingFlips(day), 1);
        vm.warp((day + 1) * 1 days + 15 minutes);
        vm.expectRevert(Sherwood.FlipsPending.selector);
        hook.settle(day, 1);
        dice.reveal(1, bytes32(uint256(3))); // alice loses: 0, bob 160
        assertEq(hook.pendingFlips(day), 0);
        hook.settle(day, 1);
        assertTrue(hook.settle(day, 1));
        (, address[3] memory top, int256[3] memory topPoints,,) = hook.result(day);
        assertEq(top[0], bob);
        assertEq(topPoints[0], 160);
        assertEq(top[1], address(0)); // alice at 0 doesn't place
    }

    function test_expiredFlipsUnblockSettlement() public {
        uint256 day = _day();
        _buy(alice, 0.05 ether, Sherwood.Move.FLIP);
        vm.warp((day + 1) * 1 days + 15 minutes);
        vm.expectRevert(Sherwood.FlipsPending.selector);
        hook.settle(day, 10);
        hook.expireFlip(1);
        assertTrue(hook.settle(day, 10));
        (, address[3] memory top,,,) = hook.result(day);
        assertEq(top[0], alice);
    }

    function test_flipWinScalesWithBuySizeNotBonus() public {
        // 0.08 ETH with the holder bonus: stake 100, multiplier from 80 base points = 2.8x (audit L-1).
        uint256 day = _day();
        _buy(alice, 0.01 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 1);
        _buy(alice, 0.08 ether, Sherwood.Move.FLIP);
        dice.reveal(1, bytes32(uint256(2)));
        assertEq(hook.points(day + 1, alice), 280);
    }

    function test_robinHoodCanPayTheMover() public {
        // Accepted design: if you're the lowest of the last 10, Robin Hood pays you (chained moves).
        _buy(alice, 0.1 ether, Sherwood.Move.BUY); // leader, 100
        _buy(bob, 0.001 ether, Sherwood.Move.BUY); // bob 1
        _buy(bob, 0.01 ether, Sherwood.Move.ROBIN_HOOD); // bob 11, the lowest recent: 12.3% of 100 → bob
        assertEq(hook.points(_day(), alice), 88);
        assertEq(hook.points(_day(), bob), 23);
    }

    function test_diceFeeAboveCapScoresAsBuy() public {
        dice.setFee(0.001 ether);
        hook.fundPot{value: 1 ether}(_day());
        _buy(bob, 0.02 ether, Sherwood.Move.FLIP);
        assertEq(hook.points(_day(), bob), 20); // plain buy, nothing sent to Dice
        assertEq(hook.pendingFlips(_day()), 0);
        assertEq(address(dice).balance, 0);
    }

    function test_diceRefundFromAnywhereGoesToBuybackReserve() public {
        _buy(alice, 0.02 ether, Sherwood.Move.FLIP);
        uint256 before = hook.buybackReserve();
        dice.refundRequest(address(0), 1); // someone else triggers the refund on Dice
        assertEq(hook.buybackReserve() - before, dice.fee());
    }

    function test_lateSettlementStillGivesSevenDaysToClaim() public {
        uint256 day = _day();
        _buy(alice, 0.05 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 8 days); // nobody settled for 8 days
        hook.settle(day, 100);
        assertEq(hook.claimDeadline(day), block.timestamp + 7 days);
        vm.expectRevert(Sherwood.ClaimWindowOpen.selector);
        hook.sweepUnclaimed(day);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(day);
        assertGt(alice.balance, before);
    }

    // ── Forfeits and referrals ──────────────────────────────────────────────

    function test_winnerWhoSoldEverythingForfeitsAtSettlement() public {
        uint256 day = _day();
        _buy(alice, 0.05 ether, Sherwood.Move.BUY); // #1
        _buy(bob, 0.02 ether, Sherwood.Move.BUY); // #2
        uint256 total = hook.pot(day);
        vm.startPrank(alice);
        pfwaToken.transfer(carol, pfwaToken.balanceOf(alice)); // alice sold all of today's buys
        vm.stopPrank();
        vm.warp((day + 1) * 1 days + 15 minutes);
        uint256 todayBefore = hook.pot(day + 1);
        hook.settle(day, 100);
        (, address[3] memory top,, uint256[3] memory prize,) = hook.result(day);
        assertEq(top[0], alice);
        assertEq(prize[0], 0);
        assertEq(prize[1], total * 20 / 100);
        // #1's 50%, the empty #3 slot's 10% and the 10% rollover all land in today's pot
        assertEq(hook.pot(day + 1) - todayBefore, total - total * 20 / 100 - total * 10 / 100);
        vm.prank(alice);
        vm.expectRevert(Sherwood.NothingToClaim.selector);
        hook.claim(day);
    }

    function test_winnerWhoSoldPartForfeitsThatShare() public {
        uint256 day = _day();
        _buy(alice, 0.05 ether, Sherwood.Move.BUY); // #1
        _buy(bob, 0.02 ether, Sherwood.Move.BUY); // #2
        uint256 total = hook.pot(day);
        uint256 owed = hook.bought(day, alice);
        uint256 sold = owed / 5;
        vm.prank(alice);
        pfwaToken.transfer(carol, sold); // sold 20% of today's buys
        vm.warp((day + 1) * 1 days + 15 minutes);
        uint256 todayBefore = hook.pot(day + 1);
        hook.settle(day, 100);
        (,,, uint256[3] memory prize,) = hook.result(day);
        uint256 share = total * 50 / 100;
        uint256 kept = share * (owed - sold) / owed;
        assertEq(prize[0], kept);
        assertApproxEqAbs(prize[0], share * 80 / 100, 1);
        assertEq(prize[1], total * 20 / 100);
        // the forfeited 20% of #1's prize rolls over with the rest
        assertEq(hook.pot(day + 1) - todayBefore, total - kept - total * 20 / 100 - total * 10 / 100);

        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(day);
        assertEq(alice.balance - before, kept);
    }

    function test_partialWinnerMustKeepWhatTheyHeldToClaim() public {
        uint256 day = _day();
        _buy(alice, 0.05 ether, Sherwood.Move.BUY);
        uint256 owed = hook.bought(day, alice);
        vm.prank(alice);
        pfwaToken.transfer(carol, owed / 2); // sold half before settlement
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);

        assertEq(hook.heldToClaim(day, alice), owed - owed / 2);
        assertEq(hook.heldToClaim(day, bob), 0);
        vm.prank(alice);
        pfwaToken.transfer(carol, 1); // sold a little more after settlement
        vm.prank(alice);
        vm.expectRevert(Sherwood.MustHoldToClaim.selector);
        hook.claim(day);

        vm.prank(carol);
        pfwaToken.transfer(alice, 1); // back to what she held at settlement
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(day);
        assertGt(alice.balance, before);
    }

    function test_referrerIsSetOnceAndNeverChanges() public {
        _buy(carol, 0.001 ether, Sherwood.Move.BUY);
        _buyRef(alice, 0.01 ether, Sherwood.Move.BUY, carol);
        assertEq(hook.referrerOf(alice), carol);
        _buyRef(alice, 0.01 ether, Sherwood.Move.BUY, dave);
        assertEq(hook.referrerOf(alice), carol);
    }

    function test_cannotReferYourselfOrTheOneWhoReferredYou() public {
        _buyRef(alice, 0.01 ether, Sherwood.Move.BUY, alice);
        assertEq(hook.referrerOf(alice), address(0));
        _buyRef(bob, 0.01 ether, Sherwood.Move.BUY, alice);
        _buyRef(alice, 0.01 ether, Sherwood.Move.BUY, bob);
        assertEq(hook.referrerOf(alice), address(0));
    }

    function test_referrerEarnsTenPercentPointsOnlyOnDaysTheyPlayed() public {
        _buyRef(alice, 0.05 ether, Sherwood.Move.BUY, carol); // alice 55 (welcome +10%); carol hasn't played: nothing
        assertEq(hook.points(_day(), carol), 0);
        _buy(carol, 0.001 ether, Sherwood.Move.BUY); // carol 1
        _buy(alice, 0.05 ether, Sherwood.Move.BUY); // alice 55 more, carol +5
        assertEq(hook.points(_day(), carol), 6);
        assertEq(hook.points(_day(), alice), 110); // nothing taken from alice
    }

    function test_referrerTakesFivePercentOfPrize() public {
        uint256 day = _day();
        _buy(carol, 0.001 ether, Sherwood.Move.BUY);
        _buyRef(alice, 0.05 ether, Sherwood.Move.BUY, carol);
        uint256 total = hook.pot(day);
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);
        (,,, uint256[3] memory prize,) = hook.result(day);
        uint256 share = total * 50 / 100;
        assertEq(hook.referralEarnings(carol), share * 5 / 100);
        assertEq(prize[0], share); // the winner keeps it all; the 5% comes from the rollover

        uint256 before = carol.balance;
        vm.prank(carol);
        hook.claimReferral();
        assertEq(carol.balance - before, share * 5 / 100);
        vm.prank(carol);
        vm.expectRevert(Sherwood.NothingToClaim.selector);
        hook.claimReferral();
    }

    function test_noPrizeShareIfReferrerSkippedTheDay() public {
        uint256 day = _day();
        _buy(carol, 0.001 ether, Sherwood.Move.BUY);
        _buyRef(alice, 0.05 ether, Sherwood.Move.BUY, carol);
        vm.warp((day + 1) * 1 days + 1);
        _buy(alice, 0.05 ether, Sherwood.Move.BUY); // carol didn't play today
        vm.warp((day + 2) * 1 days + 15 minutes);
        hook.settle(day + 1, 100);
        (,,, uint256[3] memory prize,) = hook.result(day + 1);
        assertEq(prize[0], hook.pot(day + 1) * 50 / 100);
        assertEq(hook.referralEarnings(carol), 0);
    }

    function test_referralShareComesOutOfTheRollover() public {
        uint256 day = _day();
        _buy(carol, 0.001 ether, Sherwood.Move.BUY); // carol #2
        _buyRef(alice, 0.05 ether, Sherwood.Move.BUY, carol); // alice #1
        _buy(bob, 0.0005 ether, Sherwood.Move.BUY); // too small to score
        uint256 total = hook.pot(day);
        vm.warp((day + 1) * 1 days + 15 minutes);
        uint256 before = hook.pot(day + 1);
        hook.settle(day, 100);
        uint256 cut = (total * 50 / 100) * 5 / 100;
        // #1 50% + #2 20% paid in full; 10% buyback; empty #3 + rollover, minus carol's cut, roll on
        assertEq(hook.pot(day + 1) - before, total - total * 50 / 100 - total * 20 / 100 - total * 10 / 100 - cut);
    }

    function test_welcomeBonusOnlyOnTheFirstDay() public {
        uint256 day = _day();
        _buy(carol, 0.001 ether, Sherwood.Move.BUY);
        _buyRef(alice, 0.02 ether, Sherwood.Move.BUY, carol); // 20 x 1.1
        assertEq(hook.points(day, alice), 22);
        assertTrue(hook.welcomeBonusActive(day, alice));
        vm.prank(alice);
        pfwaToken.transfer(dave, 1); // no holder bonus tomorrow either
        vm.warp((day + 1) * 1 days + 1);
        assertFalse(hook.welcomeBonusActive(day + 1, alice));
        _buy(alice, 0.02 ether, Sherwood.Move.BUY);
        assertEq(hook.points(day + 1, alice), 20);
    }

    function test_noWelcomeBonusWithoutAReferrer() public {
        _buy(alice, 0.02 ether, Sherwood.Move.BUY);
        assertEq(hook.points(_day(), alice), 20);
    }

    function test_referrerOnlyOnTheFirstPlay() public {
        _buy(carol, 0.001 ether, Sherwood.Move.BUY);
        _buy(alice, 0.01 ether, Sherwood.Move.BUY); // played without a referrer
        _buyRef(alice, 0.01 ether, Sherwood.Move.BUY, carol); // too late
        assertEq(hook.referrerOf(alice), address(0));
        assertEq(hook.points(_day(), alice), 20);
    }

    function test_referredPlayerGetsHolderBonusNextDay() public {
        // A referred player who comes back the next day still holding: holder bonus only.
        uint256 day = _day();
        _buy(carol, 0.001 ether, Sherwood.Move.BUY);
        _buyRef(alice, 0.02 ether, Sherwood.Move.BUY, carol);
        vm.warp((day + 1) * 1 days + 1);
        _buy(alice, 0.02 ether, Sherwood.Move.BUY); // 20 x 1.25
        assertEq(hook.points(day + 1, alice), 25);
    }

    function test_onlyTheOwnerCanCreateThePool() public {
        address hookAddr = address(FLAGS | (uint160(0x5151) << 144));
        deployCodeTo(
            "Sherwood.sol:Sherwood",
            abi.encode(manager, Currency.wrap(address(pfwaToken)), IDiceEntropy(address(dice)), address(1), owner),
            hookAddr
        );
        PoolKey memory key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(pfwaToken)), 500, 10, IHooks(hookAddr));
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.prank(owner);
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(Sherwood(payable(hookAddr)).poolId()), PoolId.unwrap(key.toId()));
    }
}
