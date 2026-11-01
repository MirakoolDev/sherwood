// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodArenaFixture} from "./helpers/SherwoodArenaFixture.sol";
import {SherwoodArena} from "src/SherwoodArena.sol";

/// SherwoodV21Accounting's checks on the arena: every wei of a move, a burn and a settlement accounted
/// for, with the router (mock) in place of the PoolManager.
contract SherwoodArenaAccountingTest is SherwoodArenaFixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_playMatchesEveryBalance(uint256 amount) public {
        amount = bound(amount, 1, 0.5 ether);
        uint256 routerBefore = address(router).balance;
        uint256 playerBefore = alice.balance;
        _buy(alice, amount, SherwoodArena.Move.BUY);
        uint256 fee = amount / 20;
        assertEq(alice.balance, playerBefore, "all newly funded ETH was spent");
        assertEq(address(game).balance, fee);
        assertEq(game.pot(0), fee);
        assertEq(address(router).balance - routerBefore + fee, amount, "the rest went to the router");
        assertEq(gameToken.balanceOf(alice), amount - fee, "1:1 at the mock router");
        assertEq(game.bought(0, alice), amount >= MIN_BUY ? gameToken.balanceOf(alice) : 0);
    }

    /// The arena can't see a sell: it moves no ETH and no points, only the player's balance, which
    /// settlement reads.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sellMovesNoArenaEthAndKeepsTheHoldingObligation(uint256 amount, uint256 portion) public {
        amount = bound(amount, 0.001 ether, 0.5 ether);
        _buy(alice, amount, SherwoodArena.Move.BUY);
        uint256 tokens = gameToken.balanceOf(alice);
        uint256 sold = bound(portion, 1, tokens);
        uint256 potBefore = game.pot(0);
        int256 pointsBefore = game.points(0, alice);
        _sell(alice, sold);
        assertEq(game.pot(0), potBefore);
        assertEq(game.points(0, alice), pointsBefore);
        assertEq(gameToken.balanceOf(alice), tokens - sold);
        assertEq(game.bought(0, alice), tokens, "selling does not erase the holding obligation");
        assertEq(address(game).balance, game.pot(0));
    }

    function test_oneWeiAndFeeRoundingBoundary() public {
        _buy(alice, 1, SherwoodArena.Move.BUY);
        assertEq(game.pot(0), 0);
        _buy(alice, 19, SherwoodArena.Move.BUY);
        assertEq(game.pot(0), 0);
        _buy(alice, 20, SherwoodArena.Move.BUY);
        assertEq(game.pot(0), 1);
        assertEq(address(game).balance, 1);
        assertEq(game.playerCount(0), 0);
    }

    /// A router that sends ETH back (a partial fill) reverts the whole move: the fee, the Dice request,
    /// the charges, the referral and the first-play mark all roll back.
    function test_partialBuyRollsBackFeeDiceRequestChargesAndReferral() public {
        router.setRefundBps(100);
        uint256 playerBefore = alice.balance;
        vm.deal(alice, playerBefore + 1 ether);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.PartialFill.selector);
        game.play{value: 1 ether}(uint8(SherwoodArena.Move.FLIP), 0, referrer);
        assertEq(alice.balance, playerBefore + 1 ether);
        assertEq(address(router).balance, 0);
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
        assertEq(gameToken.balanceOf(alice), 0);
    }

    /// A burn the router only partly fills keeps the rest in the reserve.
    function test_partialBuybackRefundsItsReserve() public {
        _seed(0, 10 ether);
        _finishRound(0);
        router.setRefundBps(4000);
        uint256 requested = game.buybackReserve();
        uint256 beforeETH = address(game).balance;
        uint256 nextPot = game.pot(game.currentRound());
        vm.prank(owner);
        game.buybackAndBurn(type(uint256).max, 1);
        uint256 spent = beforeETH - address(game).balance;
        assertEq(spent, requested - (requested * 4000) / 10_000);
        assertEq(gameToken.balanceOf(DEAD), spent);
        assertEq(game.buybackReserve(), requested - spent);
        assertEq(address(router).balance, spent);
        assertEq(game.pot(game.currentRound()), nextPot);
        assertEq(gameToken.balanceOf(address(game)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_slippageRevertIsAtomic(uint256 seed) public {
        _seed(0, bound(seed, 1 ether, 100 ether));
        _finishRound(0);
        uint256 reserve = game.buybackReserve();
        uint256 gameBalance = address(game).balance;
        vm.prank(owner);
        vm.expectRevert("router: too little out");
        game.buybackAndBurn(reserve, type(uint256).max);
        // A router that ignores minOut: the arena checks what actually arrived.
        router.setUnderpay(true);
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.TooLittleOut.selector);
        game.buybackAndBurn(reserve, reserve);
        assertEq(game.buybackReserve(), reserve);
        assertEq(address(game).balance, gameBalance);
        assertEq(gameToken.balanceOf(DEAD), 0);
        router.setUnderpay(false);
        vm.prank(owner);
        game.buybackAndBurn(reserve, 1);
        assertEq(gameToken.balanceOf(DEAD), reserve);
    }

    /// A router that can't fill at all (sends everything back): the reserve stays, claims still pay.
    function test_emptyRouterPreservesReserveAndClaims() public {
        _buy(alice, 0.01 ether, SherwoodArena.Move.BUY);
        _finishRound(0);
        router.setRefundBps(10_000);
        uint256 reserve = game.buybackReserve();
        uint256 balance = address(game).balance;
        vm.prank(owner);
        vm.expectRevert("router: too little out");
        game.buybackAndBurn(reserve, 1);
        vm.prank(owner);
        game.buybackAndBurn(reserve, 0); // nothing bought: all of it comes back to the reserve
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
        _buy(referrer, 0.001 ether, SherwoodArena.Move.BUY);
        _play(alice, 0.1 ether, 0, referrer);
        vm.warp(GENESIS + 10 hours);
        _play(bob, 0.09 ether, 0, referrer);
        _play(carol, 0.08 ether, 0, referrer);
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
            vm.expectRevert(SherwoodArena.NotSettled.selector);
            game.claim(0);
        }
        assertEq(_settlementHash(), single, "batch size must not change payouts, ranks, or king");
        assertEq(
            address(game).balance, _unpaid(0) + game.referralEarnings(referrer) + game.buybackReserve() + game.pot(1)
        );
    }

    function _settlementHash() internal view returns (bytes32) {
        (bool ok, bytes memory result) = address(game).staticcall(abi.encodeCall(SherwoodArena.result, (0)));
        require(ok);
        return keccak256(
            abi.encode(
                result,
                game.pot(1),
                game.buybackReserve(),
                game.referralEarnings(referrer),
                game.heldToClaim(0, alice),
                game.claimDeadline(0)
            )
        );
    }

    function test_claimAtExactDeadlineThenSweepCannotDoubleSpend() public {
        _buy(alice, 0.02 ether, SherwoodArena.Move.BUY);
        _buy(bob, 0.01 ether, SherwoodArena.Move.BUY);
        _finishRound(0);
        uint256 owed = _unpaid(0);
        uint256 beforeBalance = address(game).balance;
        vm.warp(game.claimDeadline(0));
        vm.expectRevert(SherwoodArena.ClaimWindowOpen.selector);
        game.sweepUnclaimed(0);
        vm.prank(alice);
        game.claim(0);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.NothingToClaim.selector);
        game.claim(0);
        uint256 paid = beforeBalance - address(game).balance;
        uint256 remaining = _unpaid(0);
        assertEq(paid + remaining, owed);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(bob);
        vm.expectRevert(SherwoodArena.ClaimWindowClosed.selector);
        game.claim(0);
        uint256 live = game.currentRound();
        uint256 livePot = game.pot(live);
        game.sweepUnclaimed(0);
        assertEq(game.pot(live), livePot + remaining);
        assertEq(_unpaid(0), 0);
        assertEq(address(game).balance, beforeBalance - paid);
        vm.expectRevert(SherwoodArena.NotSettled.selector);
        game.sweepUnclaimed(0);
    }

    function test_unprivilegedCallersAndOperatorCannotChangeOwnerOrFlips() public {
        vm.startPrank(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.setOwner(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.setOperator(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.setFlipsEnabled(false);
        vm.expectRevert(SherwoodArena.NotOperator.selector);
        game.refundDiceRequest(1);
        vm.expectRevert(SherwoodArena.NotOperator.selector);
        game.buybackAndBurn(1, 0);
        vm.expectRevert(SherwoodArena.NotDice.selector);
        game._entropyCallback(1, address(0), bytes32(0));
        vm.stopPrank();
        vm.prank(owner);
        game.setOperator(alice);
        vm.startPrank(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.setOwner(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.acceptOwner();
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.setFlipsEnabled(false);
        vm.stopPrank();
        assertEq(game.owner(), owner);
        assertEq(game.pendingOwner(), address(0));
        assertTrue(game.flipsEnabled());
    }
}
