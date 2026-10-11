// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SherwoodV2} from "./SherwoodV2.sol";

/// @notice Deploys a SherwoodV2 hook in its own constructor, for deployers that can't pick a CREATE2
/// salt (a factory that only deploys contracts with static constructor arguments).
/// A v4 hook's address must carry its permission flags in its low 14 bits, so the constructor
/// searches salts onchain for one that puts the hook at such an address, then deploys it there.
/// About 16k tries on average (one address in 2^14 matches), roughly 2M gas.
contract SherwoodV2Launcher {
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 internal constant MAX_TRIES = 400_000; // missing a match this long is ~e^-24

    /// @notice The game this launcher deployed.
    SherwoodV2 public immutable hook;
    /// @notice The salt it was deployed with.
    bytes32 public immutable salt;

    error NoSalt();

    /// Same arguments as SherwoodV2's constructor, in the same order, as plain types.
    constructor(
        address poolManager,
        address token,
        address host,
        uint256 hostHolderMin,
        address dice,
        address diceProvider,
        address owner,
        uint256 genesis
    ) {
        bytes memory init = abi.encodePacked(
            type(SherwoodV2).creationCode,
            abi.encode(poolManager, token, host, hostHolderMin, dice, diceProvider, owner, genesis)
        );
        bytes32 s = _mine(keccak256(init));
        address h;
        assembly ("memory-safe") {
            h := create2(0, add(init, 0x20), mload(init), s)
        }
        // SherwoodV2's constructor also checks the flags; this catches a failed create.
        if (h == address(0)) revert NoSalt();
        hook = SherwoodV2(payable(h));
        salt = s;
    }

    /// The first salt whose CREATE2 address from here carries exactly FLAGS in its low 14 bits.
    function _mine(bytes32 initHash) internal view returns (bytes32 s) {
        uint256 mask = Hooks.ALL_HOOK_MASK;
        uint256 flags = FLAGS;
        bool found;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // 0xff ++ this address ++ salt ++ initHash, hashed from ptr + 11 (85 bytes)
            mstore(ptr, address())
            mstore8(add(ptr, 11), 0xff)
            mstore(add(ptr, 64), initHash)
            for { let i := 0 } lt(i, MAX_TRIES) { i := add(i, 1) } {
                mstore(add(ptr, 32), i)
                if eq(and(keccak256(add(ptr, 11), 85), mask), flags) {
                    s := i
                    found := 1
                    break
                }
            }
        }
        if (!found) revert NoSalt();
    }
}
