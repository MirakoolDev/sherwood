// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PonsFeeSplitter, IPonsLocker, IWETH} from "src/PonsFeeSplitter.sol";

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth withdraw");
    }
}

/// Pons' locker as the splitter sees it: collectFees pays owed WETH and token to the redirect, or reverts.
contract MockLocker {
    MockWETH public immutable weth;
    MockERC20 public immutable token;
    address public recipient;
    uint256 public owedWeth;
    uint256 public owedToken;

    error NoFeesToCollect();

    constructor(MockWETH w, MockERC20 t) {
        weth = w;
        token = t;
    }

    function setRecipient(address r) external {
        recipient = r;
    }

    function accrue(uint256 w, uint256 t) external payable {
        weth.deposit{value: w}();
        token.mint(address(this), t);
        owedWeth += w;
        owedToken += t;
    }

    function collectFees(address) external returns (uint256, uint256) {
        if (owedWeth == 0 && owedToken == 0) revert NoFeesToCollect();
        (uint256 w, uint256 t) = (owedWeth, owedToken);
        (owedWeth, owedToken) = (0, 0);
        weth.transfer(recipient, w);
        token.transfer(recipient, t);
        return (w, t);
    }
}

contract Refuser {
    receive() external payable {
        revert("no");
    }
}

contract PonsFeeSplitterTest is Test {
    MockWETH weth;
    MockERC20 pfwa;
    MockLocker locker;
    PonsFeeSplitter splitter;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address pot = makeAddr("pot");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockWETH();
        pfwa = new MockERC20("PFWA", "PFWA", 18);
        locker = new MockLocker(weth, pfwa);
        splitter = new PonsFeeSplitter(IPonsLocker(address(locker)), IWETH(address(weth)), address(pfwa), owner, treasury);
        locker.setRecipient(address(splitter));
    }

    function _accrue(uint256 w, uint256 t) internal {
        vm.deal(address(this), w);
        locker.accrue{value: w}(w, t);
    }

    function test_halfTheEthToThePotTheRestToTheTreasury() public {
        vm.prank(owner);
        splitter.setPot(pot);
        _accrue(1 ether, 500_000 ether);
        splitter.distribute();
        assertEq(pot.balance, 0.5 ether);
        assertEq(treasury.balance, 0.5 ether);
        assertEq(pfwa.balanceOf(treasury), 500_000 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_oncePerDayAndAnyoneCanRunIt() public {
        vm.prank(owner);
        splitter.setPot(pot);
        _accrue(0.2 ether, 0);
        vm.prank(makeAddr("anyone"));
        splitter.distribute();
        _accrue(0.2 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(PonsFeeSplitter.TooSoon.selector, block.timestamp + 1 days));
        splitter.distribute();
        vm.warp(block.timestamp + 1 days);
        splitter.distribute();
        assertEq(pot.balance, 0.2 ether);
        assertEq(treasury.balance, 0.2 ether);
    }

    function test_withoutAPotThePotsHalfWaitsThenGoesOutWhenSet() public {
        _accrue(1 ether, 0);
        splitter.distribute();
        assertEq(treasury.balance, 0.5 ether);
        assertEq(splitter.heldForPot(), 0.5 ether);
        assertEq(address(splitter).balance, 0.5 ether);

        vm.prank(owner);
        splitter.setPot(pot);
        vm.warp(block.timestamp + 1 days);
        _accrue(0.4 ether, 0);
        splitter.distribute();
        assertEq(pot.balance, 0.5 ether + 0.2 ether, "the held half plus half the new fees");
        assertEq(treasury.balance, 0.5 ether + 0.2 ether);
        assertEq(splitter.heldForPot(), 0);
    }

    function test_nothingOwedStillPaysOutWhatIsHere() public {
        vm.prank(owner);
        splitter.setPot(pot);
        vm.deal(address(this), 0.1 ether);
        (bool ok,) = address(splitter).call{value: 0.1 ether}("");
        assertTrue(ok);
        splitter.distribute();
        assertEq(pot.balance, 0.05 ether);
        assertEq(treasury.balance, 0.05 ether);
    }

    function test_aPotThatRefusesKeepsItsShareHere() public {
        address refuser = address(new Refuser());
        vm.prank(owner);
        splitter.setPot(refuser);
        _accrue(1 ether, 0);
        splitter.distribute();
        assertEq(treasury.balance, 0.5 ether);
        assertEq(splitter.heldForPot(), 0.5 ether);
    }

    function test_theOwnerCanChangeThePotsShare() public {
        vm.startPrank(owner);
        splitter.setPot(pot);
        splitter.setPotShare(7000);
        vm.expectRevert(PonsFeeSplitter.BadShare.selector);
        splitter.setPotShare(10_001);
        vm.stopPrank();
        vm.expectRevert(PonsFeeSplitter.NotOwner.selector);
        splitter.setPotShare(0);
        _accrue(1 ether, 0);
        splitter.distribute();
        assertEq(pot.balance, 0.7 ether);
        assertEq(treasury.balance, 0.3 ether);
    }

    function test_onlyTheOwnerSetsDestinations() public {
        vm.expectRevert(PonsFeeSplitter.NotOwner.selector);
        splitter.setPot(pot);
        vm.expectRevert(PonsFeeSplitter.NotOwner.selector);
        splitter.setTreasury(pot);
        vm.prank(owner);
        vm.expectRevert(PonsFeeSplitter.ZeroAddress.selector);
        splitter.setTreasury(address(0));
        vm.prank(owner);
        splitter.setTreasury(pot);
        assertEq(splitter.treasury(), pot);
    }

    function test_ownershipIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        splitter.setOwner(next);
        assertEq(splitter.owner(), owner);
        vm.prank(next);
        splitter.acceptOwner();
        assertEq(splitter.owner(), next);
    }
}

/// The real Pons locker on a fork: the deployer redirects $PFWA's fees to the splitter, which collects them.
contract PonsFeeSplitterForkTest is Test {
    address constant LOCKER = 0x736D76699C26D0d966744cAe304C000d471f7F35;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant DEPLOYER = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;

    function test_fork_collectsAndSplitsRealPfwaFees() public {
        vm.createSelectFork("robinhood");
        address treasury = makeAddr("treasury");
        address pot = makeAddr("pot");
        PonsFeeSplitter splitter = new PonsFeeSplitter(IPonsLocker(LOCKER), IWETH(WETH), PFWA, DEPLOYER, treasury);
        vm.prank(DEPLOYER);
        (bool ok,) = LOCKER.call(abi.encodeWithSignature("setFeeRedirect(address,address)", PFWA, address(splitter)));
        assertTrue(ok, "setFeeRedirect by the deployer");
        vm.prank(DEPLOYER);
        splitter.setPot(pot);

        splitter.distribute();
        emit log_named_decimal_uint("ETH to the pot", pot.balance, 18);
        emit log_named_decimal_uint("ETH to the treasury", treasury.balance, 18);
        emit log_named_decimal_uint("PFWA to the treasury", IWETH(PFWA).balanceOf(treasury), 18);
        // The live splitter collects $PFWA's fees daily, so right after its run nothing may be owed yet.
        if (pot.balance == 0) vm.skip(true);
        assertLe(treasury.balance - pot.balance, 1, "an even split");
        assertEq(address(splitter).balance, 0);
        assertEq(IWETH(WETH).balanceOf(address(splitter)), 0);
    }
}
