// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// The hook of the imported audit's diversion scenario: a pool whose beforeSwap takes almost all the ETH
/// of every buy for itself. Before the fix the owner could name a pool carrying it as a burn pool.
contract CaptureHook {
    IPoolManager public immutable manager;
    address public immutable thief;

    constructor(IPoolManager m, address t) {
        manager = m;
        thief = t;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 taken = uint256(-params.amountSpecified) - 1;
        manager.take(key.currency0, thief, taken);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(taken)), 0), 0);
    }
}

/// The launch configuration the imported audit asked for: both burn pools fixed at deployment with no
/// way to redirect them, and an owner handover that cannot strand the hook.
contract SherwoodV2LaunchConfigTest is SherwoodV2Fixture {
    event OwnerProposed(address pendingOwner);
    event OwnerChanged(address owner);

    function test_burnPoolsAreTheBriefsPoolsDerivedFromTheConstructor() public view {
        PoolKey memory burn = game.buybackPool();
        assertEq(Currency.unwrap(burn.currency0), address(0));
        assertEq(Currency.unwrap(burn.currency1), address(gameToken), "ETH/token");
        assertEq(burn.fee, 10_000, "the 1% pool");
        assertEq(burn.tickSpacing, 100);
        assertEq(address(burn.hooks), address(0), "no hook can take the ETH");
        PoolKey memory hostBurn = game.hostBuybackPool();
        assertEq(Currency.unwrap(hostBurn.currency0), address(0));
        assertEq(Currency.unwrap(hostBurn.currency1), address(hostToken), "ETH/host");
        assertEq(hostBurn.fee, 0x800000, "the holder pool has a dynamic fee");
        assertEq(hostBurn.tickSpacing, 200);
        assertEq(address(hostBurn.hooks), 0xb914f955294799de4b891bd2EA8AF628Fa1c68CC, "the holder hook");
        assertTrue(PoolId.unwrap(burn.toId()) != PoolId.unwrap(game.poolId()));
        assertTrue(PoolId.unwrap(hostBurn.toId()) != PoolId.unwrap(game.poolId()));
    }

    /// The imported audit's reproduction, against the fixed code: the owner cannot name the capture pool,
    /// and the burn goes through the 1% pool to the dead address with every wei accounted for.
    function test_ownerCannotRedirectTheBurnToACapturePool() public {
        address thief = makeAddr("thief");
        address captureAddress = address(uint160(0xCA7000) << 24 | uint160(0x2088)); // beforeInitialize | beforeSwap | returns delta
        deployCodeTo("SherwoodV2LaunchConfig.t.sol:CaptureHook", abi.encode(manager, thief), captureAddress);
        PoolKey memory capture =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(gameToken)), 3000, 60, IHooks(captureAddress));
        manager.initialize(capture, PRICE_ONE);
        _liquidity(capture, -60000, 60000, 1_000e18);

        vm.startPrank(owner);
        (bool ok,) = address(game)
            .call(abi.encodeWithSignature("setBuybackPool((address,address,uint24,int24,address))", capture));
        assertFalse(ok, "no setter exists");
        (ok,) = address(game)
            .call(abi.encodeWithSignature("setHostBuybackPool((address,address,uint24,int24,address))", capture));
        assertFalse(ok, "no setter exists");
        vm.stopPrank();

        _buy(alice, 0.1 ether, SherwoodV2.Move.BUY);
        _finishRound(0);
        uint256 reserve = game.buybackReserve();
        assertEq(reserve, 0.0005 ether);
        uint256 managerBefore = address(manager).balance;
        uint256 deadBefore = gameToken.balanceOf(DEAD);
        vm.prank(owner);
        game.buybackAndBurn(reserve, 1);
        assertEq(thief.balance, 0, "nothing left the game but into the 1% pool");
        assertEq(address(manager).balance - managerBefore, reserve);
        assertGt(gameToken.balanceOf(DEAD), deadBefore);
        assertEq(game.buybackReserve(), 0);
    }

    function test_ownerHandoverIsTwoStep() public {
        vm.prank(owner);
        vm.expectEmit(address(game));
        emit OwnerProposed(alice);
        game.setOwner(alice);
        assertEq(game.owner(), owner, "nothing changes until the next owner accepts");
        assertEq(game.pendingOwner(), alice);

        vm.prank(bob);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.acceptOwner();
        vm.prank(owner);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.acceptOwner(); // the current owner is not the one named

        // The owner keeps every power meanwhile.
        vm.prank(owner);
        game.setOperator(carol);
        assertEq(game.operator(), carol);

        vm.prank(alice);
        vm.expectEmit(address(game));
        emit OwnerChanged(alice);
        game.acceptOwner();
        assertEq(game.owner(), alice);
        assertEq(game.pendingOwner(), address(0));
        vm.prank(alice);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.acceptOwner(); // once
        vm.prank(owner);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        game.setOperator(bob);
        vm.prank(alice);
        game.setOperator(bob);
        assertEq(game.operator(), bob);
    }

    /// The imported audit's reproduction: a handover to address(0), or to an address nobody controls,
    /// before the owner setup. The owner keeps control and can still create the game pool.
    function test_ownerHandoverToAWrongAddressIsHarmlessAndCancellable() public {
        address fresh = address(uint160(0xF2E5A0000) << 8 | uint160(0x20CC));
        deployCodeTo(
            "SherwoodV2.sol:SherwoodV2",
            abi.encode(
                manager,
                Currency.wrap(address(gameToken)),
                Currency.wrap(address(hostToken)),
                HOST_MIN,
                dice,
                address(1),
                owner,
                GENESIS
            ),
            fresh
        );
        SherwoodV2 unset = SherwoodV2(payable(fresh));
        vm.startPrank(owner);
        unset.setOwner(address(0));
        assertEq(unset.owner(), owner);
        assertEq(unset.pendingOwner(), address(0));
        address typo = makeAddr("typo");
        unset.setOwner(typo);
        assertEq(unset.pendingOwner(), typo);
        unset.setOwner(address(0)); // cancelled
        assertEq(unset.pendingOwner(), address(0));
        vm.stopPrank();
        vm.prank(typo);
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        unset.acceptOwner();

        // The owner setup still works.
        PoolKey memory key_ =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(gameToken)), 500, 10, IHooks(fresh));
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(key_, PRICE_ONE);
        vm.prank(owner);
        manager.initialize(key_, PRICE_ONE);
        assertEq(PoolId.unwrap(unset.poolId()), PoolId.unwrap(key_.toId()));
        vm.prank(owner);
        unset.setOperator(bob);
        assertEq(unset.operator(), bob);
    }
}
