// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodArenaFixture} from "./helpers/SherwoodArenaFixture.sol";
import {SherwoodArena, IArenaRouter, IDiceEntropy} from "src/SherwoodArena.sol";

/// The round length as an owner setting: a change starts at the next round boundary, old rounds keep
/// their own timing, and the game settles across a change.
contract SherwoodArenaRoundsTest is SherwoodArenaFixture {
    event RoundLengthSet(uint256 length, uint256 fromRound, uint256 fromTime);

    function _setLength(uint256 length) internal {
        vm.prank(owner);
        game.setRoundLength(length);
    }

    function test_defaultIs20Hours() public view {
        assertEq(game.ROUND_LENGTH(), 20 hours);
        assertEq(game.roundEnd(0), GENESIS + 20 hours);
        assertEq(game.roundEnd(4), GENESIS + 100 hours);
    }

    function test_aChangeStartsAtTheNextBoundary() public {
        vm.warp(GENESIS + 3 hours);
        vm.expectEmit(false, false, false, true, address(game));
        emit RoundLengthSet(1 hours, 1, GENESIS + 20 hours);
        _setLength(1 hours);
        assertEq(game.currentRound(), 0);
        assertEq(game.ROUND_LENGTH(), 20 hours, "the round being played keeps its length");
        assertEq(game.roundEnd(0), GENESIS + 20 hours, "and its end");
        assertEq(game.roundStart(1), GENESIS + 20 hours);
        assertEq(game.roundEnd(1), GENESIS + 21 hours);
        assertEq(game.roundEnd(3), GENESIS + 23 hours);

        vm.warp(GENESIS + 20 hours + 30 minutes);
        assertEq(game.currentRound(), 1);
        assertEq(game.ROUND_LENGTH(), 1 hours);
        vm.warp(GENESIS + 22 hours + 1);
        assertEq(game.currentRound(), 3);
    }

    function test_aSecondChangeBeforeTheBoundaryReplacesTheFirst() public {
        _setLength(1 hours);
        _setLength(5 minutes);
        assertEq(game.periodCount(), 2);
        assertEq(game.roundEnd(1), GENESIS + 20 hours + 5 minutes);
        _setLength(20 hours); // back to the length in force: nothing left waiting
        assertEq(game.periodCount(), 1);
        assertEq(game.roundEnd(1), GENESIS + 40 hours);
    }

    function test_changesStackAcrossBoundaries() public {
        _setLength(1 hours); // from round 1 at GENESIS + 20 h
        vm.warp(GENESIS + 20 hours + 10 minutes); // in round 1
        _setLength(15 minutes); // from round 2 at GENESIS + 21 h
        assertEq(game.periodCount(), 3);
        assertEq(game.roundEnd(0), GENESIS + 20 hours);
        assertEq(game.roundEnd(1), GENESIS + 21 hours);
        assertEq(game.roundEnd(2), GENESIS + 21 hours + 15 minutes);
        vm.warp(GENESIS + 21 hours + 50 minutes);
        assertEq(game.currentRound(), 5);
        (uint256 first, uint256 start, uint256 length) = game.period(2);
        assertEq(first, 2);
        assertEq(start, GENESIS + 21 hours);
        assertEq(length, 15 minutes);
    }

    function test_beforeGenesisItSetsRoundZero() public {
        SherwoodArena early = new SherwoodArena(
            address(gameToken),
            IArenaRouter(address(router)),
            IDiceEntropy(address(dice)),
            address(1),
            owner,
            block.timestamp + 1 days,
            500,
            true,
            20 hours
        );
        vm.prank(owner);
        early.setRoundLength(1 hours);
        assertEq(early.periodCount(), 1);
        assertEq(early.roundEnd(0), block.timestamp + 1 days + 1 hours);
    }

    function test_deployLengthIsWholeMinutesFromFiveMinutesToSevenDays() public {
        vm.expectRevert(SherwoodArena.BadRoundLength.selector);
        new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 500, true, 4 minutes
        );
        vm.expectRevert(SherwoodArena.BadRoundLength.selector);
        new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 500, true, 7 days + 1 minutes
        );
        vm.expectRevert(SherwoodArena.BadRoundLength.selector);
        new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 500, true, 2 hours + 30
        );
        SherwoodArena twenty = new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 500, true, 20 hours
        );
        assertEq(twenty.roundEnd(0), GENESIS + 20 hours);
        SherwoodArena hourly = new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 500, true, 1 hours
        );
        assertEq(hourly.roundEnd(0), GENESIS + 1 hours);
    }

    function test_onlyTheOwnerAndOnlyAllowedLengths() public {
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.setRoundLength(1 hours);
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.BadRoundLength.selector);
        game.setRoundLength(4 minutes);
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.BadRoundLength.selector);
        game.setRoundLength(0);
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.BadRoundLength.selector);
        game.setRoundLength(90 seconds + 1 hours);
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.BadRoundLength.selector);
        game.setRoundLength(8 days);
    }

    /// 4 h, 15 h, 10 min: any whole-minute length works, from the next boundary, without a new contract.
    function test_anyWholeMinuteLengthCanBeSet() public {
        uint256[4] memory lengths = [uint256(4 hours), 15 hours, 10 minutes, 7 days];
        for (uint256 i; i < lengths.length; ++i) {
            uint256 next = game.currentRound() + 1;
            uint256 boundary = game.roundEnd(next - 1);
            vm.prank(owner);
            game.setRoundLength(lengths[i]);
            vm.warp(boundary);
            assertEq(game.currentRound(), next);
            assertEq(game.roundEnd(next), boundary + lengths[i]);
            assertEq(game.ROUND_LENGTH(), lengths[i]);
        }
    }

    function test_theGameSettlesAcrossAChange() public {
        _buy(alice, 0.05 ether, SherwoodArena.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodArena.Move.BUY);
        _setLength(15 minutes);

        vm.warp(game.roundStart(1) + 1);
        assertEq(game.currentRound(), 1);
        _buy(bob, 0.03 ether, SherwoodArena.Move.BUY);
        vm.warp(game.roundStart(2) + 1);
        _buy(carol, 0.01 ether, SherwoodArena.Move.BUY);

        // Round 0 settles on its own 20-hour timing, round 1 on its 15 minutes.
        vm.warp(game.roundEnd(2) + game.SETTLE_DELAY());
        assertTrue(game.settle(0, 100));
        assertTrue(game.settle(1, 100));
        assertTrue(game.settle(2, 100));
        uint256 a0 = alice.balance;
        vm.prank(alice);
        game.claim(0);
        assertEq(alice.balance - a0, (game.pot(0) * 4800) / 10_000, "#1 and King of round 0");
        uint256 b0 = bob.balance;
        vm.prank(bob);
        game.claim(1);
        assertEq(bob.balance - b0, (game.pot(1) * 4800) / 10_000, "#1 and King of round 1");
    }

    function test_flipChargesComeBackThreeTimesARound() public {
        _setLength(1 hours);
        vm.warp(game.roundStart(1));
        (,, uint256 nextFlip) = game.nextCharges(alice);
        nextFlip; // a fresh player has every charge
        assertEq(game.flipsLeft(alice), 6);
        _buy(alice, 0.01 ether, SherwoodArena.Move.FLIP);
        assertEq(game.flipsLeft(alice), 5);
        vm.warp(block.timestamp + 20 minutes);
        assertEq(game.flipsLeft(alice), 6, "a third of a 1 h round");
    }
}
