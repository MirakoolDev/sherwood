// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SherwoodArenaFixture, MockArenaRouter} from "./helpers/SherwoodArenaFixture.sol";
import {SherwoodArena, IArenaRouter, IDiceEntropy} from "src/SherwoodArena.sol";

interface IFlashBorrower {
    function onFlash(uint256 amount) external;
}

/// Lends the token for one call, as a v4 PoolManager.unlock + take + settle would (free): the tokens go
/// out, the borrower's callback runs, and all of them must be back before the call returns.
contract FlashLender {
    MockERC20 public immutable token;

    constructor(MockERC20 t) {
        token = t;
    }

    function flash(uint256 amount, IFlashBorrower to) external {
        uint256 before = token.balanceOf(address(this));
        token.transfer(address(to), amount);
        to.onFlash(amount);
        require(token.balanceOf(address(this)) >= before, "flash not repaid");
    }
}

/// A contract player that sells its bag during the round and borrows the token for one transaction to
/// pass the holding checks: at settlement and claim, or inside play() for the holder bonus.
contract FlashPlayer is IFlashBorrower {
    SherwoodArena public immutable game;
    MockERC20 public immutable token;
    FlashLender public immutable lender;
    uint8 internal action; // 1 settle then claim, 2 claim, 3 play
    uint256 internal round;
    uint256 internal playValue;
    uint256 public walletDuringLoan;
    bool public bonusDuringLoan;
    bool public claimed;
    bytes public claimError;

    constructor(SherwoodArena g, MockERC20 t, FlashLender l) {
        (game, token, lender) = (g, t, l);
    }

    receive() external payable {}

    function play(uint8 move) external payable {
        game.play{value: msg.value}(move, 0, address(0));
    }

    function withdraw(uint256 amount) external {
        game.withdraw(amount);
    }

    function claim(uint256 r) external {
        game.claim(r);
    }

    /// Gets rid of every token in its wallet (sold elsewhere).
    function dump(address to) external {
        token.transfer(to, token.balanceOf(address(this)));
    }

    function settleAndClaimOnLoan(uint256 r, uint256 amount) external {
        (action, round) = (1, r);
        lender.flash(amount, this);
    }

    function claimOnLoan(uint256 r, uint256 amount) external {
        (action, round) = (2, r);
        lender.flash(amount, this);
    }

    function playOnLoan(uint256 amount) external payable {
        (action, playValue) = (3, msg.value);
        lender.flash(amount, this);
    }

    function onFlash(uint256 amount) external {
        require(msg.sender == address(lender), "not the lender");
        walletDuringLoan = token.balanceOf(address(this));
        if (action == 1) game.settle(round, 100);
        if (action == 1 || action == 2) {
            try game.claim(round) {
                claimed = true;
            } catch (bytes memory err) {
                claimError = err;
            }
        } else if (action == 3) {
            bonusDuringLoan = game.holderBonusActive(game.currentRound(), address(this));
            game.play{value: playValue}(0, 0, address(0));
        }
        token.transfer(address(lender), amount);
    }
}

/// A token that calls the receiver back on transfer, to try re-entering the arena from a withdraw.
contract CallbackToken is MockERC20 {
    constructor() MockERC20("PFWA", "PFWA", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool ok) {
        ok = super.transfer(to, amount);
        if (to.code.length > 0) ReentrantHolder(payable(to)).onTokens();
    }
}

/// Holds through the arena and tries every guarded entry point while its withdraw is paying out.
contract ReentrantHolder {
    SherwoodArena public immutable game;
    uint256 public blocked;
    uint256 public attempts;

    constructor(SherwoodArena g) {
        game = g;
    }

    receive() external payable {}

    function play() external payable {
        game.play{value: msg.value}(0, 0, address(0));
    }

    function withdraw(uint256 amount) external {
        game.withdraw(amount);
    }

    function onTokens() external {
        bytes[4] memory calls = [
            abi.encodeCall(SherwoodArena.withdraw, (1)),
            abi.encodeCall(SherwoodArena.play, (0, 0, address(0))),
            abi.encodeCall(SherwoodArena.claim, (0)),
            abi.encodeCall(SherwoodArena.claimReferral, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            ++attempts;
            (bool ok, bytes memory err) = address(game).call(calls[i]);
            if (!ok && bytes4(err) == SherwoodArena.Reentered.selector) ++blocked;
        }
    }
}

/// The arena keeps what play() buys (holdings) until the player withdraws; the settlement sell rule,
/// the claim check and the holder bonus read holdings, which only play() grows. A token borrowed for
/// one transaction can't pass them.
contract SherwoodArenaEscrowTest is SherwoodArenaFixture {
    event Withdrawn(address indexed player, uint256 amount);
    event PrizeForfeited(uint256 indexed round, address indexed player, uint256 amount);

    FlashLender internal lender;
    FlashPlayer internal attacker;
    address internal sink;

    function setUp() public override {
        super.setUp();
        lender = new FlashLender(gameToken);
        attacker = new FlashPlayer(game, gameToken, lender);
        sink = makeAddr("escrow sink");
    }

    function _attackerPlays(uint256 amount) internal {
        vm.deal(address(this), amount);
        attacker.play{value: amount}(0);
    }

    // ── The flash-borrow attack ─────────────────────────────────────────────────

    function test_aFlashLoanAtSettlementCannotSaveASoldBag() public {
        _attackerPlays(0.05 ether); // 50: #1 and King all round
        _buy(bob, 0.02 ether, SherwoodArena.Move.BUY);
        _buy(carol, 0.01 ether, SherwoodArena.Move.BUY);
        _seed(0, 1 ether);
        uint256 owed = game.bought(0, address(attacker));
        attacker.withdraw(type(uint256).max);
        attacker.dump(sink); // sold everything during the round
        assertEq(game.holdings(address(attacker)), 0);
        assertEq(gameToken.balanceOf(address(attacker)), 0);

        uint256 total = game.pot(0);
        uint256 loan = 100 * owed;
        gameToken.mint(address(lender), loan);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        uint256 liveBefore = game.pot(1);
        vm.expectEmit(true, true, false, true, address(game));
        emit PrizeForfeited(0, address(attacker), (total * 4000) / 10_000);
        vm.expectEmit(true, true, false, true, address(game));
        emit PrizeForfeited(0, address(attacker), (total * 800) / 10_000);
        attacker.settleAndClaimOnLoan(0, loan); // one transaction: borrow, settle, claim, repay

        assertEq(attacker.walletDuringLoan(), loan, "it held a hundred times its buys during the call");
        assertFalse(attacker.claimed());
        assertEq(bytes4(attacker.claimError()), SherwoodArena.NothingToClaim.selector);
        (, address[3] memory top,, uint256[3] memory prize,, address king,, uint256 kingPrize,) = game.result(0);
        assertEq(top[0], address(attacker));
        assertEq(king, address(attacker));
        assertEq(prize[0], 0);
        assertEq(kingPrize, 0);
        assertEq(game.heldToClaim(0, address(attacker)), 0);
        // #1's 40% and the King's 8% roll into the live pot with the empty-slot rollover.
        assertEq(game.pot(1) - liveBefore, total - prize[1] - prize[2] - (total * 1700) / 10_000);
        assertEq(gameToken.balanceOf(address(lender)), loan, "the loan went back");
        assertEq(address(attacker).balance, 0);
    }

    function test_aFlashLoanAtClaimCannotCoverWhatWasWithdrawnAfterSettlement() public {
        _attackerPlays(0.05 ether);
        _buy(bob, 0.02 ether, SherwoodArena.Move.BUY);
        uint256 owed = game.bought(0, address(attacker));
        attacker.withdraw(owed / 2);
        attacker.dump(sink); // kept half through settlement
        uint256 total = game.pot(0);
        _finishRound(0);
        (,,, uint256[3] memory prize,,,, uint256 kingPrize,) = game.result(0);
        uint256 kept = owed - owed / 2;
        assertEq(prize[0], ((total * 4000) / 10_000 * kept) / owed, "the prize scaled to what it kept");
        assertEq(kingPrize, ((total * 800) / 10_000 * kept) / owed);
        assertEq(game.heldToClaim(0, address(attacker)), kept);

        attacker.withdraw(type(uint256).max);
        attacker.dump(sink); // and sold the rest before claiming
        gameToken.mint(address(lender), 100 * owed);
        attacker.claimOnLoan(0, 100 * owed);
        assertFalse(attacker.claimed());
        assertEq(bytes4(attacker.claimError()), SherwoodArena.MustHoldToClaim.selector);
        assertEq(address(attacker).balance, 0);

        // A real buy back through the arena does count.
        _attackerPlays(0.05 ether);
        attacker.claim(0);
        assertEq(address(attacker).balance, prize[0] + kingPrize);
    }

    function test_aFlashLoanInsidePlayGivesNoHolderBonus() public {
        _attackerPlays(0.01 ether);
        _buy(bob, 0.01 ether, SherwoodArena.Move.BUY); // bob keeps his
        uint256 owed = game.bought(0, address(attacker));
        attacker.withdraw(type(uint256).max);
        attacker.dump(sink);
        vm.warp(game.roundStart(1) + 1);
        gameToken.mint(address(lender), 100 * owed);
        vm.deal(address(this), 0.01 ether);
        attacker.playOnLoan{value: 0.01 ether}(100 * owed);
        assertEq(attacker.walletDuringLoan(), 100 * owed);
        assertFalse(attacker.bonusDuringLoan());
        assertEq(game.points(1, address(attacker)), 10, "no 25% bonus");
        _buy(bob, 0.01 ether, SherwoodArena.Move.BUY);
        assertEq(game.points(1, bob), 12, "a holder through the arena gets it");
        assertEq(gameToken.balanceOf(address(lender)), 100 * owed);
    }

    // ── withdraw ────────────────────────────────────────────────────────────────

    function test_withdrawSendsTheTokensAndReducesHoldings() public {
        _buy(alice, 0.1 ether, SherwoodArena.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodArena.Move.BUY);
        uint256 held = game.holdings(alice);
        assertEq(held, 0.095 ether);
        assertEq(game.totalHoldings(), 0.095 ether + 0.019 ether);
        int256 points = game.points(0, alice);
        uint256 potBefore = game.pot(0);
        vm.expectEmit(true, false, false, true, address(game));
        emit Withdrawn(alice, 0.03 ether);
        vm.prank(alice);
        game.withdraw(0.03 ether);
        assertEq(game.holdings(alice), held - 0.03 ether);
        assertEq(game.totalHoldings(), 0.095 ether + 0.019 ether - 0.03 ether);
        assertEq(gameToken.balanceOf(alice), 0.03 ether);
        assertEq(gameToken.balanceOf(address(game)), game.totalHoldings());
        assertEq(game.points(0, alice), points, "points stay");
        assertEq(game.pot(0), potBefore, "no ETH moves");
        assertEq(game.bought(0, alice), held, "the round's buys are still owed");
    }

    function test_withdrawCapsAtHoldings() public {
        _buy(alice, 0.01 ether, SherwoodArena.Move.BUY);
        _buy(bob, 0.02 ether, SherwoodArena.Move.BUY);
        uint256 held = game.holdings(alice);
        vm.expectEmit(true, false, false, true, address(game));
        emit Withdrawn(alice, held);
        vm.prank(alice);
        game.withdraw(type(uint256).max);
        assertEq(gameToken.balanceOf(alice), held);
        assertEq(game.holdings(alice), 0);
        assertEq(game.holdings(bob), 0.019 ether, "nobody else's holdings are touched");
        assertEq(game.totalHoldings(), 0.019 ether);
    }

    function test_withdrawingNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.NothingToWithdraw.selector);
        game.withdraw(1); // holds nothing
        _buy(alice, 0.01 ether, SherwoodArena.Move.BUY);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.NothingToWithdraw.selector);
        game.withdraw(0);
        vm.prank(bob);
        vm.expectRevert(SherwoodArena.NothingToWithdraw.selector); // alice's holdings aren't bob's
        game.withdraw(1);
        vm.startPrank(alice);
        game.withdraw(type(uint256).max);
        vm.expectRevert(SherwoodArena.NothingToWithdraw.selector);
        game.withdraw(1);
        vm.stopPrank();
    }

    function test_tokensSentStraightToTheArenaAreNobodysHoldings() public {
        _buy(alice, 0.01 ether, SherwoodArena.Move.BUY);
        uint256 held = game.holdings(alice);
        gameToken.mint(bob, 1 ether);
        vm.prank(bob);
        gameToken.transfer(address(game), 1 ether); // there is no deposit
        assertEq(game.holdings(bob), 0);
        assertEq(game.holdings(alice), held);
        assertEq(game.totalHoldings(), held);
        assertGt(gameToken.balanceOf(address(game)), game.totalHoldings());
        vm.prank(bob);
        vm.expectRevert(SherwoodArena.NothingToWithdraw.selector);
        game.withdraw(1 ether);
        vm.prank(alice);
        game.withdraw(type(uint256).max);
        assertEq(gameToken.balanceOf(alice), held, "capped at her own holdings");
    }

    // ── Spare tokens: the kept 7% of each buyback, and tokens sent straight here ──

    function test_aBuybackBurnsTenSeventeenthsAndKeepsTheRest() public {
        _seed(0, 1 ether);
        _finishRound(0);
        uint256 reserve = game.buybackReserve();
        assertEq(reserve, (1 ether * 1700) / 10_000, "17% of the pot buys back");
        vm.prank(owner);
        game.buybackAndBurn(reserve, 1);
        uint256 burned = gameToken.balanceOf(address(0xdEaD));
        // At the mock router's 1:1 (after its tax), 10% of the pot's worth burns and 7% stays.
        assertEq(burned + game.spareTokens(), gameToken.balanceOf(address(0xdEaD)) + gameToken.balanceOf(address(game)));
        assertEq(burned, ((burned + game.spareTokens()) * 1000) / 1700);
        assertGt(game.spareTokens(), 0);
    }

    function test_theOwnerSendsSpareTokensButNeverHoldings() public {
        _buy(alice, 0.05 ether, SherwoodArena.Move.BUY);
        _seed(0, 1 ether);
        _finishRound(0);
        uint256 reserve = game.buybackReserve();
        vm.prank(owner);
        game.buybackAndBurn(reserve, 1);
        gameToken.mint(bob, 3 ether);
        vm.prank(bob);
        gameToken.transfer(address(game), 3 ether); // a mistaken transfer: spare too
        uint256 held = game.totalHoldings();
        uint256 spare = game.spareTokens();
        assertEq(gameToken.balanceOf(address(game)), held + spare);
        address treasury = makeAddr("treasury");

        vm.prank(alice);
        vm.expectRevert(SherwoodArena.NotOwner.selector);
        game.sendSpareTokens(treasury, 1);
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.NothingToWithdraw.selector);
        game.sendSpareTokens(address(0), 1);

        vm.prank(owner);
        game.sendSpareTokens(treasury, 1 ether);
        assertEq(gameToken.balanceOf(treasury), 1 ether);
        vm.prank(owner);
        game.sendSpareTokens(treasury, type(uint256).max); // capped at the spare
        assertEq(gameToken.balanceOf(treasury), spare, "everything spare, nothing more");
        assertEq(game.spareTokens(), 0);
        assertEq(game.totalHoldings(), held, "holdings untouched");
        assertEq(gameToken.balanceOf(address(game)), held);
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.NothingToWithdraw.selector);
        game.sendSpareTokens(treasury, 1);

        vm.prank(alice);
        game.withdraw(type(uint256).max);
        assertEq(gameToken.balanceOf(alice), held, "alice still gets all of hers");
    }

    function test_unscoredAndPreGenesisBuysAreHeldAndWithdrawable() public {
        SherwoodArena late = new SherwoodArena(
            address(gameToken),
            IArenaRouter(address(router)),
            IDiceEntropy(address(dice)),
            makeAddr("audit provider"),
            owner,
            block.timestamp + 1 hours,
            PLAY_FEE_BPS,
            true,
            20 hours
        );
        vm.deal(alice, 0.05 ether);
        vm.prank(alice);
        late.play{value: 0.05 ether}(0, 0, address(0)); // before GENESIS: scores nothing
        assertEq(late.points(0, alice), 0);
        assertEq(late.bought(0, alice), 0);
        assertEq(late.holdings(alice), 0.0475 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.deal(alice, 0.0009 ether);
        vm.prank(alice);
        late.play{value: 0.0009 ether}(0, 0, address(0)); // after GENESIS, below the minimum: unscored
        assertEq(late.bought(0, alice), 0);
        assertEq(late.holdings(alice), 0.0475 ether + 0.000855 ether);
        assertEq(late.totalHoldings(), late.holdings(alice));
        vm.prank(alice);
        late.withdraw(type(uint256).max);
        assertEq(gameToken.balanceOf(alice), 0.0475 ether + 0.000855 ether);
        assertEq(late.totalHoldings(), 0);
    }

    function test_withdrawIsGuardedAgainstReentry() public {
        CallbackToken token = new CallbackToken();
        MockArenaRouter r = new MockArenaRouter(token);
        SherwoodArena arena = new SherwoodArena(
            address(token),
            IArenaRouter(address(r)),
            IDiceEntropy(address(dice)),
            makeAddr("audit provider"),
            owner,
            GENESIS,
            PLAY_FEE_BPS,
            true,
            20 hours
        );
        ReentrantHolder holder = new ReentrantHolder(arena);
        vm.deal(address(this), 0.01 ether);
        holder.play{value: 0.01 ether}();
        uint256 held = arena.holdings(address(holder));
        holder.withdraw(held);
        assertEq(holder.attempts(), 4);
        assertEq(holder.blocked(), 4, "withdraw, play, claim and claimReferral all refused mid-withdraw");
        assertEq(token.balanceOf(address(holder)), held);
        assertEq(arena.holdings(address(holder)), 0);
        assertEq(arena.totalHoldings(), 0);
    }

    // ── The sell rule and the claim check read holdings ─────────────────────────

    function test_withdrawingTwentyPercentBeforeSettlementLosesTwentyPercentEvenKeptInTheWallet() public {
        _buy(alice, 0.1 ether, SherwoodArena.Move.BUY); // #1 and King
        _buy(bob, 0.05 ether, SherwoodArena.Move.BUY);
        uint256 total = game.pot(0);
        uint256 owed = game.bought(0, alice);
        vm.prank(alice);
        game.withdraw(owed / 5); // the tokens sit in her wallet, unsold
        uint256 first = (total * 4000) / 10_000;
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        vm.expectEmit(true, true, false, true, address(game));
        emit PrizeForfeited(0, alice, first - (first * (owed - owed / 5)) / owed);
        assertTrue(game.settle(0, 100));
        (,,, uint256[3] memory prize,,,, uint256 kingPrize,) = game.result(0);
        assertEq(prize[0], (first * (owed - owed / 5)) / owed);
        assertEq(kingPrize, ((total * 800) / 10_000 * (owed - owed / 5)) / owed);
        assertEq(prize[1], (total * 2000) / 10_000, "bob withdrew nothing");
        assertEq(game.heldToClaim(0, alice), owed - owed / 5);
        assertEq(gameToken.balanceOf(alice), owed / 5);
    }

    function test_withdrawingAfterSettlementBlocksTheClaimUntilAPlayRestoresIt() public {
        _buy(alice, 0.05 ether, SherwoodArena.Move.BUY);
        _finishRound(0);
        uint256 held = game.heldToClaim(0, alice);
        assertEq(held, game.holdings(alice));
        vm.prank(alice);
        game.withdraw(1);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.MustHoldToClaim.selector);
        game.claim(0);
        vm.prank(alice);
        gameToken.transfer(address(game), 1); // straight back to the arena: not a holding
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.MustHoldToClaim.selector);
        game.claim(0);
        _buy(alice, 0.0005 ether, SherwoodArena.Move.BUY); // a buy through the arena
        uint256 before = alice.balance;
        uint256 owed = _unpaid(0);
        vm.prank(alice);
        game.claim(0);
        assertEq(alice.balance - before, owed);
        // Claimed: withdrawing everything now costs nothing.
        vm.prank(alice);
        game.withdraw(type(uint256).max);
        assertEq(game.holdings(alice), 0);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.NothingToClaim.selector);
        game.claim(0);
        assertEq(alice.balance - before, owed);
    }
}
