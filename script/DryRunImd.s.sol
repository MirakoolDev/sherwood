// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DeploySherwoodV2} from "./DeploySherwoodV2.s.sol";
import {SetupSherwoodV2} from "./SetupSherwoodV2.s.sol";

/// Simulation only (never --broadcast): deploy the $IMD game, then run the owner setup, on a fork.
///   TOKEN=0x5F7B…7127 GENESIS=<unix> forge script script/DryRunImd.s.sol --rpc-url <rpc> --sender 0x4209…1EEF
contract DryRunImd is Script {
    function run() external {
        address hook = address(new DeploySherwoodV2().run());
        vm.setEnv("HOOK", vm.toString(hook));
        new SetupSherwoodV2().run();
    }
}
