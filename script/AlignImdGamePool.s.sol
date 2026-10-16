// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolPriceAlign} from "../src/PoolPriceAlign.sol";

/// Walks the empty Season 2 game pool (ETH/$IMD, 0.9%, Sherwood hook) to the 1% ETH/$IMD pool's live
/// price: deploys PoolPriceAlign through the CREATE2 deployer (once), then calls align. Trades nothing.
///   forge script script/AlignImdGamePool.s.sol --rpc-url <rpc> --sender 0x4209…1EEF   (simulation)
contract AlignImdGamePool is Script {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant HOOK = 0xc33c907127b94303F578d6Be551C36F45939e0cC;
    bytes32 constant SALT = bytes32(uint256(0x5e2));

    function run() external {
        PoolKey memory game = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(IMD), 9_000, 180, IHooks(HOOK));
        PoolKey memory market = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
        (, int24 before,,) = MANAGER.getSlot0(game.toId());
        vm.startBroadcast();
        PoolPriceAlign align = new PoolPriceAlign{salt: SALT}(MANAGER);
        align.align(game, market);
        vm.stopBroadcast();
        (, int24 afterTick,,) = MANAGER.getSlot0(game.toId());
        (, int24 marketTick,,) = MANAGER.getSlot0(market.toId());
        console2.log("helper", address(align));
        console2.log("game tick before / after / market:");
        console2.logInt(before);
        console2.logInt(afterTick);
        console2.logInt(marketTick);
    }
}
