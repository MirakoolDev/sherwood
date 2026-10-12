// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodV2Fixture} from "./helpers/SherwoodV2Fixture.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// Generic adversarial v4 integration stand-in, not a replica of the live PFWA holder hook.
/// Charges a specified ETH delta, an unspecified token delta, and overrides a dynamic LP fee.
contract AuditBurnFeeHook {
    IPoolManager public immutable manager;
    uint256 public ethFees;
    uint256 public tokenFees;

    constructor(IPoolManager m) {
        manager = m;
    }
    receive() external payable {}

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(manager));
        require(params.zeroForOne && params.amountSpecified < 0);
        uint256 fee = uint256(-params.amountSpecified) / 100;
        manager.take(key.currency0, address(this), fee);
        ethFees += fee;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), uint24(10_000 | 0x400000));
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(manager));
        uint256 fee = uint256(int256(delta.amount1())) / 100;
        manager.take(key.currency1, address(this), fee);
        tokenFees += fee;
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }
}

contract SherwoodV2BuybackHookTest is SherwoodV2Fixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_burnUsesNetDeltasIncludingExternalHookFees(bool isHost, uint256 amountSeed) public {
        MockERC20 output = isHost ? hostToken : gameToken;
        address feeAddress = address(uint160(0xBACC0000) | uint160(0xCC));
        deployCodeTo("SherwoodV2BuybackHook.t.sol:AuditBurnFeeHook", abi.encode(manager), feeAddress);
        AuditBurnFeeHook feeHook = AuditBurnFeeHook(payable(feeAddress));
        PoolKey memory feeKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(output)), 0x800000, 60, IHooks(feeAddress));
        manager.initialize(feeKey, PRICE_ONE);
        _liquidity(feeKey, -60000, 60000, 1_000e18);
        vm.prank(owner);
        if (isHost) game.setHostBuybackPool(feeKey);
        else game.setBuybackPool(feeKey);
        _seed(0, bound(amountSeed, 1 ether, 10 ether));
        _finishRound(0);
        uint256 reserve = isHost ? game.hostBuybackReserve() : game.buybackReserve();
        uint256 other = isHost ? game.buybackReserve() : game.hostBuybackReserve();
        uint256 beforeETH = address(game).balance;
        uint256 managerBefore = address(manager).balance;
        uint256 snapshot = vm.snapshotState();
        vm.prank(owner);
        if (isHost) game.buybackAndBurnHost(reserve, 0);
        else game.buybackAndBurn(reserve, 0);
        uint256 netOut = output.balanceOf(DEAD);
        assertGt(netOut, 0);
        assertGt(feeHook.tokenFees(), 0);
        assertEq(feeAddress.balance, reserve / 100);
        assertEq(feeHook.ethFees(), feeAddress.balance);
        assertEq(output.balanceOf(feeAddress), feeHook.tokenFees());
        assertEq(beforeETH - address(game).balance, reserve);
        assertEq(address(manager).balance - managerBefore + feeAddress.balance, reserve);
        assertEq(isHost ? game.hostBuybackReserve() : game.buybackReserve(), 0);
        assertEq(isHost ? game.buybackReserve() : game.hostBuybackReserve(), other);
        assertEq(isHost ? gameToken.balanceOf(DEAD) : hostToken.balanceOf(DEAD), 0);
        assertTrue(vm.revertToState(snapshot));
        vm.prank(owner);
        vm.expectRevert(SherwoodV2.TooLittleOut.selector);
        if (isHost) game.buybackAndBurnHost(reserve, netOut + 1);
        else game.buybackAndBurn(reserve, netOut + 1);
        assertEq(feeAddress.balance, 0, "failed slippage must revert the outside hook's fee too");
        assertEq(output.balanceOf(feeAddress), 0);
        assertEq(feeHook.ethFees(), 0);
        assertEq(feeHook.tokenFees(), 0);
        vm.prank(owner);
        if (isHost) game.buybackAndBurnHost(reserve, netOut);
        else game.buybackAndBurn(reserve, netOut);
        assertEq(output.balanceOf(DEAD), netOut, "slippage boundary is the actual net tokens burned");
    }
}
