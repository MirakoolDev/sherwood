// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Sherwood pot vault
/// @notice The fixed recipient of the pool's buy tax. Hookr locks a pool's tax recipient at launch, so the
/// pool pays this contract and it passes every wei straight on to the current arena, whose receive() adds
/// it to the live round's pot. Replacing the arena (a fixed or upgraded game) doesn't need a new pool: the
/// owner proposes the new arena and anyone can complete the switch after SWITCH_DELAY, so players see it
/// coming. The vault never keeps ETH except when the arena refuses it, and then flush() retries.
contract SherwoodPotVault {
    uint256 public constant SWITCH_DELAY = 2 days;

    address public owner;
    address public pendingOwner;
    /// @notice Where the tax goes now.
    address public arena;
    /// @notice The proposed next arena and when the switch can be made (0: none proposed).
    address public nextArena;
    uint256 public switchAt;

    event Forwarded(address indexed arena, uint256 amount, bool ok);
    event ArenaProposed(address indexed next, uint256 switchAt);
    event ArenaSwitchCancelled(address indexed next);
    event ArenaSwitched(address indexed previous, address indexed next);
    event OwnerProposed(address indexed next);
    event OwnerChanged(address indexed owner);

    error NotOwner();
    error NoArena();
    error NothingProposed();
    error TooEarly();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner, address _arena) {
        if (_arena == address(0)) revert NoArena();
        owner = _owner;
        arena = _arena;
    }

    /// The tax (or anyone's ETH) arrives and goes straight on to the arena. Never reverts, so the pool's
    /// payout always succeeds; ETH the arena refuses waits here for flush().
    receive() external payable {
        _forward();
    }

    /// @notice Sends anything held here to the arena. Anyone can call.
    function flush() external {
        _forward();
    }

    function _forward() internal {
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        address to = arena;
        (bool ok,) = to.call{value: amount}("");
        emit Forwarded(to, amount, ok);
    }

    /// Proposes a new arena; the switch can be made SWITCH_DELAY from now. Proposing again restarts the wait.
    function proposeArena(address next) external onlyOwner {
        if (next == address(0)) revert NoArena();
        nextArena = next;
        switchAt = block.timestamp + SWITCH_DELAY;
        emit ArenaProposed(next, switchAt);
    }

    function cancelSwitch() external onlyOwner {
        if (nextArena == address(0)) revert NothingProposed();
        emit ArenaSwitchCancelled(nextArena);
        delete nextArena;
        delete switchAt;
    }

    /// @notice Makes the proposed arena current once the wait is over. Anyone can call.
    function switchArena() external {
        address next = nextArena;
        if (next == address(0)) revert NothingProposed();
        if (block.timestamp < switchAt) revert TooEarly();
        emit ArenaSwitched(arena, next);
        arena = next;
        delete nextArena;
        delete switchAt;
        _forward();
    }

    function setOwner(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnerProposed(next);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = msg.sender;
        delete pendingOwner;
        emit OwnerChanged(msg.sender);
    }
}
