// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/Test.sol";
import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";

/// Edges the rest of the suite does not pin: the zero and the empty, the same call twice, hook data
/// of odd lengths, the last second of a round, and fuzzed properties over settlement conservation,
/// the charge clocks, shield charges and buy scoring. Everything runs through the real PoolManager.
contract SherwoodV2EdgesTest is SherwoodV2Fixture {
    address internal sink;

    function setUp() public override {
        super.setUp();
        sink = makeAddr("edges sink");
    }

    // ── Settlement edges ────────────────────────────────────────────────────────

    function test_settleWithAZeroBatchMakesNoProgressAndNeverReverts() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        assertFalse(game.settle(0, 0));
        (bool settled, address[3] memory top,,,,,,,) = game.result(0);
        assertFalse(settled);
        assertEq(top[0], address(0), "a zero batch must not rank anyone");
        assertFalse(game.settle(0, 1));
        assertTrue(game.settle(0, 1), "two players need two batches of one");
        (settled, top,,,,,,,) = game.result(0);
        assertTrue(settled);
        assertEq(top[0], bob);
        assertEq(top[1], alice);
        assertEq(top[2], address(0));
        vm.expectRevert(SherwoodV2.AlreadySettled.selector);
        game.settle(0, 1);
    }

    function test_emptyRoundSettlesIntoBurnsAndRolloverWithNothingToClaimOrSweep() public {
        _seed(0, 1 ether);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        assertEq(game.playerCount(0), 0);
        assertTrue(game.settle(0, 0), "an empty board settles even with a zero batch");
        (bool settled,,, uint256[3] memory prize,, address king,, uint256 kingPrize,) = game.result(0);
        assertTrue(settled);
        assertEq(prize[0] + prize[1] + prize[2] + kingPrize, 0);
        assertEq(king, address(0));
        assertEq(game.buybackReserve(), 0.1 ether);
        assertEq(game.hostBuybackReserve(), 0.07 ether);
        assertEq(game.pot(1), 0.83 ether, "every unawarded share rolls into the live round");
        assertEq(address(game).balance, game.pot(1) + game.buybackReserve() + game.hostBuybackReserve());

        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        game.claim(0);

        vm.warp(game.claimDeadline(0) + 1);
        uint256 live = game.currentRound();
        uint256 before = game.pot(live);
        game.sweepUnclaimed(0);
        assertEq(game.pot(live), before, "nothing to sweep from an empty round");
        vm.expectRevert(SherwoodV2.NotSettled.selector);
        game.sweepUnclaimed(0);
    }

    function test_settleOfTheLiveRoundOrAnImpossibleRoundReverts() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        uint256 live = game.currentRound();
        vm.expectRevert(SherwoodV2.RoundNotOver.selector);
        game.settle(live, 100);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY() - 1);
        vm.expectRevert(SherwoodV2.RoundNotOver.selector);
        game.settle(0, 100);
        vm.expectRevert(stdError.arithmeticError);
        game.settle(type(uint256).max, 1);
    }

    function test_rolloverLandsInTheRoundLiveAtSettlementNotTheNextOne() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        uint256 total = game.pot(0);
        vm.warp(game.roundStart(3) + 1);
        assertTrue(game.settle(0, 100));
        // #1 and King to alice (48%), #2 and #3 unawarded (30%) join the 5% rollover; burns take 17%.
        uint256 expectedRollover =
            total - (total * 4000) / 10_000 - (total * 800) / 10_000 - (total * 1000) / 10_000 - (total * 700) / 10_000;
        assertEq(game.pot(1), 0);
        assertEq(game.pot(2), 0);
        assertEq(game.pot(3), expectedRollover);
    }

    function test_claimsSweepsAndReferralClaimsForRoundsThatNeverSettledRevert() public {
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NotSettled.selector);
        game.claim(5);
        vm.expectRevert(SherwoodV2.NotSettled.selector);
        game.sweepUnclaimed(5);
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        game.claimReferral();
    }

    function test_secondClaimRevertsAndASweepAfterAFullClaimMovesNothing() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        uint256 total = game.pot(0);
        _finishRound(0);
        uint256 before = alice.balance;
        vm.prank(alice);
        game.claim(0);
        assertEq(alice.balance - before, (total * 4000) / 10_000 + (total * 800) / 10_000, "rank and King together");
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        game.claim(0);
        vm.warp(game.claimDeadline(0) + 1);
        uint256 live = game.currentRound();
        uint256 potBefore = game.pot(live);
        game.sweepUnclaimed(0);
        assertEq(game.pot(live), potBefore);
        // What is left is the rollover (in round 1's pot, live at settlement) and the two reserves.
        assertEq(
            address(game).balance, game.pot(1) + game.pot(live) + game.buybackReserve() + game.hostBuybackReserve()
        );
    }

    function test_buybackNeverSpendsMoreThanTheReserveAndAnEmptyReserveCannotBurn() public {
        vm.prank(owner);
        vm.expectRevert();
        game.buybackAndBurn(1, 0);
        _seed(0, 1 ether);
        _finishRound(0);
        uint256 reserve = game.buybackReserve();
        uint256 hostReserve = game.hostBuybackReserve();
        uint256 balanceBefore = address(game).balance;
        vm.prank(owner);
        game.buybackAndBurn(reserve * 10, 0);
        assertEq(game.buybackReserve(), 0);
        assertEq(balanceBefore - address(game).balance, reserve, "the burn is clamped to the reserve");
        assertEq(game.hostBuybackReserve(), hostReserve, "the other reserve is untouched");
        assertGt(gameToken.balanceOf(DEAD), 0);
        vm.prank(owner);
        vm.expectRevert();
        game.buybackAndBurn(1, 0);
    }

    // ── Hook data and moves ─────────────────────────────────────────────────────

    function test_hookDataOfOddLengthsDecodesTheMoveAndIgnoresTheRest() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        // 33 bytes: the move word plus a stray byte still plays the move.
        _buyData(bob, 0.01 ether, abi.encodePacked(uint256(SherwoodV2.Move.STEAL), bytes1(0x01)));
        assertEq(game.points(0, bob), 12, "a 33-byte STEAL takes 20% of the previous player");
        assertEq(game.points(0, alice), 8);
        assertEq(game.stealsLeft(bob), 17);
        // 64 bytes with an unknown move and a clean referrer: a plain buy, the referrer is kept.
        _buyData(carol, 0.01 ether, abi.encode(uint256(99), referrer));
        assertEq(game.points(0, carol), 11, "a plain buy with the welcome bonus of a referred first play");
        assertEq(game.referrerOf(carol), referrer);
        assertEq(game.points(0, referrer), 0, "no referral points: the referrer has not played this round");
        // 20 bytes (a bare address): a plain buy and no referrer.
        _buyData(referrer, 0.01 ether, abi.encodePacked(alice));
        assertEq(game.points(0, referrer), 10);
        assertEq(game.referrerOf(referrer), address(0));
        // 63 bytes: the move word is read, the truncated referrer is not.
        address dave = makeAddr("edges dave");
        _buyData(
            dave,
            0.01 ether,
            abi.encodePacked(uint256(SherwoodV2.Move.BUY), bytes31(bytes32(uint256(uint160(alice)) << 96)))
        );
        assertEq(game.points(0, dave), 10);
        assertEq(game.referrerOf(dave), address(0));
    }

    function test_robinHoodByTheLeaderPlaysAsABuyAndKeepsItsCharge() public {
        _buy(bob, 0.005 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        assertEq(game.leader(0), alice);
        _buy(alice, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertEq(game.points(0, alice), 20);
        assertEq(game.points(0, bob), 5);
        assertEq(game.robinsLeft(alice), 3, "no target: the charge is kept");
    }

    function test_stealFromAPreviousPlayerWipedToZeroSpendsTheChargeAndMovesNothing() public {
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.points(0, alice), 0);
        assertEq(game.lastPlayer(0), alice);
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL);
        assertEq(game.points(0, bob), 10);
        assertEq(game.points(0, alice), 0);
        assertEq(game.stealsLeft(bob), 17, "the move was made, there was nothing to take");
    }

    function test_shieldRaisedNearTheEndOfARoundStillReflectsInTheNext() public {
        vm.warp(game.roundEnd(0) - 10 minutes);
        _buy(alice, 0.025 ether, SherwoodV2.Move.SHIELD);
        assertEq(game.shieldUntil(alice), game.roundEnd(0) + 20 minutes);
        vm.warp(game.roundEnd(0) + 5 minutes);
        assertEq(game.currentRound(), 1);
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY); // 12: the holder bonus for keeping round 0's buys
        assertEq(game.points(1, alice), 12);
        _buy(bob, 0.01 ether, SherwoodV2.Move.STEAL);
        assertEq(game.points(1, bob), 8, "the reflected cut comes off the attacker");
        assertEq(game.points(1, alice), 14);
        assertFalse(game.shieldActive(alice));
        assertEq(game.shieldUntil(alice), 0, "the shield broke on the reflect");
    }

    // ── Flip lifecycle at the round boundary ────────────────────────────────────

    function test_flipInTheLastSecondOfARoundExpiresBeforeSettlementOpens() public {
        vm.warp(game.roundEnd(0) - 1);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP);
        uint64 seq = dice.nextSequence() - 1;
        (address player,, uint64 round, uint64 requestedAt,,) = game.flips(seq);
        assertEq(player, alice);
        assertEq(round, 0);
        assertEq(game.pendingFlips(0), 1);
        assertEq(game.points(0, alice), 0);

        vm.warp(requestedAt + FLIP_TIMEOUT - 1);
        vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
        game.expireFlip(seq);
        vm.warp(requestedAt + FLIP_TIMEOUT);
        assertLt(block.timestamp, game.roundEnd(0) + game.SETTLE_DELAY(), "expiry opens before settlement does");
        game.expireFlip(seq);
        assertEq(game.pendingFlips(0), 0);
        assertEq(game.points(0, alice), 10, "an unrevealed flip scores as a plain buy in its own round");
        assertEq(game.reignOf(0, alice), 0, "a reign started after the round ended counts nothing");

        vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
        game.expireFlip(seq);
        vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
        game.expireFlip(seq + 1000);

        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        assertTrue(game.settle(0, 100));
        (, address[3] memory top,,,, address king,, uint256 kingPrize,) = game.result(0);
        assertEq(top[0], alice);
        assertEq(king, address(0), "nobody held #1 inside the round");
        assertEq(kingPrize, 0);
    }

    function test_settlementIsBlockedOnlyUntilTheLastSecondFlipIsExpired() public {
        vm.warp(game.roundEnd(0) - 1);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP);
        uint64 seq = dice.nextSequence() - 1;
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        vm.expectRevert(SherwoodV2.FlipsPending.selector);
        game.settle(0, 100);
        game.expireFlip(seq);
        assertTrue(game.settle(0, 100));
        // A late reveal of the expired flip changes nothing.
        assertTrue(dice.reveal(seq, bytes32(uint256(1))));
        assertEq(game.points(0, alice), 10);
        assertEq(game.pendingFlips(0), 0);
    }

    function test_kingOfTheHillViewIsTheOracleForTheSettledKing() public {
        uint256 start = GENESIS + 1;
        _buy(alice, 0.01 ether, SherwoodV2.Move.BUY);
        vm.warp(start + 1 hours);
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY);
        vm.warp(start + 3 hours);
        _buy(alice, 0.02 ether, SherwoodV2.Move.BUY);
        assertEq(game.kingOfTheHill(0), bob, "two hours at #1 beat one so far");
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        uint256 aliceReign = 1 hours + (game.roundEnd(0) - (start + 3 hours));
        assertEq(game.reignOf(0, alice), aliceReign);
        assertEq(game.reignOf(0, bob), 2 hours);
        assertEq(game.kingOfTheHill(0), alice);
        assertTrue(game.settle(0, 100));
        (,,,,, address king, uint256 kingReign,,) = game.result(0);
        assertEq(king, alice);
        assertEq(kingReign, aliceReign);
        assertEq(game.kingOfTheHill(0), alice);
    }

    // ── Fuzzed properties ───────────────────────────────────────────────────────

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_buyPointsAndPotFollowTheEthIn(uint256 amount) public {
        amount = bound(amount, 1, 0.5 ether);
        uint256 potBefore = game.pot(0);
        _buy(alice, amount, SherwoodV2.Move.BUY);
        uint256 fee = (amount * 500) / 10_000;
        assertEq(game.pot(0) - potBefore, fee);
        assertEq(address(game).balance, game.pot(0));
        uint256 expected = amount >= MIN_BUY ? amount / 0.001 ether : 0;
        if (expected > 100) expected = 100;
        assertEq(uint256(game.points(0, alice)), expected);
        assertEq(game.bought(0, alice) > 0, amount >= MIN_BUY, "only scoring buys are tracked");
        assertEq(game.playerCount(0), amount >= MIN_BUY ? 1 : 0);
    }

    /// Four players with a live referral; the winners move away a fuzzed share of their holdings.
    /// Every wei of the settled pot must land in exactly one of prizes, the referral cut, the two
    /// reserves and the rollover, and the hook must still hold everything it owes.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_settlementConservesEveryWeiOfThePot(
        uint256 seedAmount,
        uint256 keepAlice,
        uint256 keepBob,
        uint256 keepCarol
    ) public {
        seedAmount = bound(seedAmount, 0, 50 ether);
        _buy(referrer, 0.001 ether, SherwoodV2.Move.BUY);
        _buyData(alice, 0.03 ether, abi.encode(uint256(SherwoodV2.Move.BUY), referrer));
        _buy(bob, 0.02 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.01 ether, SherwoodV2.Move.BUY);
        _seed(0, seedAmount);
        _moveAway(alice, bound(keepAlice, 0, 10_000));
        _moveAway(bob, bound(keepBob, 0, 10_000));
        _moveAway(carol, bound(keepCarol, 0, 10_000));
        uint256 total = game.pot(0);

        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        uint256 liveBefore = game.pot(1);
        assertTrue(game.settle(0, 100));
        (, address[3] memory top,, uint256[3] memory prize,, address king,, uint256 kingPrize,) = game.result(0);
        assertEq(top[0], alice);
        assertEq(top[1], bob);
        assertEq(top[2], carol);
        assertEq(king, alice);

        uint256 cut = game.referralEarnings(referrer);
        uint256 accounted = prize[0] + prize[1] + prize[2] + kingPrize + cut + game.buybackReserve()
            + game.hostBuybackReserve() + (game.pot(1) - liveBefore);
        assertEq(accounted, total, "the split must account for every wei of the pot");
        assertEq(
            address(game).balance,
            game.pot(1) + _unpaid(0) + cut + game.buybackReserve() + game.hostBuybackReserve(),
            "ETH held must equal what is owed"
        );
        assertEq(game.buybackReserve(), (total * 1000) / 10_000);
        assertEq(game.hostBuybackReserve(), (total * 700) / 10_000);
        uint256[4] memory shareBps = [uint256(4000), 2000, 1000, 800];
        address[4] memory winners = [alice, bob, carol, alice];
        uint256[4] memory prizes = [prize[0], prize[1], prize[2], kingPrize];
        uint256 expectedCut;
        for (uint256 i; i < 4; ++i) {
            uint256 share = (total * shareBps[i]) / 10_000;
            uint256 owed = game.bought(0, winners[i]);
            uint256 held = gameToken.balanceOf(winners[i]);
            uint256 expected = held < owed ? (share * held) / owed : share;
            assertEq(prizes[i], expected, "a prize shrinks with the share of the buys sold");
            assertLe(prizes[i], share);
            if (winners[i] == alice) expectedCut += (prizes[i] * 500) / 10_000;
            bool hasPrize = i == 0 ? (prizes[0] > 0 || prizes[3] > 0) : prizes[i] > 0;
            if (i < 3) assertEq(game.heldToClaim(0, winners[i]), hasPrize ? (held < owed ? held : owed) : 0);
        }
        assertEq(cut, expectedCut, "the referrer gets 5% of each of alice's prizes");
        assertGe((game.pot(1) - liveBefore) + cut, (total * 500) / 10_000, "the cut comes out of the 5% rollover");

        // Everyone who can claim does, the rest sweeps: the hook ends holding only the live pot and reserves.
        _claimIfAny(alice, 0);
        _claimIfAny(bob, 0);
        _claimIfAny(carol, 0);
        if (cut > 0) {
            vm.prank(referrer);
            game.claimReferral();
        }
        vm.warp(game.claimDeadline(0) + 1);
        game.sweepUnclaimed(0);
        uint256 live = game.currentRound();
        assertEq(
            address(game).balance, game.pot(1) + game.pot(live) + game.buybackReserve() + game.hostBuybackReserve()
        );
    }

    /// Alice steals once after each random wait. The bank never exceeds 18, a landed Steal spends
    /// exactly one charge, with none left the move plays as a Buy, and the next-charge view agrees.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_stealChargesNeverExceedTheBankAndSpendExactlyOne(uint256[8] memory gaps) public {
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(block.timestamp + bound(gaps[i], 0, 3 hours));
            uint256 round = game.currentRound();
            _buy(bob, 0.001 ether, SherwoodV2.Move.BUY);
            uint256 left = game.stealsLeft(alice);
            assertLe(left, 18);
            (uint256 next,,) = game.nextCharges(alice);
            if (left == 18) {
                assertEq(next, 0, "a full bank has no next charge");
            } else {
                assertGt(next, block.timestamp);
                assertLe(next, block.timestamp + 10 minutes);
            }
            int256 bobPoints = game.points(round, bob);
            int256 alicePoints = game.points(round, alice);
            uint256 scored = 1; // a minimum buy scores 1 point, with or without the 25% holder bonus
            _buy(alice, 0.001 ether, SherwoodV2.Move.STEAL);
            if (left > 0) {
                assertEq(game.stealsLeft(alice), left - 1, "a landed Steal spends one charge");
                uint256 moved = (uint256(bobPoints) * game.scaledBps(2000, 4000, 1)) / 10_000;
                assertEq(game.points(round, alice), alicePoints + int256(scored + moved));
                assertEq(game.points(round, bob), bobPoints - int256(moved));
            } else {
                assertEq(game.stealsLeft(alice), 0);
                assertEq(game.points(round, alice), alicePoints + int256(scored), "no charge: a plain buy");
                assertEq(game.points(round, bob), bobPoints);
            }
        }
    }

    /// Robin Hood's bank is three charges an hour apart; after a long wait it is full again.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_robinChargesRechargeOnePerHourUpToThree(uint256 wait, uint8 spends) public {
        wait = bound(wait, 0, 5 hours);
        spends = uint8(bound(spends, 0, 4));
        _buy(bob, 0.001 ether, SherwoodV2.Move.BUY);
        _buy(carol, 0.01 ether, SherwoodV2.Move.BUY); // carol leads by far, bob is the lowest recent
        uint256 spent;
        for (uint256 i; i < spends; ++i) {
            uint256 before = game.robinsLeft(alice);
            _buy(alice, 0.001 ether, SherwoodV2.Move.ROBIN_HOOD);
            if (before > 0) ++spent;
            assertEq(game.robinsLeft(alice), before > 0 ? before - 1 : 0);
        }
        assertEq(spent, spends > 3 ? 3 : spends);
        // A cheatcode read, not block.timestamp: under via-IR a cached timestamp moves with vm.warp.
        uint256 spentAt = vm.getBlockTimestamp();
        vm.warp(spentAt + wait);
        uint256 expected = 3 - spent + wait / 1 hours;
        if (expected > 3) expected = 3;
        assertEq(game.robinsLeft(alice), expected);
        (, uint256 next,) = game.nextCharges(alice);
        if (expected == 3) assertEq(next, 0);
        else assertEq(next, spentAt + (wait / 1 hours + 1) * 1 hours, "charges land on the hour from the spend");
    }

    /// A shield charge appears exactly when the round's cumulative play crosses a 0.025 ETH mark, a
    /// SHIELD with a charge arms for 30 minutes and spends it, and a player never holds two.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_shieldChargeTracksEveryCrossingOfTheMark(uint256[6] memory raw, uint256 moveMask) public {
        bool charge;
        uint256 cumulative;
        for (uint256 i; i < raw.length; ++i) {
            uint256 amount = bound(raw[i], MIN_BUY, 0.03 ether);
            bool useShield = (moveMask >> i) & 1 == 1;
            if ((cumulative + amount) / 0.025 ether > cumulative / 0.025 ether) charge = true;
            cumulative += amount;
            uint256 untilBefore = game.shieldUntil(alice);
            _buy(alice, amount, useShield ? SherwoodV2.Move.SHIELD : SherwoodV2.Move.BUY);
            if (useShield && charge) {
                charge = false;
                assertEq(game.shieldUntil(alice), block.timestamp + 30 minutes, "a SHIELD with a charge arms");
                assertTrue(game.shieldActive(alice));
            } else {
                assertEq(game.shieldUntil(alice), untilBefore, "no charge: the shield is untouched");
            }
            assertEq(game.shieldCharges(0, alice), charge ? 1 : 0);
            (uint128 played,,) = game.shieldStats(0, alice);
            assertEq(played, cumulative);
        }
    }

    /// Steals, Robin Hoods and reflected hits only move points: over any sequence of Buy, Steal,
    /// Robin Hood and Shield plays by three wallets, the board's total is exactly the points scored.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_stealsRobinHoodsAndReflectsAreZeroSum(uint256[10] memory seeds) public {
        address[3] memory players = [alice, bob, carol];
        int256 expectedTotal;
        for (uint256 i; i < seeds.length; ++i) {
            address who = players[seeds[i] % 3];
            uint256 raw = (seeds[i] >> 8) % 4;
            SherwoodV2.Move move = raw == 3 ? SherwoodV2.Move.SHIELD : SherwoodV2.Move(raw);
            uint256 amount = bound(seeds[i] >> 16, MIN_BUY, 0.1 ether);
            int256 potBefore = int256(game.pot(0));
            _buy(who, amount, move);
            expectedTotal += int256(amount / 0.001 ether);
            assertEq(int256(game.pot(0)) - potBefore, int256((amount * 500) / 10_000));
        }
        int256 total;
        for (uint256 i; i < 3; ++i) {
            total += game.points(0, players[i]);
        }
        assertEq(total, expectedTotal, "moves only redistribute points");
        assertEq(address(game).balance, game.pot(0));
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_fundPotAcceptsTheCurrentRoundThroughAYearAhead(uint256 round, uint256 jump) public {
        round = bound(round, 0, 1000);
        jump = bound(jump, 0, 5);
        vm.warp(game.roundStart(jump) + 1);
        vm.deal(address(this), 1 ether);
        if (round < jump || round > jump + 365) {
            vm.expectRevert(SherwoodV2.RoundPassed.selector);
            game.fundPot{value: 1 ether}(round);
            assertEq(game.pot(round), 0);
        } else {
            game.fundPot{value: 1 ether}(round);
            assertEq(game.pot(round), 1 ether);
            assertEq(address(game).balance, 1 ether);
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    function _moveAway(address who, uint256 keepBps) internal {
        uint256 balance = gameToken.balanceOf(who);
        uint256 away = balance - (balance * keepBps) / 10_000;
        vm.prank(who);
        gameToken.transfer(sink, away);
    }

    function _claimIfAny(address who, uint256 round) internal {
        (, address[3] memory top,, uint256[3] memory prize,, address king,, uint256 kingPrize,) = game.result(round);
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            if (top[i] == who) owed += prize[i];
        }
        if (king == who) owed += kingPrize;
        if (owed == 0) return;
        uint256 before = who.balance;
        vm.prank(who);
        game.claim(round);
        assertEq(who.balance - before, owed);
    }
}
