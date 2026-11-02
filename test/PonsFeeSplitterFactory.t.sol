// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PonsFeeSplitter, IPonsLocker, IWETH} from "src/PonsFeeSplitter.sol";
import {PonsFeeSplitterFactory} from "src/PonsFeeSplitterFactory.sol";
import {MockWETH, MockLocker} from "./PonsFeeSplitter.t.sol";

/// A Pons-launched token as the factory sees it: who launched it, which Pons factory made it, its pair token.
contract MockPonsToken is MockERC20 {
    address public immutable deployer;
    address public immutable launchFactory;
    address public immutable pairToken;

    constructor(address d, address f, address p) MockERC20("Launch", "LNCH", 18) {
        (deployer, launchFactory, pairToken) = (d, f, p);
    }
}

contract NotAToken {}

contract PonsFeeSplitterFactoryTest is Test {
    MockWETH weth;
    MockPonsToken token;
    MockLocker locker;
    PonsFeeSplitterFactory factory;
    address pons = makeAddr("pons launch factory");
    address launcher = makeAddr("launcher");
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address pot = makeAddr("game pot");

    event SplitterCreated(address indexed token, address indexed splitter, address indexed owner, address treasury);

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockWETH();
        token = new MockPonsToken(launcher, pons, address(weth));
        locker = new MockLocker(weth, MockERC20(address(token)));
        factory = new PonsFeeSplitterFactory(IPonsLocker(address(locker)), IWETH(address(weth)), pons);
    }

    function test_theLauncherGetsASplitterAtThePredictedAddress() public {
        address predicted = factory.predict(address(token), owner, treasury);
        vm.expectEmit(true, true, true, true);
        emit SplitterCreated(address(token), predicted, owner, treasury);
        vm.prank(launcher);
        address s = factory.create(address(token), owner, treasury);
        assertEq(s, predicted);
        assertEq(factory.splitterOf(address(token)), s);
        assertEq(factory.count(), 1);
        assertEq(factory.page(0, 10)[0], s);
        PonsFeeSplitter splitter = PonsFeeSplitter(payable(s));
        assertEq(address(splitter.locker()), address(locker));
        assertEq(address(splitter.weth()), address(weth));
        assertEq(splitter.token(), address(token));
        assertEq(splitter.owner(), owner, "the owner given, never the factory");
        assertEq(splitter.treasury(), treasury);
        assertEq(splitter.pot(), address(0));
        assertEq(splitter.potBps(), 5000);
    }

    function test_onlyTheLauncherOnlyOnceOnlyPonsTokensOnlyWethPairs() public {
        vm.expectRevert(PonsFeeSplitterFactory.NotTokenDeployer.selector);
        factory.create(address(token), owner, treasury); // someone else can't take the token's slot

        MockPonsToken foreign = new MockPonsToken(launcher, makeAddr("another factory"), address(weth));
        vm.prank(launcher);
        vm.expectRevert(PonsFeeSplitterFactory.NotPonsToken.selector);
        factory.create(address(foreign), owner, treasury);

        address notToken = address(new NotAToken());
        vm.prank(launcher);
        vm.expectRevert(PonsFeeSplitterFactory.NotPonsToken.selector);
        factory.create(notToken, owner, treasury);

        MockPonsToken usdPair = new MockPonsToken(launcher, pons, makeAddr("usdg"));
        vm.prank(launcher);
        vm.expectRevert(PonsFeeSplitterFactory.NotWethPair.selector);
        factory.create(address(usdPair), owner, treasury);

        vm.prank(launcher);
        vm.expectRevert(PonsFeeSplitterFactory.ZeroAddress.selector);
        factory.create(address(token), address(0), treasury);
        vm.prank(launcher);
        vm.expectRevert(PonsFeeSplitterFactory.ZeroAddress.selector);
        factory.create(address(token), owner, address(0));

        vm.prank(launcher);
        factory.create(address(token), owner, treasury);
        vm.prank(launcher);
        vm.expectRevert(PonsFeeSplitterFactory.AlreadyCreated.selector);
        factory.create(address(token), makeAddr("other owner"), treasury);
    }

    /// The whole flow a project follows: create, redirect Pons fees, set the pot, and the daily split pays out.
    function test_aSplitterFromTheFactorySplitsFeesLikeOurs() public {
        vm.prank(launcher);
        PonsFeeSplitter splitter = PonsFeeSplitter(payable(factory.create(address(token), owner, treasury)));
        locker.setRecipient(address(splitter)); // the launcher's setFeeRedirect on Pons
        vm.prank(owner);
        splitter.setPot(pot);
        vm.prank(owner);
        splitter.setPotShare(3000);

        vm.deal(address(this), 1 ether);
        locker.accrue{value: 1 ether}(1 ether, 500 ether);
        splitter.distribute();
        assertEq(pot.balance, 0.3 ether);
        assertEq(treasury.balance, 0.7 ether);
        assertEq(token.balanceOf(treasury), 500 ether);
    }

    function test_theFactoryCanNotTouchASplitter() public {
        vm.prank(launcher);
        PonsFeeSplitter splitter = PonsFeeSplitter(payable(factory.create(address(token), owner, treasury)));
        vm.prank(address(factory));
        vm.expectRevert(PonsFeeSplitter.NotOwner.selector);
        splitter.setPot(address(factory));
    }

    function test_pageClampsAndPredictDependsOnOwnerAndTreasury() public {
        assertEq(factory.page(0, 5).length, 0);
        vm.prank(launcher);
        factory.create(address(token), owner, treasury);
        assertEq(factory.page(1, 5).length, 0);
        assertEq(factory.page(0, 0).length, 0);
        assertTrue(factory.predict(address(token), owner, treasury) != factory.predict(address(token), treasury, owner));
    }
}

/// Against the real chain: $PFWA is a Pons token paired with WETH, so its launcher could make a splitter here.
contract PonsFeeSplitterFactoryForkTest is Test {
    address constant LOCKER = 0x736D76699C26D0d966744cAe304C000d471f7F35;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PONS_FACTORY = 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB;
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant PFWA_LAUNCHER = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;

    function test_fork_aRealPonsTokenGetsASplitter() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        PonsFeeSplitterFactory factory = new PonsFeeSplitterFactory(IPonsLocker(LOCKER), IWETH(WETH), PONS_FACTORY);
        vm.expectRevert(PonsFeeSplitterFactory.NotTokenDeployer.selector);
        factory.create(PFWA, address(this), address(this));
        vm.prank(PFWA_LAUNCHER);
        address s = factory.create(PFWA, PFWA_LAUNCHER, PFWA_LAUNCHER);
        assertEq(s, factory.predict(PFWA, PFWA_LAUNCHER, PFWA_LAUNCHER));
        assertEq(PonsFeeSplitter(payable(s)).token(), PFWA);
    }
}
