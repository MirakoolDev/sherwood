// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";

contract ReferralReceiver {
    SherwoodV2 internal game;
    bool public rejecting = true;
    bool public attack;
    uint256 public blockedCalls;

    constructor(SherwoodV2 g) {
        game = g;
    }

    function configure(bool reject, bool reenter) external {
        rejecting = reject;
        attack = reenter;
    }

    function withdraw() external {
        game.claimReferral();
    }

    receive() external payable {
        require(!rejecting, "reject ETH");
        if (!attack) return;
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(SherwoodV2.claimReferral, ()));
        require(!ok && bytes4(reason) == SherwoodV2.Reentered.selector, "referral reentrancy allowed");
        ++blockedCalls;
        (ok, reason) = address(game).call(abi.encodeCall(SherwoodV2.claim, (0)));
        require(!ok && bytes4(reason) == SherwoodV2.Reentered.selector, "claim reentrancy allowed");
        ++blockedCalls;
        (ok, reason) = address(game).call(abi.encodeCall(SherwoodV2.sweepUnclaimed, (0)));
        require(!ok && bytes4(reason) == SherwoodV2.Reentered.selector, "sweep reentrancy allowed");
        ++blockedCalls;
    }
}

contract SherwoodV2LifecycleTest is SherwoodV2Fixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_diceOutageFallsBackWithoutConsumingFlip(uint256 amount, bool failQuote) public {
        amount = bound(amount, 0.001 ether, 0.1 ether);
        dice.configure(25_000_000_000_000, failQuote ? 1 : 2);
        _buy(alice, amount, SherwoodV2.Move.FLIP);
        assertEq(game.points(0, alice), int256(amount / 0.001 ether));
        assertEq(game.flipsLeft(alice), 6);
        assertEq(game.pendingFlips(0), 0);
        assertEq(dice.nextSequence(), 1);
        assertEq(address(dice).balance, 0);
        assertEq(game.pot(0), amount / 20);
        assertEq(address(game).balance, amount / 20);
        assertGt(gameToken.balanceOf(alice), 0);
    }

    /// Revision 2 added a second bound: the Dice fee may not exceed the 5% the flip's own buy pays in.
    /// Since that 5% is in the pot before the move runs, a pot short of the fee is no longer reachable.
    function test_diceFeeAtCapNeedsABuyWhoseShareCoversItAndOneWeiAboveCapFallsBack() public {
        dice.configure(uint128(MAX_DICE_FEE), 0);
        _seed(0, 1 ether); // a full pot does not help: the bound is on the buy's own share
        _buy(alice, 0.001 ether, SherwoodV2.Move.FLIP); // pays 0.00005 in, below the 0.0005 fee
        assertEq(game.points(0, alice), 1, "scores as a plain buy");
        assertEq(game.flipsLeft(alice), 6, "no flip charge spent");
        assertEq(dice.nextSequence(), 1, "nothing was requested");
        uint256 potBefore = game.pot(0);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP); // pays exactly the fee in: the boundary flips
        assertEq(game.points(0, alice), 1, "the stake rides on the flip");
        assertEq(game.flipsLeft(alice), 5);
        assertEq(game.pendingFlips(0), 1);
        assertEq(game.pot(0), potBefore + 0.0005 ether - MAX_DICE_FEE);
        assertEq(address(dice).balance, MAX_DICE_FEE);
        dice.configure(uint128(MAX_DICE_FEE + 1), 0);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP); // one wei over the cap, though the buy could pay it
        assertEq(game.points(0, alice), 11);
        assertEq(game.flipsLeft(alice), 5);
        assertEq(dice.nextSequence(), 2);
        // Fee one wei above the buy's share, well under the cap: the same fallback.
        dice.configure(uint128(0.00005 ether + 1), 0);
        _buy(bob, 0.001 ether, SherwoodV2.Move.FLIP);
        assertEq(game.points(0, bob), 1);
        assertEq(game.flipsLeft(bob), 6);
        assertEq(dice.nextSequence(), 2);
        dice.configure(uint128(0.00005 ether), 0);
        _buy(bob, 0.001 ether, SherwoodV2.Move.FLIP);
        assertEq(game.flipsLeft(bob), 5);
        assertEq(dice.nextSequence(), 3);
    }

    function test_multipleFlipsResolveOutOfOrderAgainstSavedPreviousPlayers() public {
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.02 ether, SherwoodV2.Move.FLIP); // loses 20 to Bob
        _buy(carol, 0.03 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.04 ether, SherwoodV2.Move.FLIP); // expires for 40
        _buy(bob, 0.05 ether, SherwoodV2.Move.FLIP); // wins 125
        assertEq(game.pendingFlips(0), 3);
        assertTrue(dice.reveal(3, bytes32(uint256(2))));
        assertTrue(dice.reveal(1, bytes32(uint256(1))));
        assertEq(game.points(0, alice), -20);
        assertEq(game.points(0, bob), 155);
        assertEq(game.points(0, carol), 30);
        vm.warp(vm.getBlockTimestamp() + FLIP_TIMEOUT - 1);
        vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
        game.expireFlip(2);
        vm.warp(vm.getBlockTimestamp() + 1);
        game.expireFlip(2);
        assertEq(game.points(0, alice), 20);
        assertEq(game.pendingFlips(0), 0);
        // Delivery after timeout recovery and duplicate/unknown callbacks cannot move points again.
        assertTrue(dice.reveal(2, bytes32(uint256(2))));
        vm.startPrank(address(dice));
        game._entropyCallback(1, game.diceProvider(), bytes32(uint256(2)));
        game._entropyCallback(type(uint64).max, game.diceProvider(), bytes32(uint256(1)));
        vm.stopPrank();
        assertEq(game.points(0, alice), 20);
        assertEq(game.points(0, bob), 155);
        assertEq(game.pendingFlips(0), 0);
        vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
        game.expireFlip(2);
    }

    function test_expiryAndDiceRefundUseSeparateAccountingAndCannotRepeat() public {
        _buy(alice, 0.02 ether, SherwoodV2.Move.FLIP);
        uint256 fee = dice.fee();
        uint256 potBefore = game.pot(0);
        vm.warp(vm.getBlockTimestamp() + FLIP_TIMEOUT);
        game.expireFlip(1);
        assertEq(game.pot(0), potBefore);
        assertEq(game.points(0, alice), 20);
        vm.prank(owner);
        game.refundDiceRequest(1);
        assertEq(game.buybackReserve(), fee);
        assertEq(game.pot(0), potBefore);
        assertEq(address(game).balance, 0.001 ether);
        vm.prank(owner);
        vm.expectRevert("request closed");
        game.refundDiceRequest(1);
        assertEq(game.buybackReserve(), fee);
        assertEq(game.pendingFlips(0), 0);
    }

    function test_timeoutRecoveryUnblocksBatchedSettlementAtExactOpening() public {
        vm.warp(game.roundEnd(0) - 1);
        _buy(alice, 0.02 ether, SherwoodV2.Move.FLIP);
        _buy(bob, 0.03 ether, SherwoodV2.Move.FLIP);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        vm.expectRevert(SherwoodV2.FlipsPending.selector);
        game.settle(0, 1);
        game.expireFlip(1);
        vm.expectRevert(SherwoodV2.FlipsPending.selector);
        game.settle(0, 1);
        game.expireFlip(2);
        assertFalse(game.settle(0, 1));
        assertTrue(game.settle(0, 1));
        (bool settled, address[3] memory top,,,,,,,) = game.result(0);
        assertTrue(settled);
        assertEq(top[0], bob);
        assertEq(top[1], alice);
        uint256 unpaid = _unpaid(0);
        assertTrue(dice.reveal(1, bytes32(uint256(1))));
        assertTrue(dice.reveal(2, bytes32(uint256(2))));
        assertEq(_unpaid(0), unpaid);
        assertEq(game.points(0, alice), 20);
        assertEq(game.points(0, bob), 30);
    }

    function test_eachChargeClockRechargesAtItsExactBoundary() public {
        uint256 start = vm.getBlockTimestamp();
        _buy(bob, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        for (uint256 i; i < 3; ++i) {
            _buy(alice, 0.001 ether, SherwoodV2.Move.ROBIN_HOOD);
        }
        for (uint256 i; i < 18; ++i) {
            _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
            _buy(alice, 0.001 ether, SherwoodV2.Move.STEAL);
        }
        for (uint256 i; i < 6; ++i) {
            _buy(alice, 0.001 ether, SherwoodV2.Move.FLIP);
        }
        assertEq(game.stealsLeft(alice), 0);
        assertEq(game.robinsLeft(alice), 0);
        assertEq(game.flipsLeft(alice), 0);
        (uint256 stealAt, uint256 robinAt, uint256 flipAt) = game.nextCharges(alice);
        assertEq(stealAt, start + 10 minutes);
        assertEq(robinAt, start + 1 hours);
        assertEq(flipAt, start + 6 hours + 40 minutes);
        vm.warp(stealAt - 1);
        assertEq(game.stealsLeft(alice), 0);
        vm.warp(stealAt);
        assertEq(game.stealsLeft(alice), 1);
        vm.warp(robinAt - 1);
        assertEq(game.robinsLeft(alice), 0);
        vm.warp(robinAt);
        assertEq(game.robinsLeft(alice), 1);
        vm.warp(flipAt - 1);
        assertEq(game.flipsLeft(alice), 0);
        vm.warp(flipAt);
        assertEq(game.flipsLeft(alice), 1);
        vm.warp(start + 40 hours);
        assertEq(game.stealsLeft(alice), 18);
        assertEq(game.robinsLeft(alice), 3);
        assertEq(game.flipsLeft(alice), 6);
        (stealAt, robinAt, flipAt) = game.nextCharges(alice);
        assertEq(stealAt | robinAt | flipAt, 0);
    }

    function test_partialRechargeSurvivesSpendingAnotherBankedCharge() public {
        uint256 start = vm.getBlockTimestamp();
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.001 ether, SherwoodV2.Move.STEAL);
        vm.warp(start + 599);
        _buy(bob, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.001 ether, SherwoodV2.Move.STEAL);
        assertEq(game.stealsLeft(alice), 16);
        (uint256 next,,) = game.nextCharges(alice);
        assertEq(next, start + 600);
        vm.warp(start + 600);
        assertEq(game.stealsLeft(alice), 17);
    }

    function test_referralTransferFailureRollsBackAndCrossFunctionReentryIsBlocked() public {
        ReferralReceiver receiver = new ReferralReceiver(game);
        _buy(address(receiver), 0.001 ether, SherwoodV2.Move.BUY);
        _buyData(alice, 0.1 ether, abi.encode(uint256(0), address(receiver)));
        _buyData(bob, 0.09 ether, abi.encode(uint256(0), address(receiver)));
        _buyData(carol, 0.08 ether, abi.encode(uint256(0), address(receiver)));
        _finishRound(0);
        uint256 owed = game.referralEarnings(address(receiver));
        uint256 hookBefore = address(game).balance;
        assertGt(owed, 0);
        vm.expectRevert(SherwoodV2.TransferFailed.selector);
        receiver.withdraw();
        assertEq(game.referralEarnings(address(receiver)), owed);
        assertEq(address(game).balance, hookBefore);
        receiver.configure(false, true);
        receiver.withdraw();
        assertEq(receiver.blockedCalls(), 3);
        assertEq(address(receiver).balance, owed);
        assertEq(game.referralEarnings(address(receiver)), 0);
        assertEq(address(game).balance, hookBefore - owed);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        receiver.withdraw();
        // The transient guard was released after both successful and failed withdrawals.
        vm.prank(alice);
        game.claim(0);
    }
}
