// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IArenaRouter} from "./SherwoodArena.sol";

/// @notice The part of HookrRouter (Robinhood Chain 0xC2Bc…93C9) the adapter uses.
interface IHookrRouter {
    struct Swap {
        PoolKey key;
        bool zeroForOne;
        int128 amountSpecified;
        uint128 amountBound;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint256 deadline;
    }

    function swap(Swap calldata params, address engagement, uint256[] calldata campaigns)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut);
}

/// @notice The part of HookrRules (0x4a71…7942) the adapter uses: the trader share of arb recapture.
interface IHookrRules {
    function claimable(Currency currency, address beneficiary) external view returns (uint256);
    function claimTo(Currency currency, address to) external returns (uint256);
}

/// @title Hookr router adapter for the Sherwood arena
/// @notice The arena's one swap (IArenaRouter.buy) as a buy on the ETH/$PFWA pool on Hookr's root, through
/// HookrRouter: all the ETH sent is the exact input, the $PFWA goes straight to `recipient`. Only the arena
/// can buy through it. Hookr sees this contract as the payer of every move, so the trader share of each arb
/// recapture is credited here as a claim; claimTradeShare() sends it to the arena, which adds it to the
/// live round's pot.
contract HookrRouterAdapter is IArenaRouter {
    IHookrRouter public immutable hookr;
    IHookrRules public immutable rules;
    /// @notice The pool: ETH (currency0, address zero) and $PFWA (currency1) on Hookr's root.
    address public immutable token;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hooks;
    address public immutable deployer;
    /// @notice The arena this adapter serves. Bound once, after the arena is deployed with this adapter.
    address public arena;

    event ArenaBound(address indexed arena);
    event TradeShareClaimed(address indexed arena, uint256 amount);

    error NotArena();
    error NotDeployer();
    error AlreadyBound();
    error NotBound();
    error RefundFailed();
    error UnexpectedEth();

    constructor(IHookrRouter _hookr, IHookrRules _rules, address _token, uint24 _fee, int24 _tickSpacing, address _hooks) {
        hookr = _hookr;
        rules = _rules;
        token = _token;
        fee = _fee;
        tickSpacing = _tickSpacing;
        hooks = _hooks;
        deployer = msg.sender;
    }

    function bindArena(address _arena) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (arena != address(0)) revert AlreadyBound();
        arena = _arena;
        emit ArenaBound(_arena);
    }

    /// @notice The pool key the adapter swaps on (and the site quotes with, from this contract's address).
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }

    /// Spends all the ETH sent on $PFWA for `recipient`. Hookr refuses a zero bound, so 0 becomes 1 (the
    /// arena checks what arrived against the player's own minOut). Input the router doesn't spend comes
    /// back here and goes on to the arena, which then reverts the move as a partial fill.
    function buy(uint256 minOut, address recipient) external payable returns (uint256 out) {
        if (msg.sender != arena) revert NotArena();
        IHookrRouter.Swap memory s = IHookrRouter.Swap({
            key: poolKey(),
            zeroForOne: true,
            amountSpecified: -int128(int256(msg.value)),
            amountBound: uint128(minOut == 0 ? 1 : minOut),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
            recipient: recipient,
            deadline: block.timestamp
        });
        uint256 amountIn;
        (amountIn, out) = hookr.swap{value: msg.value}(s, address(0), new uint256[](0));
        uint256 unspent = msg.value - amountIn;
        if (unspent != 0) {
            (bool ok,) = msg.sender.call{value: unspent}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice The trader share waiting for this adapter in Hookr's Rules, in ETH.
    function tradeShareClaimable() external view returns (uint256) {
        return rules.claimable(Currency.wrap(address(0)), address(this));
    }

    /// @notice Sends the trader share of arb recapture to the arena's live pot. Anyone may call; it reverts
    /// (Hookr's NothingToClaim) when nothing is credited.
    function claimTradeShare() external returns (uint256 amount) {
        address a = arena;
        if (a == address(0)) revert NotBound();
        amount = rules.claimTo(Currency.wrap(address(0)), a);
        emit TradeShareClaimed(a, amount);
    }

    /// Only the router's refunds of unspent input, during a buy.
    receive() external payable {
        if (msg.sender != address(hookr)) revert UnexpectedEth();
    }
}
