// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Moves an empty stretch of a v4 pool's price to another pool's live price, trading nothing.
/// A pool nobody can trade in (no liquidity between its price and the market's) keeps the price it was
/// created at; this walks it to the reference pool's price with a 1-wei swap limited to that price.
/// Across a stretch with no liquidity the swap moves the price and exchanges nothing; if any liquidity
/// sits in the way, tokens would change hands and the call reverts instead. Holds no funds, no owner.
contract PoolPriceAlign is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;

    error NotManager();
    error DifferentPair();
    error WouldTrade();
    error Missed();

    event Aligned(bytes32 indexed poolId, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96);

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @notice Moves `pool`'s price to `ref`'s current price. Both must pair the same two currencies.
    function align(PoolKey calldata pool, PoolKey calldata ref) external {
        if (
            Currency.unwrap(pool.currency0) != Currency.unwrap(ref.currency0)
                || Currency.unwrap(pool.currency1) != Currency.unwrap(ref.currency1)
        ) revert DifferentPair();
        (uint160 target,,,) = manager.getSlot0(ref.toId());
        manager.unlock(abi.encode(pool, target));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (PoolKey memory pool, uint160 target) = abi.decode(data, (PoolKey, uint160));
        (uint160 from,,,) = manager.getSlot0(pool.toId());
        if (from == target) return "";
        // Price falls on zeroForOne swaps and rises on oneForZero ones; exact input of 1 wei.
        BalanceDelta delta =
            manager.swap(pool, SwapParams({zeroForOne: target < from, amountSpecified: -1, sqrtPriceLimitX96: target}), "");
        if (delta.amount0() != 0 || delta.amount1() != 0) revert WouldTrade();
        (uint160 to,,,) = manager.getSlot0(pool.toId());
        if (to != target) revert Missed();
        emit Aligned(PoolId.unwrap(pool.toId()), from, to);
        return "";
    }
}
