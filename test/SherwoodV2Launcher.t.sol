// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SherwoodV2Launcher} from "src/SherwoodV2Launcher.sol";
import {SherwoodV2} from "src/SherwoodV2.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract AuditLauncherFactory {
    function deploy(address owner) external returns (SherwoodV2Launcher) {
        return new SherwoodV2Launcher(
            0x8366a39CC670B4001A1121B8F6A443A643e40951,
            0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127,
            0xa934bA4F59070149d37A93F8A002Af79BAe35563,
            100_000e18,
            0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c,
            0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6,
            owner,
            1_791_835_200
        );
    }
}

contract SherwoodV2LauncherOfflineTest is Test {
    function test_constructorWorksOnEmptyChainAndFactoryDoesNotOwnHook() public {
        vm.chainId(4663);
        address owner = makeAddr("explicit launch owner");
        AuditLauncherFactory factory = new AuditLauncherFactory();
        assertEq(address(0x8366a39CC670B4001A1121B8F6A443A643e40951).code.length, 0);
        uint256 gasBefore = gasleft();
        SherwoodV2Launcher launcher = factory.deploy(owner);
        emit log_named_uint("offline launcher deployment gas", gasBefore - gasleft());
        SherwoodV2 hook = launcher.hook();
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x20CC);
        assertEq(hook.owner(), owner);
        assertEq(hook.operator(), owner);
        assertEq(address(hook.poolManager()), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(Currency.unwrap(hook.token()), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
        assertEq(Currency.unwrap(hook.host()), 0xa934bA4F59070149d37A93F8A002Af79BAe35563);
        assertEq(address(hook.dice()), 0xd8A0680e7699526B57140ED4EAfdCc7219Dc0A0c);
        assertEq(hook.diceProvider(), 0x8741b8a825644D9Ef18Faf2DAB5e9b47B900F2b6);
        assertEq(hook.GENESIS(), 1_791_835_200);
        assertEq(hook.hostHolderMin(), 100_000e18);
        assertTrue(hook.hostEnabled());
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(SherwoodV2).creationCode,
                abi.encode(
                    address(hook.poolManager()),
                    Currency.unwrap(hook.token()),
                    Currency.unwrap(hook.host()),
                    hook.hostHolderMin(),
                    address(hook.dice()),
                    hook.diceProvider(),
                    owner,
                    hook.GENESIS()
                )
            )
        );
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launcher), launcher.salt(), initHash))))
        );
        assertEq(address(hook), predicted, "published salt must reproduce the actual child");
        assertGt(address(hook).code.length, 0);
        assertLe(address(hook).code.length, 24_576);
        assertLe(address(launcher).code.length, 24_576);
        assertLt(type(SherwoodV2Launcher).creationCode.length + 8 * 32, 49_152);
        assertEq(address(hook).balance, 0);
        assertEq(address(launcher).balance, 0);
        vm.prank(address(factory));
        vm.expectRevert(SherwoodV2.NotOwner.selector);
        hook.setOperator(address(factory));
        vm.prank(owner);
        hook.setOperator(makeAddr("explicit operator"));
        assertEq(hook.operator(), makeAddr("explicit operator"));
    }
}
