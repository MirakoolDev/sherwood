// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2Handler} from "./helpers/SherwoodV2Handler.sol";

/// The same six-actor handler as SherwoodV2Invariant, started from a different state: no settled
/// round, nothing claimed, the Dice fee at its cap (so flips cost the pot the most they can), a shield
/// already broken by a reflected Robin Hood, a player below zero and a flip pending. The campaign
/// checks that what the hook holds is exactly what it owes
/// on this trajectory too, and adds consistency checks between the reign holder, the cached #1 and the
/// actors' points, and between claim deadlines and round ends.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SherwoodV2FreshBoardInvariantTest is SherwoodV2Fixture {
    SherwoodV2Handler internal handler;
    address internal constant UNKNOWN_REIGN = address(1);

    function setUp() public override {
        super.setUp();
        handler = new SherwoodV2Handler(game, dice, router, gameToken, hostToken, gameKey);
        hostToken.mint(handler.actors(2), HOST_MIN);
        handler.diceFailure(3, 0); // the fee cap exactly: a flip needs a buy of at least 0.01 ETH
        handler.fund(0, 0.5 ether, true);
        handler.buy(0, 0.025 ether, 4, 1); // a shield up
        handler.buy(1, 0.05 ether, 3, 0); // a flip pending at the cap fee
        handler.buy(2, 0.01 ether, 1, 0); // a steal by the host holder
        handler.buy(3, 0.001 ether, 2, 5); // a minimum Robin Hood

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.transferHolding.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.diceFailure.selector;
        selectors[6] = handler.resolve.selector;
        selectors[7] = handler.settleRound.selector;
        selectors[8] = handler.claim.selector;
        selectors[9] = handler.sweep.selector;
        selectors[10] = handler.burn.selector;
        selectors[11] = handler.refund.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ethHeldEqualsEveryObligation() public view {
        uint256 owed = game.buybackReserve() + game.hostBuybackReserve();
        for (uint256 r; r <= handler.MAX_ROUND() + 2; ++r) {
            (bool settled,,,,,,,,) = game.result(r);
            owed += settled ? handler.unpaidPrizes(r) : game.pot(r);
        }
        for (uint256 i; i < 6; ++i) {
            owed += game.referralEarnings(handler.actors(i));
        }
        assertEq(address(game).balance, owed, "every wei held must be owed to exactly one obligation");
        uint256 inflow = handler.deposits() + handler.swapFees() + dice.returned();
        uint256 outflow = handler.prizesPaid() + handler.referralsPaid() + handler.burnETH() + dice.received();
        assertLe(outflow, inflow, "ETH out can never exceed ETH in");
    }

    function invariant_reignHolderIsTheCachedLeaderWithTheMostPoints() public view {
        uint256 round = game.currentRound();
        address holder = game.reignHolder(round);
        assertTrue(holder != UNKNOWN_REIGN, "six players never leave #1 unknown between transactions");
        int256 best;
        for (uint256 i; i < 6; ++i) {
            int256 p = game.points(round, handler.actors(i));
            if (p > best) best = p;
        }
        if (holder == address(0)) {
            assertLe(best, 0, "nobody at #1 means nobody above zero");
        } else {
            assertEq(holder, game.leader(round), "the reign holder is the cached #1");
            assertEq(game.points(round, holder), best, "the reign holder has the most points");
            assertGt(best, 0);
        }
    }

    function invariant_settledRoundsKeepSevenDaysToClaimAndNeverHoldPendingFlips() public view {
        for (uint256 r; r < game.currentRound(); ++r) {
            (bool settled,, int256[3] memory pts, uint256[3] memory prize,,,, uint256 kingPrize,) = game.result(r);
            if (!settled) continue;
            assertGe(game.claimDeadline(r), game.roundEnd(r) + CLAIM_WINDOW);
            assertEq(game.pendingFlips(r), 0);
            uint256 total = game.pot(r);
            assertLe(prize[0], (total * 4000) / 10_000);
            assertLe(prize[1], (total * 2000) / 10_000);
            assertLe(prize[2], (total * 1000) / 10_000);
            assertLe(kingPrize, (total * 800) / 10_000);
            for (uint256 i; i < 3; ++i) {
                if (pts[i] <= 0) assertEq(prize[i], 0, "no prize without points above zero");
            }
        }
    }

    function test_freshBoardStartsWithAReflectedHitAFlipAndAFullLiability() public view {
        // The seeded Robin Hood aimed at the shielded leader: reflected, the shield broke, the robber paid.
        assertFalse(game.shieldActive(handler.actors(0)));
        assertEq(game.shieldCharges(0, handler.actors(0)), 0);
        assertEq(game.points(0, handler.actors(3)), -1, "a minimum Robin Hood paid 2 of its 1 point");
        assertEq(game.pendingFlips(0), 1);
        assertEq(game.pot(0) + dice.received(), handler.deposits() + handler.swapFees());
        invariant_ethHeldEqualsEveryObligation();
        invariant_reignHolderIsTheCachedLeaderWithTheMostPoints();
        invariant_settledRoundsKeepSevenDaysToClaimAndNeverHoldPendingFlips();
    }
}
