// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of PonsLaunchLocker (Robinhood Chain 0x736d…7f35) the splitter uses. The token's deployer
/// points its fees here with setFeeRedirect(token, splitter); the recipient may then collect them itself.
interface IPonsLocker {
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1);
}

interface IWETH {
    function withdraw(uint256 amount) external;
    function balanceOf(address who) external view returns (uint256);
}

interface IERC20Min {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title Pons fee splitter
/// @notice Receives a Pons-launched token's creator fees (WETH and the token) and, once a day, splits them:
/// a share of the ETH (half to start) to a game pot, the rest of the ETH and all of the token to a treasury wallet. Anyone
/// can run it; each run first collects whatever the Pons locker owes. Until a pot is set, the pot's half
/// waits here and goes out on the first run after it is.
contract PonsFeeSplitter {
    uint256 public constant INTERVAL = 1 days;

    IPonsLocker public immutable locker;
    IWETH public immutable weth;
    /// @notice The Pons-launched token whose fees this splits ($PFWA).
    address public immutable token;

    address public owner;
    address public pendingOwner;
    /// @notice Where half the ETH goes: the game's pot (its vault). Zero: held here for it.
    address public pot;
    /// @notice Where the other half of the ETH and all the token go.
    address public treasury;
    /// @notice The pot's share of each run's new ETH, in basis points. The owner can change it.
    uint256 public potBps = 5000;
    /// @notice ETH set aside for the pot, waiting for a pot address (or a pot that refused it).
    uint256 public heldForPot;
    uint256 public lastRun;

    event Distributed(uint256 ethToPot, uint256 ethToTreasury, uint256 tokenToTreasury, uint256 heldForPot);
    event PotSet(address indexed pot);
    event PotShareSet(uint256 bps);
    event TreasurySet(address indexed treasury);
    event OwnerProposed(address indexed next);
    event OwnerChanged(address indexed owner);

    error NotOwner();
    error TooSoon(uint256 nextRunAt);
    error ZeroAddress();
    error TransferFailed();
    error BadShare();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPonsLocker _locker, IWETH _weth, address _token, address _owner, address _treasury) {
        if (_owner == address(0) || _treasury == address(0)) revert ZeroAddress();
        locker = _locker;
        weth = _weth;
        token = _token;
        owner = _owner;
        treasury = _treasury;
    }

    /// WETH unwraps here, and anything else sent counts as fees.
    receive() external payable {}

    /// @notice Collects what Pons owes, then splits everything here. Once per INTERVAL; anyone can call.
    function distribute() external {
        uint256 next = lastRun + INTERVAL;
        if (block.timestamp < next) revert TooSoon(next);
        lastRun = block.timestamp;

        // Pons reverts when nothing is owed; a run with nothing new still pays out what's here.
        try locker.collectFees(token) {} catch {}
        uint256 w = weth.balanceOf(address(this));
        if (w > 0) weth.withdraw(w);

        uint256 fresh = address(this).balance - heldForPot;
        uint256 potShare = fresh * potBps / 10_000;
        uint256 forPot = potShare + heldForPot;
        uint256 forTreasury = fresh - potShare;
        uint256 tokens = IERC20Min(token).balanceOf(address(this));

        uint256 toPot;
        heldForPot = forPot;
        if (pot != address(0) && forPot > 0) {
            (bool ok,) = pot.call{value: forPot}("");
            if (ok) {
                toPot = forPot;
                heldForPot = 0;
            }
        }
        if (forTreasury > 0) {
            (bool ok,) = treasury.call{value: forTreasury}("");
            if (!ok) revert TransferFailed();
        }
        if (tokens > 0 && !IERC20Min(token).transfer(treasury, tokens)) revert TransferFailed();
        emit Distributed(toPot, forTreasury, tokens, heldForPot);
    }

    /// @notice When the next run is allowed.
    function nextRunAt() external view returns (uint256) {
        return lastRun + INTERVAL;
    }

    function setPot(address next) external onlyOwner {
        pot = next;
        emit PotSet(next);
    }

    /// @notice The pot's share of new ETH from the next run on, in basis points (5000 = half, 10000 = all).
    function setPotShare(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert BadShare();
        potBps = bps;
        emit PotShareSet(bps);
    }

    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        treasury = next;
        emit TreasurySet(next);
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
