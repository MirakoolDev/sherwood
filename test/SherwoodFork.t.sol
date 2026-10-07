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
import {Sherwood, IDiceEntropy} from "../src/Sherwood.sol";

/// Runs Sherwood on a copy of Robinhood Chain: the real PoolManager, $PFWA, Dice
/// Protocol and the $PFWA holder pool (for the buyback).
contract SherwoodForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant DICE = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    address constant DICE_PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    address constant ADMIN = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;
    address constant HOLDER_HOOK = 0xb914f955294799de4b891bd2EA8AF628Fa1c68CC;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    Sherwood hook;
    PoolKey gameKey;
    PoolKey holderKey;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    address player = makeAddr("player");

    function setUp() public {
        vm.createSelectFork("robinhood");
        swapRouter = new PoolSwapTest(MANAGER);
        lpRouter = new PoolModifyLiquidityTest(MANAGER);

        address hookAddr = address(FLAGS | (uint160(0x5353) << 144));
        deployCodeTo(
            "Sherwood.sol:Sherwood",
            abi.encode(MANAGER, Currency.wrap(PFWA), IDiceEntropy(DICE), DICE_PROVIDER, ADMIN),
            hookAddr
        );
        hook = Sherwood(payable(hookAddr));

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

    function _swapBuy(uint256 amount, Sherwood.Move move) internal {
        vm.deal(player, player.balance + amount);
        vm.prank(player, player);
        swapRouter.swap{value: amount}(
            gameKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(move))
        );
    }

    function test_fork_buyOnLivePoolManager() public {
        uint256 before = IERC20(PFWA).balanceOf(player);
        _swapBuy(0.01 ether, Sherwood.Move.BUY);
        assertEq(hook.points(hook.currentDay(), player), 10);
        assertGt(IERC20(PFWA).balanceOf(player) - before, 0);
        assertEq(hook.pot(hook.currentDay()), 0.0005 ether);
        emit log_named_uint("PFWA bought with 0.01 ETH", (IERC20(PFWA).balanceOf(player) - before) / 1e18);
    }

    function test_fork_flipRequestsRealDice() public {
        _swapBuy(0.02 ether, Sherwood.Move.FLIP);
        // The pot paid the live Dice fee; the flip waits for Dice's reveal.
        uint256 diceFee = IDiceEntropy(DICE).getFeeV2(DICE_PROVIDER, 200_000);
        assertEq(hook.pot(hook.currentDay()), 0.001 ether - diceFee);
        assertEq(hook.points(hook.currentDay(), player), 0);
    }

    function test_fork_buybackBurnsThroughHolderPool() public {
        uint256 day = hook.currentDay();
        _swapBuy(0.1 ether, Sherwood.Move.BUY);
        vm.warp((day + 1) * 1 days + 15 minutes);
        hook.settle(day, 100);
        uint256 reserve = hook.buybackReserve();
        vm.startPrank(ADMIN);
        hook.setBuybackPool(holderKey);
        uint256 deadBefore = IERC20(PFWA).balanceOf(DEAD);
        hook.buybackAndBurn(reserve, 1);
        vm.stopPrank();
        uint256 burned = IERC20(PFWA).balanceOf(DEAD) - deadBefore;
        assertGt(burned, 0);
        emit log_named_uint("PFWA burned from 0.0005 ETH buyback", burned / 1e18);
    }
}
