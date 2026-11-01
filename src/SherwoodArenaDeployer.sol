// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SherwoodArena, IArenaRouter, IDiceEntropy} from "./SherwoodArena.sol";
import {HookrRouterAdapter, IHookrRouter, IHookrRules} from "./HookrRouterAdapter.sol";
import {SherwoodPotVault} from "./SherwoodPotVault.sol";

/// @title Sherwood on Hookr, deployed in one transaction
/// @notice Deploys the $PFWA arena's three contracts already wired together: the adapter (bound to the arena,
/// which only this deployer may do), the arena, and the pot vault the Hookr pool's buy tax is paid to. The
/// owner (of the arena and the vault) is passed in, not the sender, so this can go through a CREATE2 proxy.
/// After it, the owner launches the pool on Hookr with the vault as the tax recipient and calls setTaxQueue.
contract SherwoodArenaDeployer {
    // Robinhood Chain 4663: Hookr 1 (router, rules, root), $PFWA, HoodRand.
    address constant HOOKR_ROUTER = 0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9;
    address constant HOOKR_RULES = 0x4a71c270b1520F94064268102AebD744b0DE7942;
    address constant HOOKR_ROOT = 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc;
    address constant PFWA = 0xa934bA4F59070149d37A93F8A002Af79BAe35563;
    address constant HOODRAND = 0xbE5105faf1Cb76733876959d5802448d066D734F;
    uint24 constant DYNAMIC_FEE = 8_388_608;
    int24 constant TICK_SPACING = 200;

    HookrRouterAdapter public immutable adapter;
    SherwoodArena public immutable arena;
    SherwoodPotVault public immutable vault;

    constructor(address owner, uint256 genesis, uint256 roundLength) {
        adapter = new HookrRouterAdapter(IHookrRouter(HOOKR_ROUTER), IHookrRules(HOOKR_RULES), PFWA, DYNAMIC_FEE, TICK_SPACING, HOOKR_ROOT);
        arena = new SherwoodArena(
            PFWA, IArenaRouter(address(adapter)), IDiceEntropy(HOODRAND), HOODRAND, owner, genesis, 0, true, roundLength
        );
        adapter.bindArena(address(arena));
        vault = new SherwoodPotVault(owner, address(arena));
    }
}
