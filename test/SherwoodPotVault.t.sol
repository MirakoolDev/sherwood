// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodArenaFixture} from "./helpers/SherwoodArenaFixture.sol";
import {SherwoodArena} from "src/SherwoodArena.sol";
import {SherwoodPotVault} from "src/SherwoodPotVault.sol";
import {MockTaxQueue} from "./SherwoodArenaHookr.t.sol";

contract RefusesEth {
    bool public open;

    function setOpen(bool o) external {
        open = o;
    }

    receive() external payable {
        require(open, "closed");
    }
}

/// The vault as the pool's fixed tax recipient: it passes the tax on to the arena's live pot, and a new
/// arena takes over only after a public wait.
contract SherwoodPotVaultTest is SherwoodArenaFixture {
    event PotFunded(uint256 indexed round, uint256 amount, bool fromSell);

    SherwoodPotVault internal vault;
    MockTaxQueue internal queue;

    function setUp() public override {
        super.setUp();
        vault = new SherwoodPotVault(owner, address(game));
        queue = new MockTaxQueue(address(vault)); // the pool pays the vault, never the arena directly
        vm.prank(owner);
        game.setTaxQueue(address(queue));
    }

    function test_taxThroughTheVaultLandsInTheLivePot() public {
        vm.deal(address(queue), 0.0015 ether);
        vm.expectEmit(true, false, false, true, address(game));
        emit PotFunded(0, 0.0015 ether, false);
        game.pullTax();
        assertEq(game.pot(0), 0.0015 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_aMovePullsTaxThroughTheVault() public {
        vm.deal(address(queue), 0.001 ether);
        _buy(alice, 0.01 ether, SherwoodArena.Move.BUY);
        assertEq(game.pot(0), 0.001 ether + 0.0005 ether, "the tax plus the move's play fee");
    }

    function test_anArenaThatRefusesLeavesTheEthForFlush() public {
        RefusesEth closed = new RefusesEth();
        SherwoodPotVault v = new SherwoodPotVault(owner, address(closed));
        (bool ok,) = address(v).call{value: 0.2 ether}("");
        assertTrue(ok, "the vault never refuses the pool");
        assertEq(address(v).balance, 0.2 ether);
        closed.setOpen(true);
        v.flush();
        assertEq(address(closed).balance, 0.2 ether);
    }

    function test_aNewArenaTakesOverOnlyAfterTheWait() public {
        address next = address(new RefusesEth());
        RefusesEth(payable(next)).setOpen(true);
        vm.prank(owner);
        vault.proposeArena(next);
        assertEq(vault.switchAt(), block.timestamp + 2 days);

        vm.expectRevert(SherwoodPotVault.TooEarly.selector);
        vault.switchArena();
        (bool ok,) = address(vault).call{value: 0.1 ether}("");
        assertTrue(ok);
        assertEq(game.pot(0), 0.1 ether, "the current arena still gets the tax during the wait");

        vm.warp(block.timestamp + 2 days);
        vm.prank(bob); // anyone completes it
        vault.switchArena();
        assertEq(vault.arena(), next);
        (ok,) = address(vault).call{value: 0.3 ether}("");
        assertTrue(ok);
        assertEq(next.balance, 0.3 ether);
    }

    function test_theOwnerCanCancelASwitch() public {
        vm.prank(owner);
        vault.proposeArena(alice);
        vm.prank(owner);
        vault.cancelSwitch();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(SherwoodPotVault.NothingProposed.selector);
        vault.switchArena();
        assertEq(vault.arena(), address(game));
    }

    function test_onlyTheOwnerProposesOrCancels() public {
        vm.prank(alice);
        vm.expectRevert(SherwoodPotVault.NotOwner.selector);
        vault.proposeArena(alice);
        vm.prank(alice);
        vm.expectRevert(SherwoodPotVault.NotOwner.selector);
        vault.cancelSwitch();
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        vault.setOwner(alice);
        assertEq(vault.owner(), owner);
        vm.prank(bob);
        vm.expectRevert(SherwoodPotVault.NotOwner.selector);
        vault.acceptOwner();
        vm.prank(alice);
        vault.acceptOwner();
        assertEq(vault.owner(), alice);
    }
}
