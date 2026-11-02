// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodArenaFixture, MockArenaRouter, TaxPusher} from "./helpers/SherwoodArenaFixture.sol";
import {SherwoodArena, IArenaRouter, IDiceEntropy} from "src/SherwoodArena.sol";

/// A player that's a contract (an agent): plays, holds the token, claims.
contract ArenaAgent {
    function play(SherwoodArena a, uint8 move) external payable {
        a.play{value: msg.value}(move, 0, address(0));
    }

    function claim(SherwoodArena a, uint256 round) external {
        a.claim(round);
    }

    function withdraw(SherwoodArena a, uint256 amount) external {
        a.withdraw(amount);
    }

    receive() external payable {}
}

/// What only the arena does: the router path, the buy tax, slippage, players that are contracts, sells
/// (withdrawals) settled at settlement, the Flip switch, re-entry through the router, and the play fee settings.
contract SherwoodArenaRouterTest is SherwoodArenaFixture {
    event PotFunded(uint256 indexed round, uint256 amount, bool fromSell);
    event PrizeForfeited(uint256 indexed round, address indexed player, uint256 amount);

    /// Everything the arena owes: the open pots, unpaid prizes, referral shares and the burn reserve.
    function _owed(address[] memory referrers) internal view returns (uint256 owed) {
        owed = game.buybackReserve();
        for (uint256 r; r <= game.currentRound() + 2; ++r) {
            (bool settled,,,,,,,,) = game.result(r);
            owed += settled ? _unpaid(r) : game.pot(r);
        }
        for (uint256 i; i < referrers.length; ++i) {
            owed += game.referralEarnings(referrers[i]);
        }
    }

    function _assertBooks() internal view {
        assertEq(address(game).balance, _owed(new address[](0)), "ETH held must equal what is owed");
    }

    // ── The buy tax ─────────────────────────────────────────────────────────────

    function test_taxPushedDuringAMoveCreditsTheLivePot() public {
        router.setTax(300, address(game), false); // 3%, pushed by another contract mid-swap
        vm.expectEmit(true, false, false, true, address(game));
        emit PotFunded(0, 0.005 ether, false); // the play fee
        vm.expectEmit(true, false, false, true, address(game));
        emit PotFunded(0, 0.00285 ether, false); // the tax: 3% of the 0.095 swapped
        _buy(alice, 0.1 ether, SherwoodArena.Move.BUY);
        assertEq(game.pot(0), 0.005 ether + 0.00285 ether);
        assertEq(game.holdings(alice), 0.095 ether - 0.00285 ether);
        assertEq(gameToken.balanceOf(address(game)), 0.095 ether - 0.00285 ether);
        assertEq(game.bought(0, alice), 0.095 ether - 0.00285 ether);
        assertEq(game.points(0, alice), 100, "points are on the ETH sent");
        _assertBooks();
    }

    /// The arena treats ETH from its router during a swap as a refund. A tax the router itself sends
    /// back mid-swap would read as a partial fill: the real adapter must not do that (Hookr's tax comes
    /// from Hookr's contracts, and Hookr's router refunds go to the adapter, not here).
    function test_taxPushedByTheRouterItselfMidSwapRevertsTheMove() public {
        router.setTax(300, address(game), true);
        vm.deal(alice, 0.1 ether);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.PartialFill.selector);
        game.play{value: 0.1 ether}(0, 0, address(0));
    }

    function test_routerEthOutsideASwapGoesToThePot() public {
        vm.deal(address(router), 1 ether);
        vm.prank(address(router));
        (bool ok,) = address(game).call{value: 0.2 ether}("");
        assertTrue(ok);
        assertEq(game.pot(0), 0.2 ether);
        _assertBooks();
    }

    function test_taxPushedBetweenRoundsLandsInTheLiveRound() public {
        TaxPusher pusher = new TaxPusher();
        vm.warp(game.roundEnd(0) + 1); // round 0 over but not yet settled
        pusher.push{value: 0.3 ether}(address(game));
        assertEq(game.pot(0), 0);
        assertEq(game.pot(1), 0.3 ether);
        _assertBooks();
    }

    // ── Slippage and fills ──────────────────────────────────────────────────────

    function test_underpayingRouterIsCaughtByTheArenaWithNoStateLeft() public {
        router.setUnderpay(true); // pays half and ignores minOut
        vm.deal(alice, 0.05 ether);
        vm.prank(alice);
        vm.expectRevert(SherwoodArena.TooLittleOut.selector);
        game.play{value: 0.05 ether}(uint8(SherwoodArena.Move.SHIELD), 0.04 ether, referrer);
        assertEq(alice.balance, 0.05 ether);
        assertEq(game.pot(0), 0);
        assertEq(game.points(0, alice), 0);
        assertEq(game.bought(0, alice), 0);
        assertEq(game.firstRoundPlus1(alice), 0);
        assertEq(game.referrerOf(alice), address(0));
        assertEq(game.shieldBlocks(alice), 0);
        assertEq(game.playerCount(0), 0);
        assertEq(game.holdings(alice), 0);
        assertEq(game.totalHoldings(), 0);
        assertEq(gameToken.balanceOf(address(game)), 0);
        // The same router within the limit is fine.
        vm.prank(alice);
        game.play{value: 0.05 ether}(uint8(SherwoodArena.Move.BUY), 0.02 ether, address(0));
        assertEq(game.holdings(alice), 0.02375 ether);
        assertEq(game.points(0, alice), 50);
    }

    function test_routerMinOutRevertBubblesWithNoStateLeft() public {
        vm.deal(alice, 0.05 ether);
        vm.prank(alice);
        vm.expectRevert("router: too little out");
        game.play{value: 0.05 ether}(0, 1 ether, address(0));
        assertEq(game.pot(0), 0);
        assertEq(game.points(0, alice), 0);
        assertEq(address(game).balance, 0);
    }

    // ── Players ─────────────────────────────────────────────────────────────────

    /// The player is msg.sender, not tx.origin: an agent contract scores, holds and claims for itself.
    function test_aContractPlayerScoresHoldsAndClaims() public {
        ArenaAgent agent = new ArenaAgent();
        vm.deal(address(this), 0.05 ether);
        vm.prank(address(this), alice); // signed by alice, played by the agent
        agent.play{value: 0.05 ether}(game, 0);
        assertEq(game.points(0, address(agent)), 50);
        assertEq(game.points(0, alice), 0);
        assertEq(game.holdings(address(agent)), 0.0475 ether);
        assertEq(game.bought(0, address(agent)), 0.0475 ether);
        _finishRound(0);
        uint256 owed = _unpaid(0);
        agent.claim(game, 0);
        assertEq(address(agent).balance, owed);
        agent.withdraw(game, type(uint256).max); // and takes its tokens out after
        assertEq(gameToken.balanceOf(address(agent)), 0.0475 ether);
        assertEq(game.holdings(address(agent)), 0);
        _assertBooks();
    }

    // ── Selling: settled at settlement ──────────────────────────────────────────

    function test_soldTwentyPercentLosesTwentyPercent() public {
        _buy(alice, 0.1 ether, SherwoodArena.Move.BUY); // #1 and King
        _buy(bob, 0.05 ether, SherwoodArena.Move.BUY);
        uint256 total = game.pot(0);
        uint256 bought_ = game.bought(0, alice);
        _sell(alice, bought_ / 5); // withdrew and sold 20%: points stay
        assertEq(game.points(0, alice), 100);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        uint256 first = (total * 4000) / 10_000;
        vm.expectEmit(true, true, false, true, address(game));
        emit PrizeForfeited(0, alice, first - (first * (bought_ - bought_ / 5)) / bought_);
        game.settle(0, 100);
        (,,, uint256[3] memory prize,,,, uint256 kingPrize,) = game.result(0);
        assertEq(prize[0], (first * (bought_ - bought_ / 5)) / bought_, "keeps 80% of #1's prize");
        uint256 king = (total * 800) / 10_000;
        assertEq(kingPrize, (king * (bought_ - bought_ / 5)) / bought_, "and 80% of the King's");
        assertEq(prize[1], (total * 2000) / 10_000, "bob held everything");
        assertEq(game.heldToClaim(0, alice), bought_ - bought_ / 5);
        _assertBooks();
    }

    // ── The Flip switch ─────────────────────────────────────────────────────────

    function test_flipsSwitchedOffPlayAsABuyAndSpendNoCharge() public {
        vm.prank(owner);
        game.setFlipsEnabled(false);
        assertFalse(game.flipsEnabled());
        _buy(bob, 0.02 ether, SherwoodArena.Move.FLIP);
        assertEq(game.points(0, bob), 20, "scored as a buy");
        assertEq(game.flipsLeft(bob), 6, "no charge spent");
        assertEq(dice.nextSequence(), 1, "Dice never asked");
        assertEq(game.pendingFlips(0), 0);
        assertEq(game.pot(0), 0.001 ether, "no Dice fee out of the pot");
        vm.prank(owner);
        game.setFlipsEnabled(true);
        _buy(bob, 0.02 ether, SherwoodArena.Move.FLIP);
        assertEq(dice.nextSequence(), 2);
        assertEq(game.flipsLeft(bob), 5);
    }

    function test_aPendingFlipStillExpiresAfterFlipsAreSwitchedOff() public {
        _buy(bob, 0.02 ether, SherwoodArena.Move.FLIP);
        vm.prank(owner);
        game.setFlipsEnabled(false);
        vm.warp(vm.getBlockTimestamp() + FLIP_TIMEOUT);
        game.expireFlip(1);
        assertEq(game.points(0, bob), 20);
        assertEq(game.pendingFlips(0), 0);
    }

    function test_flipsCanStartSwitchedOff() public {
        SherwoodArena off = new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 500, false, 20 hours
        );
        assertFalse(off.flipsEnabled());
        vm.deal(bob, 0.02 ether);
        vm.prank(bob);
        off.play{value: 0.02 ether}(uint8(SherwoodArena.Move.FLIP), 0, address(0));
        assertEq(off.points(0, bob), 20);
        assertEq(dice.nextSequence(), 1);
    }

    // ── Re-entry through the router ─────────────────────────────────────────────

    function _attempt(bytes memory data) internal returns (bytes4 error_) {
        router.setReentry(address(game), data);
        _buy(alice, 0.01 ether, SherwoodArena.Move.BUY);
        assertFalse(router.reentered(), "re-entry must fail");
        error_ = bytes4(router.reentryError());
    }

    function test_theRouterCannotReenterPlayClaimsSweepsOrTheBurn() public {
        // Something to claim and sweep first.
        _buy(bob, 0.02 ether, SherwoodArena.Move.BUY);
        _finishRound(0);
        assertEq(_attempt(abi.encodeCall(SherwoodArena.play, (0, 0, address(0)))), SherwoodArena.Reentered.selector);
        assertEq(_attempt(abi.encodeCall(SherwoodArena.claim, (0))), SherwoodArena.Reentered.selector);
        assertEq(_attempt(abi.encodeCall(SherwoodArena.claimReferral, ())), SherwoodArena.Reentered.selector);
        assertEq(_attempt(abi.encodeCall(SherwoodArena.sweepUnclaimed, (0))), SherwoodArena.Reentered.selector);
        assertEq(_attempt(abi.encodeCall(SherwoodArena.withdraw, (1))), SherwoodArena.Reentered.selector);
        _assertBooks();
    }

    /// What the router may call during a swap keeps the books: seeding a pot (counted, not mistaken for
    /// a refund) and settling another round (moves no ETH).
    function test_fundPotAndSettleDuringASwapKeepTheBooks() public {
        _buy(bob, 0.02 ether, SherwoodArena.Move.BUY);
        vm.warp(game.roundEnd(0) + game.SETTLE_DELAY());
        vm.deal(address(router), 1 ether);
        router.setReentry(address(game), abi.encodeCall(SherwoodArena.settle, (0, 100)));
        _buy(alice, 0.01 ether, SherwoodArena.Move.BUY);
        assertTrue(router.reentered());
        (bool settled,,,,,,,,) = game.result(0);
        assertTrue(settled);
        _assertBooks();
    }

    // ── The burn ────────────────────────────────────────────────────────────────

    function test_theBurnsOwnTaxComesBackIntoThePot() public {
        _seed(0, 1 ether);
        _finishRound(0);
        router.setTax(500, address(game), false);
        uint256 reserve = game.buybackReserve();
        uint256 live = game.currentRound();
        uint256 potBefore = game.pot(live);
        vm.prank(owner);
        game.buybackAndBurn(reserve, 0);
        uint256 tax = (reserve * 500) / 10_000;
        assertEq(game.buybackReserve(), 0);
        assertEq(game.pot(live), potBefore + tax, "the tax on the burn lands in the live pot");
        assertEq(gameToken.balanceOf(DEAD), ((reserve - tax) * 1000) / 1700);
        assertEq(game.spareTokens(), (reserve - tax) - ((reserve - tax) * 1000) / 1700);
        _assertBooks();
    }

    function test_anEmptyReserveCannotBurn() public {
        vm.prank(owner);
        vm.expectRevert(SherwoodArena.NothingToBurn.selector);
        game.buybackAndBurn(1 ether, 0);
    }

    function test_aDiceRefundGoesToTheBurnReserve() public {
        _buy(alice, 0.02 ether, SherwoodArena.Move.FLIP);
        vm.warp(vm.getBlockTimestamp() + FLIP_TIMEOUT);
        game.expireFlip(1);
        vm.prank(owner);
        game.refundDiceRequest(1);
        assertEq(game.buybackReserve(), dice.fee());
        _assertBooks();
    }

    // ── The play fee ────────────────────────────────────────────────────────────

    function test_aZeroPlayFeeSendsEverythingToTheRouter() public {
        SherwoodArena free = new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 0, true, 20 hours
        );
        router.setTax(200, address(free), false);
        vm.deal(alice, 0.1 ether);
        vm.prank(alice);
        free.play{value: 0.1 ether}(0, 0, address(0));
        assertEq(free.pot(0), 0.002 ether, "only the tax");
        assertEq(free.holdings(alice), 0.098 ether);
        assertEq(free.points(0, alice), 100);
        // A flip still costs the pot at most 5% of its move: the tax pot covers Dice's fee.
        vm.deal(bob, 0.02 ether);
        vm.prank(bob);
        free.play{value: 0.02 ether}(uint8(SherwoodArena.Move.FLIP), 0, address(0));
        assertEq(dice.nextSequence(), 2, "the flip was requested");
    }

    function test_aPlayFeeAboveFivePercentIsRefused() public {
        vm.expectRevert(SherwoodArena.BadPlayFee.selector);
        new SherwoodArena(
            address(gameToken), IArenaRouter(address(router)), IDiceEntropy(address(dice)), address(1), owner, GENESIS, 501, true, 20 hours
        );
    }

    // ── v2's ABI, kept ──────────────────────────────────────────────────────────

    function test_noHostToken() public view {
        assertFalse(game.hostBonusActive(alice));
        assertEq(game.hostBuybackReserve(), 0);
        assertEq(game.BUYBACK_BPS(), 1700);
        assertEq(game.BURN_BPS(), 1000);
        assertEq(address(game.router()), address(router));
        assertEq(game.token(), address(gameToken));
        assertEq(game.playFeeBps(), 500);
    }
}
