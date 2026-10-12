// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";

/// Revision 2 of the King of the Hill tracking: once the cached #1 of a round with more than
/// MAX_LEADER_SCAN (1,500) players is debited, or #1 loses a flip on a board of more than
/// MAX_CALLBACK_SCAN (12), #1 is "unknown" (reign holder address(1)) and the next play, sell or flip
/// expiry resumes the rescan in chunks of at least LEADER_SCAN_CHUNK (200) players, as far as its gas
/// allows. Every point change restarts the unknown spell; when the rescan completes, the #1 it finds
/// is credited back to the spell's start. The implementation's own tests drive the resume through
/// plays; these cover the other two entry points (a sell and a flip expiry), a restart caused by a
/// Dice loss mid-rescan, conservation of reign seconds across repeated spells, a fuzzed check that the
/// chunked rescan always lands on the true #1, the marker's isolation, and the 1,500 boundary.
/// The final unknown spell of a round, which settlement drops instead of crediting to the final #1,
/// is reported in .imd-findings.json rather than asserted here.
contract SherwoodV2UnknownReignTest is SherwoodV2Fixture {
    address internal constant UNKNOWN = address(1);
    uint256 internal constant BIG = 1501; // one over MAX_LEADER_SCAN
    uint256 internal constant CHUNK_GAS = 1_500_000; // a plain buy plus one 200-player chunk
    address internal dave;

    function setUp() public override {
        super.setUp();
        dave = makeAddr("audit dave");
    }

    /// Fills the round with `n` one-point players at distinct synthetic addresses.
    function _fill(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _buy(address(uint160(0x200000 + i)), 0.001 ether, SherwoodV2.Move.BUY);
        }
    }

    function _filler(uint256 i) internal pure returns (address) {
        return address(uint160(0x200000 + i));
    }

    /// A play with the gas budget a wallet's estimate would give it.
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

    /// alice (100), bob (90) and BIG - 2 one-point players.
    function _bigBoard() internal {
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 2);
        assertEq(game.playerCount(0), BIG);
        assertEq(game.reignHolder(0), alice);
    }

    /// The player with the most points above zero, first in join order on a tie (settle's rule).
    function _trueLeader(uint256 round) internal view returns (address best) {
        uint256 n = game.playerCount(round);
        int256 top;
        for (uint256 start; start < n; start += 500) {
            (address[] memory players, int256[] memory pts) = game.playersPage(round, start, 500);
            for (uint256 i; i < players.length; ++i) {
                if (pts[i] > top) (top, best) = (pts[i], players[i]);
            }
        }
    }

    // ── A debit of #1 on a big board ───────────────────────────────────────────

    function test_debitOfTheLeaderOnABigBoardLeavesFirstPlaceUnknownUntilTheNextPlayRescans() public {
        uint256 t0 = GENESIS + 1; // setUp warps here; never cache block.timestamp across warps under via-IR
        _bigBoard();

        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice)); // alice wiped: the board is too big to rescan in the sell
        assertEq(game.reignHolder(0), UNKNOWN, "#1 is unknown, not the debited cache");
        assertEq(game.reignOf(0, alice), 1 hours, "alice keeps exactly the seconds she held #1");
        assertEq(game.leader(0), alice, "the cache is left stale; nothing rescanned 1,501 players");
        assertEq(game.reignOf(0, UNKNOWN), 0, "the marker never accumulates seconds");

        // A play with gas to spare rescans the whole board before it changes anything, so bob is
        // credited from the sell: nothing changed in between.
        vm.warp(t0 + 2 hours);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        assertEq(game.reignHolder(0), bob);
        assertEq(game.leader(0), bob);
        assertEq(game.reignOf(0, bob), 1 hours, "credited back to the sell");
        assertEq(game.reignOf(0, carol), 0);
        assertEq(game.reignOf(0, UNKNOWN), 0);

        _seed(0, 1 ether);
        vm.warp(game.roundEnd(0) + 5 hours);
        assertEq(game.reignOf(0, bob), game.roundEnd(0) - (t0 + 1 hours), "capped at the round's end");
        assertEq(game.reignOf(0, alice) + game.reignOf(0, bob), game.roundEnd(0) - t0, "no overlap, no gap");
        while (!game.settle(0, 400)) {}
        assertEq(game.heldToClaim(0, UNKNOWN), 0, "the marker never wins a slot");
        vm.prank(UNKNOWN);
        vm.expectRevert(SherwoodV2.NothingToClaim.selector);
        game.claim(0);
    }

    // ── The two resume paths the implementation's tests do not drive ───────────

    function test_sellByAScoredPlayerResumesTheRescanBeforeItsOwnDebit() public {
        uint256 t0 = GENESIS + 1;
        _bigBoard();
        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), UNKNOWN);

        // A one-point player sells: afterSwap resumes the rescan first (bob is #1, credited from alice's
        // sell), then wipes the seller, which cannot change #1.
        vm.warp(t0 + 1 hours + 20 minutes);
        _sellAll(_filler(7), 30_000_000);
        assertEq(game.points(0, _filler(7)), 0);
        assertEq(game.reignHolder(0), bob);
        assertEq(game.leader(0), bob);
        assertEq(game.reignOf(0, bob), 20 minutes, "credited back to the start of the unknown spell");

        // A sell under a tight budget only covers one chunk and leaves #1 unknown.
        vm.warp(t0 + 2 hours);
        _sellAll(bob, 1_700_000); // bob wiped: unknown again, and the next sell gets one chunk
        assertEq(game.reignHolder(0), UNKNOWN);
        assertEq(game.reignOf(0, bob), 1 hours);
        vm.warp(t0 + 2 hours + 1 minutes);
        _sellAll(_filler(8), 1_700_000);
        assertEq(game.reignHolder(0), UNKNOWN, "one chunk of 1,501 players is not enough");
        assertEq(game.points(0, _filler(8)), 0);
    }

    function test_sellByAPlayerWithoutPointsNeitherResumesNorRestartsTheSpell() public {
        uint256 t0 = GENESIS + 1;
        _bigBoard();
        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), UNKNOWN);

        // dave never played: his sell changes no points, so it is not a point change and the spell's
        // start stays at alice's sell.
        gameToken.transfer(dave, 1e18);
        vm.warp(t0 + 1 hours + 30 minutes);
        _sellAll(dave, 30_000_000);
        assertEq(game.points(0, dave), 0);
        assertEq(game.reignHolder(0), UNKNOWN);
        assertEq(game.leader(0), alice, "nothing was rescanned");

        vm.warp(t0 + 3 hours);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY);
        assertEq(game.reignHolder(0), bob);
        assertEq(game.reignOf(0, bob), 2 hours, "credited back to alice's sell, not to dave's sell");
    }

    function test_expiredFlipResumesTheRescanBeforeItCreditsTheStake() public {
        uint256 t0 = GENESIS + 1;
        _bigBoard();
        _buy(dave, 0.01 ether, SherwoodV2.Move.FLIP); // stake 10 riding on sequence 1
        assertEq(game.pendingFlips(0), 1);
        assertEq(game.points(0, dave), 0);

        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), UNKNOWN);

        // Dice never answers: anyone expires the flip. The expiry resumes the rescan first (bob, from
        // alice's sell), then credits dave's stake, which cannot pass bob.
        vm.warp(t0 + 1 hours + FLIP_TIMEOUT);
        game.expireFlip(1);
        assertEq(game.points(0, dave), 10);
        assertEq(game.pendingFlips(0), 0);
        assertEq(game.reignHolder(0), bob);
        assertEq(game.leader(0), bob);
        assertEq(game.reignOf(0, bob), FLIP_TIMEOUT);
        assertEq(game.reignOf(0, UNKNOWN), 0);
    }

    // ── A Dice loss by the running best restarts the rescan ────────────────────

    function test_diceLossByTheRunningBestRestartsTheRescanAndTheSpell() public {
        uint256 t0 = GENESIS + 1;
        _bigBoard();
        _buy(carol, 0.085 ether, SherwoodV2.Move.BUY); // 85, the last player: found only by a full rescan
        assertEq(game.playerCount(0), 1502);

        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice)); // unknown; the cache is alice at 0
        uint256 t1 = t0 + 1 hours + 1 minutes;
        vm.warp(t1);
        _play(_filler(0), 0.001 ether, SherwoodV2.Move.BUY, CHUNK_GAS); // chunk 1: bob (90) is the best so far
        assertEq(game.leader(0), bob);
        assertEq(game.reignHolder(0), UNKNOWN);

        // bob flips under a tight budget (chunk 2 scanned, then the request), and loses: the running
        // best lost points, so the rescan starts over from the first player.
        uint256 t2 = t0 + 1 hours + 2 minutes;
        vm.warp(t2);
        _play(bob, 0.01 ether, SherwoodV2.Move.FLIP, 1_800_000);
        assertEq(game.pendingFlips(0), 1);
        uint256 t3 = t0 + 1 hours + 3 minutes;
        vm.warp(t3);
        vm.cool(address(game));
        assertTrue(dice.reveal(1, bytes32(uint256(1))), "a loss by the running best fits the Dice gas limit");
        assertEq(game.points(0, bob), 80);
        assertEq(game.points(0, _filler(0)), 12, "the previous player takes the lost stake: 1 + 1 + 10");
        assertEq(game.leader(0), bob, "the cache is bob, debited: the rescan restarts from the first player");
        assertEq(game.reignHolder(0), UNKNOWN);

        // Without the restart, five more chunks would finish the 1,502 players (two were done).
        // With it, seven more leave the board unfinished and the eighth completes it.
        for (uint256 i = 1; i <= 7; ++i) {
            vm.warp(t3 + i * 1 minutes);
            _play(_filler(1000 + i), 0.001 ether, SherwoodV2.Move.BUY, CHUNK_GAS);
            assertEq(game.reignHolder(0), UNKNOWN, "restarted: still unfinished");
        }
        vm.warp(t3 + 8 minutes);
        _play(_filler(1008), 0.001 ether, SherwoodV2.Move.BUY, CHUNK_GAS);
        assertEq(game.reignHolder(0), carol, "the full rescan finds carol (85) over bob (80)");
        assertEq(game.leader(0), carol);
        vm.warp(t3 + 9 minutes);
        assertEq(game.reignOf(0, carol), 2 minutes, "credited back to the last point change before completion");
        assertEq(game.reignOf(0, bob), 0, "bob never held #1 for an observed second");
    }

    // ── Conservation across repeated spells ────────────────────────────────────

    function test_reignSecondsNeverOverlapAcrossRepeatedUnknownSpellsAndTheKingIsTheLongest() public {
        uint256 t0 = GENESIS + 1;
        _bigBoard();
        uint256 t1 = t0 + 1 hours;
        vm.warp(t1);
        _sell(alice, gameToken.balanceOf(alice)); // spell 1 starts
        uint256 t2 = t0 + 2 hours;
        vm.warp(t2);
        _buy(carol, 0.001 ether, SherwoodV2.Move.BUY); // resolves spell 1: bob from t1
        assertEq(game.reignHolder(0), bob);
        uint256 t3 = t0 + 5 hours;
        vm.warp(t3);
        _sell(bob, gameToken.balanceOf(bob)); // spell 2 starts; nobody above 1 point is left
        assertEq(game.reignHolder(0), UNKNOWN);
        assertEq(game.reignOf(0, bob), 4 hours);
        uint256 t4 = t0 + 6 hours;
        vm.warp(t4);
        _buy(dave, 0.01 ether, SherwoodV2.Move.BUY); // resolves spell 2 first: the first one-point player from t3
        assertEq(game.reignHolder(0), dave, "dave's own 10 points then take #1 from t4");
        assertEq(game.reignOf(0, _filler(0)), 1 hours, "the earliest of the tied one-point players held #1 for spell 2");
        assertEq(game.reignOf(0, carol), 0);

        _seed(0, 10 ether);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        while (!game.settle(0, 400)) {}
        (bool settled, address[3] memory top,,,, address king, uint256 kingReign,,) = game.result(0);
        assertTrue(settled);
        assertEq(top[0], dave);
        assertEq(king, dave, "14 hours at #1 beats bob's 4");
        assertEq(kingReign, game.roundEnd(0) - t4);
        assertEq(kingReign, game.reignOf(0, dave));
        uint256 total = game.reignOf(0, alice) + game.reignOf(0, bob) + game.reignOf(0, _filler(0))
            + game.reignOf(0, dave) + game.reignOf(0, carol) + game.reignOf(0, UNKNOWN);
        assertEq(total, game.roundEnd(0) - t0, "every second of the round is credited exactly once");
    }

    // ── The chunked rescan always lands on the true #1 ─────────────────────────

    /// forge-config: default.fuzz.runs = 6
    function testFuzz_chunkedRescanFindsTheTrueLeader(uint256 seed) public {
        // Five contenders at random sizes, spread across the join order, then alice at the top sells.
        uint256[5] memory slots = [uint256(0), 300, 750, 1200, BIG - 3];
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        for (uint256 i; i < BIG - 1; ++i) {
            uint256 amount = 0.001 ether;
            for (uint256 k; k < 5; ++k) {
                if (i == slots[k]) amount = bound(uint256(keccak256(abi.encode(seed, k))), 0.002 ether, 0.099 ether);
            }
            _buy(_filler(i), amount, SherwoodV2.Move.BUY);
        }
        assertEq(game.playerCount(0), BIG);
        vm.warp(GENESIS + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), UNKNOWN);
        // Plays with random budgets between one chunk and the whole board; the board must resolve
        // within ten of them, on the true #1 (new players score 1 point and cannot pass a contender).
        uint256 plays;
        while (game.reignHolder(0) == UNKNOWN) {
            assertLt(plays, 10, "ten plays of at least one chunk each cover 1,501 players");
            uint256 gas = bound(uint256(keccak256(abi.encode(seed, "gas", plays))), CHUNK_GAS, 9_000_000);
            vm.warp(GENESIS + 1 hours + (plays + 1) * 1 minutes);
            _play(address(uint160(0x400000 + plays)), 0.001 ether, SherwoodV2.Move.BUY, gas);
            ++plays;
        }
        address expected = _trueLeader(0);
        assertEq(game.reignHolder(0), expected, "the rescan must land on the player with the most points");
        assertEq(game.leader(0), expected);
        assertGt(game.points(0, expected), 1);
    }

    // ── Deferred Dice rescan on a board of more than 12 players ────────────────

    function test_deferredDiceRescanIsResolvedByASellAndCreditedBackToTheReveal() public {
        uint256 t0 = GENESIS + 1;
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY); // 50, #1 from t0
        _fill(11);
        _buy(bob, 0.045 ether, SherwoodV2.Move.BUY); // 45; 13 players
        assertEq(game.playerCount(0), 13);

        uint256 t1 = t0 + 60;
        vm.warp(t1);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP); // stake 10, previous = bob
        vm.cool(address(game));
        assertTrue(dice.reveal(1, bytes32(uint256(1))), "callback must fit the Dice gas limit");
        assertEq(game.points(0, alice), 40);
        assertEq(game.points(0, bob), 55);
        assertEq(game.reignHolder(0), UNKNOWN, "13 players is too many to rescan in the callback");
        assertEq(game.reignOf(0, alice), 60);

        // A one-point player sells: afterSwap rescans the board (14 players, in one go) before the wipe.
        uint256 t2 = t1 + 300;
        vm.warp(t2);
        _sellAll(_filler(3), 30_000_000);
        assertEq(game.reignHolder(0), bob);
        assertEq(game.leader(0), bob);
        assertEq(game.reignOf(0, bob), 300, "credited back to the reveal");
        assertEq(game.reignOf(0, UNKNOWN), 0);

        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        assertTrue(game.settle(0, 100));
        (, address[3] memory top,,,, address king, uint256 kingReign,,) = game.result(0);
        assertEq(top[0], bob);
        assertEq(king, bob);
        assertEq(kingReign, game.roundEnd(0) - t1);
        assertEq(kingReign, game.reignOf(0, bob));
        assertEq(game.reignOf(0, alice), 60);
    }

    function test_expiredFlipOfTheLeaderRescansAndLeavesNoMarker() public {
        _buy(alice, 0.05 ether, SherwoodV2.Move.BUY);
        _fill(11);
        _buy(bob, 0.045 ether, SherwoodV2.Move.BUY);
        _buy(alice, 0.01 ether, SherwoodV2.Move.FLIP);
        vm.warp(block.timestamp + FLIP_TIMEOUT);
        game.expireFlip(1); // scores as a buy: alice 60, no debit, no stale cache
        assertEq(game.points(0, alice), 60);
        assertEq(game.reignHolder(0), alice);
        assertEq(game.reignOf(0, UNKNOWN), 0);
    }

    // ── Robin Hood by the stale cached leader ──────────────────────────────────

    function test_robinHoodByTheStaleCachedLeaderWaitsForTheRescanAndKeepsItsCharge() public {
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 2);
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY); // cached leader and last player
        uint256 t1 = GENESIS + 1 + 10 minutes;
        vm.warp(t1);
        _buy(bob, 0.001 ether, SherwoodV2.Move.STEAL); // 20% of alice's 100: bob 111, alice 80
        assertEq(game.points(0, alice), 80);
        assertEq(game.reignHolder(0), UNKNOWN);
        assertEq(game.reignOf(0, alice), 10 minutes);
        uint256 robins = game.robinsLeft(alice);
        vm.warp(t1 + 1 minutes);
        _play(alice, 0.001 ether, SherwoodV2.Move.ROBIN_HOOD, CHUNK_GAS); // one chunk: #1 still unknown
        assertEq(game.points(0, alice), 81, "the buy scores");
        assertEq(game.points(0, bob), 111, "nothing moved");
        assertEq(game.robinsLeft(alice), robins, "no charge spent");
        assertEq(game.reignHolder(0), UNKNOWN);
        assertEq(game.reignOf(0, UNKNOWN), 0, "the open spell restarted at this play");
        // With gas to spare the rescan completes first (bob, credited back to the previous play), then
        // the Robin Hood debits bob: on this board that leaves #1 unknown again.
        vm.warp(t1 + 3 minutes);
        _play(alice, 0.001 ether, SherwoodV2.Move.ROBIN_HOOD, 30_000_000);
        assertEq(game.points(0, bob), 111 - 11, "10% of the leader's points moved at a 1-point buy");
        assertEq(game.robinsLeft(alice), robins - 1);
        assertEq(game.reignOf(0, bob), 2 minutes, "bob held #1 from the restart to the robbery");
        assertEq(game.reignHolder(0), UNKNOWN, "the robbery debited #1 on a board too big to rescan in place");
        assertEq(game.leader(0), bob, "the cache: still the best known, and still above everyone");
    }

    // ── Isolation and the boundary ─────────────────────────────────────────────

    function test_anUnknownSpellDoesNotLeakIntoTheNextRound() public {
        uint256 t0 = GENESIS + 1;
        _bigBoard();
        vm.warp(t0 + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), UNKNOWN);

        vm.warp(game.roundEnd(0) + 1);
        _buy(carol, 0.002 ether, SherwoodV2.Move.BUY);
        assertEq(game.reignHolder(1), carol, "round 1 starts with a known leader");
        assertEq(game.leader(1), carol);
        assertEq(game.reignHolder(0), UNKNOWN, "round 0's spell is round 0's");
        vm.warp(game.roundEnd(1) + game.SETTLE_DELAY());
        while (!game.settle(0, 400)) {}
        assertTrue(game.settle(1, 10));
        (, address[3] memory top,,,, address king, uint256 kingReign,,) = game.result(1);
        assertEq(top[0], carol);
        assertEq(king, carol);
        assertEq(kingReign, game.ROUND_LENGTH() - 1);
        assertEq(game.reignOf(1, UNKNOWN), 0);
        (,,,,, king, kingReign,,) = game.result(0);
        assertEq(kingReign, game.reignOf(0, king), "the King's reign is always what reignOf shows");
        assertTrue(king != UNKNOWN && king != address(0));
    }

    function test_boardOfExactlyMaxLeaderScanIsRescannedInsideTheDebitingSwap() public {
        // 1,500 players is the largest board a swap still rescans: a debited cache is repaired in place.
        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _buy(bob, 0.09 ether, SherwoodV2.Move.BUY);
        _fill(BIG - 3);
        assertEq(game.playerCount(0), 1500);
        vm.warp(block.timestamp + 1 hours);
        _sell(alice, gameToken.balanceOf(alice));
        assertEq(game.reignHolder(0), bob, "a 1,500-player board is rescanned inside the sell");
        assertEq(game.leader(0), bob);
        _buy(dave, 0.01 ether, SherwoodV2.Move.ROBIN_HOOD);
        assertEq(game.points(0, bob), 79); // 90 less 12.3% of 90 at a 10-point buy
        assertEq(game.robinsLeft(dave), 2);
    }
}
