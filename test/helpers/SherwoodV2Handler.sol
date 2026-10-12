// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";
import {AuditDice} from "./SherwoodV2Fixture.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// All successful operations go through the real hook and real PoolManager. Unexpected reverts fail
/// the campaign; expected failures are checked by selector, never swallowed by catch-all handlers.
contract SherwoodV2Handler is Test {
    SherwoodV2 public immutable game;
    AuditDice public immutable dice;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    MockERC20 public immutable token;
    MockERC20 public immutable host;
    PoolKey internal gameKey;
    address public immutable owner;
    address[6] public actors;
    uint256 public constant MAX_ROUND = 32;
    // Internal game constants (README values); pinned so a silent change in the hook fails the campaign.
    uint256 internal constant MIN_BUY = 0.001 ether;
    uint256 internal constant FLIP_TIMEOUT = 10 minutes;

    // Independent ETH-flow ledger. No deal() ever touches the hook, manager, or Dice.
    uint256 public deposits;
    uint256 public swapFees;
    uint256 public prizesPaid;
    uint256 public referralsPaid;
    uint256 public burnETH;
    uint256 public buys;
    uint256 public sells;
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

    constructor(SherwoodV2 g, AuditDice d, PoolSwapTest r, MockERC20 t, MockERC20 h, PoolKey memory key_) {
        game = g;
        dice = d;
        manager = g.poolManager();
        router = r;
        token = t;
        host = h;
        gameKey = key_;
        owner = g.owner();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("sequence actor ", vm.toString(i)));
        }
    }

    function buy(uint256 actorSeed, uint256 rawAmount, uint256 moveSeed, uint256 refSeed) public {
        address player = actors[actorSeed % actors.length];
        uint256 amount = bound(rawAmount, 1, 0.2 ether);
        uint256 beforeTokens = token.balanceOf(player);
        uint256 poolBefore = address(manager).balance;
        uint256 paidDiceBefore = dice.received();
        uint256 hookBefore = address(game).balance;
        uint256 round = game.currentRound();
        uint256 boughtBefore = game.bought(round, player);
        vm.deal(player, player.balance + amount);
        vm.prank(player, player);
        BalanceDelta delta = router.swap{value: amount}(
            gameKey,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(moveSeed % 5, actors[refSeed % actors.length])
        );
        uint256 fee = amount / 20;
        swapFees += fee;
        ++buys;
        assertEq(int256(delta.amount0()), -int256(amount));
        assertEq(address(manager).balance - poolBefore + fee, amount);
        assertEq(address(game).balance + dice.received() - paidDiceBefore, hookBefore + fee);
        uint256 receivedTokens = token.balanceOf(player) - beforeTokens;
        assertEq(int256(delta.amount1()), int256(receivedTokens));
        assertEq(game.bought(round, player) - boughtBefore, amount >= MIN_BUY ? receivedTokens : 0);
    }

    function sell(uint256 actorSeed, uint256 amountSeed) public {
        address player = actors[actorSeed % actors.length];
        uint256 tokens = token.balanceOf(player);
        if (tokens == 0) return;
        uint256 amount = bound(amountSeed, 1, tokens);
        uint256 beforeETH = player.balance;
        uint256 poolBefore = address(manager).balance;
        uint256 hookBefore = address(game).balance;
        int256 score = game.points(game.currentRound(), player);
        vm.startPrank(player, player);
        token.approve(address(router), type(uint256).max);
        BalanceDelta delta = router.swap(
            gameKey,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        uint256 gross = poolBefore - address(manager).balance;
        swapFees += gross / 20;
        ++sells;
        assertEq(address(game).balance - hookBefore, gross / 20);
        assertEq(player.balance - beforeETH + gross / 20, gross);
        assertEq(int256(delta.amount1()), -int256(amount));
        assertEq(game.points(game.currentRound(), player), score > 0 ? int256(0) : score);
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

    function transferHolding(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool hostToken) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        MockERC20 asset = hostToken ? host : token;
        uint256 amount = bound(amountSeed, 0, asset.balanceOf(from));
        vm.prank(from);
        asset.transfer(to, amount);
    }

    function advance(uint256 elapsed) public {
        uint256 latest = game.roundStart(MAX_ROUND);
        uint256 next = vm.getBlockTimestamp() + bound(elapsed, 0, 3 * game.ROUND_LENGTH());
        vm.warp(next < latest ? next : latest);
    }

    function diceFailure(uint256 feeSeed, uint256 modeSeed) public {
        // Includes a free request, ordinary fees, exactly the fee cap, and fees just above it.
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
                vm.expectRevert(SherwoodV2.FlipNotExpired.selector);
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
            vm.expectRevert(SherwoodV2.FlipsPending.selector);
            game.settle(round, 6);
            // Permissionless recovery is possible for every flip once settlement opens.
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
            if (referralOwed == 0) vm.expectRevert(SherwoodV2.NothingToClaim.selector);
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
            reason = SherwoodV2.NotSettled.selector;
        } else if (block.timestamp > game.claimDeadline(round)) {
            reason = SherwoodV2.ClaimWindowClosed.selector;
        } else if (owed != 0 && token.balanceOf(player) < game.heldToClaim(round, player)) {
            reason = SherwoodV2.MustHoldToClaim.selector;
        } else if (owed == 0) {
            reason = SherwoodV2.NothingToClaim.selector;
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
            vm.expectRevert(SherwoodV2.NotSettled.selector);
            game.sweepUnclaimed(round);
        } else if (block.timestamp <= game.claimDeadline(round)) {
            vm.expectRevert(SherwoodV2.ClaimWindowOpen.selector);
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

    function burn(uint256 amountSeed, bool hostBurn, bool rejectSlippage) public {
        uint256 reserve = hostBurn ? game.hostBuybackReserve() : game.buybackReserve();
        if (reserve == 0) return;
        uint256 requested = bound(amountSeed, 1, reserve);
        uint256 poolBefore = address(manager).balance;
        uint256 beforeETH = address(game).balance;
        uint256 other = hostBurn ? game.buybackReserve() : game.hostBuybackReserve();
        uint256 minimum = rejectSlippage ? type(uint256).max : 0;
        vm.prank(owner);
        if (rejectSlippage) vm.expectRevert(SherwoodV2.TooLittleOut.selector);
        if (hostBurn) game.buybackAndBurnHost(requested, minimum);
        else game.buybackAndBurn(requested, minimum);
        uint256 paid = address(manager).balance - poolBefore;
        burnETH += paid;
        if (!rejectSlippage) ++burns;
        assertEq(beforeETH - address(game).balance, paid);
        assertLe(paid, requested);
        assertEq(hostBurn ? game.hostBuybackReserve() : game.buybackReserve(), reserve - paid);
        assertEq(hostBurn ? game.buybackReserve() : game.hostBuybackReserve(), other);
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
