// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

contract SherwoodV2AccountingTest is SherwoodV2Fixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_buyDeltaMatchesEveryBalance(uint256 amount) public {
        amount = bound(amount, 1, 0.5 ether);
        uint256 poolBefore = address(manager).balance;
        uint256 playerBefore = alice.balance;
        BalanceDelta delta = _buy(alice, amount, SherwoodV2.Move.BUY);
        uint256 fee = amount / 20;
        assertEq(int256(delta.amount0()), -int256(amount), "router owes the gross input exactly");
        assertEq(alice.balance, playerBefore, "all newly funded ETH was spent");
        assertEq(address(game).balance, fee);
        assertEq(game.pot(0), fee);
        assertEq(address(manager).balance - poolBefore + fee, amount);
        assertEq(uint256(int256(delta.amount1())), gameToken.balanceOf(alice));
        assertEq(game.bought(0, alice), amount >= MIN_BUY ? gameToken.balanceOf(alice) : 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sellDeltaAndRoundTripCannotCreateETH(uint256 amount, uint256 portion) public {
        amount = bound(amount, 0.001 ether, 0.5 ether);
        _buy(alice, amount, SherwoodV2.Move.BUY);
        uint256 tokens = gameToken.balanceOf(alice);
        uint256 sold = bound(portion, 1, tokens);
        uint256 potBefore = game.pot(0);
        uint256 poolBefore = address(manager).balance;
        uint256 playerBefore = alice.balance;
        BalanceDelta delta = _sell(alice, sold);
        uint256 gross = poolBefore - address(manager).balance;
        uint256 fee = game.pot(0) - potBefore;
        assertEq(fee, gross / 20);
        assertEq(int256(delta.amount1()), -int256(sold));
        assertEq(uint256(int256(delta.amount0())), alice.balance - playerBefore);
        assertEq(alice.balance - playerBefore + fee, gross);
        assertEq(gameToken.balanceOf(alice), tokens - sold);
        assertEq(game.bought(0, alice), tokens, "selling does not erase the holding obligation");
        assertEq(game.points(0, alice), 0);
        assertLe(alice.balance - playerBefore, amount, "buy/sell cycle cannot print ETH");
        assertEq(address(game).balance, game.pot(0));
    }

    function test_oneWeiAndFeeRoundingBoundary() public {
        _buy(alice, 1, SherwoodV2.Move.BUY);
        assertEq(game.pot(0), 0);
        _buy(alice, 19, SherwoodV2.Move.BUY);
        assertEq(game.pot(0), 0);
        _buy(alice, 20, SherwoodV2.Move.BUY);
        assertEq(game.pot(0), 1);
        assertEq(address(game).balance, 1);
        assertEq(game.playerCount(0), 0);
    }

    function test_partialBuyRollsBackFeeDiceRequestChargesAndReferral() public {
        uint256 playerBefore = alice.balance;
        uint256 managerBefore = address(manager).balance;
        vm.deal(alice, playerBefore + 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(game),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SherwoodV2.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(alice, alice);
        router.swap{value: 1 ether}(
            gameKey,
            SwapParams(true, -1 ether, TickMath.getSqrtPriceAtTick(-1)),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(SherwoodV2.Move.FLIP), referrer)
        );
        assertEq(alice.balance, playerBefore + 1 ether);
        assertEq(address(manager).balance, managerBefore);
        assertEq(address(game).balance, 0);
        assertEq(game.pot(0), 0);
        assertEq(address(dice).balance, 0);
        assertEq(dice.nextSequence(), 1);
        assertEq(game.pendingFlips(0), 0);
        assertEq(game.flipsLeft(alice), 6);
        assertEq(game.referrerOf(alice), address(0));
        assertEq(game.firstRoundPlus1(alice), 0);
        assertEq(game.playerCount(0), 0);
        assertEq(game.shieldCharges(0, alice), 0);
        assertEq(game.reignHolder(0), address(0));
    }

    function test_bothPartialBuybacksRefundOnlyTheirOwnReserve() public {
        _partialBurn(false);
        _partialBurn(true);
    }

    function _partialBurn(bool host) internal {
        MockERC20 outToken = host ? hostToken : gameToken;
        PoolKey memory narrow =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(outToken)), 500, 10, IHooks(address(0)));
        manager.initialize(narrow, PRICE_ONE);
        _liquidity(narrow, -10, 10, 1e15);
        vm.prank(owner);
        if (host) game.setHostBuybackPool(narrow);
        else game.setBuybackPool(narrow);
        uint256 round = game.currentRound();
        _seed(round, 10 ether);
        _finishRound(round);
        uint256 requested = host ? game.hostBuybackReserve() : game.buybackReserve();
        uint256 otherBefore = host ? game.buybackReserve() : game.hostBuybackReserve();
        uint256 beforeETH = address(game).balance;
        uint256 poolBefore = address(manager).balance;
        uint256 burntBefore = outToken.balanceOf(DEAD);
        uint256 nextPot = game.pot(game.currentRound());
        vm.prank(owner);
        if (host) game.buybackAndBurnHost(type(uint256).max, 1);
        else game.buybackAndBurn(type(uint256).max, 1);
        uint256 spent = beforeETH - address(game).balance;
        assertGt(spent, 0);
        assertLt(spent, requested, "this must exercise a partial fill");
        assertGt(outToken.balanceOf(DEAD), burntBefore);
        assertEq(address(manager).balance - poolBefore, spent);
        assertEq(host ? game.hostBuybackReserve() : game.buybackReserve(), requested - spent);
        assertEq(host ? game.buybackReserve() : game.hostBuybackReserve(), otherBefore);
        assertEq(game.pot(game.currentRound()), nextPot);
        assertEq(outToken.balanceOf(address(game)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_slippageRevertIsAtomicForEitherBurn(bool host, uint256 seed) public {
        _configureBurns();
        _seed(0, bound(seed, 1 ether, 100 ether));
        _finishRound(0);
        uint256 gameReserve = game.buybackReserve();
        uint256 hostReserve = game.hostBuybackReserve();
        uint256 gameBalance = address(game).balance;
        uint256 managerBalance = address(manager).balance;
        vm.prank(owner);
        vm.expectRevert(SherwoodV2.TooLittleOut.selector);
        if (host) game.buybackAndBurnHost(hostReserve, type(uint256).max);
        else game.buybackAndBurn(gameReserve, type(uint256).max);
        assertEq(game.buybackReserve(), gameReserve);
        assertEq(game.hostBuybackReserve(), hostReserve);
        assertEq(address(game).balance, gameBalance);
        assertEq(address(manager).balance, managerBalance);
        assertEq(gameToken.balanceOf(DEAD), 0);
        assertEq(hostToken.balanceOf(DEAD), 0);
        // A rejected burn cannot lock the PoolManager or prevent the other burn.
        vm.prank(owner);
        if (host) game.buybackAndBurn(gameReserve, 1);
        else game.buybackAndBurnHost(hostReserve, 1);
        assertGt(host ? gameToken.balanceOf(DEAD) : hostToken.balanceOf(DEAD), 0);
    }

    function test_emptyBuybackLiquidityPreservesReserveAndClaims() public {
        PoolKey memory empty = burnKey;
        empty.fee = 500;
        manager.initialize(empty, PRICE_ONE);
        vm.prank(owner);
        game.setBuybackPool(empty);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _finishRound(0);
        uint256 reserve = game.buybackReserve();
        uint256 balance = address(game).balance;
        vm.prank(owner);
        vm.expectRevert(SherwoodV2.TooLittleOut.selector);
        game.buybackAndBurn(reserve, 1);
        vm.prank(owner);
        game.buybackAndBurn(reserve, 0);
        assertEq(game.buybackReserve(), reserve);
        assertEq(address(game).balance, balance);
        assertEq(gameToken.balanceOf(DEAD), 0);
        uint256 owed = _unpaid(0);
        vm.prank(alice);
        game.claim(0);
        assertEq(balance - address(game).balance, owed);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_batchedSettlementSameAsSinglePass(uint256 batchSeed, uint256 seed, uint256 kept) public {
        _buy(referrer, 0.001 ether, SherwoodV2.Move.BUY);
        _buyData(alice, 0.1 ether, abi.encode(uint256(0), referrer));
        vm.warp(GENESIS + 10 hours);
        _buyData(bob, 0.09 ether, abi.encode(uint256(0), referrer));
        _buyData(carol, 0.08 ether, abi.encode(uint256(0), referrer));
        uint256 holding = gameToken.balanceOf(alice);
        kept = bound(kept, 0, holding);
        vm.prank(alice);
        gameToken.transfer(makeAddr("outside holder"), holding - kept);
        _seed(0, bound(seed, 0, 100 ether));
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        uint256 snapshot = vm.snapshotState();
        assertTrue(game.settle(0, 100));
        bytes32 single = _settlementHash();
        assertTrue(vm.revertToState(snapshot));
        uint256 batch = bound(batchSeed, 1, 3);
        while (!game.settle(0, batch)) {
            assertEq(game.buybackReserve(), 0, "batches must not allocate ETH early");
            assertEq(game.referralEarnings(referrer), 0);
            vm.prank(alice);
            vm.expectRevert(SherwoodV2.NotSettled.selector);
            game.claim(0);
        }
        assertEq(_settlementHash(), single, "batch size must not change payouts, ranks, or king");
        assertEq(
            address(game).balance,
            _unpaid(0) + game.referralEarnings(referrer) + game.buybackReserve() + game.hostBuybackReserve()
                + game.pot(1)
        );
    }

    function _settlementHash() internal view returns (bytes32) {
        (bool ok, bytes memory result) = address(game).staticcall(abi.encodeCall(SherwoodV2.result, (0)));
        require(ok);
        return keccak256(
            abi.encode(
                result,
                game.pot(1),
                game.buybackReserve(),
                game.hostBuybackReserve(),
                game.referralEarnings(referrer),
                game.heldToClaim(0, alice),
                game.claimDeadline(0)
            )
        );
    }

    function test_claimAtExactDeadlineThenSweepCannotDoubleSpend() public {
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        _finishRound(0);
        uint256 owed = _unpaid(0);
        uint256 beforeBalance = address(game).balance;
        vm.warp(game.claimDeadline(0));
        vm.expectRevert(SherwoodV2.ClaimWindowOpen.selector);
        game.sweepUnclaimed(0);
        vm.prank(alice);
        game.claim(0);
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        game.claim(0);
        uint256 paid = beforeBalance - address(game).balance;
        uint256 remaining = _unpaid(0);
        assertEq(paid + remaining, owed);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(bob);
        vm.expectRevert(SherwoodV2.ClaimWindowClosed.selector);
        game.claim(0);
        uint256 live = game.currentRound();
        uint256 livePot = game.pot(live);
        game.sweepUnclaimed(0);
        assertEq(game.pot(live), livePot + remaining);
        assertEq(_unpaid(0), 0);
        assertEq(address(game).balance, beforeBalance - paid);
        vm.expectRevert(SherwoodV2.NotSettled.selector);
        game.sweepUnclaimed(0);
    }

    function test_unprivilegedCallbacksAndOperatorCannotChangeOwnerOrPools() public {
        vm.startPrank(alice);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.setOwner(alice);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.setOperator(alice);
        vm.expectRevert(SherwoodV2.NotPoolManager.selector);
        game.unlockCallback(abi.encode(false, 1 ether, 0));
        vm.expectRevert(SherwoodV2.NotPoolManager.selector);
        game.beforeSwap(alice, gameKey, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(SherwoodV2.NotPoolManager.selector);
        game.afterSwap(
            alice, gameKey, SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1), BalanceDelta.wrap(0), ""
        );
        vm.expectRevert(SherwoodV2.NotOperator.selector);
        game.refundDiceRequest(1);
        vm.stopPrank();
        vm.prank(owner);
        game.setOperator(alice);
        vm.startPrank(alice);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.setBuybackPool(burnKey);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.setHostBuybackPool(hostKey);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.setOwner(alice);
        vm.stopPrank();
        assertEq(game.owner(), owner);
    }
}
