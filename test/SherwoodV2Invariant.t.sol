// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2Handler} from "./helpers/SherwoodV2Handler.sol";

/// Six actors trade through real v4 accounting over up to 32 rounds. Settled pots are historical
/// totals, not liabilities: only unsettled pots, unpaid prizes, referrals, and reserves are owed.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SherwoodV2InvariantTest is SherwoodV2Fixture {
    SherwoodV2Handler internal handler;

    function setUp() public override {
        super.setUp();
        _configureBurns();
        handler = new SherwoodV2Handler(game, dice, router, gameToken, hostToken, gameKey);
        hostToken.mint(handler.actors(0), HOST_MIN);
        // Start with active referrals, outstanding prizes, both burn reserves, and an expired request.
        handler.fund(0, 1 ether, false);
        handler.buy(0, 0.001 ether, 0, 0);
        handler.buy(1, 0.1 ether, 0, 0);
        handler.buy(2, 0.08 ether, 0, 0);
        handler.buy(3, 0.05 ether, 3, 0);
        handler.advance(game.ROUND_LENGTH() + game.SETTLE_DELAY());
        handler.settleRound(0, 6);
        handler.claim(0, 1, false);
        handler.claim(0, 0, true);
        handler.refund(1);
        handler.burn(100_000_000_000_000, false, false);
        handler.buy(4, 0.025 ether, 4, 0);
        handler.buy(5, 0.01 ether, 1, 0);
        handler.buy(0, 0.01 ether, 2, 0);
        handler.buy(1, 0.01 ether, 3, 0);

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

    function invariant_allETHHasExactlyOneLiability() public view {
        uint256 owed = game.buybackReserve() + game.hostBuybackReserve();
        for (uint256 r; r <= handler.MAX_ROUND() + 2; ++r) {
            (bool settled,,,,,,,,) = game.result(r);
            owed += settled ? handler.unpaidPrizes(r) : game.pot(r);
        }
        for (uint256 i; i < 6; ++i) {
            owed += game.referralEarnings(handler.actors(i));
        }
        assertEq(address(game).balance, owed, "ETH must back every obligation exactly, including rounding dust");
    }

    function invariant_totalETHOutNeverExceedsRecordedETHIn() public view {
        uint256 inflow = handler.deposits() + handler.swapFees() + dice.returned();
        uint256 outflow = handler.prizesPaid() + handler.referralsPaid() + handler.burnETH() + dice.received();
        assertLe(outflow, inflow);
        assertEq(address(game).balance + outflow, inflow, "external cash-flow ledger must reconcile");
        assertEq(address(dice).balance + dice.returned(), dice.received());
    }

    function invariant_settledRanksPrizesAndScoresNeverChange() public view {
        for (uint256 r; r <= game.currentRound(); ++r) {
            bytes32 digest = handler.frozen(r);
            if (digest != bytes32(0)) {
                assertEq(handler.settlementDigest(r), digest, "finalized game outcome changed");
                assertEq(game.pendingFlips(r), 0);
            }
        }
    }

    function invariant_finalWinnersMatchScoresAndReignDurations() public view {
        for (uint256 round; round < game.currentRound(); ++round) {
            (bool settled, address[3] memory top, int256[3] memory pts,,, address king, uint256 kingReign,,) =
                game.result(round);
            if (!settled) continue;
            assertGe(pts[0], pts[1]);
            assertGe(pts[1], pts[2]);
            for (uint256 rank; rank < 3; ++rank) {
                if (top[rank] == address(0)) {
                    assertEq(pts[rank], 0);
                } else {
                    assertGt(pts[rank], 0);
                    assertEq(game.points(round, top[rank]), pts[rank]);
                    for (uint256 prior; prior < rank; ++prior) {
                        assertTrue(top[prior] != top[rank]);
                    }
                }
            }
            uint256 totalReign;
            for (uint256 i; i < 6; ++i) {
                address actor = handler.actors(i);
                int256 score = game.points(round, actor);
                // Every unplaced candidate must be below each rank not already occupied by them.
                for (uint256 rank; rank < 3; ++rank) {
                    if (actor == top[rank]) break;
                    assertLe(score, pts[rank]);
                }
                uint256 reign = game.reignOf(round, actor);
                totalReign += reign;
                assertLe(reign, kingReign);
                if (reign == kingReign && reign != 0) assertLe(score, game.points(round, king));
            }
            assertLe(totalReign, game.ROUND_LENGTH());
            assertEq(game.reignOf(round, king), kingReign);
        }
    }

    function invariant_pendingFlipCountersMatchLiveRequests() public view {
        uint256[35] memory pending;
        for (uint64 seq = 1; seq < dice.nextSequence(); ++seq) {
            (address player,, uint64 r,,,) = game.flips(seq);
            if (player != address(0)) {
                ++pending[r];
                (address consumer,,,, bool revealed, bool refunded) = dice.requests(seq);
                assertEq(consumer, address(game));
                assertFalse(revealed || refunded);
            }
        }
        for (uint256 r; r < pending.length; ++r) {
            assertEq(game.pendingFlips(r), pending[r]);
        }
    }

    function invariant_chargeViewsAndReignsStayConsistent() public view {
        uint256 round = game.currentRound();
        uint256 reignSum;
        address leader = game.reignHolder(round);
        int256 leading = game.points(round, leader);
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            uint256[3] memory left = [game.stealsLeft(actor), game.robinsLeft(actor), game.flipsLeft(actor)];
            uint256[3] memory cap = [uint256(18), 3, 6];
            uint256[3] memory interval = [uint256(10 minutes), 1 hours, 6 hours + 40 minutes];
            (uint256 s, uint256 r, uint256 f) = game.nextCharges(actor);
            uint256[3] memory next = [s, r, f];
            for (uint256 j; j < 3; ++j) {
                assertLe(left[j], cap[j]);
                if (left[j] == cap[j]) {
                    assertEq(next[j], 0);
                } else {
                    assertGt(next[j], block.timestamp);
                    assertLe(next[j], block.timestamp + interval[j]);
                }
            }
            assertLe(game.shieldCharges(round, actor), 1);
            reignSum += game.reignOf(round, actor);
            assertLe(game.points(round, actor), leading > 0 ? leading : int256(0), "small-board reign holder must lead");
        }
        assertLe(reignSum, block.timestamp - game.roundStart(round), "reign seconds must not overlap");
        if (leader != address(0)) assertGt(leading, 0);
    }

    function test_handlerExercisesRecoveryClaimsAndSweeps() public {
        handler.resolve(2, false, false);
        handler.sell(4, 1);
        handler.burn(1 ether, true, false);
        handler.advance(3 * game.ROUND_LENGTH());
        handler.advance(3 * game.ROUND_LENGTH());
        handler.advance(3 * game.ROUND_LENGTH());
        handler.sweep(0);
        assertGt(handler.buys(), 0);
        assertGt(handler.sells(), 0);
        assertGt(handler.settledRounds(), 0);
        assertGt(handler.prizeClaims(), 0);
        assertGt(handler.referralClaims(), 0);
        assertGt(handler.expired(), 0);
        assertGt(handler.revealed(), 0);
        assertGt(handler.refunds(), 0);
        assertGt(handler.burns(), 0);
        assertGt(handler.sweptRounds(), 0);
        invariant_allETHHasExactlyOneLiability();
        invariant_totalETHOutNeverExceedsRecordedETHIn();
        invariant_settledRanksPrizesAndScoresNeverChange();
        invariant_finalWinnersMatchScoresAndReignDurations();
        invariant_pendingFlipCountersMatchLiveRequests();
        invariant_chargeViewsAndReignsStayConsistent();
    }
}
