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
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {SherwoodV2} from "../src/SherwoodV2.sol";
import {SherwoodV2Launcher} from "../src/SherwoodV2Launcher.sol";

/// The $IMD launch rehearsed on a Robinhood Chain fork: the launcher deploys the hook the way the IMD
/// factory would (no salt from outside), then the owner setup, a play, settlement and both burns.
contract SherwoodV2LauncherForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant DICE = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    address constant DICE_PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    address constant ADMIN = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;
    address constant BOT = 0x4f77C413e6B2c6463812EFAa2033373c075cd7d9;
    address constant HOLDER_HOOK = 0xb914f955294799de4b891bd2EA8AF628Fa1c68CC;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        string memory rpc = vm.envOr("SHERWOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_forkLauncher_imdLaunchEndToEnd() public {
        uint256 genesis = block.timestamp + 1 hours;
        uint256 gasBefore = gasleft();
        SherwoodV2Launcher launcher =
            new SherwoodV2Launcher(address(MANAGER), IMD, PFWA, 100_000e18, DICE, DICE_PROVIDER, ADMIN, genesis);
        emit log_named_uint("launcher deploy gas (mining + hook)", gasBefore - gasleft());
        SherwoodV2 game = launcher.hook();
        assertEq(uint160(address(game)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertEq(Currency.unwrap(game.token()), IMD);
        assertEq(Currency.unwrap(game.host()), PFWA);
        assertEq(game.owner(), ADMIN);
        assertTrue(game.hostEnabled());

        // Owner setup, as SetupSherwoodV2 does it.
        PoolKey memory burnKey =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
        PoolKey memory hostKey =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(PFWA), 0x800000, 200, IHooks(HOLDER_HOOK));
        PoolKey memory key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(IMD), 9_000, 180, IHooks(address(game)));
        (uint160 price, int24 tick,,) = MANAGER.getSlot0(burnKey.toId());
        assertGt(price, 0);
        vm.startPrank(ADMIN);
        MANAGER.initialize(key, price);
        game.setOperator(BOT);
        game.setBuybackPool(burnKey);
        game.setHostBuybackPool(hostKey);
        vm.stopPrank();

        // Community liquidity: one-sided $IMD below the price, where buys push the tick.
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(MANAGER);
        deal(IMD, address(this), 100_000_000e18);
        IERC20(IMD).approve(address(lp), type(uint256).max);
        int24 upper = (tick / 180) * 180;
        if (upper > tick) upper -= 180;
        lp.modifyLiquidity(key, ModifyLiquidityParams(upper - 180 * 40, upper, 1e22, 0), "");

        // A play once the game opens.
        vm.warp(genesis + 1);
        PoolSwapTest swap = new PoolSwapTest(MANAGER);
        address player = makeAddr("player");
        vm.deal(player, 1 ether);
        vm.prank(player, player);
        swap.swap{value: 0.05 ether}(
            key,
            SwapParams(true, -0.05 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(SherwoodV2.Move.BUY))
        );
        assertEq(game.points(0, player), 50);
        assertGt(IERC20(IMD).balanceOf(player), 0);

        // Settle, then both burns from the bot.
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        game.settle(0, 100);
        uint256 imdDead = IERC20(IMD).balanceOf(DEAD);
        uint256 pfwaDead = IERC20(PFWA).balanceOf(DEAD);
        vm.startPrank(BOT);
        game.buybackAndBurn(game.buybackReserve(), 1);
        game.buybackAndBurnHost(game.hostBuybackReserve(), 1);
        vm.stopPrank();
        assertGt(IERC20(IMD).balanceOf(DEAD), imdDead);
        assertGt(IERC20(PFWA).balanceOf(DEAD), pfwaDead);
        emit log_named_uint("IMD burned", (IERC20(IMD).balanceOf(DEAD) - imdDead) / 1e18);
        emit log_named_uint("PFWA burned", (IERC20(PFWA).balanceOf(DEAD) - pfwaDead) / 1e18);
    }
}
