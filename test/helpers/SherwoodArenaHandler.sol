// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SherwoodArena} from "src/SherwoodArena.sol";
import {ArenaDice, MockArenaRouter, TaxPusher} from "./SherwoodArenaFixture.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// SherwoodV21Handler's campaign on the arena. Every move goes through play() and the mock router, which
/// pushes a 1% buy tax to the arena (from a separate contract, as Hookr's tax would) during the swap.
/// Unexpected reverts fail the campaign; expected failures are checked by selector.
contract SherwoodArenaHandler is Test {
    SherwoodArena public immutable game;
    ArenaDice public immutable dice;
    MockArenaRouter public immutable router;
    MockERC20 public immutable token;
    TaxPusher public immutable taxPusher;
    address public immutable owner;
    address[6] public actors;
    uint256 public constant MAX_ROUND = 32;
    uint256 public constant TAX_BPS = 100;
    uint256 internal constant MIN_BUY = 0.001 ether;
    uint256 internal constant FLIP_TIMEOUT = 10 minutes;

    // Independent ETH-flow ledger. No deal() ever touches the arena, the router or Dice.
    uint256 public deposits;
    uint256 public swapFees; // play fees and buy tax: ETH from moves that stays in the arena
    uint256 public prizesPaid;
    uint256 public referralsPaid;
    uint256 public burnETH;
    uint256 public buys;
    uint256 public sells;
    uint256 public taxPushes;
    uint256 public settledRounds;
    uint256 public prizeClaims;
    uint256 public referralClaims;
    uint256 public sweptRounds;
    uint256 public burns;
    uint256 public revealed;
    uint256 public expired;
    uint256 public refunds;
    mapping(uint256 => bytes32) public frozen;
    mapping(uint256 => bool) public swept;

    constructor(SherwoodArena g, ArenaDice d, MockArenaRouter r, MockERC20 t) {
        game = g;
        dice = d;
        router = r;
        token = t;
        taxPusher = new TaxPusher();
        owner = g.owner();
        r.setTax(TAX_BPS, address(g), false);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("sequence actor ", vm.toString(i)));
        }
    }

    function buy(uint256 actorSeed, uint256 rawAmount, uint256 moveSeed, uint256 refSeed) public {
        address player = actors[actorSeed % actors.length];
        uint256 amount = bound(rawAmount, 1, 0.2 ether);
        uint256 beforeTokens = token.balanceOf(player);
        uint256 routerBefore = router.ethReceived();
        uint256 paidDiceBefore = dice.received();
        uint256 gameBefore = address(game).balance;
        uint256 round = game.currentRound();
        uint256 boughtBefore = game.bought(round, player);
        vm.deal(player, player.balance + amount);
        vm.prank(player);
        game.play{value: amount}(uint8(moveSeed % 5), 0, actors[refSeed % actors.length]);
        uint256 fee = amount / 20;
        uint256 tax = ((amount - fee) * TAX_BPS) / 10_000;
        swapFees += fee + tax;
        ++buys;
        assertEq(router.ethReceived() - routerBefore + fee + tax, amount, "every wei of the move is accounted");
        assertEq(address(game).balance + dice.received() - paidDiceBefore, gameBefore + fee + tax);
        uint256 receivedTokens = token.balanceOf(player) - beforeTokens;
        assertEq(receivedTokens, amount - fee - tax, "1:1 at the mock router, after the fee and the tax");
        assertEq(game.bought(round, player) - boughtBefore, amount >= MIN_BUY ? receivedTokens : 0);
    }

    /// A sell anywhere else: the arena sees nothing; only the balance drops (tokens leave to an outsider).
    function sell(uint256 actorSeed, uint256 amountSeed) public {
        address player = actors[actorSeed % actors.length];
        uint256 tokens = token.balanceOf(player);
        if (tokens == 0) return;
        uint256 amount = bound(amountSeed, 1, tokens);
        uint256 gameBefore = address(game).balance;
        int256 score = game.points(game.currentRound(), player);
        vm.prank(player);
        token.transfer(address(0xbeef), amount);
        ++sells;
        assertEq(address(game).balance, gameBefore);
        assertEq(game.points(game.currentRound(), player), score, "a sell doesn't touch points");
    }

    /// The pool's buy tax arriving on its own (not during one of the arena's swaps).
    function pushTax(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 0, 0.5 ether);
        uint256 round = game.currentRound();
        uint256 potBefore = game.pot(round);
        vm.deal(address(this), amount);
        taxPusher.push{value: amount}(address(game));
        deposits += amount;
        ++taxPushes;
        assertEq(game.pot(round), potBefore + amount);
    }

    function fund(uint256 roundSeed, uint256 amountSeed, bool plainTransfer) public {
        uint256 amount = bound(amountSeed, 0, 2 ether);
        uint256 round = game.currentRound() + roundSeed % 3;
        vm.deal(address(this), amount);
        if (plainTransfer) {
            (bool ok,) = address(game).call{value: amount}("");
            assertTrue(ok);
        } else {
            game.fundPot{value: amount}(round);
        }
        deposits += amount;
    }

    function transferHolding(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function advance(uint256 elapsed) public {
        uint256 latest = game.roundStart(MAX_ROUND);
        uint256 next = vm.getBlockTimestamp() + bound(elapsed, 0, 3 * game.ROUND_LENGTH());
        vm.warp(next < latest ? next : latest);
    }

    function diceFailure(uint256 feeSeed, uint256 modeSeed) public {
        uint128[5] memory fees =
            [uint128(0), 25_000_000_000_000, 100_000_000_000_000, 500_000_000_000_000, 500_000_000_000_001];
        dice.configure(fees[feeSeed % 5], uint8(modeSeed % 3));
    }

    function resolve(uint256 sequenceSeed, bool win, bool expireInstead) public {
        if (dice.nextSequence() == 1) return;
        uint64 seq = uint64(bound(sequenceSeed, 1, dice.nextSequence() - 1));
        (address player,,, uint64 requestedAt,,) = game.flips(seq);
        if (player == address(0)) return;
        if (expireInstead) {
            if (block.timestamp < requestedAt + FLIP_TIMEOUT) {
                vm.expectRevert(SherwoodArena.FlipNotExpired.selector);
                game.expireFlip(seq);
                return;
            }
            game.expireFlip(seq);
            ++expired;
        } else {
            vm.cool(address(game));
            assertTrue(dice.reveal(seq, bytes32(uint256(win ? 2 : 1))), "callback exceeded requested gas");
            ++revealed;
        }
        (player,,,,,) = game.flips(seq);
        assertEq(player, address(0));
    }

    function settleRound(uint256 roundSeed, uint256 batchSeed) public {
        uint256 live = game.currentRound();
        if (live == 0) return;
        uint256 round = bound(roundSeed, 0, live - 1);
        (bool settled,,,,,,,,) = game.result(round);
        if (settled || block.timestamp < game.roundEnd(round) + game.SETTLE_DELAY()) return;
        if (game.pendingFlips(round) != 0) {
            vm.expectRevert(SherwoodArena.FlipsPending.selector);
            game.settle(round, 6);
            for (uint64 seq = 1; seq < dice.nextSequence(); ++seq) {
                (address player,, uint64 r,,,) = game.flips(seq);
                if (player != address(0) && r == round) {
                    game.expireFlip(seq);
                    ++expired;
                }
            }
        }
        if (game.settle(round, bound(batchSeed, 1, 6))) {
            ++settledRounds;
            frozen[round] = settlementDigest(round);
        }
    }

    function claim(uint256 roundSeed, uint256 actorSeed, bool referral) public {
        address player = actors[actorSeed % actors.length];
        uint256 beforeETH = player.balance;
        if (referral) {
            uint256 referralOwed = game.referralEarnings(player);
            vm.prank(player);
            if (referralOwed == 0) vm.expectRevert(SherwoodArena.NothingToClaim.selector);
            game.claimReferral();
            assertEq(player.balance - beforeETH, referralOwed);
            referralsPaid += referralOwed;
            if (referralOwed > 0) ++referralClaims;
            return;
        }
        uint256 round = bound(roundSeed, 0, game.currentRound());
        (
            bool settled,
            address[3] memory top,,
            uint256[3] memory prize,
            bool[3] memory claimed,
            address king,,
            uint256 kingPrize,
            bool kingClaimed
        ) = game.result(round);
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            if (top[i] == player && !claimed[i]) owed += prize[i];
        }
        if (king == player && !kingClaimed) owed += kingPrize;
        bytes4 reason;
        if (!settled) {
            reason = SherwoodArena.NotSettled.selector;
        } else if (block.timestamp > game.claimDeadline(round)) {
            reason = SherwoodArena.ClaimWindowClosed.selector;
        } else if (owed != 0 && token.balanceOf(player) < game.heldToClaim(round, player)) {
            reason = SherwoodArena.MustHoldToClaim.selector;
        } else if (owed == 0) {
            reason = SherwoodArena.NothingToClaim.selector;
        }
        vm.prank(player);
        if (reason != bytes4(0)) vm.expectRevert(reason);
        game.claim(round);
        if (reason == bytes4(0)) {
            assertEq(player.balance - beforeETH, owed);
            prizesPaid += owed;
            ++prizeClaims;
        } else {
            assertEq(player.balance, beforeETH);
        }
    }

    function sweep(uint256 roundSeed) public {
        uint256 round = bound(roundSeed, 0, game.currentRound());
        (bool settled,,,,,,,,) = game.result(round);
        if (!settled || swept[round]) {
            vm.expectRevert(SherwoodArena.NotSettled.selector);
            game.sweepUnclaimed(round);
        } else if (block.timestamp <= game.claimDeadline(round)) {
            vm.expectRevert(SherwoodArena.ClaimWindowOpen.selector);
            game.sweepUnclaimed(round);
        } else {
            uint256 live = game.currentRound();
            uint256 beforePot = game.pot(live);
            uint256 unpaid = unpaidPrizes(round);
            game.sweepUnclaimed(round);
            assertEq(game.pot(live), beforePot + unpaid);
            swept[round] = true;
            ++sweptRounds;
        }
    }

    /// The burn's own buy pays the tax too: it comes straight back into the live pot.
    function burn(uint256 amountSeed, bool, bool rejectSlippage) public {
        uint256 reserve = game.buybackReserve();
        if (reserve == 0) return;
        uint256 requested = bound(amountSeed, 1, reserve);
        uint256 routerBefore = router.ethReceived();
        uint256 beforeETH = address(game).balance;
        uint256 live = game.currentRound();
        uint256 potBefore = game.pot(live);
        uint256 minimum = rejectSlippage ? type(uint256).max : 0;
        vm.prank(owner);
        if (rejectSlippage) vm.expectRevert("router: too little out");
        game.buybackAndBurn(requested, minimum);
        if (rejectSlippage) {
            assertEq(game.buybackReserve(), reserve);
            assertEq(address(game).balance, beforeETH);
            return;
        }
        uint256 paid = router.ethReceived() - routerBefore;
        // The tax on the burn's own buy is the arena's ETH coming back (into the pot), not new ETH in:
        // the arena's net outflow is what the router kept.
        uint256 tax = (requested * TAX_BPS) / 10_000;
        burnETH += paid;
        ++burns;
        assertEq(paid + tax, requested);
        assertEq(beforeETH - address(game).balance, paid);
        assertEq(game.buybackReserve(), reserve - requested);
        assertEq(game.pot(live), potBefore + tax);
    }

    function refund(uint256 sequenceSeed) public {
        if (dice.nextSequence() == 1) return;
        uint64 seq = uint64(bound(sequenceSeed, 1, dice.nextSequence() - 1));
        (address consumer,, uint128 paid,, bool wasRevealed, bool wasRefunded) = dice.requests(seq);
        (address player,,,,,) = game.flips(seq);
        if (consumer == address(0) || player != address(0) || wasRevealed || wasRefunded) return;
        uint256 beforeReserve = game.buybackReserve();
        vm.prank(owner);
        game.refundDiceRequest(seq);
        assertEq(game.buybackReserve(), beforeReserve + paid);
        ++refunds;
    }

    function unpaidPrizes(uint256 round) public view returns (uint256 amount) {
        (,,, uint256[3] memory prizes, bool[3] memory claimed,,, uint256 kingPrize, bool kingClaimed) =
            game.result(round);
        for (uint256 i; i < 3; ++i) {
            if (!claimed[i]) amount += prizes[i];
        }
        if (!kingClaimed) amount += kingPrize;
    }

    function settlementDigest(uint256 round) public view returns (bytes32) {
        (
            bool settled,
            address[3] memory top,
            int256[3] memory pts,
            uint256[3] memory prizes,,
            address king,
            uint256 reign,
            uint256 kingPrize,
        ) = game.result(round);
        bytes32 scores;
        for (uint256 i; i < actors.length; ++i) {
            scores = keccak256(abi.encode(scores, game.points(round, actors[i]), game.heldToClaim(round, actors[i])));
        }
        return
            keccak256(abi.encode(settled, top, pts, prizes, king, reign, kingPrize, game.claimDeadline(round), scores));
    }
}
