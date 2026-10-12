// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SherwoodV2, IDiceEntropy} from "../src/SherwoodV2.sol";

/// Runs Sherwood v2 on a copy of Robinhood Chain: the real PoolManager, $PFWA, Dice
/// Protocol and the $PFWA holder pool (for the buyback). `hook` is $PFWA's own game (host
/// features off); the host tests deploy a second game for a stand-in token hosted by $PFWA.
contract SherwoodV2ForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant DICE = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    address constant DICE_PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    address constant ADMIN = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;
    address constant HOLDER_HOOK = 0xb914f955294799de4b891bd2EA8AF628Fa1c68CC;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant HOST_MIN = 100_000e18;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    SherwoodV2 hook;
    PoolKey gameKey;
    PoolKey holderKey;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    address player = makeAddr("player");

    function setUp() public {
        string memory rpc = vm.envOr("SHERWOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        swapRouter = new PoolSwapTest(MANAGER);
        lpRouter = new PoolModifyLiquidityTest(MANAGER);

        address hookAddr = address(FLAGS | (uint160(0x5454) << 144));
        deployCodeTo(
            "SherwoodV2.sol:SherwoodV2",
            abi.encode(
                MANAGER,
                Currency.wrap(PFWA),
                Currency.wrap(PFWA),
                HOST_MIN,
                IDiceEntropy(DICE),
                DICE_PROVIDER,
                ADMIN,
                block.timestamp - 1 hours
            ),
            hookAddr
        );
        hook = SherwoodV2(payable(hookAddr));

        holderKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(PFWA),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(HOLDER_HOOK)
        });
        (uint160 marketPrice, int24 marketTick,,) = MANAGER.getSlot0(holderKey.toId());

        // Start the game pool at the holder pool's live price.
        gameKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(PFWA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        vm.prank(ADMIN);
        MANAGER.initialize(gameKey, marketPrice);

        // One-sided $PFWA below the current tick: buys (ETH in) push the tick down into it.
        int24 upper = (marketTick / 60) * 60;
        if (upper > marketTick) upper -= 60;
        deal(PFWA, address(this), 10_000_000 ether);
        IERC20(PFWA).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            gameKey,
            ModifyLiquidityParams({tickLower: upper - 60 * 200, tickUpper: upper, liquidityDelta: 2e21, salt: 0}),
            ""
        );
    }

    receive() external payable {} // the LP router refunds unused ETH

    function _swapBuy(uint256 amount, SherwoodV2.Move move) internal {
        vm.deal(player, player.balance + amount);
        vm.prank(player, player);
        swapRouter.swap{value: amount}(
            gameKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(move))
        );
    }

    function test_forkV2_buyOnLivePoolManager() public {
        uint256 before = IERC20(PFWA).balanceOf(player);
        _swapBuy(0.01 ether, SherwoodV2.Move.BUY);
        assertEq(hook.points(hook.currentRound(), player), 10);
        assertGt(IERC20(PFWA).balanceOf(player) - before, 0);
        assertEq(hook.pot(hook.currentRound()), 0.0005 ether);
        emit log_named_uint("PFWA bought with 0.01 ETH", (IERC20(PFWA).balanceOf(player) - before) / 1e18);
    }

    function test_forkV2_flipRequestsRealDice() public {
        _swapBuy(0.02 ether, SherwoodV2.Move.FLIP);
        // The pot paid the live Dice fee; the flip waits for Dice's reveal.
        uint256 diceFee = IDiceEntropy(DICE).getFeeV2(DICE_PROVIDER, 200_000);
        assertEq(hook.pot(hook.currentRound()), 0.001 ether - diceFee);
        assertEq(hook.points(hook.currentRound(), player), 0);
    }

    function test_forkV2_buybackBurnsThroughHolderPool() public {
        uint256 round = hook.currentRound();
        _swapBuy(0.1 ether, SherwoodV2.Move.BUY);
        vm.warp(hook.roundEnd(round) + 15 minutes);
        hook.settle(round, 100);
        uint256 reserve = hook.buybackReserve();
        // $PFWA's own game: the host's 7% burns with the 10%.
        assertFalse(hook.hostEnabled());
        assertEq(hook.hostBuybackReserve(), 0);
        assertEq(reserve, (0.005 ether * 1000) / 10_000 + (0.005 ether * 700) / 10_000);
        vm.startPrank(ADMIN);
        hook.setBuybackPool(holderKey);
        uint256 deadBefore = IERC20(PFWA).balanceOf(DEAD);
        hook.buybackAndBurn(reserve, 1);
        vm.stopPrank();
        uint256 burned = IERC20(PFWA).balanceOf(DEAD) - deadBefore;
        assertGt(burned, 0);
        emit log_named_uint("PFWA burned from 0.00085 ETH buyback", burned / 1e18);
    }

    function test_forkV2_winnerClaimsHoldingRealPfwa() public {
        uint256 round = hook.currentRound();
        _swapBuy(0.1 ether, SherwoodV2.Move.BUY); // #1 and King
        vm.warp(hook.roundEnd(round) + 15 minutes);
        uint256 before = player.balance;
        hook.settle(round, 100);
        assertEq(player.balance, before); // nothing sent at settlement
        assertEq(hook.heldToClaim(round, player), hook.bought(round, player));
        (,,, uint256[3] memory prize,,,, uint256 kingPrize,) = hook.result(round);

        uint256 held = IERC20(PFWA).balanceOf(player);
        vm.prank(player);
        IERC20(PFWA).transfer(DEAD, held / 10); // sold some after settlement
        vm.prank(player);
        vm.expectRevert(SherwoodV2.MustHoldToClaim.selector);
        hook.claim(round);

        // Never claimed: after the window it's swept into the round live then.
        vm.warp(hook.claimDeadline(round) + 1);
        uint256 current = hook.currentRound();
        uint256 potBefore = hook.pot(current);
        hook.sweepUnclaimed(round);
        assertEq(hook.pot(current) - potBefore, prize[0] + kingPrize);
    }

    // ── A game for another token, hosted by $PFWA ───────────────────────────

    /// Deploys a second game for a stand-in token (as $IMD would be) with $PFWA as its host, and
    /// a game pool for it with liquidity on both sides.
    function _hostedGame() internal returns (SherwoodV2 game, PoolKey memory key, MockERC20 imd) {
        imd = new MockERC20("IMD", "IMD", 18);
        address hookAddr = address(FLAGS | (uint160(0x5455) << 144));
        deployCodeTo(
            "SherwoodV2.sol:SherwoodV2",
            abi.encode(
                MANAGER,
                Currency.wrap(address(imd)),
                Currency.wrap(PFWA),
                HOST_MIN,
                IDiceEntropy(DICE),
                DICE_PROVIDER,
                ADMIN,
                block.timestamp - 1 hours
            ),
            hookAddr
        );
        game = SherwoodV2(payable(hookAddr));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(imd)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        vm.prank(ADMIN);
        MANAGER.initialize(key, 79228162514264337593543950336); // 1:1
        imd.mint(address(this), 1_000_000 ether);
        imd.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 50 ether}(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 10e18, salt: 0}), ""
        );
    }

    function _swapBuyIn(PoolKey memory key, address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        swapRouter.swap{value: amount}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(SherwoodV2.Move.BUY))
        );
    }

    function test_forkV2_hostBurnBuysRealPfwaThroughHolderPool() public {
        (SherwoodV2 game, PoolKey memory key,) = _hostedGame();
        assertTrue(game.hostEnabled());
        uint256 round = game.currentRound();
        _swapBuyIn(key, player, 0.1 ether);
        uint256 total = game.pot(round);
        vm.warp(game.roundEnd(round) + 15 minutes);
        game.settle(round, 100);
        uint256 reserve = game.hostBuybackReserve();
        assertEq(reserve, (total * 700) / 10_000);

        vm.startPrank(ADMIN);
        game.setHostBuybackPool(holderKey); // Hookr's dynamic-fee ETH/$PFWA pool
        uint256 deadBefore = IERC20(PFWA).balanceOf(DEAD);
        game.buybackAndBurnHost(reserve, 1);
        vm.stopPrank();
        uint256 burned = IERC20(PFWA).balanceOf(DEAD) - deadBefore;
        assertGt(burned, 0);
        assertEq(game.hostBuybackReserve(), 0);
        emit log_named_uint("PFWA burned from a 0.00035 ETH host buyback (7% of the pot)", burned / 1e18);
    }

    function test_forkV2_hostBonusForRealPfwaHolders() public {
        (SherwoodV2 game, PoolKey memory key,) = _hostedGame();
        uint256 round = game.currentRound();
        deal(PFWA, player, HOST_MIN);
        assertTrue(game.hostBonusActive(player));
        _swapBuyIn(key, player, 0.02 ether); // 20 x 1.1
        assertEq(game.points(round, player), 22);
        address other = makeAddr("other");
        _swapBuyIn(key, other, 0.02 ether);
        assertEq(game.points(round, other), 20);
    }
}
