// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolPriceAlign} from "../src/PoolPriceAlign.sol";

/// The live Season 2 game pool, created at yesterday's $IMD price, walked to the 1% pool's price.
contract PoolPriceAlignForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant HOOK = 0xc33c907127b94303F578d6Be551C36F45939e0cC;
    address constant ADMIN = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;

    PoolKey game = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(IMD), 9_000, 180, IHooks(HOOK));
    PoolKey market = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
    PoolPriceAlign align;

    function setUp() public {
        vm.createSelectFork("robinhood");
        align = new PoolPriceAlign(MANAGER);
    }

    function test_alignsTheEmptyGamePoolToMarketAndTradesNothing() public {
        (uint160 before, int24 tickBefore,,) = MANAGER.getSlot0(game.toId());
        (uint160 target, int24 marketTick,,) = MANAGER.getSlot0(market.toId());
        emit log_named_int("game tick before", tickBefore);
        emit log_named_int("market tick", marketTick);
        assertTrue(before != target);
        uint256 ethBefore = ADMIN.balance;
        uint256 imdBefore = IERC20(IMD).balanceOf(ADMIN);
        uint256 hookEth = HOOK.balance;
        uint128 liqBefore = MANAGER.getLiquidity(game.toId());

        vm.prank(ADMIN, ADMIN);
        align.align(game, market);

        (uint160 afterPrice, int24 tickAfter,,) = MANAGER.getSlot0(game.toId());
        assertEq(afterPrice, target);
        assertEq(tickAfter, marketTick);
        assertEq(ADMIN.balance, ethBefore);
        assertEq(IERC20(IMD).balanceOf(ADMIN), imdBefore);
        assertEq(HOOK.balance, hookEth);
        assertEq(MANAGER.getLiquidity(game.toId()), liqBefore);
        assertEq(address(align).balance, 0);
        emit log_named_int("game tick after", tickAfter);
    }

    function test_revertsInsteadOfTradingWhenLiquiditySitsInTheWay() public {
        (, int24 tick,,) = MANAGER.getSlot0(game.toId());
        (, int24 marketTick,,) = MANAGER.getSlot0(market.toId());
        // A two-sided position straddling the game price, inside the stretch the price must cross.
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(MANAGER);
        deal(IMD, address(this), 1_000e18);
        vm.deal(address(this), 10 ether);
        IERC20(IMD).approve(address(lp), type(uint256).max);
        int24 lower = (tick / 180) * 180;
        lp.modifyLiquidity{value: 1 ether}(game, ModifyLiquidityParams(lower, lower + 360, 1e18, 0), "");
        assertTrue(marketTick > tick);
        vm.expectRevert();
        align.align(game, market);
    }

    receive() external payable {}
}
