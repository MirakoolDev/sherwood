// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {SherwoodV2, IDiceEntropy} from "../src/SherwoodV2.sol";

/// Deploys a Sherwood v2 game for one token on Robinhood Chain (4663).
/// The hook address must carry the permission flags in its low bits (0x20CC), so it is mined:
/// CREATE2 through the standard deployer proxy, with a salt searched over the exact constructor args.
/// Whoever broadcasts only pays gas; `owner` (our admin) is set in the constructor.
///
///   TOKEN=0x5F7B…7127 GENESIS=<unix> forge script script/DeploySherwoodV2.s.sol --rpc-url robinhood --broadcast
///
/// Env: TOKEN (game token, required), GENESIS (round 0 start, required),
///      HOST (default $PFWA; set equal to TOKEN for $PFWA's own game), HOST_MIN (default 100k), OWNER (default admin).
contract DeploySherwoodV2 is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant DICE = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    address constant DICE_PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    address constant ADMIN = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external returns (SherwoodV2 hook) {
        address token = vm.envAddress("TOKEN");
        uint256 genesis = vm.envUint("GENESIS");
        address host = vm.envOr("HOST", PFWA);
        uint256 hostMin = vm.envOr("HOST_MIN", uint256(100_000e18));
        address owner = vm.envOr("OWNER", ADMIN);
        require(CREATE2_DEPLOYER.code.length > 0, "no CREATE2 deployer proxy on this chain");
        require(genesis > block.timestamp, "GENESIS is in the past");

        bytes memory args = abi.encode(
            MANAGER, Currency.wrap(token), Currency.wrap(host), hostMin, IDiceEntropy(DICE), DICE_PROVIDER, owner, genesis
        );
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SherwoodV2).creationCode, args);

        vm.startBroadcast();
        hook = new SherwoodV2{salt: salt}(
            MANAGER, Currency.wrap(token), Currency.wrap(host), hostMin, IDiceEntropy(DICE), DICE_PROVIDER, owner, genesis
        );
        vm.stopBroadcast();
        require(address(hook) == expected, "hook address mismatch");

        console2.log("SherwoodV2 hook:", address(hook));
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("token / host / owner:", token, host, owner);
        console2.log("genesis:", genesis);
    }
}
