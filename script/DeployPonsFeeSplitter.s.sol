// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PonsFeeSplitter, IPonsLocker, IWETH} from "../src/PonsFeeSplitter.sol";

/// Deploys the splitter for $PFWA's Pons fees and points those fees at it, in one broadcast.
/// Broadcast from the wallet that launched $PFWA on Pons (only it may call setFeeRedirect):
///
///   forge script script/DeployPonsFeeSplitter.s.sol --rpc-url robinhood --broadcast --account <dev wallet>
///
/// Env: OWNER and TREASURY (both default to the dev wallet), POT (default unset: the pot's half waits in the splitter).
contract DeployPonsFeeSplitter is Script {
    address constant LOCKER = 0x736D76699C26D0d966744cAe304C000d471f7F35;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant DEV = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;

    function run() external returns (PonsFeeSplitter splitter) {
        address owner = vm.envOr("OWNER", DEV);
        address treasury = vm.envOr("TREASURY", DEV);
        address pot = vm.envOr("POT", address(0));
        vm.startBroadcast();
        splitter = new PonsFeeSplitter(IPonsLocker(LOCKER), IWETH(WETH), PFWA, owner, treasury);
        (bool ok,) = LOCKER.call(abi.encodeWithSignature("setFeeRedirect(address,address)", PFWA, address(splitter)));
        require(ok, "setFeeRedirect: broadcast from the wallet that launched PFWA");
        if (pot != address(0)) splitter.setPot(pot);
        vm.stopBroadcast();
        console2.log("PonsFeeSplitter", address(splitter));
    }
}
