// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SherwoodV2} from "../src/SherwoodV2.sol";

/// Owner setup for the $IMD game after the hook is deployed. Broadcast from the admin wallet (the hook's owner):
///   1. create the ETH/$IMD game pool on the hook (0.9% LP fee), at the 1% ETH/$IMD pool's live price
///   2. setOperator(bot) so upkeep can settle and burn
/// The two burn pools (the 1% ETH/$IMD pool and the ETH/$PFWA holder pool) are fixed in the hook at
/// deployment; this script only checks that both exist. Each step is skipped if already done, so a
/// failed run can be re-run.
///
///   HOOK=0x… forge script script/SetupSherwoodV2.s.sol --rpc-url robinhood --broadcast --account admin
contract SetupSherwoodV2 is Script {
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant BOT = 0x4f77C413e6B2c6463812EFAa2033373c075cd7d9;

    function run() external {
        SherwoodV2 hook = SherwoodV2(payable(vm.envAddress("HOOK")));
        require(Currency.unwrap(hook.token()) == IMD, "hook is not the $IMD game");
        require(Currency.unwrap(hook.host()) == PFWA, "hook's host is not $PFWA");

        PoolKey memory burnKey = hook.buybackPool();
        PoolKey memory hostKey = hook.hostBuybackPool();
        PoolKey memory gameKey =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(IMD), 9_000, 180, IHooks(address(hook)));

        (uint160 price,,,) = MANAGER.getSlot0(burnKey.toId());
        require(price != 0, "ETH/IMD 1% pool not found");
        (uint160 hostPrice,,,) = MANAGER.getSlot0(hostKey.toId());
        require(hostPrice != 0, "ETH/PFWA holder pool not found");

        vm.startBroadcast();
        if (PoolId.unwrap(hook.poolId()) == bytes32(0)) MANAGER.initialize(gameKey, price);
        if (hook.operator() != BOT) hook.setOperator(BOT);
        vm.stopBroadcast();

        console2.log("game pool id:");
        console2.logBytes32(PoolId.unwrap(gameKey.toId()));
        console2.log("operator:", hook.operator());
    }
}
