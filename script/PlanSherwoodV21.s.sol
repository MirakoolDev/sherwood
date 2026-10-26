// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {SherwoodV21, IDiceEntropy} from "../src/SherwoodV21.sol";

/// Plans a Sherwood v2.1 game for one token without sending anything: mines the hook's CREATE2 salt
/// over the exact constructor arguments and prints the three transactions the admin wallet signs:
///   1. deploy the hook through the standard CREATE2 deployer proxy (data = salt ++ init code)
///   2. create the ETH/token game pool on the hook (owner only; 0.9% LP fee, tick spacing 180). v2.1
///      burns the token through this same pool, so there is no separate burn pool.
///   3. setOperator(bot) so upkeep can settle and burn
/// The pool is created empty at SQRT_PRICE (ETH = currency0); anyone can add liquidity afterwards.
///
///   TOKEN=0x… GENESIS=<unix> SQRT_PRICE=<uint160> forge script script/PlanSherwoodV21.s.sol --rpc-url robinhood
contract PlanSherwoodV21 is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant DICE = 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c;
    address constant DICE_PROVIDER = 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6;
    address constant ADMIN = 0x420944b441715E34Dd672AE0Eb4526A7AD7d1EEF;
    address constant BOT = 0x4f77C413e6B2c6463812EFAa2033373c075cd7d9;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external view {
        address token = vm.envAddress("TOKEN");
        uint256 genesis = vm.envUint("GENESIS");
        uint160 sqrtPrice = uint160(vm.envUint("SQRT_PRICE"));
        uint256 hostMin = vm.envOr("HOST_MIN", uint256(100_000e18));

        bytes memory args = abi.encode(
            MANAGER, Currency.wrap(token), Currency.wrap(PFWA), hostMin, IDiceEntropy(DICE), DICE_PROVIDER, ADMIN, genesis
        );
        bytes memory init = abi.encodePacked(type(SherwoodV21).creationCode, args);
        (address hook, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(SherwoodV21).creationCode, args);

        PoolKey memory gameKey = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), 9_000, 180, IHooks(hook));

        console2.log("hook:", hook);
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("init code bytes:", init.length);
        console2.log("game pool id:");
        console2.logBytes32(PoolId.unwrap(gameKey.toId()));
        console2.log("TX1 to:", CREATE2_DEPLOYER);
        console2.log("TX1 data:");
        console2.logBytes(abi.encodePacked(salt, init));
        console2.log("TX2 to:", address(MANAGER));
        console2.log("TX2 data:");
        console2.logBytes(abi.encodeCall(IPoolManager.initialize, (gameKey, sqrtPrice)));
        console2.log("TX3 to:", hook);
        console2.log("TX3 data:");
        console2.logBytes(abi.encodeCall(SherwoodV21.setOperator, (BOT)));
    }
}
