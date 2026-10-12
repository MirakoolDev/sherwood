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

contract LargeBoardNoDice {
    function getFeeV2(address, uint32) external pure returns (uint128) {
        return 25_000_000_000_000;
    }
}

contract SherwoodV2LargeBoardKingTest is Test {
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
                IDiceEntropy(address(new LargeBoardNoDice())),
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

    /// A play with a gas budget of the caller's choosing, like a wallet's estimate would give it. A
    /// plain buy costs about 340k here; a chunk of 200 cold players about 950k more.
    function _play(address who, uint256 amount, SherwoodV2.Move move, uint256 gas) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        router.swap{value: amount, gas: gas}(
            gameKey,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(move))
        );
    }

    /// alice (100), bob (90) and 1,499 one-point players: one more than MAX_LEADER_SCAN.
    function _bigBoard(address alice, address bob) internal {
        _buy(alice, 0.1 ether);
        _buy(bob, 0.09 ether);
        for (uint256 i; i < 1499; ++i) {
            _buy(address(uint160(0x100000 + i)), 0.001 ether);
        }
    }

    function _sellAll(address who) internal {
        _sellAll(who, 30_000_000);
    }

    function _sellAll(address who, uint256 gas) internal {
        uint256 amount = gameToken.balanceOf(who);
        vm.startPrank(who, who);
        gameToken.approve(address(router), type(uint256).max);
        router.swap{gas: gas}(
            gameKey,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
    }

    /// 1,501 players, the leader sells, a 1-point player then plays: the stale cache hands that
    /// player the reign for the rest of the round and the King of the Hill prize, while Bob holds
    /// the top score (90 points) the whole time.
    function test_kingPrizeGoesToTrueLeaderOnLargeBoard() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        _buy(alice, 0.1 ether); // 100 points
        _buy(bob, 0.09 ether); // 90 points
        for (uint256 i; i < 1499; ++i) {
            _buy(address(uint160(0x100000 + i)), 0.001 ether); // 1 point each
        }
        vm.warp(GENESIS + 1 hours);
        _sellAll(alice); // alice's points wiped; the cached leader is now stale and n > MAX_LEADER_SCAN
        _buy(carol, 0.001 ether); // 1 point
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        while (!game.settle(0, 200)) {}
        (, address[3] memory top,,,, address king,,,) = game.result(0);
        assertEq(top[0], bob, "bob is #1");
        assertEq(king, bob, "bob held #1 for ~19 hours and must be King; carol (1 point) is crowned instead");
    }

    /// A play with as much gas as a wallet's estimate gives it rescans LEADER_SCAN_CHUNK players and
    /// stops; the next plays carry on from its cursor until the board is done. Every one of them
    /// changes points, so the new #1 is credited from the last play before the rescan completed.
    function test_rescanResumesInChunksUnderATightGasBudget() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _bigBoard(alice, bob);
        assertEq(game.playerCount(0), 1501);
        vm.warp(GENESIS + 1 hours);
        _sellAll(alice); // alice wiped: #1 is unknown until the board is rescanned
        assertEq(game.reignHolder(0), address(1));
        assertEq(game.leader(0), alice); // the stale cache
        // 1,501 players at 200 a play: seven plays leave it unfinished, the eighth completes it.
        for (uint256 i = 1; i <= 7; ++i) {
            vm.warp(GENESIS + 1 hours + i * 1 minutes);
            _play(address(uint160(0x200000 + i)), 0.001 ether, SherwoodV2.Move.BUY, 1_500_000);
            assertEq(game.reignHolder(0), address(1), "still unknown");
        }
        assertEq(game.leader(0), bob); // the best found so far
        vm.warp(GENESIS + 1 hours + 8 minutes);
        _play(address(uint160(0x200008)), 0.001 ether, SherwoodV2.Move.BUY, 1_500_000);
        assertEq(game.reignHolder(0), bob);
        assertEq(game.leader(0), bob);
        // bob is credited back to the last point change before the rescan completed (the 7th play).
        vm.warp(GENESIS + 1 hours + 9 minutes);
        assertEq(game.reignOf(0, bob), 2 minutes);
        assertEq(game.reignOf(0, alice), 1 hours - 1);
        // A debit of #1 on this board is paid for by the following plays, not by the move itself.
        vm.cool(address(game));
        uint256 g = gasleft();
        _play(address(uint160(0x200009)), 0.001 ether, SherwoodV2.Move.BUY, 1_500_000);
        emit log_named_uint("resolved board, plain buy gas", g - gasleft());
    }

    /// A play with gas to spare finishes the rescan in one go, and the new #1 is credited back to the
    /// debit that started it: nothing changed in between.
    function test_rescanFinishesInOnePlayWithGasToSpare() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _bigBoard(alice, bob);
        vm.warp(GENESIS + 1 hours);
        _sellAll(alice);
        assertEq(game.reignHolder(0), address(1));
        vm.warp(GENESIS + 2 hours);
        vm.cool(address(game));
        uint256 g = gasleft();
        _play(address(uint160(0x200000)), 0.001 ether, SherwoodV2.Move.BUY, 30_000_000);
        emit log_named_uint("1,501 cold players rescanned in one play, gas", g - gasleft());
        assertEq(game.reignHolder(0), bob);
        assertEq(game.reignOf(0, bob), 1 hours); // since alice's sell
    }

    /// Robin Hood needs #1: while the rescan is unfinished it scores as a buy and keeps its charge, and
    /// works again as soon as the board is done.
    function test_robinHoodWaitsForTheRescanAndKeepsItsCharge() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address dave = makeAddr("dave");
        _bigBoard(alice, bob);
        vm.warp(GENESIS + 1 hours);
        _sellAll(alice);
        _play(dave, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD, 1_500_000); // one chunk: #1 still unknown
        assertEq(game.reignHolder(0), address(1));
        assertEq(game.points(0, dave), 10);
        assertEq(game.points(0, bob), 90);
        assertEq(game.robinsLeft(dave), 3, "the charge is kept");
        _play(address(uint160(0x200000)), 0.001 ether, SherwoodV2.Move.BUY, 30_000_000); // finishes the rescan
        assertEq(game.reignHolder(0), bob);
        _play(dave, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD, 30_000_000);
        assertEq(game.points(0, bob), 79, "12.3% of the leader's points moved (10 points scale the 10% up)");
        assertEq(game.robinsLeft(dave), 2);
    }

    /// If the best player found so far loses points mid-rescan, the rescan starts over, so the result
    /// is always the real #1.
    function test_debitOfTheRunningBestRestartsTheRescan() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        _buy(carol, 0.08 ether); // 80 points, scanned last
        _bigBoard(alice, bob);
        assertEq(game.playerCount(0), 1502);
        vm.warp(GENESIS + 1 hours);
        _sellAll(alice);
        _play(address(uint160(0x200000)), 0.001 ether, SherwoodV2.Move.BUY, 1_500_000); // scans carol, alice, bob, ...
        assertEq(game.leader(0), bob);
        assertEq(game.reignHolder(0), address(1));
        vm.warp(GENESIS + 1 hours + 1 minutes);
        _sellAll(bob, 1_700_000); // the best so far is wiped (after one more chunk): start over
        assertEq(game.reignHolder(0), address(1));
        for (uint256 i = 1; i <= 8; ++i) {
            vm.warp(GENESIS + 1 hours + 1 minutes + i * 1 minutes);
            _play(address(uint160(0x300000 + i)), 0.001 ether, SherwoodV2.Move.BUY, 1_500_000);
        }
        assertEq(game.reignHolder(0), carol);
        assertEq(game.leader(0), carol);
        assertEq(game.points(0, carol), 80);
        assertEq(game.reignOf(0, bob), 0);
    }
}
