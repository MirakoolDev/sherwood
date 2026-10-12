// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SherwoodV2, IDiceEntropy} from "src/SherwoodV2.sol";

contract UnknownReignNoDice {
    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 25_000_000_000_000;
    }
}

/// The reviewer's proof for finding de3202be (high): on a board above MAX_LEADER_SCAN the seconds while #1 was
/// unknown used to be handed to the round's final #1. Now the next transaction rescans the board and
/// credits the #1 it finds back to the last point change, so bob gets his 18 hours and is King.
/// (Before the fix: every second after the cached leader was first debited was parked on the
/// UNKNOWN_REIGN marker and handed to the round's final #1 at settlement, whoever actually held #1
/// during that time. Bob was #1 for 18 of the round's 20 hours; Dave took #1 in the last hour and was
/// crowned King with 19 hours of reign.)
contract SherwoodV2UnknownReignKingTest is Test {
    uint256 internal constant GENESIS = 1_791_835_200;
    uint160 internal constant PRICE_ONE = 79228162514264337593543950336;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    MockERC20 internal gameToken;
    SherwoodV2 internal game;
    PoolKey internal gameKey;

    receive() external payable {}

    function setUp() public {
        vm.warp(GENESIS + 1);
        address owner = makeAddr("owner");
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        PoolModifyLiquidityTest lr = new PoolModifyLiquidityTest(manager);
        gameToken = new MockERC20("Game", "GAME", 18);
        MockERC20 hostToken = new MockERC20("Host", "HOST", 18);
        address hookAddress = address(uint160(0xA11D0000) | uint160(0x20CC));
        deployCodeTo(
            "SherwoodV2.sol:SherwoodV2",
            abi.encode(
                manager,
                Currency.wrap(address(gameToken)),
                Currency.wrap(address(hostToken)),
                uint256(100_000e18),
                IDiceEntropy(address(new UnknownReignNoDice())),
                makeAddr("provider"),
                owner,
                GENESIS
            ),
            hookAddress
        );
        game = SherwoodV2(payable(hookAddress));
        gameKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(gameToken)), 9000, 180, IHooks(hookAddress));
        vm.prank(owner);
        manager.initialize(gameKey, PRICE_ONE);
        gameToken.mint(address(this), 1e30);
        gameToken.approve(address(lr), type(uint256).max);
        vm.deal(address(this), 50_000 ether);
        lr.modifyLiquidity{value: 25_000 ether}(
            gameKey, ModifyLiquidityParams(-59400, 59400, 10_000e18, bytes32(0)), ""
        );
    }

    function _buy(address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        router.swap{value: amount}(
            gameKey,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(0))
        );
    }

    function _sellAll(address who) internal {
        uint256 amount = gameToken.balanceOf(who);
        vm.startPrank(who, who);
        gameToken.approve(address(router), type(uint256).max);
        router.swap(
            gameKey,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
    }

    function test_kingOfTheHillIsTheLongestAtFirstPlaceNotTheFinalLeader() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address dave = makeAddr("dave");
        _buy(alice, 0.1 ether); // 100 points, #1 from GENESIS + 1
        _buy(bob, 0.09 ether); // 90 points
        for (uint256 i; i < 1499; ++i) {
            _buy(address(uint160(0x100000 + i)), 0.001 ether); // 1 point each: 1,501 players
        }
        vm.warp(GENESIS + 1 hours);
        _sellAll(alice); // alice wiped: bob (90) is #1 from now, but the cache is stale and unknown
        assertEq(game.reignHolder(0), address(1));
        vm.warp(GENESIS + 19 hours);
        _buy(dave, 0.1 ether); // 100 points: dave is #1 for the last hour only
        assertEq(game.points(0, dave), 100);
        assertEq(game.points(0, bob), 90);

        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        while (!game.settle(0, 200)) {}
        (, address[3] memory top,,,, address king, uint256 kingReign,,) = game.result(0);
        assertEq(top[0], dave, "dave is #1 at the end");
        assertEq(top[1], bob);
        assertEq(king, bob, "bob held #1 for 18 hours, dave for 1: bob must be King; dave is crowned instead");
        assertLe(kingReign, 18 hours);
        // The seconds while #1 was unknown went to bob, who held #1 then, and to nobody else.
        assertEq(kingReign, 18 hours);
        assertEq(game.reignOf(0, bob), kingReign);
        assertEq(game.reignOf(0, dave), 1 hours);
        assertEq(game.reignOf(0, alice), 1 hours - 1);
        assertEq(game.kingOfTheHill(0), bob);
    }
}
