// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SherwoodV2, IDiceEntropy} from "../src/SherwoodV2.sol";

/// Stand-in for Dice Protocol: records requests and lets the test reveal them.
contract MockDiceV2 {
    uint128 public fee = 25_000_000_000_000; // 0.000025 ETH, as on Robinhood Chain

    function setFee(uint128 next) external {
        fee = next;
    }
    uint64 public nextSequence = 1;
    mapping(uint64 => address) public requester;
    mapping(uint64 => uint32) public gasLimitOf;

    function getFeeV2(address, uint32) external view returns (uint128) {
        return fee;
    }

    function requestV2(address, bytes32, uint32 gasLimit) external payable returns (uint64 sequence) {
        require(msg.value >= fee, "fee");
        sequence = nextSequence++;
        requester[sequence] = msg.sender;
        gasLimitOf[sequence] = gasLimit;
    }

    /// Reveals the way Dice (Pyth Entropy) does: the callback gets exactly the gas limit the request
    /// asked for, and a callback that fails is not applied (here: the reveal reverts).
    function reveal(uint64 sequence, bytes32 random) external {
        (bool ok,) = requester[sequence].call{gas: gasLimitOf[sequence]}(
            abi.encodeWithSelector(SherwoodV2._entropyCallback.selector, sequence, address(0), random)
        );
        require(ok, "callback failed within its gas limit");
    }

    /// Like `reveal`, but reports the outcome and the gas the callback used instead of reverting.
    function tryReveal(uint64 sequence, bytes32 random) external returns (bool ok, uint256 gasUsed) {
        uint256 before = gasleft();
        (ok,) = requester[sequence].call{gas: gasLimitOf[sequence]}(
            abi.encodeWithSelector(SherwoodV2._entropyCallback.selector, sequence, address(0), random)
        );
        gasUsed = before - gasleft();
    }

    function refundRequest(address, uint64 sequence) external {
        (bool ok,) = requester[sequence].call{value: fee}("");
        require(ok);
    }

    receive() external payable {}
}

/// A Dice that refuses every request, as if paused or out of randomness.
contract BrokenDiceV2 {
    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 25_000_000_000_000;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64) {
        revert("paused");
    }
}

/// A player wallet with code: it can refuse ETH, burn all the gas it gets, or try to re-enter.
contract Winner {
    enum Mode {
        ACCEPT,
        REVERT,
        BURN_GAS,
        REENTER
    }

    Mode public mode = Mode.REVERT;
    SherwoodV2 public hook;
    uint256 public round;
    bool public reentryFailed;

    function setMode(Mode next, SherwoodV2 h, uint256 r) external {
        (mode, hook, round) = (next, h, r);
    }

    function claim(SherwoodV2 h, uint256 r) external {
        h.claim(r);
    }

    receive() external payable {
        if (mode == Mode.ACCEPT) return;
        if (mode == Mode.BURN_GAS) {
            while (true) {}
        }
        if (mode == Mode.REENTER) {
            try hook.claim(round) {}
            catch {
                reentryFailed = true;
            }
            try hook.settle(round, 100) {} catch {}
            return;
        }
        revert("no ETH");
    }
}

contract SherwoodV2Test is Test, Deployers {
    SherwoodV2 hook;
    MockERC20 gameToken;
    MockERC20 hostToken; // stands in for $PFWA, the host of this game
    MockDiceV2 dice;
    PoolKey gameKey;
    PoolKey buybackKey;
    PoolKey hostKey; // an ETH/host pool for the host burn

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant START = 1_760_000_000;
    uint256 constant GENESIS = START - 2 hours; // tests start 2 hours into round 0
    uint256 constant HOST_MIN = 100_000e18;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    event Played(
        uint256 indexed round,
        address indexed player,
        SherwoodV2.Move move,
        uint256 ethIn,
        uint256 pointsScored,
        address indexed target,
        uint256 pointsMoved
    );
    event Reflected(
        uint256 indexed round, address indexed attacker, address indexed defender, uint256 points, SherwoodV2.Move move
    );
    event ReignChanged(uint256 indexed round, address indexed newHolder, uint256 at);
    event ShieldArmed(uint256 indexed round, address indexed player, uint256 until);
    event PrizeClaimed(uint256 indexed round, address indexed player, uint256 amount);
    event UnclaimedSwept(uint256 indexed round, uint256 amount);
    event RoundSettled(
        uint256 indexed round,
        address[3] top,
        address king,
        uint256[4] prize,
        uint256 buyback,
        uint256 rollover,
        uint256 hostBuyback
    );

    function setUp() public {
        vm.warp(START);
        deployFreshManagerAndRouters();
        gameToken = new MockERC20("PFWA", "PFWA", 18);
        gameToken.mint(address(this), 1e30);
        gameToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        hostToken = new MockERC20("HOST", "HOST", 18);
        hostToken.mint(address(this), 1e30);
        hostToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        dice = new MockDiceV2();

        address hookAddr = address(FLAGS | (uint160(0x4444) << 144));
        _deployHook(hookAddr, GENESIS);
        hook = SherwoodV2(payable(hookAddr));

        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        Currency pfwa = Currency.wrap(address(gameToken));
        vm.prank(owner);
        (gameKey,) = initPool(eth, pfwa, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        _addLiquidity(gameKey);
        // The burn pools are fixed in the hook: the ETH/token 1% pool and the ETH/host holder pool, whose
        // hook lives at a fixed address. A permissive stand-in is etched there so the pool can exist here.
        buybackKey = hook.buybackPool();
        hostKey = hook.hostBuybackPool();
        deployCodeTo("MockHolderHook.sol:MockHolderHook", "", address(hostKey.hooks));
        manager.initialize(buybackKey, SQRT_PRICE_1_1);
        _addLiquidity(buybackKey);
        manager.initialize(hostKey, SQRT_PRICE_1_1);
        _addLiquidity(hostKey);
    }

    function _deployHook(address hookAddr, uint256 genesis) internal {
        _deployHook(hookAddr, genesis, address(hostToken));
    }

    function _deployHook(address hookAddr, uint256 genesis, address hostAddr) internal {
        deployCodeTo(
            "SherwoodV2.sol:SherwoodV2",
            abi.encode(
                manager,
                Currency.wrap(address(gameToken)),
                Currency.wrap(hostAddr),
                HOST_MIN,
                IDiceEntropy(address(dice)),
                address(1),
                owner,
                genesis
            ),
            hookAddr
        );
    }

    function _addLiquidity(PoolKey memory key) internal {
        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 500 ether}(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 100e18, salt: 0}), ""
        );
    }

    function _swapIn(PoolKey memory key, address who, uint256 amount, bytes memory data) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        swapRouter.swap{value: amount}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        );
    }

    function _buy(address who, uint256 amount, SherwoodV2.Move move) internal {
        _swapIn(gameKey, who, amount, abi.encode(uint256(move)));
    }

    function _buyRef(address who, uint256 amount, SherwoodV2.Move move, address ref) internal {
        _swapIn(gameKey, who, amount, abi.encode(uint256(move), ref));
    }

    function _sell(address who, uint256 pfwaIn) internal {
        gameToken.mint(who, pfwaIn);
        vm.startPrank(who, who);
        gameToken.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            gameKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(pfwaIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _round() internal view returns (uint256) {
        return hook.currentRound();
    }

    /// When `round` can first be settled.
    function _settleTime(uint256 round) internal view returns (uint256) {
        return hook.roundEnd(round) + 15 minutes;
    }

    /// One second into the round after `round`.
    function _nextRound(uint256 round) internal {
        vm.warp(hook.roundStart(round + 1) + 1);
    }

    function _bps(uint256 total, uint256 bps) internal pure returns (uint256) {
        return (total * bps) / 10_000;
    }

    function _kingPrize(uint256 round) internal view returns (uint256 p) {
        (,,,,,,, p,) = hook.result(round);
    }

    function _kingOf(uint256 round) internal view returns (address s, uint256 reign) {
        (,,,,, s, reign,,) = hook.result(round);
    }

    // ── Buying and points ───────────────────────────────────────────────────────

    function test_buyScoresByBuySizeAndFundsPot() public {
        _buy(alice, 0.025 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(_round(), alice), 25);
        assertEq(hook.pot(_round()), 0.00125 ether); // 5% of 0.025
        assertEq(address(hook).balance, 0.00125 ether);
    }

    function test_pointsCapAt100PerBuy() public {
        _buy(alice, 0.5 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(_round(), alice), 100);
    }

    function test_belowMinimumScoresNothingButPaysFee() public {
        _buy(alice, 0.0009 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(_round(), alice), 0);
        assertEq(hook.pot(_round()), 0.000045 ether);
    }

    function test_noHookDataIsPlainBuy() public {
        _swapIn(gameKey, alice, 0.01 ether, "");
        assertEq(hook.points(_round(), alice), 10);
    }

    function test_unknownMoveIsPlainBuy() public {
        _swapIn(gameKey, alice, 0.01 ether, abi.encode(uint256(5)));
        assertEq(hook.points(_round(), alice), 10);
    }

    function test_buyerReceivesPfwaForEthAfterFee() public {
        uint256 before = gameToken.balanceOf(alice);
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        uint256 got = gameToken.balanceOf(alice) - before;
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

    // ── Rounds ──────────────────────────────────────────────────────────────────

    function test_roundBoundaries() public {
        assertEq(hook.GENESIS(), GENESIS);
        assertEq(hook.ROUND_LENGTH(), 20 hours);
        assertEq(hook.roundStart(0), GENESIS);
        assertEq(hook.roundEnd(0), GENESIS + 20 hours);
        assertEq(hook.roundStart(3), GENESIS + 60 hours);
        assertEq(hook.roundEnd(3), GENESIS + 80 hours);
        assertEq(_round(), 0);
        vm.warp(GENESIS + 20 hours - 1);
        assertEq(_round(), 0);
        vm.warp(GENESIS + 20 hours);
        assertEq(_round(), 1);
        vm.warp(GENESIS + 100 hours + 5);
        assertEq(_round(), 5);
    }

    function test_buysScoreInTheRoundTheyHappen() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundEnd(0) - 1);
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundEnd(0));
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(0, alice), 30);
        assertEq(hook.points(1, alice), 37); // 30 with the holder bonus: she played round 0 and holds
        assertEq(hook.points(2, alice), 0);
        assertEq(hook.pot(1), 0.0015 ether);
    }

    function test_beforeGenesisFeesGoToRoundZeroButNothingScores() public {
        address hookAddr = address(FLAGS | (uint160(0x6161) << 144));
        _deployHook(hookAddr, START + 1 hours);
        SherwoodV2 late = SherwoodV2(payable(hookAddr));
        PoolKey memory key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(gameToken)), 3000, 60, IHooks(hookAddr));
        vm.prank(owner);
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);

        assertEq(late.currentRound(), 0);
        _swapIn(key, alice, 0.05 ether, abi.encode(uint256(SherwoodV2.Move.BUY), carol));
        assertEq(late.pot(0), 0.0025 ether); // the fee lands in round 0
        assertEq(late.points(0, alice), 0); // nothing scored
        assertEq(late.bought(0, alice), 0); // and no holding rules on it
        assertEq(late.playerCount(0), 0);
        assertEq(late.firstRoundPlus1(alice), 0);
        assertEq(late.referrerOf(alice), address(0));
        assertEq(late.reignHolder(0), address(0));

        vm.warp(START + 1 hours); // GENESIS
        _swapIn(key, alice, 0.01 ether, abi.encode(uint256(SherwoodV2.Move.BUY)));
        assertEq(late.points(0, alice), 10);
        assertEq(late.pot(0), 0.003 ether);
        assertEq(late.reignHolder(0), alice);
        assertEq(late.roundEnd(0), START + 21 hours);
    }

    function test_settleTimingPerRound() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundEnd(0) + 15 minutes - 1);
        vm.expectRevert(SherwoodV2.RoundNotOver.selector);
        hook.settle(0, 100);
        vm.warp(hook.roundEnd(0) + 15 minutes);
        assertTrue(hook.settle(0, 100));
        uint256 rolled = hook.pot(1); // the rollover lands in round 1
        assertGt(rolled, 0);

        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        vm.expectRevert(SherwoodV2.RoundNotOver.selector);
        hook.settle(1, 100);
        vm.warp(hook.roundEnd(1) + 15 minutes - 1);
        vm.expectRevert(SherwoodV2.RoundNotOver.selector);
        hook.settle(1, 100);
        vm.warp(hook.roundEnd(1) + 15 minutes);
        assertTrue(hook.settle(1, 100));
        (, address[3] memory top,,,,,,,) = hook.result(1);
        assertEq(top[0], bob);
        assertGt(hook.pot(2), 0);
    }

    // ── Moves ───────────────────────────────────────────────────────────────────

    function test_stealTakes20PercentOfPreviousPlayer() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // alice 50
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // bob 10 + 22% of 50 = 11 stolen
        assertEq(hook.points(_round(), alice), 39);
        assertEq(hook.points(_round(), bob), 21);
    }

    function test_fullSizeStealTakes40Percent() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100
        _buy(bob, 0.1 ether, SherwoodV2.Move.STEAL); // bob 100 + 40
        assertEq(hook.points(_round(), alice), 60);
        assertEq(hook.points(_round(), bob), 140);
    }

    function test_fullSizeRobinHoodMoves33Percent() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100, leader
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY); // bob 2
        _buy(carol, 0.1 ether, SherwoodV2.Move.ROBIN_HOOD); // carol ties alice at 100; alice stays #1 and loses 33 to bob
        assertEq(hook.points(_round(), alice), 67);
        assertEq(hook.points(_round(), bob), 35);
        assertEq(hook.points(_round(), carol), 100);
    }

    function test_scaledBpsRange() public view {
        assertEq(hook.scaledBps(1000, 3300, 100), 3300);
        assertEq(hook.scaledBps(2000, 4000, 1), 2020);
        assertEq(hook.scaledBps(20_000, 30_000, 500), 30_000);
    }

    function test_stealOnYourselfDoesNothingExtra() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.01 ether, SherwoodV2.Move.STEAL);
        assertEq(hook.points(_round(), alice), 60);
    }

    function test_robinHoodMovesLeaderPointsToLowestRecent() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100, leader
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY); // bob 2
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD); // carol 10 → 12.3%: 12 of alice's go to lowest recent (bob)
        assertEq(hook.points(_round(), alice), 88);
        assertEq(hook.points(_round(), bob), 14);
        assertEq(hook.points(_round(), carol), 10);
    }

    function test_robinHoodFindsNewLeaderAfterLeaderLosesPoints() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY); // bob 90
        _buy(carol, 0.01 ether, SherwoodV2.Move.BUY); // carol 10
        _buy(dave, 0.005 ether, SherwoodV2.Move.BUY); // dave 5
        _sell(alice, 0.001 ether); // alice wiped → bob is the real leader
        _buy(carol, 0.001 ether, SherwoodV2.Move.ROBIN_HOOD); // 9 of bob's 90 → lowest recent (alice at 0)
        assertEq(hook.points(_round(), bob), 81);
        assertEq(hook.points(_round(), alice), 9);
    }

    function test_flipWinDoublesPoints() public {
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // bob stakes 20 → wins 2.2x
        assertEq(hook.points(_round(), bob), 0);
        dice.reveal(1, bytes32(uint256(2))); // even → win
        assertEq(hook.points(_round(), bob), 44);
    }

    function test_fullSizeFlipWinPaysTriple() public {
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.1 ether, SherwoodV2.Move.FLIP); // 100-point stake → 3x
        dice.reveal(1, bytes32(uint256(2)));
        assertEq(hook.points(_round(), bob), 300);
    }

    function test_flipLossGoesNegativeAndPaysPreviousPlayer() public {
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // odd → lose
        assertEq(hook.points(_round(), bob), -20);
        assertEq(hook.points(_round(), alice), 50);
    }

    function test_flipLossComesOffExistingPoints() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // alice 10
        _buy(bob, 0.03 ether, SherwoodV2.Move.BUY); // bob 30
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // previous is bob himself → loss goes nowhere
        dice.reveal(1, bytes32(uint256(5)));
        assertEq(hook.points(_round(), bob), 10);
    }

    function test_sellLeavesNegativeScore() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // bob -20
        _sell(bob, 0.001 ether);
        assertEq(hook.points(_round(), bob), -20);
    }

    function test_stealFromNegativePlayerTakesNothing() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // bob -20, alice 30
        _buy(carol, 0.005 ether, SherwoodV2.Move.BUY);
        _buy(dave, 0.01 ether, SherwoodV2.Move.BUY); // previous for the next steal is dave
        _buy(bob, 0.001 ether, SherwoodV2.Move.BUY); // bob -19, now the previous player
        _buy(carol, 0.001 ether, SherwoodV2.Move.STEAL); // 20% of a negative score → nothing
        assertEq(hook.points(_round(), carol), 6);
        assertEq(hook.points(_round(), bob), -19);
    }

    function test_negativePlayersNeverPlace() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        dice.reveal(1, bytes32(uint256(3))); // bob -20
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        (, address[3] memory top,,,,,,,) = hook.result(round);
        assertEq(top[0], alice);
        assertEq(top[1], address(0));
    }

    function test_flipPaysDiceFeeFromPot() public {
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        assertEq(hook.pot(_round()), 0.001 ether - 0.000025 ether);
        assertEq(address(dice).balance, 0.000025 ether);
    }

    function test_unrevealedFlipExpiresAsPlainBuy() public {
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
        hook.expireFlip(1);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        hook.expireFlip(1);
        assertEq(hook.points(_round(), bob), 20);
        dice.reveal(1, bytes32(uint256(2))); // a late reveal does nothing
        assertEq(hook.points(_round(), bob), 20);
    }

    function test_flipScoresAsBuyWhenDiceRefuses() public {
        BrokenDiceV2 broken = new BrokenDiceV2();
        vm.etch(address(dice), address(broken).code); // swap in a Dice that reverts
        uint256 potBefore = hook.pot(_round());
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // must not revert
        assertEq(hook.points(_round(), bob), 20); // scored as a plain buy
        assertEq(hook.pot(_round()) - potBefore, 0.001 ether); // no Dice fee taken
        assertEq(hook.flipsLeft(bob), 6); // and no flip used up
    }

    function test_onlyDiceCanDeliverRandomness() public {
        vm.expectRevert(SherwoodV2.NotDice.selector);
        hook._entropyCallback(1, address(0), bytes32(0));
    }

    // ── Selling ─────────────────────────────────────────────────────────────────

    function test_sellWipesPointsAndFundsPot() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        uint256 potBefore = hook.pot(_round());
        _sell(alice, 0.01 ether);
        assertEq(hook.points(_round(), alice), 0);
        assertGt(hook.pot(_round()), potBefore); // 5% of the ETH paid out
    }

    // ── Move charges ────────────────────────────────────────────────────────────

    function test_stealChargesStackAndRecharge() public {
        assertEq(hook.stealsLeft(bob), 18); // a new wallet starts with a full bank
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        for (uint256 i; i < 18; ++i) {
            _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
            _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // 18 in a row
        }
        assertEq(hook.stealsLeft(bob), 0);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        int256 carolBefore = hook.points(0, carol);
        vm.expectEmit(true, true, true, true, address(hook));
        emit Played(0, bob, SherwoodV2.Move.BUY, 0.01 ether, 10, address(0), 0);
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // none left: a plain buy
        assertEq(hook.points(0, carol), carolBefore);
        (uint256 nextSteal,,) = hook.nextCharges(bob);
        assertEq(nextSteal, vm.getBlockTimestamp() + 10 minutes);

        vm.warp(vm.getBlockTimestamp() + 10 minutes - 1);
        assertEq(hook.stealsLeft(bob), 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(hook.stealsLeft(bob), 1);
        vm.warp(vm.getBlockTimestamp() + 5 hours); // banks up to 18, no more
        assertEq(hook.stealsLeft(bob), 18);
        (nextSteal,,) = hook.nextCharges(bob);
        assertEq(nextSteal, 0);
    }

    function test_chargesBankedPastTheCapAreDropped() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        vm.warp(vm.getBlockTimestamp() + 5 hours); // a full bank for hours: still 18
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL);
        assertEq(hook.stealsLeft(bob), 17);
        (uint256 nextSteal,,) = hook.nextCharges(bob);
        assertEq(nextSteal, vm.getBlockTimestamp() + 10 minutes); // refills from now, not from the past
    }

    function test_stealWithNoTargetUsesNoCharge() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.STEAL); // first player: nobody to steal from
        assertEq(hook.stealsLeft(alice), 18);
        _buy(alice, 0.01 ether, SherwoodV2.Move.STEAL); // on herself
        assertEq(hook.stealsLeft(alice), 18);
    }

    function test_chargesCarryAcrossRounds() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundEnd(0) - 60);
        for (uint256 i; i < 18; ++i) {
            _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
            _buy(bob, 0.001 ether, SherwoodV2.Move.STEAL);
        }
        vm.warp(hook.roundEnd(0) + 60); // round 1, 2 minutes later: a new round refills nothing
        assertEq(hook.stealsLeft(bob), 0);
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // a plain buy
        assertEq(hook.points(1, alice), 62); // holder bonus, nothing taken
    }

    function test_robinHoodChargesStackAndRecharge() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY); // bob 2
        assertEq(hook.robinsLeft(carol), 3);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD); // 12 of alice's → bob
        assertEq(hook.points(0, alice), 88);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD); // three in a row
        assertEq(hook.robinsLeft(carol), 0);
        int256 aliceBefore = hook.points(0, alice);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD); // none left: a plain buy
        assertEq(hook.points(0, alice), aliceBefore);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(hook.robinsLeft(carol), 1);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertLt(hook.points(0, alice), aliceBefore);
    }

    function test_flipChargesStackAcrossRounds() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        assertEq(hook.flipsLeft(bob), 6); // two rounds' worth to start
        for (uint256 i; i < 6; ++i) {
            _buy(bob, 0.002 ether, SherwoodV2.Move.FLIP);
        }
        assertEq(hook.flipsLeft(bob), 0);
        assertEq(hook.pendingFlips(0), 6);
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // seventh: a plain buy
        assertEq(hook.pendingFlips(0), 6);
        dice.reveal(1, bytes32(uint256(2))); // resolving one doesn't give it back
        assertEq(hook.flipsLeft(bob), 0);

        vm.warp(vm.getBlockTimestamp() + hook.ROUND_LENGTH()); // a round later: 3 back
        assertEq(hook.flipsLeft(bob), 3);
        vm.warp(vm.getBlockTimestamp() + hook.ROUND_LENGTH()); // unused, they bank up to 6
        assertEq(hook.flipsLeft(bob), 6);
    }

    // ── Shields ─────────────────────────────────────────────────────────────────

    function test_shieldChargeEarnedAtCumulativeThreshold() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP); // every move counts
        assertEq(hook.shieldCharges(0, alice), 0);
        _buy(alice, 0.0009 ether, SherwoodV2.Move.BUY); // below MIN_BUY: doesn't count
        assertEq(hook.shieldCharges(0, alice), 0);
        _buy(alice, 0.005 ether, SherwoodV2.Move.BUY); // 0.025 played
        assertEq(hook.shieldCharges(0, alice), 1);
        (uint128 played, uint64 used, bool charge) = hook.shieldStats(0, alice);
        assertEq(played, 0.025 ether);
        assertEq(used, 0);
        assertTrue(charge);

        _nextRound(0); // charges and the ETH count are per round
        assertEq(hook.shieldCharges(1, alice), 0);
    }

    function test_shieldChargesCapAtOne() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // crosses 4 marks: holds 1, the rest are lost
        assertEq(hook.shieldCharges(0, alice), 1);
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY); // 5th mark while holding one: lost too
        assertEq(hook.shieldCharges(0, alice), 1);
        _buy(alice, 0.001 ether, SherwoodV2.Move.SHIELD); // spends it
        assertEq(hook.shieldCharges(0, alice), 0);
        assertEq(hook.shieldUntil(alice), vm.getBlockTimestamp() + 30 minutes);
        _buy(alice, 0.01 ether, SherwoodV2.Move.SHIELD); // 0.141: no new mark, so a plain buy
        assertEq(hook.shieldCharges(0, alice), 0);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // 0.151: crosses 0.15
        assertEq(hook.shieldCharges(0, alice), 1);
        (, uint64 used,) = hook.shieldStats(0, alice);
        assertEq(used, 1);
    }

    function test_shieldWithoutChargeIsPlainBuy() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit Played(0, alice, SherwoodV2.Move.BUY, 0.01 ether, 10, address(0), 0);
        _buy(alice, 0.01 ether, SherwoodV2.Move.SHIELD);
        assertEq(hook.points(0, alice), 10);
        assertEq(hook.shieldUntil(alice), 0);
        assertFalse(hook.shieldActive(alice));
    }

    function test_shieldScoresLikeABuyAndArmsWithTheChargeItEarns() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit ShieldArmed(0, alice, vm.getBlockTimestamp() + 30 minutes);
        _buy(alice, 0.025 ether, SherwoodV2.Move.SHIELD); // earns the charge and spends it
        assertEq(hook.points(0, alice), 25);
        assertTrue(hook.shieldActive(alice));
        assertEq(hook.shieldCharges(0, alice), 0);
    }

    function test_shieldRearmRefreshesExpiry() public {
        _buy(alice, 0.025 ether, SherwoodV2.Move.SHIELD);
        uint256 first = hook.shieldUntil(alice);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _buy(alice, 0.025 ether, SherwoodV2.Move.SHIELD); // new charge at 0.05
        assertEq(hook.shieldUntil(alice), first + 10 minutes);
        (, uint64 used,) = hook.shieldStats(0, alice);
        assertEq(used, 2);
    }

    function test_shieldExpiresAfterThirtyMinutes() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.SHIELD); // alice 50, shielded
        vm.warp(vm.getBlockTimestamp() + 30 minutes - 1);
        assertTrue(hook.shieldActive(alice));
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(hook.shieldActive(alice));
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // a normal steal: 11 of 50
        assertEq(hook.points(0, alice), 39);
        assertEq(hook.points(0, bob), 21);
    }

    function test_stealIntoShieldIsReflected() public {
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY); // bob 50
        _buy(alice, 0.05 ether, SherwoodV2.Move.SHIELD); // alice 50, shielded
        vm.expectEmit(true, true, true, true, address(hook));
        emit Reflected(0, bob, alice, 11, SherwoodV2.Move.STEAL);
        vm.expectEmit(true, true, true, true, address(hook));
        emit Played(0, bob, SherwoodV2.Move.STEAL, 0.01 ether, 10, alice, 0);
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // bob 60; 22% of alice's 50 = 11 flows bob → alice
        assertEq(hook.points(0, bob), 49);
        assertEq(hook.points(0, alice), 61);
        assertEq(hook.shieldUntil(alice), 0); // broken
        assertFalse(hook.shieldActive(alice));
        assertEq(hook.stealsLeft(bob), 17); // still used a steal
    }

    function test_reflectedStealTakesTheFullCutBelowZero() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.SHIELD); // alice 50, shielded
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // bob 10; would take 11, pays all 11 like a lost flip
        assertEq(hook.points(0, bob), -1);
        assertEq(hook.points(0, alice), 61);
        assertFalse(hook.shieldActive(alice));
        // The shield is gone: the next steal lands.
        _buy(alice, 0.001 ether, SherwoodV2.Move.BUY); // alice 62, previous
        _buy(carol, 0.01 ether, SherwoodV2.Move.STEAL); // 22% of 62 = 13
        assertEq(hook.points(0, alice), 49);
    }

    /// Audit (low): a fresh wallet with one point could strip the leader's shield for 0.001 ETH because the
    /// reflect was capped at the attacker's points. Now the attacker pays the whole cut the move would
    /// have taken, so the shield pays the defender exactly what the attack would have cost them.
    function test_throwawayWalletPaysTheFullCutToBreakAShield() public {
        address mallory = makeAddr("mallory");
        _buy(alice, 0.1 ether, SherwoodV2.Move.SHIELD); // alice 100, #1, shielded
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY); // bob 2: someone a Robin Hood could pay
        _buy(mallory, 0.001 ether, SherwoodV2.Move.ROBIN_HOOD); // mallory 1; the 10% cut (10) is reflected
        assertEq(hook.points(0, alice), 110);
        assertEq(hook.points(0, mallory), -9);
        assertFalse(hook.shieldActive(alice)); // the shield did its job and broke
        _buy(bob, 0.1 ether, SherwoodV2.Move.ROBIN_HOOD); // bob 102; 33% of 110 = 36 to the lowest recent (mallory)
        assertEq(hook.points(0, alice), 74);
        assertEq(hook.points(0, mallory), 27);
        assertEq(hook.points(0, bob), 102);
    }

    /// Audit (low): a Steal on a shielded previous player with nothing to take used to delete the shield.
    function test_stealThatTakesNothingLeavesTheShieldUp() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.SHIELD); // alice 50, shielded
        _sell(alice, 0.001 ether); // wiped to 0, still the previous player
        assertEq(hook.lastPlayer(0), alice);
        assertEq(hook.points(0, alice), 0);
        assertTrue(hook.shieldActive(alice));
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // 22% of 0 = 0: nothing reflected, nothing broken
        assertEq(hook.points(0, bob), 10);
        assertEq(hook.points(0, alice), 0);
        assertTrue(hook.shieldActive(alice));
        assertEq(hook.stealsLeft(bob), 17); // the steal was still played
    }

    function test_robinHoodIntoShieldIsReflected() public {
        _buy(carol, 0.05 ether, SherwoodV2.Move.BUY); // carol 50
        _buy(alice, 0.1 ether, SherwoodV2.Move.SHIELD); // alice 100, leader, shielded
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY); // bob 2, lowest recent
        vm.expectEmit(true, true, true, true, address(hook));
        emit Reflected(0, carol, alice, 12, SherwoodV2.Move.ROBIN_HOOD);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD); // carol 60; the 12 cut goes carol → alice
        assertEq(hook.points(0, carol), 48);
        assertEq(hook.points(0, alice), 112);
        assertEq(hook.points(0, bob), 2); // the lowest recent gets nothing
        assertFalse(hook.shieldActive(alice));
        assertEq(hook.robinsLeft(carol), 2);
    }

    function test_reflectedRobinHoodTakesTheFullCutBelowZero() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.SHIELD); // alice 100, shielded
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD); // carol 10, cut 12 → pays all 12
        assertEq(hook.points(0, carol), -2);
        assertEq(hook.points(0, alice), 112);
        assertEq(hook.points(0, bob), 2);
        assertEq(hook.shieldUntil(alice), 0);
    }

    function test_robinHoodAfterShieldExpiresLands() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.SHIELD);
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _buy(carol, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertEq(hook.points(0, alice), 88);
        assertEq(hook.points(0, bob), 14);
    }

    // ── King (time at #1) ────────────────────────────────────────────────────

    function test_reignCountsSecondsAtNumberOne() public {
        uint256 t0 = vm.getBlockTimestamp();
        vm.expectEmit(true, true, true, true, address(hook));
        emit ReignChanged(0, alice, t0);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // alice 10
        assertEq(hook.reignHolder(0), alice);
        vm.warp(t0 + 100);
        assertEq(hook.reignOf(0, alice), 100); // live
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY); // bob 20 takes #1
        assertEq(hook.reignHolder(0), bob);
        vm.warp(t0 + 150);
        assertEq(hook.reignOf(0, alice), 100);
        assertEq(hook.reignOf(0, bob), 50);
        assertEq(hook.kingOfTheHill(0), alice);
        vm.warp(t0 + 201);
        assertEq(hook.kingOfTheHill(0), bob);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY); // no change at #1
        assertEq(hook.reignHolder(0), bob);
        assertEq(hook.reignOf(0, bob), 101);
    }

    function test_reignChangesOnSteal() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // alice 50
        vm.warp(t0 + 100);
        _buy(bob, 0.04 ether, SherwoodV2.Move.STEAL); // bob 40 + 28% of 50 = 14 → 54; alice 36
        assertEq(hook.points(0, bob), 54);
        assertEq(hook.reignHolder(0), bob);
        assertEq(hook.reignOf(0, alice), 100);
    }

    function test_reignChangesOnRobinHood() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100
        _buy(bob, 0.08 ether, SherwoodV2.Move.BUY); // bob 80
        vm.warp(t0 + 100);
        _buy(carol, 0.1 ether, SherwoodV2.Move.ROBIN_HOOD); // carol 100; 33 of alice's → bob (113)
        assertEq(hook.points(0, bob), 113);
        assertEq(hook.reignHolder(0), bob);
        assertEq(hook.reignOf(0, alice), 100);
        assertEq(hook.reignOf(0, bob), 0);
    }

    function test_reignChangesOnReflect() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY); // bob 50, #1
        _buy(alice, 0.045 ether, SherwoodV2.Move.SHIELD); // alice 45, shielded
        vm.warp(t0 + 100);
        _buy(bob, 0.001 ether, SherwoodV2.Move.STEAL); // bob 51; 20.2% of 45 = 9 reflected → bob 42, alice 54
        assertEq(hook.points(0, alice), 54);
        assertEq(hook.reignHolder(0), alice);
        assertEq(hook.reignOf(0, bob), 100);
    }

    function test_reignChangesOnFlipWin() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY); // alice 30
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        vm.warp(t0 + 100);
        dice.reveal(1, bytes32(uint256(2))); // bob 44
        assertEq(hook.reignHolder(0), bob);
        assertEq(hook.reignOf(0, alice), 100);
    }

    function test_reignChangesOnFlipLoss() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY); // alice 30
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY); // bob 50, #1
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // previous is bob: a loss goes nowhere
        _buy(alice, 0.001 ether, SherwoodV2.Move.BUY); // alice 31
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // previous alice
        vm.warp(t0 + 100);
        dice.reveal(2, bytes32(uint256(3))); // bob loses 20 to alice: bob 30, alice 51
        assertEq(hook.points(0, alice), 51);
        assertEq(hook.reignHolder(0), alice);
        assertEq(hook.reignOf(0, bob), 100);
    }

    function test_reignChangesOnFlipExpiry() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.05 ether, SherwoodV2.Move.FLIP);
        vm.warp(t0 + 10 minutes);
        hook.expireFlip(1); // bob 50
        assertEq(hook.reignHolder(0), bob);
        assertEq(hook.reignOf(0, alice), 10 minutes);
    }

    function test_reignChangesOnSellWipe() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.03 ether, SherwoodV2.Move.BUY);
        vm.warp(t0 + 100);
        _sell(alice, 0.001 ether);
        assertEq(hook.reignHolder(0), bob);
        assertEq(hook.reignOf(0, alice), 100);
    }

    function test_reignCanBeVacant() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        vm.warp(t0 + 100);
        gameToken.mint(alice, 0.001 ether);
        vm.prank(alice);
        gameToken.approve(address(swapRouter), type(uint256).max);
        vm.expectEmit(true, true, true, true, address(hook));
        emit ReignChanged(0, address(0), t0 + 100);
        vm.prank(alice, alice);
        swapRouter.swap( // alice sells: nobody above zero
            gameKey,
            SwapParams({zeroForOne: false, amountSpecified: -0.001 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(hook.reignHolder(0), address(0));
        vm.warp(t0 + 150);
        _buy(bob, 0.001 ether, SherwoodV2.Move.BUY);
        vm.warp(t0 + 160);
        assertEq(hook.reignOf(0, alice), 100);
        assertEq(hook.reignOf(0, bob), 10);
        assertEq(hook.reignOf(0, address(0)), 0);
    }

    function test_reignStopsAtRoundEndAndIsFinalizedAtSettlement() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 end = hook.roundEnd(0);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        vm.warp(end + 5 hours);
        assertEq(hook.reignOf(0, alice), end - t0); // capped at the round's end
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY); // round 1: doesn't touch round 0
        assertEq(hook.reignOf(1, bob), 0);
        hook.settle(0, 100);
        (address s, uint256 reign) = _kingOf(0);
        assertEq(s, alice);
        assertEq(reign, end - t0);
        assertEq(hook.reignOf(0, alice), end - t0);
        assertEq(hook.kingOfTheHill(0), alice);
    }

    function test_leaderChangeAfterRoundEndCountsNothing() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 end = hook.roundEnd(0);
        _buy(alice, 0.03 ether, SherwoodV2.Move.BUY);
        vm.warp(end - 1);
        _buy(bob, 0.1 ether, SherwoodV2.Move.FLIP);
        vm.warp(end + 5 minutes);
        dice.reveal(1, bytes32(uint256(2))); // bob 300, #1 from the round's end
        assertEq(hook.reignHolder(0), bob);
        assertEq(hook.reignOf(0, bob), 0);
        assertEq(hook.reignOf(0, alice), end - t0);
        vm.warp(_settleTime(0));
        hook.settle(0, 100);
        (, address[3] memory top,,,, address s,,,) = hook.result(0);
        assertEq(top[0], bob);
        assertEq(s, alice);
    }

    function test_kingTieGoesToMorePoints() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // alice 10, #1
        vm.warp(t0 + 100);
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY); // bob 20, #1
        vm.warp(t0 + 200);
        _sell(bob, 0.001 ether); // back to alice...
        _sell(alice, 0.001 ether); // ...and to nobody: 100 seconds each
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // revealed after the round: points, no seconds
        vm.warp(_settleTime(0));
        dice.reveal(1, bytes32(uint256(2)));
        assertEq(hook.reignOf(0, alice), 100);
        assertEq(hook.reignOf(0, bob), 100);
        assertEq(hook.kingOfTheHill(0), bob); // live view applies the same tie rule
        hook.settle(0, 100);
        (address s, uint256 reign) = _kingOf(0);
        assertEq(s, bob);
        assertEq(reign, 100);
    }

    function test_kingFullTieGoesToTheEarlierPlayer() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        vm.warp(t0 + 100);
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(t0 + 200);
        _sell(bob, 0.001 ether);
        _sell(alice, 0.001 ether); // 100 seconds and 0 points each
        assertEq(hook.kingOfTheHill(0), alice);
        vm.warp(_settleTime(0));
        assertFalse(hook.settle(0, 1)); // in batches
        assertTrue(hook.settle(0, 1));
        (address s,) = _kingOf(0);
        assertEq(s, alice);
    }

    // ── Settlement ──────────────────────────────────────────────────────────────

    function test_potSplitSumsToWhole() public view {
        assertEq(hook.FIRST_BPS(), 4000);
        assertEq(hook.SECOND_BPS(), 2000);
        assertEq(hook.THIRD_BPS(), 1000);
        assertEq(hook.KING_BPS(), 800);
        assertEq(hook.BURN_BPS(), 1000);
        assertEq(hook.HOST_BURN_BPS(), 700);
        assertEq(hook.ROLLOVER_BPS(), 500);
        assertEq(
            hook.FIRST_BPS() + hook.SECOND_BPS() + hook.THIRD_BPS() + hook.KING_BPS() + hook.BURN_BPS()
                + hook.HOST_BURN_BPS() + hook.ROLLOVER_BPS(),
            10_000
        );
        // The rollover covers the largest possible referral cut: 5% of all four prizes.
        uint256 prizes = hook.FIRST_BPS() + hook.SECOND_BPS() + hook.THIRD_BPS() + hook.KING_BPS();
        assertLe(prizes * 500 / 10_000, hook.ROLLOVER_BPS());
    }

    function test_settleSplitsPotAndWinnersClaim() public {
        uint256 round = _round();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // 100, #1 all round: also the King
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY); // 50
        _buy(carol, 0.02 ether, SherwoodV2.Move.BUY); // 20
        _buy(dave, 0.01 ether, SherwoodV2.Move.BUY); // 10
        uint256 total = hook.pot(round);

        vm.expectRevert(SherwoodV2.RoundNotOver.selector);
        hook.settle(round, 100);
        vm.expectRevert(SherwoodV2.NotSettled.selector);
        hook.claim(round);

        vm.warp(_settleTime(round));
        uint256[4] memory before = [alice.balance, bob.balance, carol.balance, dave.balance];
        uint256 hookBefore = address(hook).balance;
        assertTrue(hook.settle(round, 100));
        (
            bool settled,
            address[3] memory top,,
            uint256[3] memory prize,
            bool[3] memory claimed,
            address s,,
            uint256 kingPrize,
            bool kingClaimed
        ) = hook.result(round);
        assertTrue(settled);
        assertEq(top[0], alice);
        assertEq(top[1], bob);
        assertEq(top[2], carol);
        assertEq(s, alice);
        assertEq(prize[0], _bps(total, 4000));
        assertEq(prize[1], _bps(total, 2000));
        assertEq(prize[2], _bps(total, 1000));
        assertEq(kingPrize, _bps(total, 800));
        assertTrue(!claimed[0] && !claimed[1] && !claimed[2] && !kingClaimed);
        assertEq(hook.buybackReserve(), _bps(total, 1000));
        assertEq(
            hook.pot(round + 1),
            total - prize[0] - prize[1] - prize[2] - kingPrize - _bps(total, 1000) - _bps(total, 700)
        );
        assertApproxEqAbs(hook.pot(round + 1), _bps(total, 500), 5);
        assertEq(hook.hostBuybackReserve(), _bps(total, 700));

        // Settlement sends nothing: winners claim.
        assertEq(address(hook).balance, hookBefore);
        assertEq(alice.balance, before[0]);
        assertEq(bob.balance, before[1]);

        // alice claims #1 and King in one go.
        vm.expectEmit(true, true, true, true, address(hook));
        emit PrizeClaimed(round, alice, prize[0] + kingPrize);
        vm.prank(alice);
        hook.claim(round);
        assertEq(alice.balance - before[0], prize[0] + kingPrize);
        vm.prank(bob);
        hook.claim(round);
        assertEq(bob.balance - before[1], prize[1]);
        vm.prank(carol);
        hook.claim(round);
        assertEq(carol.balance - before[2], prize[2]);
        assertEq(address(hook).balance, hook.buybackReserve() + hook.hostBuybackReserve() + hook.pot(round + 1));
        (,,,, claimed,,,, kingClaimed) = hook.result(round);
        assertTrue(claimed[0] && claimed[1] && claimed[2] && kingClaimed);

        // Nothing is paid twice, and non-winners get nothing.
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        hook.claim(round);
        vm.prank(dave);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        hook.claim(round);
        assertEq(dave.balance, before[3]);
        vm.expectRevert(SherwoodV2.AlreadySettled.selector);
        hook.settle(round, 100);
        vm.warp(hook.claimDeadline(round) + 1);
        uint256 current = hook.currentRound();
        uint256 potBefore = hook.pot(current);
        hook.sweepUnclaimed(round);
        assertEq(hook.pot(current), potBefore); // nothing left to sweep
    }

    function test_settleInBatchesSendsNothing() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        uint256 hookBefore = address(hook).balance;
        uint256 bobBefore = bob.balance;
        assertFalse(hook.settle(round, 2));
        vm.prank(bob);
        vm.expectRevert(SherwoodV2.NotSettled.selector); // not claimable until the last batch
        hook.claim(round);
        assertTrue(hook.settle(round, 2));
        assertEq(address(hook).balance, hookBefore);
        assertEq(bob.balance, bobBefore);
        vm.prank(bob);
        hook.claim(round);
        assertGt(bob.balance, bobBefore);
    }

    function test_gas_completingSettleBatch() public {
        uint256 round = _round();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // #1 and King
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundEnd(round) - 100);
        _buy(dave, 0.2 ether, SherwoodV2.Move.BUY); // #1 at the end: 4 separate winners
        for (uint256 i; i < 20; ++i) {
            _buy(address(uint160(0x2000 + i)), 0.001 ether, SherwoodV2.Move.BUY);
        }
        vm.warp(_settleTime(round));
        uint256 g = gasleft();
        hook.settle(round, 100);
        emit log_named_uint("settle, 24 players, 4 prizes (one batch)", g - gasleft());
        (address k,) = _kingOf(round);
        assertEq(k, alice);
        g = gasleft();
        vm.prank(alice);
        hook.claim(round);
        emit log_named_uint("claim, King only", g - gasleft());
    }

    function test_walletThatRefusesEthCanClaimOnceItAccepts() public {
        Winner w = new Winner(); // refuses ETH
        uint256 round = _round();
        _buy(address(w), 0.05 ether, SherwoodV2.Move.BUY); // #1 and King
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY);
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        assertTrue(hook.settle(round, 100)); // a bad wallet can't block settlement: nobody is called
        uint256 owed = _bps(total, 4000) + _bps(total, 800);
        vm.expectRevert(SherwoodV2.TransferFailed.selector);
        w.claim(hook, round);
        (,,,, bool[3] memory claimed,,,, bool kingClaimed) = hook.result(round);
        assertFalse(claimed[0]);
        assertFalse(kingClaimed);
        w.setMode(Winner.Mode.ACCEPT, hook, round);
        w.claim(hook, round);
        assertEq(address(w).balance, owed);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        w.claim(hook, round); // once only
    }

    function test_settleNeverCallsWinners() public {
        Winner w = new Winner();
        w.setMode(Winner.Mode.BURN_GAS, hook, 0);
        uint256 round = _round();
        _buy(address(w), 0.05 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        uint256 g = gasleft();
        assertTrue(hook.settle(round, 100));
        uint256 used = g - gasleft();
        emit log_named_uint("settle with a gas-burning winner", used);
        assertLt(used, 450_000);
        assertGt(_kingPrize(round), 0);
    }

    function test_reentrantWinnerGetsNothingExtra() public {
        Winner w = new Winner();
        uint256 round = _round();
        w.setMode(Winner.Mode.REENTER, hook, round);
        _buy(address(w), 0.05 ether, SherwoodV2.Move.BUY); // #1 and King
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        uint256 hookBefore = address(hook).balance;
        w.claim(hook, round);
        uint256 owed = _bps(total, 4000) + _bps(total, 800);
        // Its receive() ran (so the payment went through) but re-entering claim() failed.
        assertTrue(w.reentryFailed());
        assertEq(address(w).balance, owed);
        assertEq(hookBefore - address(hook).balance, owed);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        w.claim(hook, round);
    }

    function test_settleInBatches() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        assertFalse(hook.settle(round, 2));
        assertTrue(hook.settle(round, 2));
        (, address[3] memory top,,,, address s,,,) = hook.result(round);
        assertEq(top[0], bob);
        assertEq(top[1], carol);
        assertEq(top[2], alice);
        assertEq(s, bob); // alice's reign lasted 0 seconds (same block)
    }

    function test_unawardedSharesRollOverWhenFewerThanThreePlayers() public {
        uint256 round = _round();
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        // alice 40% + King 8%, buyback 10%, host buyback 7%, the rest (35%) rolls into the next round
        assertEq(
            hook.pot(round + 1), total - _bps(total, 4000) - _bps(total, 800) - _bps(total, 1000) - _bps(total, 700)
        );
    }

    function test_noKingShareRollsOver() public {
        uint256 round = _round();
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP); // nobody above zero during the round
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        dice.reveal(1, bytes32(uint256(2))); // bob 44, but #1 only from the round's end
        hook.settle(round, 100);
        (, address[3] memory top,, uint256[3] memory prize,, address s, uint256 reign, uint256 kingPrize,) =
            hook.result(round);
        assertEq(top[0], bob);
        assertEq(prize[0], _bps(total, 4000));
        assertEq(s, address(0));
        assertEq(reign, 0);
        assertEq(kingPrize, 0);
        assertEq(hook.pot(round + 1), total - _bps(total, 4000) - _bps(total, 1000) - _bps(total, 700));
    }

    function test_unclaimedPrizesSweepAfterSevenDays() public {
        uint256 round = _round();
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY); // #1 and King
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,,,,,) = hook.result(round);
        uint256 owed = prize[0] + _kingPrize(round);
        vm.expectRevert(SherwoodV2.ClaimWindowOpen.selector);
        hook.sweepUnclaimed(round);
        vm.warp(hook.claimDeadline(round));
        vm.expectRevert(SherwoodV2.ClaimWindowOpen.selector); // the last second still belongs to the winner
        hook.sweepUnclaimed(round);
        vm.warp(hook.claimDeadline(round) + 1); // 7 days after settlement
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.ClaimWindowClosed.selector);
        hook.claim(round);
        uint256 current = hook.currentRound();
        assertGt(current, round + 1);
        uint256 potBefore = hook.pot(current);
        uint256 nextBefore = hook.pot(round + 1);
        vm.expectEmit(true, true, true, true, address(hook));
        emit UnclaimedSwept(round, owed);
        vm.prank(dave); // anyone can
        hook.sweepUnclaimed(round);
        // Into the pot of the round live when it's swept, not the one after the prize's round.
        assertEq(hook.pot(current) - potBefore, owed);
        assertEq(hook.pot(round + 1), nextBefore);
        (,,,, bool[3] memory claimed,,,, bool kingClaimed) = hook.result(round);
        assertTrue(claimed[0] && kingClaimed); // done: swept
        vm.expectRevert(SherwoodV2.NotSettled.selector);
        hook.sweepUnclaimed(round); // once only
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.ClaimWindowClosed.selector);
        hook.claim(round);
    }

    function test_sweepLandsInTheRoundLiveWhenSwept() public {
        uint256 round = _round();
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,,,,,) = hook.result(round);
        uint256 owed = prize[0] + _kingPrize(round);
        vm.warp(hook.claimDeadline(round) + 3 days); // swept late
        uint256 current = hook.currentRound();
        uint256 earlier = hook.currentRound() - 3; // the round live when the window closed
        uint256 earlierBefore = hook.pot(earlier);
        uint256 potBefore = hook.pot(current);
        hook.sweepUnclaimed(round);
        assertEq(hook.pot(current) - potBefore, owed);
        assertEq(hook.pot(earlier), earlierBefore);
    }

    function test_sweepUnsettledRoundReverts() public {
        uint256 round = _round();
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.claimDeadline(round) + 1);
        vm.expectRevert(SherwoodV2.NotSettled.selector);
        hook.sweepUnclaimed(round);
    }

    function test_flipRevealedAfterSettlementIsIgnored() public {
        uint256 round = _round();
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        vm.warp(_settleTime(round));
        hook.expireFlip(1); // settlement waits for this; the flip scores as a plain buy
        hook.settle(round, 100);
        dice.reveal(1, bytes32(uint256(2))); // Dice reveals late: nothing changes
        assertEq(hook.points(round, bob), 20);
    }

    // ── King prizes and claims ───────────────────────────────────────────────

    /// alice holds #1 most of the round, bob overtakes near the end. carol and dave fill #2/#3 when asked.
    function _kingNotFirst(bool fillPodium) internal returns (uint256 round) {
        return _kingNotFirst(fillPodium, alice);
    }

    /// The same with `king` in alice's place.
    function _kingNotFirst(bool fillPodium, address king) internal returns (uint256 round) {
        round = _round();
        _buy(king, 0.01 ether, SherwoodV2.Move.BUY); // 10, #1
        vm.warp(hook.roundEnd(round) - 100);
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY); // bob 50, #1 for the last 100 seconds
        if (fillPodium) {
            _buy(carol, 0.03 ether, SherwoodV2.Move.BUY);
            _buy(dave, 0.02 ether, SherwoodV2.Move.BUY); // alice drops to 4th
        }
    }

    function test_kingOutsideTopThreeClaimsKingPrize() public {
        uint256 round = _kingNotFirst(true);
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        uint256 before = alice.balance;
        hook.settle(round, 100);
        (, address[3] memory top,,,, address s, uint256 reign, uint256 kingPrize, bool kingClaimed) = hook.result(round);
        assertEq(top[0], bob);
        assertEq(top[1], carol);
        assertEq(top[2], dave);
        assertEq(s, alice);
        assertEq(reign, hook.roundEnd(round) - 100 - START);
        assertEq(kingPrize, _bps(total, 800));
        assertFalse(kingClaimed);
        assertEq(alice.balance, before); // nothing sent at settlement
        assertEq(hook.kingOfTheHill(round), alice);
        assertEq(hook.heldToClaim(round, alice), hook.bought(round, alice));

        vm.expectEmit(true, true, true, true, address(hook));
        emit PrizeClaimed(round, alice, kingPrize);
        vm.prank(alice);
        hook.claim(round);
        assertEq(alice.balance - before, kingPrize);
        (,,,,,,,, kingClaimed) = hook.result(round);
        assertTrue(kingClaimed);
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        hook.claim(round);
    }

    function test_rankAndKingClaimedTogether() public {
        uint256 round = _kingNotFirst(false); // alice #2 and King
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,, address s,, uint256 kingPrize,) = hook.result(round);
        assertEq(s, alice);
        assertEq(prize[1], _bps(total, 2000));
        uint256 before = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        hook.claim(round);
        assertEq(alice.balance - before, prize[1] + kingPrize);
        uint256 claims;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PrizeClaimed.selector) {
                ++claims;
                assertEq(abi.decode(logs[i].data, (uint256)), prize[1] + kingPrize); // one payment
            }
        }
        assertEq(claims, 1);
        (,,,, bool[3] memory claimed,,,, bool kingClaimed) = hook.result(round);
        assertTrue(claimed[1]);
        assertTrue(kingClaimed);
        assertFalse(claimed[0]); // bob hasn't claimed yet
    }

    function test_rankAndKingClaimNeedsTheHolding() public {
        uint256 round = _kingNotFirst(false); // alice #2 and King
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        uint256 held = hook.heldToClaim(round, alice);
        assertEq(held, hook.bought(round, alice));
        vm.prank(alice);
        gameToken.transfer(carol, 1); // sold a little after settlement
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.MustHoldToClaim.selector); // neither prize goes out
        hook.claim(round);
        (,,,, bool[3] memory claimed,,,, bool kingClaimed) = hook.result(round);
        assertFalse(claimed[1]);
        assertFalse(kingClaimed);
        vm.prank(carol);
        gameToken.transfer(alice, 1); // bought back
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(round);
        assertGt(alice.balance, before);
    }

    function test_kingMustHoldToClaim() public {
        uint256 round = _kingNotFirst(true); // alice King only
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        uint256 held = gameToken.balanceOf(alice);
        vm.prank(alice);
        gameToken.transfer(bob, held); // sold everything after settlement
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.MustHoldToClaim.selector);
        hook.claim(round);
        vm.prank(bob);
        gameToken.transfer(alice, held); // bought back within the window
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(round);
        assertEq(alice.balance - before, _kingPrize(round));
    }

    function test_kingPrizeForfeitsPartly() public {
        uint256 round = _kingNotFirst(false);
        uint256 total = hook.pot(round);
        uint256 owed = hook.bought(round, alice);
        uint256 sold = owed / 4;
        vm.prank(alice);
        gameToken.transfer(carol, sold); // sold 25% of the round's buys
        vm.warp(_settleTime(round));
        uint256 nextBefore = hook.pot(round + 1);
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,,,, uint256 kingPrize,) = hook.result(round);
        uint256 keptRank = _bps(total, 2000) * (owed - sold) / owed;
        uint256 keptKing = _bps(total, 800) * (owed - sold) / owed;
        assertEq(prize[1], keptRank);
        assertEq(kingPrize, keptKing);
        assertEq(prize[0], _bps(total, 4000)); // bob kept everything
        assertEq(
            hook.pot(round + 1) - nextBefore,
            total - _bps(total, 4000) - keptRank - keptKing - _bps(total, 1000) - _bps(total, 700)
        );
        assertEq(hook.heldToClaim(round, alice), owed - sold); // what she held at settlement
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        hook.claim(round);
        assertEq(alice.balance - aliceBefore, keptRank + keptKing);
    }

    function test_kingWhoSoldEverythingGetsNothing() public {
        uint256 round = _kingNotFirst(true);
        uint256 total = hook.pot(round);
        vm.startPrank(alice);
        gameToken.transfer(carol, gameToken.balanceOf(alice));
        vm.stopPrank();
        vm.warp(_settleTime(round));
        uint256 nextBefore = hook.pot(round + 1);
        hook.settle(round, 100);
        (address s,) = _kingOf(round);
        assertEq(s, alice);
        assertEq(_kingPrize(round), 0);
        assertEq(
            hook.pot(round + 1) - nextBefore,
            total - _bps(total, 4000) - _bps(total, 2000) - _bps(total, 1000) - _bps(total, 1000) - _bps(total, 700)
        );
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        hook.claim(round);
    }

    function test_unclaimedKingPrizeDeadlineAndSweep() public {
        uint256 round = _kingNotFirst(true); // alice King only, never claims
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        assertEq(hook.claimDeadline(round), vm.getBlockTimestamp() + 7 days);
        uint256 kingPrize = _kingPrize(round);
        vm.prank(bob);
        hook.claim(round);
        vm.prank(carol);
        hook.claim(round);
        vm.prank(dave);
        hook.claim(round);

        vm.warp(hook.claimDeadline(round));
        vm.expectRevert(SherwoodV2.ClaimWindowOpen.selector);
        hook.sweepUnclaimed(round);
        vm.warp(hook.claimDeadline(round) + 1);
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.ClaimWindowClosed.selector);
        hook.claim(round);
        uint256 current = hook.currentRound();
        uint256 potBefore = hook.pot(current);
        hook.sweepUnclaimed(round);
        assertEq(hook.pot(current) - potBefore, kingPrize); // the claimed top three aren't swept
        (,,,,,,,, bool kingClaimed) = hook.result(round);
        assertTrue(kingClaimed);
    }

    function test_sweepTakesRankAndKingLeftUnclaimed() public {
        uint256 round = _kingNotFirst(false); // alice #2 and King; bob #1
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,,,, uint256 kingPrize,) = hook.result(round);
        vm.prank(bob);
        hook.claim(round);
        vm.warp(hook.claimDeadline(round) + 1);
        uint256 current = hook.currentRound();
        uint256 potBefore = hook.pot(current);
        hook.sweepUnclaimed(round);
        assertEq(hook.pot(current) - potBefore, prize[1] + kingPrize);
    }

    function test_referrerTakesFivePercentOfKingPrize() public {
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY); // the referrer plays this round
        uint256 round = _round();
        _buyRef(alice, 0.01 ether, SherwoodV2.Move.BUY, carol); // alice 11, #1
        vm.warp(hook.roundEnd(round) - 100);
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY);
        _buy(dave, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(makeAddr("erin"), 0.02 ether, SherwoodV2.Move.BUY); // alice 4th: she wins only as King
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        (, address[3] memory top,,,, address s,, uint256 kingPrize,) = hook.result(round);
        assertEq(s, alice);
        assertTrue(top[0] != alice && top[1] != alice && top[2] != alice);
        assertEq(hook.referralEarnings(carol), kingPrize * 5 / 100);
    }

    // ── Buyback ─────────────────────────────────────────────────────────────────

    function test_buybackSwapsInOtherPoolAndBurns() public {
        uint256 round = _round();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        uint256 reserve = hook.buybackReserve();
        assertGt(reserve, 0);

        vm.expectRevert(SherwoodV2.NotOperator.selector);
        hook.buybackAndBurn(reserve, 0);

        uint256 deadBefore = gameToken.balanceOf(DEAD);
        vm.prank(owner);
        hook.buybackAndBurn(reserve, 1);
        assertGt(gameToken.balanceOf(DEAD), deadBefore);
        assertEq(hook.buybackReserve(), 0);
    }

    /// The burn pool is fixed at deployment to the existing ETH/token 1% pool: nobody, the owner
    /// included, can point the buyback reserve anywhere else (a pool with a hook could take the ETH).
    function test_buybackPoolIsFixedToTheOnePercentPoolWithNoSetter() public {
        PoolKey memory k = hook.buybackPool();
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), address(gameToken));
        assertEq(k.fee, 10_000);
        assertEq(k.tickSpacing, 100);
        assertEq(address(k.hooks), address(0));
        assertTrue(PoolId.unwrap(k.toId()) != PoolId.unwrap(hook.poolId()));
        vm.prank(owner);
        (bool ok,) = address(hook)
            .call(abi.encodeWithSignature("setBuybackPool((address,address,uint24,int24,address))", gameKey));
        assertFalse(ok, "the setter is gone");
    }

    function test_recentPlayersMostRecentFirst() public {
        _buy(alice, 0.001 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.001 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        address[] memory r = hook.recentPlayers(_round());
        assertEq(r.length, 3);
        assertEq(r[0], carol);
        assertEq(r[2], alice);
        for (uint256 i; i < 12; ++i) {
            _buy(dave, 0.001 ether, SherwoodV2.Move.BUY);
        }
        assertEq(hook.recentPlayers(_round()).length, 10);
    }

    function test_onlyOneGamePool() public {
        vm.expectRevert();
        initPool(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(gameToken)), IHooks(address(hook)), 500, SQRT_PRICE_1_1
        );
    }

    function test_fundPotSeedsCurrentAndFutureRounds() public {
        uint256 round = _round();
        hook.fundPot{value: 0.1 ether}(round);
        hook.fundPot{value: 0.2 ether}(round + 3);
        assertEq(hook.pot(round), 0.1 ether);
        assertEq(hook.pot(round + 3), 0.2 ether);
        vm.warp(vm.getBlockTimestamp() + 20 hours);
        vm.expectRevert(SherwoodV2.RoundPassed.selector);
        hook.fundPot{value: 1}(round);
    }

    /// Review (low): a round too far ahead could never be settled, stranding its seed.
    function test_fundPotRejectsRoundsTooFarAhead() public {
        uint256 round = _round();
        hook.fundPot{value: 1}(round + 365);
        assertEq(hook.pot(round + 365), 1);
        vm.expectRevert(SherwoodV2.RoundPassed.selector);
        hook.fundPot{value: 1}(round + 366);
        vm.expectRevert(SherwoodV2.RoundPassed.selector);
        hook.fundPot{value: 1}(type(uint256).max);
    }

    /// Review (low): `settle(round, type(uint256).max)` means "all remaining" and must not overflow.
    function test_settleAllRemainingWithMax() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round) + 1);
        assertFalse(hook.settle(round, 1));
        assertTrue(hook.settle(round, type(uint256).max));
        (bool settled, address[3] memory top,,,,,,,) = hook.result(round);
        assertTrue(settled);
        assertEq(top[0], alice);
        assertEq(top[1], bob);
    }

    /// Review (low): a referrer word that isn't a clean address is ignored; the swap never reverts over it.
    function test_dirtyReferrerWordIsIgnoredNotAReasonToRevert() public {
        _swapIn(gameKey, alice, 0.01 ether, abi.encode(uint256(0), bytes32(uint256(1) << 200)));
        assertEq(hook.points(_round(), alice), 10);
        assertEq(hook.referrerOf(alice), address(0));
        // A clean referrer in the same slot still works.
        _buyRef(bob, 0.01 ether, SherwoodV2.Move.BUY, carol);
        assertEq(hook.referrerOf(bob), carol);
    }

    /// Review (low): a flip never costs the pot more than its own buy paid in. At a Dice fee above the
    /// buy's 5% the move scores as a buy and keeps its flip charge.
    function test_flipScoresAsBuyWhenDiceFeeExceedsTheBuysPotShare() public {
        uint256 round = _round();
        hook.fundPot{value: 0.01 ether}(round);
        dice.setFee(0.0005 ether); // = MAX_DICE_FEE, so only the new bound applies
        uint256 before = hook.pot(round);
        _buy(alice, 0.001 ether, SherwoodV2.Move.FLIP); // pays 0.00005 ETH in; the fee would take 0.0005
        assertEq(hook.pot(round), before + 0.00005 ether, "the pot never shrinks because of a buy");
        assertEq(hook.points(round, alice), 1);
        assertEq(hook.pendingFlips(round), 0);
        assertEq(hook.flipsLeft(alice), 6);
        // A buy whose 5% covers the fee still flips.
        _buy(bob, 0.01 ether, SherwoodV2.Move.FLIP); // 0.0005 ETH in
        assertEq(hook.pendingFlips(round), 1);
    }

    function test_plainEthTransferLandsInCurrentPot() public {
        (bool ok,) = address(hook).call{value: 0.05 ether}("");
        assertTrue(ok);
        assertEq(hook.pot(_round()), 0.05 ether);
    }

    function test_seededPotPaysTheWinner() public {
        uint256 round = _round();
        hook.fundPot{value: 1 ether}(round);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        uint256 total = hook.pot(round);
        vm.warp(hook.roundEnd(round) + 16 minutes);
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,,,,,) = hook.result(round);
        assertEq(prize[0], _bps(total, 4000));
    }

    // ── Holding rules ───────────────────────────────────────────────────────

    function test_buysAreRecordedPerRound() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        assertGt(hook.bought(_round(), alice), 0);
        assertEq(hook.bought(_round(), alice), gameToken.balanceOf(alice));
    }

    function test_holdingRuleUsesBalanceAtSettlement() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        uint256 held = gameToken.balanceOf(alice);
        vm.prank(alice);
        gameToken.transfer(bob, held); // "sold" somewhere else during the round...
        vm.warp(_settleTime(round) - 1);
        vm.prank(bob);
        gameToken.transfer(alice, held); // ...and bought back before settlement: counts as held
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        uint256 total = hook.pot(round);
        assertEq(hook.heldToClaim(round, alice), held);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(round);
        assertEq(alice.balance - before, _bps(total, 4000) + _bps(total, 800));
        vm.prank(alice);
        gameToken.transfer(bob, held); // selling after claiming changes nothing
        assertEq(alice.balance - before, _bps(total, 4000) + _bps(total, 800));
    }

    function test_winnerMustHoldThatRoundsBuysToClaim() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        uint256 held = gameToken.balanceOf(alice);

        vm.prank(alice);
        gameToken.transfer(bob, held); // "sold" somewhere else
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.MustHoldToClaim.selector);
        hook.claim(round);

        vm.prank(bob);
        gameToken.transfer(alice, held); // bought back
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(round);
        assertGt(alice.balance, before);
    }

    function test_partialWinnerMustKeepWhatTheyHeldToClaim() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        uint256 owed = hook.bought(round, alice);
        vm.prank(alice);
        gameToken.transfer(carol, owed / 2); // sold half before settlement
        vm.warp(_settleTime(round));
        hook.settle(round, 100);

        assertEq(hook.heldToClaim(round, alice), owed - owed / 2);
        assertEq(hook.heldToClaim(round, bob), 0);
        vm.prank(alice);
        gameToken.transfer(carol, 1); // sold a little more after settlement
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.MustHoldToClaim.selector);
        hook.claim(round);

        vm.prank(carol);
        gameToken.transfer(alice, 1); // back to what she held at settlement
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim(round);
        assertGt(alice.balance, before);
    }

    function test_holderBonusForKeepingLastRoundsBuys() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // 10
        assertFalse(hook.holderBonusActive(round, alice));
        _nextRound(round);
        assertTrue(hook.holderBonusActive(round + 1, alice));
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // 10 x 1.25
        assertEq(hook.points(round + 1, alice), 12);
        _buy(bob, 0.1 ether, SherwoodV2.Move.BUY); // no history: plain 100
        assertEq(hook.points(round + 1, bob), 100);
    }

    function test_holderBonusMaxesAt125Points() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _nextRound(round);
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(round + 1, alice), 125);
    }

    function test_noHolderBonusAfterSellingLastRoundsBuys() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        uint256 held = gameToken.balanceOf(alice);
        vm.prank(alice);
        gameToken.transfer(bob, held / 2);
        _nextRound(round);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(round + 1, alice), 10);
    }

    function test_holderBonusNeedsLastRoundsPlay() public {
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundStart(round + 2) + 1); // skipped a round
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(round + 2, alice), 10);
    }

    function test_holderBonusDoesNotRaiseStealShare() public {
        uint256 round = _round();
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        _nextRound(round);
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // alice 50
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL); // bob 12 with bonus; steal share from his 10-point size: 22% of 50 = 11
        assertEq(hook.points(round + 1, alice), 39);
        assertEq(hook.points(round + 1, bob), 23);
    }

    // ── Audit fixes (v1, carried over) ──────────────────────────────────────

    function test_buyStoppedByPriceLimitReverts() public {
        // Scored on the declared ETH, so a buy must spend all of it (audit H-1).
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert();
        swapRouter.swap{value: 0.1 ether}(
            gameKey,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: SQRT_PRICE_1_1 - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(SherwoodV2.Move.BUY))
        );
        assertEq(hook.points(_round(), alice), 0);
    }

    function test_settleWaitsForPendingFlips() public {
        // A reveal between settlement batches would change scores already ranked (audit M-1).
        uint256 round = _round();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.06 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.1 ether, SherwoodV2.Move.FLIP);
        assertEq(hook.pendingFlips(round), 1);
        vm.warp(_settleTime(round));
        vm.expectRevert(SherwoodV2.FlipsPending.selector);
        hook.settle(round, 1);
        dice.reveal(1, bytes32(uint256(3))); // alice loses: 0, bob 160
        assertEq(hook.pendingFlips(round), 0);
        hook.settle(round, 1);
        assertTrue(hook.settle(round, 1));
        (, address[3] memory top, int256[3] memory topPoints,,, address s,,,) = hook.result(round);
        assertEq(top[0], bob);
        assertEq(topPoints[0], 160);
        assertEq(top[1], address(0)); // alice at 0 doesn't place
        assertEq(s, alice); // but she held #1 for the whole round
    }

    function test_expiredFlipsUnblockSettlement() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.FLIP);
        vm.warp(_settleTime(round));
        vm.expectRevert(SherwoodV2.FlipsPending.selector);
        hook.settle(round, 10);
        hook.expireFlip(1);
        assertTrue(hook.settle(round, 10));
        (, address[3] memory top,,,,,,,) = hook.result(round);
        assertEq(top[0], alice);
    }

    function test_flipWinScalesWithBuySizeNotBonus() public {
        // 0.08 ETH with the holder bonus: stake 100, multiplier from 80 base points = 2.8x (audit L-1).
        uint256 round = _round();
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _nextRound(round);
        _buy(alice, 0.08 ether, SherwoodV2.Move.FLIP);
        dice.reveal(1, bytes32(uint256(2)));
        assertEq(hook.points(round + 1, alice), 280);
    }

    function test_robinHoodCanPayTheMover() public {
        // Accepted design: if you're the lowest of the last 10, Robin Hood pays you (chained moves).
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // leader, 100
        _buy(bob, 0.001 ether, SherwoodV2.Move.BUY); // bob 1
        _buy(bob, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD); // bob 11, the lowest recent: 12.3% of 100 → bob
        assertEq(hook.points(_round(), alice), 88);
        assertEq(hook.points(_round(), bob), 23);
    }

    function test_diceFeeAboveCapScoresAsBuy() public {
        dice.setFee(0.001 ether);
        hook.fundPot{value: 1 ether}(_round());
        _buy(bob, 0.02 ether, SherwoodV2.Move.FLIP);
        assertEq(hook.points(_round(), bob), 20); // plain buy, nothing sent to Dice
        assertEq(hook.pendingFlips(_round()), 0);
        assertEq(address(dice).balance, 0);
    }

    function test_diceRefundFromAnywhereGoesToBuybackReserve() public {
        _buy(alice, 0.02 ether, SherwoodV2.Move.FLIP);
        uint256 before = hook.buybackReserve();
        dice.refundRequest(address(0), 1); // someone else triggers the refund on Dice
        assertEq(hook.buybackReserve() - before, dice.fee());
    }

    function test_lateSettlementStillGivesSevenDaysToClaim() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundEnd(round) + 8 days); // nobody settled for 8 days
        hook.settle(round, 100);
        assertEq(hook.claimDeadline(round), vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(SherwoodV2.ClaimWindowOpen.selector);
        hook.sweepUnclaimed(round);
        uint256 before = alice.balance;
        vm.warp(hook.claimDeadline(round)); // the last second still counts
        vm.prank(alice);
        hook.claim(round);
        assertGt(alice.balance, before);
    }

    function test_claimDeadlineFromRoundEndWhenSettledOnTime() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        assertEq(hook.claimDeadline(round), _settleTime(round) + 7 days); // settledAt > roundEnd
        assertEq(hook.claimDeadline(round + 5), hook.roundEnd(round + 5) + 7 days); // unsettled: from the end
    }

    // ── Forfeits and referrals ──────────────────────────────────────────────

    function test_winnerWhoSoldEverythingForfeitsAtSettlement() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // #1 and King
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY); // #2
        uint256 total = hook.pot(round);
        vm.startPrank(alice);
        gameToken.transfer(carol, gameToken.balanceOf(alice)); // alice sold all of this round's buys
        vm.stopPrank();
        vm.warp(_settleTime(round));
        uint256 nextBefore = hook.pot(round + 1);
        hook.settle(round, 100);
        (, address[3] memory top,, uint256[3] memory prize,,,,,) = hook.result(round);
        assertEq(top[0], alice);
        assertEq(prize[0], 0);
        assertEq(_kingPrize(round), 0);
        assertEq(prize[1], _bps(total, 2000));
        // #1's 40%, the King's 8%, the empty #3 slot's 10% and the 5% rollover all land in the next pot
        assertEq(hook.pot(round + 1) - nextBefore, total - _bps(total, 2000) - _bps(total, 1000) - _bps(total, 700));
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        hook.claim(round);
    }

    function test_winnerWhoSoldPartForfeitsThatShare() public {
        uint256 round = _round();
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // #1 and King
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY); // #2
        uint256 total = hook.pot(round);
        uint256 owed = hook.bought(round, alice);
        uint256 sold = owed / 5;
        vm.prank(alice);
        gameToken.transfer(carol, sold); // sold 20% of this round's buys
        vm.warp(_settleTime(round));
        uint256 nextBefore = hook.pot(round + 1);
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,,,,,) = hook.result(round);
        uint256 share = _bps(total, 4000);
        uint256 kept = share * (owed - sold) / owed;
        uint256 keptKing = _bps(total, 800) * (owed - sold) / owed;
        assertEq(prize[0], kept);
        assertApproxEqAbs(prize[0], share * 80 / 100, 1);
        assertEq(_kingPrize(round), keptKing);
        assertEq(prize[1], _bps(total, 2000));
        // the forfeited 20% of alice's prizes rolls over with the rest
        assertEq(
            hook.pot(round + 1) - nextBefore,
            total - kept - keptKing - _bps(total, 2000) - _bps(total, 1000) - _bps(total, 700)
        );
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        hook.claim(round);
        assertEq(alice.balance - aliceBefore, kept + keptKing);
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        hook.claim(round);
    }

    function test_referrerIsSetOnceAndNeverChanges() public {
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        _buyRef(alice, 0.01 ether, SherwoodV2.Move.BUY, carol);
        assertEq(hook.referrerOf(alice), carol);
        _buyRef(alice, 0.01 ether, SherwoodV2.Move.BUY, dave);
        assertEq(hook.referrerOf(alice), carol);
    }

    function test_cannotReferYourselfOrTheOneWhoReferredYou() public {
        _buyRef(alice, 0.01 ether, SherwoodV2.Move.BUY, alice);
        assertEq(hook.referrerOf(alice), address(0));
        _buyRef(bob, 0.01 ether, SherwoodV2.Move.BUY, alice);
        _buyRef(alice, 0.01 ether, SherwoodV2.Move.BUY, bob);
        assertEq(hook.referrerOf(alice), address(0));
    }

    function test_referrerEarnsTenPercentPointsOnlyInRoundsTheyPlayed() public {
        _buyRef(alice, 0.05 ether, SherwoodV2.Move.BUY, carol); // alice 55 (welcome +10%); carol hasn't played: nothing
        assertEq(hook.points(_round(), carol), 0);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY); // carol 1
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // alice 55 more, carol +5
        assertEq(hook.points(_round(), carol), 6);
        assertEq(hook.points(_round(), alice), 110); // nothing taken from alice
    }

    function test_referrerTakesFivePercentOfPrize() public {
        uint256 round = _round();
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        _buyRef(alice, 0.05 ether, SherwoodV2.Move.BUY, carol); // #1 and King
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        (,,, uint256[3] memory prize,,,,,) = hook.result(round);
        uint256 share = _bps(total, 4000);
        uint256 kingShare = _bps(total, 800);
        uint256 cut = share * 5 / 100 + kingShare * 5 / 100;
        assertEq(hook.referralEarnings(carol), cut);
        assertEq(prize[0], share); // the winner keeps it all; the 5% comes from the rollover
        assertEq(_kingPrize(round), kingShare);

        uint256 before = carol.balance;
        vm.prank(carol);
        hook.claimReferral();
        assertEq(carol.balance - before, cut);
        vm.prank(carol);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        hook.claimReferral();
    }

    function test_noPrizeShareIfReferrerSkippedTheRound() public {
        uint256 round = _round();
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        _buyRef(alice, 0.05 ether, SherwoodV2.Move.BUY, carol);
        _nextRound(round);
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // carol didn't play this round
        vm.warp(_settleTime(round + 1));
        hook.settle(round + 1, 100);
        (,,, uint256[3] memory prize,,,,,) = hook.result(round + 1);
        assertEq(prize[0], _bps(hook.pot(round + 1), 4000));
        assertEq(hook.referralEarnings(carol), 0);
    }

    function test_referralShareComesOutOfTheRollover() public {
        uint256 round = _round();
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY); // carol #2
        _buyRef(alice, 0.05 ether, SherwoodV2.Move.BUY, carol); // alice #1 and King
        _buy(bob, 0.0005 ether, SherwoodV2.Move.BUY); // too small to score
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        uint256 before = hook.pot(round + 1);
        hook.settle(round, 100);
        uint256 cut = _bps(total, 4000) * 5 / 100 + _bps(total, 800) * 5 / 100;
        // #1 40% + #2 20% + King 8% awarded in full; 10% + 7% host buyback; empty #3 + rollover, minus carol's cut, roll on
        assertEq(
            hook.pot(round + 1) - before,
            total - _bps(total, 4000) - _bps(total, 2000) - _bps(total, 800) - _bps(total, 1000) - _bps(total, 700)
                - cut
        );
    }

    function test_welcomeBonusOnlyInTheFirstRound() public {
        uint256 round = _round();
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        _buyRef(alice, 0.02 ether, SherwoodV2.Move.BUY, carol); // 20 x 1.1
        assertEq(hook.points(round, alice), 22);
        assertTrue(hook.welcomeBonusActive(round, alice));
        vm.prank(alice);
        gameToken.transfer(dave, 1); // no holder bonus next round either
        _nextRound(round);
        assertFalse(hook.welcomeBonusActive(round + 1, alice));
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(round + 1, alice), 20);
    }

    function test_noWelcomeBonusWithoutAReferrer() public {
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(_round(), alice), 20);
    }

    function test_referrerOnlyOnTheFirstPlay() public {
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // played without a referrer
        _buyRef(alice, 0.01 ether, SherwoodV2.Move.BUY, carol); // too late
        assertEq(hook.referrerOf(alice), address(0));
        assertEq(hook.points(_round(), alice), 20);
    }

    function test_referredPlayerGetsHolderBonusNextRound() public {
        // A referred player who comes back the next round still holding: holder bonus only.
        uint256 round = _round();
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        _buyRef(alice, 0.02 ether, SherwoodV2.Move.BUY, carol);
        _nextRound(round);
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY); // 20 x 1.25
        assertEq(hook.points(round + 1, alice), 25);
    }

    function test_onlyTheOwnerCanCreateThePool() public {
        address hookAddr = address(FLAGS | (uint160(0x5151) << 144));
        _deployHook(hookAddr, GENESIS);
        PoolKey memory key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(gameToken)), 500, 10, IHooks(hookAddr));
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.prank(owner);
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(PoolId.unwrap(SherwoodV2(payable(hookAddr)).poolId()), PoolId.unwrap(key.toId()));
    }

    function test_samePermissionsAsV1() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertEq(FLAGS, 0x20CC);
    }

    // ── Host token ($PFWA hosting another token's game) ─────────────────────

    function test_hostWiring() public view {
        assertEq(Currency.unwrap(hook.token()), address(gameToken));
        assertEq(Currency.unwrap(hook.host()), address(hostToken));
        assertEq(hook.hostHolderMin(), HOST_MIN);
        assertTrue(hook.hostEnabled());
    }

    function test_hostBurnReserveAccruesSevenPercent() public {
        uint256 round = _round();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // #1 and King
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        uint256 rollover = total - _bps(total, 4000) - _bps(total, 800) - _bps(total, 1000) - _bps(total, 700);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RoundSettled(
            round,
            [alice, address(0), address(0)],
            alice,
            [_bps(total, 4000), 0, 0, _bps(total, 800)],
            _bps(total, 1000),
            rollover,
            _bps(total, 700)
        );
        hook.settle(round, 100);
        assertEq(hook.hostBuybackReserve(), _bps(total, 700));
        assertEq(hook.buybackReserve(), _bps(total, 1000));
        assertEq(hook.pot(round + 1), rollover);

        // It adds up round after round.
        _buy(bob, 0.05 ether, SherwoodV2.Move.BUY);
        uint256 total2 = hook.pot(round + 1);
        vm.warp(_settleTime(round + 1));
        hook.settle(round + 1, 100);
        assertEq(hook.hostBuybackReserve(), _bps(total, 700) + _bps(total2, 700));
    }

    /// The host burn pool is fixed at deployment to the ETH/$PFWA holder pool (dynamic fee, tick
    /// spacing 200, Hookr's holder hook), with the host token from the constructor: no setter.
    function test_hostBuybackPoolIsFixedToTheHolderPoolWithNoSetter() public {
        PoolKey memory k = hook.hostBuybackPool();
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), address(hostToken));
        assertEq(k.fee, 0x800000);
        assertEq(k.tickSpacing, 200);
        assertEq(address(k.hooks), 0xb914f955294799de4b891bd2EA8AF628Fa1c68CC);
        vm.prank(owner);
        (bool ok,) =
            address(hook).call(abi.encodeWithSignature("setHostBuybackPool((address,address,uint24,int24,address))", k));
        assertFalse(ok, "the setter is gone");
    }

    function test_buybackAndBurnHostBurnsHostToDead() public {
        uint256 round = _round();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        vm.warp(_settleTime(round));
        hook.settle(round, 100);
        uint256 reserve = hook.hostBuybackReserve();
        uint256 gameReserve = hook.buybackReserve();
        assertGt(reserve, 0);

        vm.expectRevert(SherwoodV2.NotOperator.selector);
        hook.buybackAndBurnHost(reserve, 0);

        vm.prank(owner);
        vm.expectRevert(SherwoodV2.TooLittleOut.selector);
        hook.buybackAndBurnHost(reserve, type(uint256).max);

        address op = makeAddr("operator");
        vm.prank(owner);
        hook.setOperator(op);
        uint256 deadHost = hostToken.balanceOf(DEAD);
        uint256 deadGame = gameToken.balanceOf(DEAD);
        uint256 hookBefore = address(hook).balance;
        vm.recordLogs();
        vm.prank(op);
        hook.buybackAndBurnHost(reserve * 10, 1); // asks for more than the reserve: burns the reserve
        uint256 burned = hostToken.balanceOf(DEAD) - deadHost;
        assertGt(burned, 0);
        assertEq(gameToken.balanceOf(DEAD), deadGame); // the game token's burn is separate
        assertEq(hook.hostBuybackReserve(), 0);
        assertEq(hook.buybackReserve(), gameReserve);
        assertEq(hookBefore - address(hook).balance, reserve);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("HostBuybackBurned(uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                (uint256 ethIn, uint256 hostBurned) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(ethIn, reserve);
                assertEq(hostBurned, burned);
                found = true;
            }
        }
        assertTrue(found);

        // The game burn still runs on its own pool and reserve.
        vm.prank(op);
        hook.buybackAndBurn(gameReserve, 1);
        assertGt(gameToken.balanceOf(DEAD), deadGame);
        assertEq(hostToken.balanceOf(DEAD) - deadHost, burned);
        assertEq(hook.buybackReserve(), 0);
    }

    function test_hostBonusAtTheThreshold() public {
        uint256 round = _round();
        hostToken.transfer(alice, HOST_MIN - 1);
        assertFalse(hook.hostBonusActive(alice));
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY); // one token short: plain 20
        assertEq(hook.points(round, alice), 20);

        hostToken.transfer(alice, 1);
        assertTrue(hook.hostBonusActive(alice));
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY); // 20 x 1.1
        assertEq(hook.points(round, alice), 42);

        vm.prank(alice);
        hostToken.transfer(bob, 1); // checked at every play
        assertFalse(hook.hostBonusActive(alice));
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(round, alice), 62);
    }

    function test_hostBonusStacksWithTheOtherBonuses() public {
        uint256 round = _round();
        hostToken.transfer(alice, HOST_MIN);
        hostToken.transfer(bob, HOST_MIN);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        _buyRef(alice, 0.02 ether, SherwoodV2.Move.BUY, carol); // 20 x (1 + 10% welcome + 10% host)
        assertEq(hook.points(round, alice), 24);
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        _nextRound(round);
        _buy(bob, 0.1 ether, SherwoodV2.Move.BUY); // 100 x (1 + 25% holder + 10% host)
        assertEq(hook.points(round + 1, bob), 135);
    }

    function test_hostSameAsGameTokenTurnsHostFeaturesOff() public {
        address hookAddr = address(FLAGS | (uint160(0x7171) << 144));
        _deployHook(hookAddr, GENESIS, address(gameToken)); // $PFWA's own game
        SherwoodV2 own = SherwoodV2(payable(hookAddr));
        PoolKey memory key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(gameToken)), 3000, 60, IHooks(hookAddr));
        vm.prank(owner);
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
        assertFalse(own.hostEnabled());
        // One burn, through the holder pool of the (host = game) token.
        PoolKey memory burn = own.buybackPool();
        assertEq(Currency.unwrap(burn.currency1), address(gameToken));
        assertEq(burn.fee, hostKey.fee);
        assertEq(burn.tickSpacing, hostKey.tickSpacing);
        assertEq(address(burn.hooks), address(hostKey.hooks));

        uint256 round = own.currentRound();
        gameToken.mint(alice, HOST_MIN * 10); // holds plenty of the host (= game) token
        assertFalse(own.hostBonusActive(alice));
        _swapIn(key, alice, 0.05 ether, abi.encode(uint256(SherwoodV2.Move.BUY)));
        assertEq(own.points(round, alice), 50); // no host bonus
        uint256 total = own.pot(round);
        vm.warp(_settleTime(round));
        own.settle(round, 100);
        // The host's 7% burns with the game token's 10%; the rollover is unchanged.
        assertEq(own.buybackReserve(), _bps(total, 1000) + _bps(total, 700));
        assertEq(own.hostBuybackReserve(), 0);
        assertEq(
            own.pot(round + 1), total - _bps(total, 4000) - _bps(total, 800) - _bps(total, 1000) - _bps(total, 700)
        );
    }

    function test_referralWorstCaseKeepsRolloverAboveZero() public {
        // All four prizes go to referred players whose referrer played: the largest cut there is.
        uint256 round = _round();
        address ref = makeAddr("ref");
        _buy(ref, 0.001 ether, SherwoodV2.Move.BUY);
        _buyRef(alice, 0.01 ether, SherwoodV2.Move.BUY, ref); // alice #1 for most of the round: King
        vm.warp(hook.roundEnd(round) - 100);
        _buyRef(bob, 0.05 ether, SherwoodV2.Move.BUY, ref);
        _buyRef(carol, 0.04 ether, SherwoodV2.Move.BUY, ref);
        _buyRef(dave, 0.03 ether, SherwoodV2.Move.BUY, ref); // alice drops out of the top three
        vm.deal(address(this), 10 ether);
        hook.fundPot{value: 7 ether + 3}(round); // a big pot with awkward rounding
        uint256 total = hook.pot(round);
        vm.warp(_settleTime(round));
        uint256 before = hook.pot(round + 1);
        hook.settle(round, 100);

        (, address[3] memory top,, uint256[3] memory prize,, address king,, uint256 kingPrize,) = hook.result(round);
        assertEq(top[0], bob);
        assertEq(top[1], carol);
        assertEq(top[2], dave);
        assertEq(king, alice);
        uint256 prizes = prize[0] + prize[1] + prize[2] + kingPrize;
        assertEq(prizes, _bps(total, 4000) + _bps(total, 2000) + _bps(total, 1000) + _bps(total, 800));
        uint256 cuts = hook.referralEarnings(ref);
        assertEq(cuts, prize[0] * 5 / 100 + prize[1] * 5 / 100 + prize[2] * 5 / 100 + kingPrize * 5 / 100);
        uint256 rolled = hook.pot(round + 1) - before;
        assertEq(rolled, total - prizes - cuts - _bps(total, 1000) - _bps(total, 700));
        // 5% rollover - 3.9% in cuts: about 1.1% of the pot still rolls on.
        assertApproxEqAbs(rolled, _bps(total, 110), 10);
        // And everything owed is covered.
        assertGe(
            address(hook).balance,
            prizes + cuts + hook.buybackReserve() + hook.hostBuybackReserve() + hook.pot(round + 1)
        );
    }

    // ── Dice callback gas (audit: high) ─────────────────────────────────────

    function _fillBoard(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _buy(address(uint160(0x1000 + i)), 0.001 ether, SherwoodV2.Move.BUY);
        }
    }

    /// Audit (high): a lost flip by #1 marks the cached leader stale, and the callback used to rescan the
    /// whole board inside FLIP_CALLBACK_GAS. With 20+ players Dice dropped the reveal, and the leader's
    /// loss became a refund at expiry. A big board now closes the reign in the callback and leaves the
    /// rescan to the next play, which runs with its caller's gas.
    function test_leaderLostFlipCallbackFitsDiceGasLimitOnABigBoard() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100, #1
        _fillBoard(200);
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY); // bob 2, the previous player a loss pays
        _buy(alice, 0.05 ether, SherwoodV2.Move.FLIP); // stake 50, sequence 1
        assertEq(hook.pendingFlips(0), 1);
        vm.warp(t0 + 60);
        vm.cool(address(hook)); // the reveal is its own transaction: every slot it reads is cold
        (bool ok, uint256 gasUsed) = dice.tryReveal(1, bytes32(uint256(1))); // odd: a loss
        emit log_named_uint("leader loss on 202 players, callback gas", gasUsed);
        assertTrue(ok, "the callback must fit FLIP_CALLBACK_GAS");
        assertLt(gasUsed, 200_000);
        assertEq(hook.points(0, alice), 50);
        assertEq(hook.points(0, bob), 52);
        assertEq(hook.pendingFlips(0), 0);
        // The reign was closed at the reveal: alice keeps the 60 seconds she really held #1 and #1 is
        // unknown until the board is rescanned.
        assertEq(hook.reignHolder(0), address(1));
        assertEq(hook.reignOf(0, alice), 60);
        // The next play rescans first (bob is #1 with 52). Nothing changed since the reveal, so bob has
        // held #1 since then and his reign is credited back to it.
        vm.warp(t0 + 120);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        assertEq(hook.leader(0), bob);
        assertEq(hook.reignHolder(0), bob);
        vm.warp(t0 + 130);
        assertEq(hook.reignOf(0, bob), 70);
        assertEq(hook.reignOf(0, alice), 60);
        // The flip is resolved: it can't be expired into a refund any more.
        vm.warp(t0 + 11 minutes);
        vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
        hook.expireFlip(1);
    }

    /// The same loss on a board of MAX_CALLBACK_SCAN players is rescanned inside the callback, so the
    /// new #1 is found right away and no reign time is lost.
    function test_leaderLostFlipRescansASmallBoardInsideTheCallback() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100, #1
        _buy(carol, 0.06 ether, SherwoodV2.Move.BUY); // carol 60
        _fillBoard(9); // 12 players once bob joins
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY); // bob 2, previous
        _buy(alice, 0.05 ether, SherwoodV2.Move.FLIP); // stake 50
        assertEq(hook.playerCount(0), 12);
        vm.warp(t0 + 60);
        vm.cool(address(hook));
        (bool ok, uint256 gasUsed) = dice.tryReveal(1, bytes32(uint256(1)));
        emit log_named_uint("leader loss on 12 players, callback gas", gasUsed);
        assertTrue(ok);
        assertLt(gasUsed, 200_000);
        assertEq(hook.points(0, alice), 50);
        assertEq(hook.points(0, bob), 52);
        assertEq(hook.leader(0), carol); // the rescan corrected the cache (bob was credited above alice)
        assertEq(hook.reignHolder(0), carol);
        assertEq(hook.reignOf(0, alice), 60);
        vm.warp(t0 + 70);
        assertEq(hook.reignOf(0, carol), 10);
    }

    /// One player past the bound: the callback defers the rescan instead of running out of gas.
    function test_leaderLostFlipDefersTheRescanJustPastTheBound() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.06 ether, SherwoodV2.Move.BUY);
        _fillBoard(10); // 13 players once bob joins
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.05 ether, SherwoodV2.Move.FLIP);
        assertEq(hook.playerCount(0), 13);
        vm.cool(address(hook));
        (bool ok, uint256 gasUsed) = dice.tryReveal(1, bytes32(uint256(1)));
        emit log_named_uint("leader loss on 13 players, callback gas", gasUsed);
        assertTrue(ok);
        assertLt(gasUsed, 200_000);
        assertEq(hook.reignHolder(0), address(1)); // #1 unknown until the next play rescans and credits them back to here
        assertEq(hook.points(0, alice), 50);
        assertEq(hook.points(0, bob), 52);
    }

    /// #1 loses a flip on a board of more than 12 players and nobody plays again before the round ends:
    /// the rescan never runs, so settlement credits the unknown spell to the final #1.
    function test_settleCreditsTheFinalUnknownSpellToTheFinalLeader() public {
        uint256 start = vm.getBlockTimestamp();
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // alice 100, #1
        _buy(carol, 0.06 ether, SherwoodV2.Move.BUY); // carol 60
        _fillBoard(10);
        _buy(bob, 0.002 ether, SherwoodV2.Move.BUY);
        vm.warp(start + 1 hours);
        _buy(alice, 0.05 ether, SherwoodV2.Move.FLIP);
        dice.reveal(1, bytes32(uint256(1))); // alice loses 50: carol is #1, but nobody knows until a rescan
        uint256 spellStart = vm.getBlockTimestamp();
        assertEq(hook.reignHolder(0), address(1));
        assertEq(hook.points(0, alice), 50);

        vm.warp(_settleTime(0)); // no play after the reveal
        hook.settle(0, type(uint256).max);
        (,,,,, address king, uint256 kingReign,,) = hook.result(0);
        assertEq(king, carol);
        assertEq(kingReign, hook.roundEnd(0) - spellStart);
        assertEq(kingReign, hook.reignOf(0, carol));
        assertEq(hook.reignOf(0, alice), spellStart - start);
        assertEq(hook.reignHolder(0), carol);
    }

    /// The other callback paths on a big, cold board: a non-leader's loss, and a win that takes #1.
    function test_otherFlipOutcomesFitDiceGasLimitOnABigBoard() public {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _fillBoard(200);
        _buy(bob, 0.05 ether, SherwoodV2.Move.FLIP); // sequence 1: bob is not #1
        _buy(carol, 0.1 ether, SherwoodV2.Move.FLIP); // sequence 2: a win makes carol #1
        vm.cool(address(hook));
        (bool ok, uint256 gasUsed) = dice.tryReveal(1, bytes32(uint256(1)));
        emit log_named_uint("non-leader loss, callback gas", gasUsed);
        assertTrue(ok);
        vm.cool(address(hook));
        (ok, gasUsed) = dice.tryReveal(2, bytes32(uint256(2)));
        emit log_named_uint("win taking #1, callback gas", gasUsed);
        assertTrue(ok);
        assertEq(hook.points(0, carol), 300);
        assertEq(hook.reignHolder(0), carol);
    }

    // ── Gas notes ───────────────────────────────────────────────────────────

    function test_gas_reignUpkeep() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        uint256 g = gasleft();
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY); // no change at #1
        emit log_named_uint("buy, #1 unchanged", g - gasleft());
        g = gasleft();
        _buy(carol, 0.1 ether, SherwoodV2.Move.BUY); // takes #1
        emit log_named_uint("buy, #1 changes", g - gasleft());
        for (uint256 i; i < 200; ++i) {
            _buy(address(uint160(0x1000 + i)), 0.001 ether, SherwoodV2.Move.BUY);
        }
        g = gasleft();
        _sell(carol, 0.001 ether); // #1 sells: rescans 203 players
        emit log_named_uint("leader sell with 203 players (rescan)", g - gasleft());
    }
}
