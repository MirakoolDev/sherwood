// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Dice Protocol randomness (a Pyth Entropy fork on Robinhood Chain).
interface IDiceEntropy {
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 assignedSequenceNumber);
    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128 feeAmount);
    function refundRequest(address provider, uint64 sequenceNumber) external;
}

/// @title Sherwood v2
/// @notice A leaderboard game in rolling 20-hour rounds, played with buys on an ETH/token Uniswap v4 pool.
/// The game token is $PFWA for Sherwood itself, or another token (e.g. $IMD) whose game also feeds
/// the host token ($PFWA): part of every pot burns $PFWA, and $PFWA holders score more.
///
/// Every exact-input swap pays 5% of its ETH side into the round's pot. Buys of at
/// least 0.001 ETH score 1 point per 0.001 ETH (up to 100 per buy), with one of
/// five moves picked on sherwood.pfwa.fun and passed as hook data:
///   BUY        your points.
///   STEAL      your points, plus 20% of the previous player's. A charge every 10 minutes,
///              up to 18 banked.
///   ROBIN_HOOD your points, and 10% of the leader's go to the lowest of the last 10 players.
///              A charge every hour, up to 3 banked.
///   FLIP       a Dice Protocol coin flip: win double this buy's points, or lose them to the
///              previous player. A loss comes off your total, so it can take you below zero.
///              Three charges a round, up to 6 banked.
///   SHIELD     your points, and if you have a charge, a 30-minute shield: the next Steal or
///              Robin Hood aimed at you is turned around and the attacker pays you instead.
///              Every 0.025 ETH you play in a round earns a charge; you can hold one.
/// Charges stack across rounds and a new wallet starts with a full bank. A move with no charge
/// left (or a Shield without a charge) plays as a BUY: a swap never reverts
/// over a move. Selling wipes the seller's points for the round if they're above zero (a
/// negative score stays). Steal and Robin Hood only take from players above zero. A swap with
/// no hook data is a BUY.
/// The player is the wallet that signed the transaction (tx.origin): hooks only see the router.
///
/// Rounds run ROUND_LENGTH back to back from GENESIS. Whoever holds #1 the longest in a round
/// is its King of the Hill. After a round ends anyone can settle it: 40/20/10% of its pot go to
/// the top three and 8% to the King, to claim within 7 days (unclaimed prizes go back into the pot
/// of the round live when they're swept); 10% buys back and burns the game token through the
/// buyback pool, 7% buys back and burns the host token through the host buyback pool, and 5% (plus
/// any unawarded share) rolls into the current round. When the game token is the host token there's
/// no host burn or host bonus: the host's 7% burns with the game token's 10%.
contract SherwoodV2 is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // ── Game constants ──────────────────────────────────────────────────────────
    uint256 internal constant FEE_BPS = 500; // 5% of every swap's ETH side → pot
    uint256 internal constant MIN_BUY = 0.001 ether;
    uint256 internal constant POINT_UNIT = 0.001 ether;
    uint256 internal constant MAX_POINTS_PER_BUY = 100;
    // Steal, Robin Hood and a flip win all grow with the buy, like points do: from the MIN share
    // at the smallest buy up to the MAX share at MAX_POINTS_PER_BUY.
    uint256 internal constant STEAL_BPS_MIN = 2000; // 20% of the previous player's points...
    uint256 internal constant STEAL_BPS_MAX = 4000; // ...up to 40%
    uint256 internal constant ROBIN_BPS_MIN = 1000; // 10% of the leader's points...
    uint256 internal constant ROBIN_BPS_MAX = 3300; // ...up to 33%
    uint256 internal constant FLIP_WIN_BPS_MIN = 20_000; // a won flip pays 2x its points...
    uint256 internal constant FLIP_WIN_BPS_MAX = 30_000; // ...up to 3x
    // Still holding all the tokens you bought here last round when you play this one: +25% points.
    uint256 internal constant HOLDER_BONUS_BPS = 12_500;
    // Holding at least hostHolderMin of the host token when you play: +10% points (games of other tokens only).
    uint256 internal constant HOST_BONUS_BPS = 11_000;
    // Referrals, only in rounds the referrer played too: 10% of each of their player's buys in bonus
    // points, and 5% of that player's prizes from the rollover. Nothing is taken from the player.
    uint256 internal constant REFERRAL_POINTS_BPS = 1000;
    uint256 internal constant REFERRAL_PRIZE_BPS = 500;
    // A referred player's first round: +10% points.
    uint256 internal constant WELCOME_BONUS_BPS = 1000;
    uint256 internal constant RECENT = 10; // Robin Hood pays the lowest of the last 10 players
    uint256 public constant SETTLE_DELAY = 15 minutes; // lets flips from the last minutes resolve
    uint256 internal constant CLAIM_WINDOW = 7 days;
    uint256 internal constant FLIP_TIMEOUT = 10 minutes; // an unrevealed flip then scores as a plain buy
    uint256 internal constant MAX_SEED_AHEAD = 365; // how far ahead fundPot can seed a round (about a year)
    uint32 internal constant FLIP_CALLBACK_GAS = 200_000;
    uint256 internal constant MAX_DICE_FEE = 0.0005 ether; // 20x Dice's fee at launch; above it a flip scores as a buy
    // When the cached #1 loses points the board is rescanned for the new #1. Up to MAX_LEADER_SCAN
    // players the move that debited #1 rescans the whole board. A bigger board is rescanned by the
    // transactions that follow (see _resumeScan), each over at least LEADER_SCAN_CHUNK players and as
    // many more as its gas allows while keeping LEADER_SCAN_RESERVE for the rest of the swap.
    uint256 internal constant MAX_LEADER_SCAN = 1500;
    uint256 internal constant LEADER_SCAN_CHUNK = 200;
    uint256 internal constant LEADER_SCAN_RESERVE = 1_000_000;
    // Bound on the leader rescan inside the Dice callback, which only has FLIP_CALLBACK_GAS: about
    // 4.4k gas per player with cold storage on top of the ~110k a lost flip by #1 costs.
    uint256 internal constant MAX_CALLBACK_SCAN = 12;
    // Reign holder while #1 is unknown (a rescan still to come). Nobody's clock runs then, but once
    // the rescan completes the #1 it finds is credited back to the last point change (see _setReign).
    address internal constant UNKNOWN_REIGN = address(1);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Length of every round. Round `r` runs from roundStart(r) to roundEnd(r).
    uint256 public constant ROUND_LENGTH = 20 hours;

    /// @notice Each SHIELD_CHARGE_ETH a player plays in a round (any move, buys of MIN_BUY or more)
    /// earns one shield charge. A player holds at most one: a charge earned while holding one is lost.
    uint256 internal constant SHIELD_CHARGE_ETH = 0.025 ether;
    /// @notice How long a shield stays up after a SHIELD move spends a charge.
    uint256 internal constant SHIELD_DURATION = 30 minutes;
    // STEAL, ROBIN_HOOD and FLIP run on charges that stack: each move earns one charge every
    // *_RECHARGE, banked up to *_MAX_CHARGES, across rounds. A wallet starts with a full bank.
    // Playing one with no charge left plays it as a BUY.
    /// @notice One STEAL charge every 10 minutes, up to 18 banked (3 hours' worth, 6x Robin Hood's).
    uint256 internal constant STEAL_RECHARGE = 10 minutes;
    uint256 internal constant STEAL_MAX_CHARGES = 18;
    /// @notice One ROBIN_HOOD charge an hour, up to 3 banked.
    uint256 internal constant ROBIN_RECHARGE = 1 hours;
    uint256 internal constant ROBIN_MAX_CHARGES = 3;
    /// @notice Three FLIP charges a round, up to 6 (two rounds' worth) banked.
    uint256 internal constant FLIP_RECHARGE = ROUND_LENGTH / 3;
    uint256 internal constant FLIP_MAX_CHARGES = 6;

    // How a settled pot is split. Sums to 10_000.
    /// @notice #1's share of the pot.
    uint256 public constant FIRST_BPS = 4000;
    /// @notice #2's share of the pot.
    uint256 public constant SECOND_BPS = 2000;
    /// @notice #3's share of the pot.
    uint256 public constant THIRD_BPS = 1000;
    /// @notice The King of the Hill's share of the pot (longest time at #1).
    uint256 public constant KING_BPS = 800;
    /// @notice Share of the pot that goes to the buyback reserve and burns the game token.
    uint256 public constant BURN_BPS = 1000;
    /// @notice Share of the pot that goes to the host buyback reserve and burns the host token
    /// (to the buyback reserve instead when the game token is the host token).
    uint256 public constant HOST_BURN_BPS = 700;
    /// @notice Share of the pot that rolls into the current round (plus anything unawarded). Referral
    /// cuts come out of it: 5% of each prize, so at most 5% of the 78% in prizes = 3.9% of the pot.
    uint256 public constant ROLLOVER_BPS = 500;

    enum Move {
        BUY,
        STEAL,
        ROBIN_HOOD,
        FLIP,
        SHIELD
    }

    // ── Wiring ──────────────────────────────────────────────────────────────────
    /// Tokens each player bought through this pool, per round. A winner keeps the share of the prize
    /// matching the share of that round's buys they still hold, and holding last round's buys earns
    /// the holder bonus this round.
    mapping(uint256 round => mapping(address player => uint256)) public bought;

    /// Who referred each player. Set once, from the first play that names one, and never changed.
    mapping(address player => address) public referrerOf;
    /// The round of each player's first play, plus one (0 = never played). A referrer can only be
    /// named on that first play, and a referred player's welcome bonus lasts that round.
    mapping(address player => uint256) public firstRoundPlus1;
    /// Referral prize shares waiting to be claimed.
    mapping(address referrer => uint256) public referralEarnings;

    IPoolManager public immutable poolManager;
    /// @notice The game token: what the game pool trades against ETH, and what its burn buys.
    Currency public immutable token;
    /// @notice The host token ($PFWA). Equal to `token` for $PFWA's own game: host features off.
    Currency public immutable host;
    /// @notice Host token a player must hold when they play for the host bonus.
    uint256 public immutable hostHolderMin;
    /// @notice Whether the host burn and host bonus are on (the game token isn't the host token).
    bool public immutable hostEnabled;
    IDiceEntropy public immutable dice;
    address public immutable diceProvider;
    /// @notice When round 0 starts. Before it swaps still work and their fees go to round 0's pot,
    /// but nothing is scored (no points, no `bought`, no first play for referrals).
    uint256 public immutable GENESIS;

    // The two burn pools are fixed here, not set after deployment: the launch factory makes no setup
    // calls, and nothing (owner included) may redirect the burn share to a pool whose hook could take
    // the ETH. The currencies come from the constructor; the rest of each key is the existing pool's.
    /// The game token's buyback pool: the existing ETH/token 1% pool, no hook.
    uint24 internal constant BURN_POOL_FEE = 10_000;
    int24 internal constant BURN_POOL_TICK_SPACING = 100;
    /// The host token's buyback pool: the ETH/$PFWA holder pool (dynamic fee, Hookr's holder hook).
    uint24 internal constant HOST_POOL_FEE = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
    int24 internal constant HOST_POOL_TICK_SPACING = 200;
    address internal constant HOST_POOL_HOOK = 0xb914f955294799de4b891bd2EA8AF628Fa1c68CC;

    address public owner;
    /// @notice Who `owner` named to take over; becomes owner on acceptOwner (0 = no handover pending).
    address public pendingOwner;
    address public operator; // runs buybacks and Dice refunds
    PoolId public poolId; // the one ETH/token pool this hook serves

    // ── Game state ──────────────────────────────────────────────────────────────
    mapping(uint256 round => mapping(address player => int256)) public points; // can go negative
    mapping(uint256 round => address[]) internal _players;
    mapping(uint256 round => mapping(address player => bool)) internal _joined;
    mapping(uint256 round => uint256) public pot;
    mapping(uint256 round => address) public lastPlayer;
    mapping(uint256 round => address) internal _leader;
    mapping(uint256 round => bool) internal _leaderStale;
    mapping(uint256 round => uint256) internal _scanCursor; // players rescanned so far while _leaderStale
    mapping(uint256 round => address[RECENT]) internal _recent;
    mapping(uint256 round => uint256) internal _recentCount;

    struct PendingFlip {
        address player;
        address previous;
        uint64 round;
        uint64 requestedAt;
        uint96 stake; // points riding on the flip
        uint96 win; // points a win pays: the stake times a multiplier set by the buy size
    }

    mapping(uint64 sequence => PendingFlip) public flips;
    mapping(uint256 round => uint256) public pendingFlips; // requested that round, not yet revealed or expired

    // ── Shields and move charges ────────────────────────────────────────────────
    struct ShieldStats {
        uint128 played; // ETH played this round (buys of MIN_BUY or more, any move)
        uint64 used; // charges spent this round
        bool charge; // holding an unused charge
    }

    /// @notice Per round and player: ETH played, shield charges spent, and whether a charge is held.
    mapping(uint256 round => mapping(address player => ShieldStats)) public shieldStats;
    /// @notice When `player`'s shield drops (0 or past = no shield). Across rounds: a shield raised
    /// near the end of a round still covers the start of the next.
    mapping(address player => uint256) public shieldUntil;
    // Charge clocks (see _charges): charges banked = (now - clock) / recharge, capped.
    mapping(address player => uint256) internal _stealClock;
    mapping(address player => uint256) internal _robinClock;
    mapping(address player => uint256) internal _flipClock;

    // ── Reign (time at #1, for the King of the Hill) ────────────────────────────
    struct Reign {
        address holder; // the current #1 (0 = nobody above zero)
        uint64 since; // when their current reign started counting
    }

    mapping(uint256 round => Reign) internal _reign;
    mapping(uint256 round => mapping(address player => uint256)) internal _reignSeconds; // finalized

    // ── Settlement ──────────────────────────────────────────────────────────────
    // Prize slots 0-2 are the top three, slot 3 is the King of the Hill.
    struct Result {
        bool settled;
        uint64 cursor; // players scanned so far (settlement can run in batches)
        address[3] top;
        int256[3] topPoints;
        address king;
        uint64 kingReign; // seconds at #1
        uint256[4] prize;
        bool[4] claimed; // claimed, or swept back into a pot
        bool swept;
        uint64 settledAt;
        uint256[4] held; // tokens each winner must still hold to claim (what they held at settlement)
    }

    mapping(uint256 round => Result) internal _results;
    uint256 public buybackReserve;
    uint256 public hostBuybackReserve;

    // ── Events ──────────────────────────────────────────────────────────────────
    event Played(
        uint256 indexed round,
        address indexed player,
        Move move,
        uint256 ethIn,
        uint256 pointsScored,
        address indexed target,
        uint256 pointsMoved
    );
    event FlipRequested(uint64 indexed sequence, uint256 indexed round, address indexed player, uint256 stake);
    event FlipResolved(uint64 indexed sequence, address indexed player, bool won, address paidTo, uint256 points);
    event PointsWiped(uint256 indexed round, address indexed player, uint256 points);
    event PotFunded(uint256 indexed round, uint256 amount, bool fromSell);
    event PotSeeded(uint256 indexed round, address indexed from, uint256 amount);
    /// @notice `prize` is #1, #2, #3, then the King of the Hill. `buyback` and `hostBuyback` went to the
    /// two burn reserves.
    event RoundSettled(
        uint256 indexed round,
        address[3] top,
        address king,
        uint256[4] prize,
        uint256 buyback,
        uint256 rollover,
        uint256 hostBuyback
    );
    event PrizeClaimed(uint256 indexed round, address indexed player, uint256 amount);
    event PrizeForfeited(uint256 indexed round, address indexed player, uint256 amount);
    event ReferrerSet(address indexed player, address indexed referrer);
    event ReferralPoints(uint256 indexed round, address indexed referrer, address indexed player, uint256 points);
    event ReferralPrize(uint256 indexed round, address indexed referrer, address indexed player, uint256 amount);
    event ReferralClaimed(address indexed referrer, uint256 amount);
    event UnclaimedSwept(uint256 indexed round, uint256 amount);
    event BuybackBurned(uint256 ethIn, uint256 tokenBurned);
    event HostBuybackBurned(uint256 ethIn, uint256 hostBurned);
    event OwnerChanged(address owner);
    /// @notice `owner` named `pendingOwner` to take over (0 = a pending handover was cancelled).
    event OwnerProposed(address pendingOwner);
    event OperatorChanged(address operator);
    /// @notice A SHIELD move spent a charge: `player` is shielded until `until`.
    event ShieldArmed(uint256 indexed round, address indexed player, uint256 until);
    /// @notice A Steal or Robin Hood hit a shield: `attacker` paid `points` to `defender` and the shield broke.
    event Reflected(
        uint256 indexed round, address indexed attacker, address indexed defender, uint256 points, Move move
    );
    /// @notice #1 changed hands (`newHolder` 0 = nobody above zero); the new reign counts from `at`.
    event ReignChanged(uint256 indexed round, address indexed newHolder, uint256 at);

    error NotPoolManager();
    error NotOwner();
    error NotOperator();
    error NotDice();
    error HookNotImplemented();
    error WrongPool();
    error PoolAlreadySet();
    error ExactOutputNotSupported();
    error PartialFill();
    error FlipsPending();
    error RoundNotOver();
    error RoundPassed();
    error MustHoldToClaim();
    error Reentered();
    error AlreadySettled();
    error NotSettled();
    error NothingToClaim();
    error ClaimWindowOpen();
    error ClaimWindowClosed();
    error FlipNotExpired();
    error TooLittleOut();
    error TransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// Guards the functions that move prize ETH (claim, claimReferral, sweepUnclaimed) against each other.
    modifier nonReentrant() {
        if (_lock(1) != 0) revert Reentered();
        _;
        _lock(0);
    }

    /// Sets the transient lock to `next` and returns what it was.
    function _lock(uint256 next) internal returns (uint256 was) {
        assembly ("memory-safe") {
            was := tload(0)
            tstore(0, next)
        }
    }

    constructor(
        IPoolManager _poolManager,
        Currency _token,
        Currency _host,
        uint256 _hostHolderMin,
        IDiceEntropy _dice,
        address _diceProvider,
        address _owner,
        uint256 _genesis
    ) {
        poolManager = _poolManager;
        token = _token;
        host = _host;
        hostHolderMin = _hostHolderMin;
        hostEnabled = Currency.unwrap(_host) != Currency.unwrap(_token);
        dice = _dice;
        diceProvider = _diceProvider;
        owner = _owner;
        operator = _owner;
        GENESIS = _genesis;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// ETH from the PoolManager (fees taken) and Dice (refunds) is accounted where it's received.
    /// Anything else sent straight here goes into the current round's pot instead of getting stuck.
    receive() external payable {
        if (msg.sender == address(dice)) buybackReserve += msg.value; // a refunded flip fee
        else if (msg.sender != address(poolManager)) _seed(currentRound(), msg.value);
    }

    /// Anyone can add ETH to the current round's pot or a future round's (within MAX_SEED_AHEAD rounds,
    /// so the ETH can always be settled out), e.g. to seed launch week.
    function fundPot(uint256 round) external payable {
        uint256 current = currentRound();
        if (round < current || round > current + MAX_SEED_AHEAD) revert RoundPassed();
        _seed(round, msg.value);
    }

    function _seed(uint256 round, uint256 amount) internal {
        pot[round] += amount;
        emit PotSeeded(round, msg.sender, amount);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice The round being played now (0 before GENESIS too).
    function currentRound() public view returns (uint256) {
        return block.timestamp < GENESIS ? 0 : (block.timestamp - GENESIS) / ROUND_LENGTH;
    }

    /// @notice When round `round` starts.
    function roundStart(uint256 round) public view returns (uint256) {
        return GENESIS + round * ROUND_LENGTH;
    }

    /// @notice When round `round` ends (and the next starts). It can be settled SETTLE_DELAY later.
    function roundEnd(uint256 round) public view returns (uint256) {
        return GENESIS + (round + 1) * ROUND_LENGTH;
    }

    // ── Hook callbacks ──────────────────────────────────────────────────────────

    /// One pool only: native ETH / token with this hook, created by the owner. Anyone can trade in
    /// it; only creating it is restricted, so nobody can claim the hook between deploy and setup.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != owner) revert NotOwner();
        if (PoolId.unwrap(poolId) != bytes32(0)) revert PoolAlreadySet();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != Currency.unwrap(token)) {
            revert WrongPool();
        }
        poolId = key.toId();
        return IHooks.beforeInitialize.selector;
    }

    /// Buys (ETH in): take the pot fee from the ETH paid in, then play the move (from GENESIS on).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();
        if (!params.zeroForOne) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 ethIn = uint256(-params.amountSpecified);
        uint256 fee = (ethIn * FEE_BPS) / 10_000;
        uint256 round = currentRound();
        if (fee > 0) {
            poolManager.take(key.currency0, address(this), fee);
            pot[round] += fee;
            emit PotFunded(round, fee, false);
        }
        if (ethIn >= MIN_BUY && block.timestamp >= GENESIS) _play(round, tx.origin, ethIn, hookData);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// Sells (tokens in): take the pot fee from the ETH paid out and wipe the seller's points.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (params.zeroForOne) {
            // A buy is scored in beforeSwap on the ETH it declares, so it must spend all of it: a
            // price limit that stops the swap early would score points for ETH never swapped.
            uint256 declared = uint256(-params.amountSpecified);
            if (uint256(int256(-delta.amount0())) + (declared * FEE_BPS) / 10_000 < declared) revert PartialFill();
            int128 tokenOut = delta.amount1();
            // Buys before GENESIS score nothing, so they aren't tracked either (no holding rules on them).
            if (tokenOut > 0 && declared >= MIN_BUY && block.timestamp >= GENESIS) {
                bought[currentRound()][tx.origin] += uint256(int256(tokenOut));
            }
            return (IHooks.afterSwap.selector, 0);
        }
        int128 ethOut = delta.amount0();
        uint256 round = currentRound();
        uint256 fee;
        if (ethOut > 0) {
            fee = (uint256(int256(ethOut)) * FEE_BPS) / 10_000;
            if (fee > 0) {
                poolManager.take(key.currency0, address(this), fee);
                pot[round] += fee;
                emit PotFunded(round, fee, true);
            }
        }
        int256 had = points[round][tx.origin];
        if (had > 0) {
            _resumeScan(round);
            _debit(round, tx.origin, uint256(had));
            emit PointsWiped(round, tx.origin, uint256(had));
            _updateReign(round);
        }
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ── Moves ───────────────────────────────────────────────────────────────────

    function _play(uint256 round, address player, uint256 ethIn, bytes calldata hookData) internal {
        _resumeScan(round);
        uint256 base = ethIn / POINT_UNIT;
        if (base > MAX_POINTS_PER_BUY) base = MAX_POINTS_PER_BUY;
        // This swap's tokens haven't reached the player yet, so the balance is what they already held.
        Move move = hookData.length >= 32 ? _decodeMove(hookData) : Move.BUY;
        if (firstRoundPlus1[player] == 0) {
            firstRoundPlus1[player] = round + 1;
            if (hookData.length >= 64) {
                // Decoded as a word so a referrer that isn't a clean address is ignored, not a revert.
                (, uint256 word) = abi.decode(hookData, (uint256, uint256));
                address referrer = word >> 160 == 0 ? address(uint160(word)) : address(0);
                if (referrer != address(0) && referrer != player && referrerOf[referrer] != player) {
                    referrerOf[player] = referrer;
                    emit ReferrerSet(player, referrer);
                }
            }
        }
        move = _limit(round, player, ethIn, move);
        uint256 bonusBps = 10_000;
        if (holderBonusActive(round, player)) bonusBps += HOLDER_BONUS_BPS - 10_000;
        if (welcomeBonusActive(round, player)) bonusBps += WELCOME_BONUS_BPS;
        if (hostBonusActive(player)) bonusBps += HOST_BONUS_BPS - 10_000;
        uint256 scored = (base * bonusBps) / 10_000;
        address previous = lastPlayer[round];
        address target;
        uint256 moved;

        if (move == Move.FLIP && _requestFlip(round, player, previous, scored, base, ethIn)) {
            // Points are credited when Dice reveals the flip.
            emit Played(round, player, move, ethIn, 0, previous, 0);
        } else {
            if (move == Move.FLIP) move = Move.BUY; // pot couldn't cover the Dice fee
            _credit(round, player, scored);
            if (move == Move.STEAL && previous != address(0) && previous != player) {
                target = previous;
                _stealClock[player] = _spend(_stealClock[player], STEAL_RECHARGE, STEAL_MAX_CHARGES);
                moved = (_positive(round, previous) * scaledBps(STEAL_BPS_MIN, STEAL_BPS_MAX, base)) / 10_000;
                if (shieldActive(previous)) {
                    _reflect(round, player, previous, moved, move);
                    moved = 0;
                } else if (moved > 0) {
                    _debit(round, previous, moved);
                    _credit(round, player, moved);
                }
            } else if (move == Move.ROBIN_HOOD) {
                address leader = _currentLeader(round);
                if (uint160(leader) > uint160(UNKNOWN_REIGN) && leader != player) {
                    target = _lowestRecent(round, leader);
                    if (target != address(0)) {
                        _robinClock[player] = _spend(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES);
                        moved = (_positive(round, leader) * scaledBps(ROBIN_BPS_MIN, ROBIN_BPS_MAX, base)) / 10_000;
                        if (shieldActive(leader)) {
                            // The cut goes back to the leader, out of the robber's points.
                            _reflect(round, player, leader, moved, move);
                            (target, moved) = (leader, 0);
                        } else if (moved > 0) {
                            _debit(round, leader, moved);
                            _credit(round, target, moved);
                        }
                    }
                }
            }
            emit Played(round, player, move, ethIn, scored, target, moved);
        }
        address ref = referrerOf[player];
        if (ref != address(0) && _joined[round][ref]) {
            uint256 bonus = (scored * REFERRAL_POINTS_BPS) / 10_000;
            if (bonus > 0) {
                _credit(round, ref, bonus);
                emit ReferralPoints(round, ref, player, bonus);
            }
        }
        lastPlayer[round] = player;
        _pushRecent(round, player);
        _updateReign(round);
    }

    /// Counts this play towards shield charges, then applies the move limits: a SHIELD without a
    /// charge, or a STEAL, ROBIN_HOOD or FLIP with no charge banked, plays as a BUY. A SHIELD with a charge spends it and raises (or refreshes) the shield.
    function _limit(uint256 round, address player, uint256 ethIn, Move move) internal returns (Move) {
        ShieldStats storage s = shieldStats[round][player];
        uint256 played = s.played;
        s.played = uint128(played + ethIn);
        // Crossing one or more SHIELD_CHARGE_ETH marks earns a charge; one is all a player can hold.
        if ((played + ethIn) / SHIELD_CHARGE_ETH > played / SHIELD_CHARGE_ETH) s.charge = true;
        if (move == Move.SHIELD) {
            if (!s.charge) return Move.BUY;
            s.charge = false;
            s.used += 1;
            uint256 until = block.timestamp + SHIELD_DURATION;
            shieldUntil[player] = until;
            emit ShieldArmed(round, player, until);
        } else if (move == Move.STEAL) {
            if (_charges(_stealClock[player], STEAL_RECHARGE, STEAL_MAX_CHARGES) == 0) return Move.BUY;
        } else if (move == Move.ROBIN_HOOD) {
            if (_charges(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES) == 0) return Move.BUY;
        } else if (move == Move.FLIP) {
            if (_charges(_flipClock[player], FLIP_RECHARGE, FLIP_MAX_CHARGES) == 0) return Move.BUY;
        }
        return move;
    }

    /// Charges banked on a clock: one per `recharge` since `clock`, at most `cap`. A clock of 0
    /// (never played the move) is a full bank. The clock never passes `block.timestamp`.
    function _charges(uint256 clock, uint256 recharge, uint256 cap) internal view returns (uint256) {
        uint256 n = (block.timestamp - clock) / recharge;
        return n < cap ? n : cap;
    }

    /// The clock after spending one charge: banked time beyond the cap is dropped first.
    function _spend(uint256 clock, uint256 recharge, uint256 cap) internal view returns (uint256) {
        uint256 full = block.timestamp - cap * recharge;
        return (clock > full ? clock : full) + recharge;
    }

    /// A Steal or Robin Hood that hit a shield: the attacker pays `amount` (all of what the move would
    /// have taken, so it can take them below zero like a lost flip) to the defender, and the shield
    /// breaks. A move that would have taken nothing reflects nothing and leaves the shield up.
    function _reflect(uint256 round, address attacker, address defender, uint256 amount, Move move) internal {
        if (amount == 0) return;
        delete shieldUntil[defender];
        _debit(round, attacker, amount);
        _credit(round, defender, amount);
        emit Reflected(round, attacker, defender, amount, move);
    }

    /// @notice True while `player`'s shield is up.
    function shieldActive(address player) public view returns (bool) {
        return block.timestamp < shieldUntil[player];
    }

    /// True in a referred player's first round.
    function welcomeBonusActive(uint256 round, address player) public view returns (bool) {
        return referrerOf[player] != address(0) && firstRoundPlus1[player] == round + 1;
    }

    /// True when `player` played last round and still holds everything they bought here then.
    function holderBonusActive(uint256 round, address player) public view returns (bool) {
        if (round == 0) return false;
        uint256 held = bought[round - 1][player];
        return held > 0 && IBalanceOf(Currency.unwrap(token)).balanceOf(player) >= held;
    }

    /// @notice True when `player` holds at least hostHolderMin of the host token right now (never
    /// in the host token's own game).
    function hostBonusActive(address player) public view returns (bool) {
        return hostEnabled && IBalanceOf(Currency.unwrap(host)).balanceOf(player) >= hostHolderMin;
    }

    /// The share a move with `scored` points gets: `min` scaled linearly up to `max` at a full-size buy.
    function scaledBps(uint256 min, uint256 max, uint256 scored) public pure returns (uint256) {
        if (scored > MAX_POINTS_PER_BUY) scored = MAX_POINTS_PER_BUY;
        return min + ((max - min) * scored) / MAX_POINTS_PER_BUY;
    }

    function _decodeMove(bytes calldata hookData) internal pure returns (Move) {
        uint256 raw = abi.decode(hookData, (uint256));
        return raw <= uint256(Move.SHIELD) ? Move(raw) : Move.BUY;
    }

    /// Pays the Dice fee out of the round's pot and records the pending flip. False if the pot can't
    /// cover it or Dice can't take the request (paused, out of randomness, ...): the move then
    /// scores as a plain buy, so a Dice outage never blocks a swap (and doesn't use up a flip).
    function _requestFlip(uint256 round, address player, address previous, uint256 stake, uint256 base, uint256 ethIn)
        internal
        returns (bool)
    {
        uint256 diceFee;
        try dice.getFeeV2(diceProvider, FLIP_CALLBACK_GAS) returns (uint128 fee) {
            diceFee = fee;
        } catch {
            return false;
        }
        // A flip never costs the pot more than its buy paid in: above that (or MAX_DICE_FEE) it scores as a buy.
        if (diceFee > MAX_DICE_FEE || diceFee > (ethIn * FEE_BPS) / 10_000 || pot[round] < diceFee) return false;
        bytes32 userRandom = keccak256(abi.encode(player, ethIn, block.number, block.timestamp, gasleft()));
        uint64 sequence;
        try dice.requestV2{value: diceFee}(diceProvider, userRandom, FLIP_CALLBACK_GAS) returns (uint64 seq) {
            sequence = seq;
        } catch {
            return false;
        }
        pot[round] -= diceFee;
        flips[sequence] = PendingFlip({
            player: player,
            previous: previous == player ? address(0) : previous,
            round: uint64(round),
            requestedAt: uint64(block.timestamp),
            stake: uint96(stake),
            win: uint96((stake * scaledBps(FLIP_WIN_BPS_MIN, FLIP_WIN_BPS_MAX, base)) / 10_000)
        });
        pendingFlips[round] += 1;
        _flipClock[player] = _spend(_flipClock[player], FLIP_RECHARGE, FLIP_MAX_CHARGES);
        _join(round, player);
        emit FlipRequested(sequence, round, player, stake);
        return true;
    }

    /// Dice calls this with the revealed random number. Must not revert.
    function _entropyCallback(uint64 sequence, address, bytes32 randomNumber) external {
        if (msg.sender != address(dice)) revert NotDice();
        PendingFlip memory f = flips[sequence];
        if (f.player == address(0)) return; // already expired or unknown
        delete flips[sequence];
        pendingFlips[f.round] -= 1;
        if (_results[f.round].settled) return; // revealed after its round was settled
        bool won = uint256(randomNumber) % 2 == 0;
        address paidTo = won ? f.player : f.previous;
        uint256 amount = won ? f.win : f.stake;
        if (!won) _debit(f.round, f.player, f.stake); // can go below zero
        if (paidTo != address(0)) _credit(f.round, paidTo, amount);
        // A loss by #1 leaves the cached leader stale. Rescanning a board bigger than
        // MAX_CALLBACK_SCAN here would run past FLIP_CALLBACK_GAS (Dice then drops the reveal), so
        // the current reign is closed now and #1 is unknown: the next play, expiry or sell rescans
        // with its caller's gas and starts the new reign from then.
        if (_leaderStale[f.round] && _players[f.round].length > MAX_CALLBACK_SCAN) _setReign(f.round, UNKNOWN_REIGN);
        else _updateReign(f.round);
        emit FlipResolved(sequence, f.player, won, paidTo, amount);
    }

    /// A flip Dice never revealed scores as a plain buy after FLIP_TIMEOUT. Anyone can call this.
    function expireFlip(uint64 sequence) external {
        PendingFlip memory f = flips[sequence];
        if (f.player == address(0) || block.timestamp < f.requestedAt + FLIP_TIMEOUT) revert FlipNotExpired();
        delete flips[sequence];
        pendingFlips[f.round] -= 1;
        if (!_results[f.round].settled) {
            _resumeScan(f.round);
            _credit(f.round, f.player, f.stake);
            _updateReign(f.round);
        }
        emit FlipResolved(sequence, f.player, true, f.player, f.stake);
    }

    // ── Points bookkeeping ──────────────────────────────────────────────────────

    function _join(uint256 round, address player) internal {
        if (!_joined[round][player]) {
            _joined[round][player] = true;
            _players[round].push(player);
        }
    }

    function _credit(uint256 round, address player, uint256 amount) internal {
        _join(round, player);
        int256 updated = points[round][player] + int256(amount);
        points[round][player] = updated;
        // Even while the cached leader is stale (debited), anyone credited above them takes over: on
        // a round too big to rescan this keeps the cache moving instead of frozen until it ends.
        address leader = _leader[round];
        if (leader == address(0) || updated > points[round][leader]) _leader[round] = player;
    }

    function _debit(uint256 round, address player, uint256 amount) internal {
        _join(round, player);
        points[round][player] -= int256(amount);
        if (player == _leader[round]) {
            // The cached #1 (or the best found so far by a rescan in progress) lost points: rescan from the start.
            _leaderStale[round] = true;
            _scanCursor[round] = 0;
        }
    }

    /// The round's leader, rescanning the board if the cached one lost points. A board above
    /// MAX_LEADER_SCAN is left to the next transactions (_resumeScan): #1 is unknown until then.
    function _currentLeader(uint256 round) internal returns (address) {
        if (!_leaderStale[round]) return _leader[round];
        if (_players[round].length > MAX_LEADER_SCAN) return UNKNOWN_REIGN;
        return _scan(round, true);
    }

    /// Called first by every play, sell and flip expiry, before it changes any points: carries on a
    /// rescan an earlier transaction left unfinished. Nothing changed since the last point change, so
    /// the #1 it finds has held #1 since then; _setReign credits them from then.
    function _resumeScan(uint256 round) internal {
        // #1 is unknown whenever the cache is stale between transactions, so an unfinished rescan just
        // restarts the unknown spell here, as the end of this transaction will anyway.
        if (_leaderStale[round]) _setReign(round, _scan(round, _players[round].length <= MAX_LEADER_SCAN));
    }

    /// Rescans the board from the saved cursor, comparing every player against the cache (which
    /// _credit keeps at the best seen so far). `all` scans to the end; otherwise it covers at least
    /// LEADER_SCAN_CHUNK players, then goes on while LEADER_SCAN_RESERVE gas is left to spare, and if
    /// the board isn't done saves its cursor and reports #1 as unknown.
    function _scan(uint256 round, bool all) internal returns (address leader) {
        leader = _leader[round];
        address[] storage players = _players[round];
        uint256 n = players.length;
        uint256 i = _scanCursor[round];
        uint256 atLeast = all ? n : i + LEADER_SCAN_CHUNK;
        int256 best = points[round][leader];
        for (; i < n; ++i) {
            if (i >= atLeast && gasleft() < LEADER_SCAN_RESERVE) break;
            address a = players[i];
            int256 p = points[round][a];
            if (p > best) (best, leader) = (p, a);
        }
        if (i < n) {
            _scanCursor[round] = i;
            _leader[round] = leader;
            return UNKNOWN_REIGN;
        }
        if (best <= 0) leader = address(0); // nobody above zero
        _leader[round] = leader;
        _leaderStale[round] = false;
    }

    /// Called once at the end of anything that changes points. If #1 changed hands, closes the old
    /// holder's reign (up to the round's end at most) and starts the new one. Point changes inside
    /// one transaction all share a timestamp, so checking once at the end counts the same seconds.
    function _updateReign(uint256 round) internal {
        _setReign(round, _currentLeader(round));
    }

    /// Makes `leader` the reign holder (0 = nobody, UNKNOWN_REIGN = unknown), closing the previous
    /// holder's reign. While #1 is unknown every point change restarts the unknown spell, so when a
    /// rescan resolves it the #1 found has held #1 for the whole spell and is credited from its start.
    function _setReign(uint256 round, address leader) internal {
        if (uint160(leader) > uint160(UNKNOWN_REIGN) && points[round][leader] <= 0) leader = address(0); // #1 must be above zero
        Reign storage g = _reign[round];
        address holder = g.holder;
        uint256 at = _reignClock(round);
        if (holder == UNKNOWN_REIGN) {
            if (leader == UNKNOWN_REIGN) {
                g.since = uint64(at); // points changed: the spell starts over
                return;
            }
            at = g.since; // resolved: credited back to the spell's start
        } else {
            if (leader == holder) return;
            if (holder != address(0)) _reignSeconds[round][holder] += at - g.since;
        }
        g.holder = leader;
        g.since = uint64(at);
        emit ReignChanged(round, leader, at);
    }

    /// Now, capped at the round's end: reigns stop counting when the round does.
    function _reignClock(uint256 round) internal view returns (uint256) {
        uint256 end = roundEnd(round);
        return block.timestamp < end ? block.timestamp : end;
    }

    /// A player's points if above zero, else 0: what Steal and Robin Hood can take.
    function _positive(uint256 round, address player) internal view returns (uint256) {
        int256 p = points[round][player];
        return p > 0 ? uint256(p) : 0;
    }

    function _pushRecent(uint256 round, address player) internal {
        uint256 count = _recentCount[round];
        _recent[round][count % RECENT] = player;
        _recentCount[round] = count + 1;
    }

    /// The lowest-scoring of the last 10 players, other than the leader. That can be the player
    /// making the move: Robin Hood for yourself is allowed, so moves can be chained.
    function _lowestRecent(uint256 round, address leader) internal view returns (address lowest) {
        uint256 count = _recentCount[round];
        uint256 n = count < RECENT ? count : RECENT;
        int256 low = type(int256).max;
        for (uint256 i; i < n; ++i) {
            address a = _recent[round][i];
            if (a == leader) continue;
            int256 p = points[round][a];
            if (p < low) (low, lowest) = (p, a);
        }
    }

    /// Whether `a` (with `sa` seconds at #1) is ahead of `b` (with `sb`) for King: more seconds,
    /// then more points; a full tie keeps `b`, the one found first. Nobody with 0 seconds qualifies.
    function _outreigns(uint256 round, address a, uint256 sa, address b, uint256 sb) internal view returns (bool) {
        return sa > sb || (sa == sb && sa > 0 && points[round][a] > points[round][b]);
    }

    // ── Settlement and prizes ───────────────────────────────────────────────────

    /// Ranks a finished round, picks its King of the Hill and splits its pot. Big rounds can be
    /// settled in batches of `maxPlayers`. Winners then claim their prizes.
    function settle(uint256 round, uint256 maxPlayers) external returns (bool done) {
        if (block.timestamp < roundEnd(round) + SETTLE_DELAY) revert RoundNotOver();
        Result storage r = _results[round];
        if (r.settled) revert AlreadySettled();
        // A reveal between batches would change scores already ranked. Every flip of a finished round
        // can be expired by the time settlement opens (FLIP_TIMEOUT < SETTLE_DELAY).
        if (pendingFlips[round] > 0) revert FlipsPending();

        // Close the last reign at the round's end (adds nothing on later batches).
        Reign storage g = _reign[round];
        if (uint160(g.holder) > uint160(UNKNOWN_REIGN)) {
            uint256 end = roundEnd(round);
            _reignSeconds[round][g.holder] += end - g.since;
            g.since = uint64(end);
        }

        address[] storage players = _players[round];
        uint256 end_ = players.length;
        if (end_ - r.cursor > maxPlayers) end_ = r.cursor + maxPlayers; // (type(uint256).max = all remaining)
        address king = r.king;
        uint256 kingReign = r.kingReign;
        for (uint256 i = r.cursor; i < end_; ++i) {
            address a = players[i];
            uint256 s = _reignSeconds[round][a];
            if (_outreigns(round, a, s, king, kingReign)) (king, kingReign) = (a, s);
            int256 p = points[round][a];
            if (p <= 0) continue; // only players above zero can place
            if (p > r.topPoints[0]) {
                (r.top[2], r.topPoints[2]) = (r.top[1], r.topPoints[1]);
                (r.top[1], r.topPoints[1]) = (r.top[0], r.topPoints[0]);
                (r.top[0], r.topPoints[0]) = (a, p);
            } else if (p > r.topPoints[1]) {
                (r.top[2], r.topPoints[2]) = (r.top[1], r.topPoints[1]);
                (r.top[1], r.topPoints[1]) = (a, p);
            } else if (p > r.topPoints[2]) {
                (r.top[2], r.topPoints[2]) = (a, p);
            }
        }
        r.cursor = uint64(end_);
        // #1 still unknown at the end (a rescan never ran after the last point change): nothing changed
        // since the spell began, so the final #1 held #1 for all of it, as a finished rescan would credit.
        if (end_ == players.length && g.holder == UNKNOWN_REIGN) {
            address top = r.top[0];
            uint256 end = roundEnd(round);
            if (top != address(0)) {
                uint256 s = _reignSeconds[round][top] += end - g.since;
                if (_outreigns(round, top, s, king, kingReign)) (king, kingReign) = (top, s);
            }
            (g.holder, g.since) = (top, uint64(end));
        }
        (r.king, r.kingReign) = (king, uint64(kingReign));
        if (end_ < players.length) return false;

        uint256 total = pot[round];
        uint256[4] memory shares = [
            (total * FIRST_BPS) / 10_000,
            (total * SECOND_BPS) / 10_000,
            (total * THIRD_BPS) / 10_000,
            (total * KING_BPS) / 10_000
        ];
        uint256 buyback = (total * BURN_BPS) / 10_000;
        uint256 hostBuyback = (total * HOST_BURN_BPS) / 10_000;
        if (!hostEnabled) (buyback, hostBuyback) = (buyback + hostBuyback, 0); // the host's own game: one burn
        uint256 awarded;
        for (uint256 i; i < 4; ++i) {
            address winner = _winner(r, i);
            if (winner == address(0)) continue; // no King (nobody ever above zero): its share rolls over
            // Sold part of that round's buys (in any pool) by settlement: the same share of the
            // prize rolls into the current pot. Sold 20%, lose 20%.
            uint256 prize = shares[i];
            uint256 owed = bought[round][winner];
            uint256 balance = IBalanceOf(Currency.unwrap(token)).balanceOf(winner);
            if (balance < owed) {
                uint256 kept = (prize * balance) / owed;
                emit PrizeForfeited(round, winner, prize - kept);
                prize = kept;
                owed = balance;
            }
            if (prize == 0) continue;
            r.prize[i] = prize;
            r.held[i] = owed;
            awarded += prize;
            // The referrer's share comes out of the rollover, not the prize: 5% of each prize is at
            // most 3.9% of the pot (all four referred), inside the rollover's 5%.
            address ref = referrerOf[winner];
            if (ref != address(0) && _joined[round][ref]) {
                uint256 cut = (prize * REFERRAL_PRIZE_BPS) / 10_000;
                referralEarnings[ref] += cut;
                awarded += cut;
                emit ReferralPrize(round, ref, winner, cut);
            }
        }
        uint256 rollover = total - awarded - buyback - hostBuyback;
        r.settled = true;
        r.settledAt = uint64(block.timestamp);
        buybackReserve += buyback;
        hostBuybackReserve += hostBuyback;
        if (rollover > 0) pot[currentRound()] += rollover;
        emit RoundSettled(round, r.top, r.king, r.prize, buyback, rollover, hostBuyback);
        return true;
    }

    /// Prize slot `i`: 0-2 the top three, 3 the King of the Hill.
    function _winner(Result storage r, uint256 i) internal view returns (address) {
        return i < 3 ? r.top[i] : r.king;
    }

    /// Pays `msg.sender` everything they won in `round` (rank and King of the Hill together).
    function claim(uint256 round) external nonReentrant {
        Result storage r = _results[round];
        if (!r.settled) revert NotSettled();
        if (block.timestamp > claimDeadline(round)) revert ClaimWindowClosed();
        uint256 amount;
        uint256 balance = IBalanceOf(Currency.unwrap(token)).balanceOf(msg.sender);
        for (uint256 i; i < 4; ++i) {
            if (_winner(r, i) == msg.sender && !r.claimed[i] && r.prize[i] > 0) {
                // Winners keep what they held at settlement until they claim. Sold more since, in
                // this pool or anywhere else? The prize stays put and goes back to a pot after the
                // claim window, unless they buy it back first.
                if (balance < r.held[i]) revert MustHoldToClaim();
                r.claimed[i] = true;
                amount += r.prize[i];
            }
        }
        if (amount == 0) revert NothingToClaim();
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit PrizeClaimed(round, msg.sender, amount);
    }

    /// Winners have CLAIM_WINDOW from the end of the round, or from settlement if that came later.
    function claimDeadline(uint256 round) public view returns (uint256) {
        uint256 end = roundEnd(round);
        uint256 settledAt = _results[round].settledAt;
        return (settledAt > end ? settledAt : end) + CLAIM_WINDOW;
    }

    /// Referrers withdraw their prize shares any time.
    function claimReferral() external nonReentrant {
        uint256 amount = referralEarnings[msg.sender];
        if (amount == 0) revert NothingToClaim();
        referralEarnings[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ReferralClaimed(msg.sender, amount);
    }

    /// Prizes left unclaimed after the claim window go back into the current round's pot.
    function sweepUnclaimed(uint256 round) external nonReentrant {
        Result storage r = _results[round];
        if (!r.settled || r.swept) revert NotSettled();
        if (block.timestamp <= claimDeadline(round)) revert ClaimWindowOpen();
        r.swept = true;
        uint256 amount;
        for (uint256 i; i < 4; ++i) {
            if (!r.claimed[i] && r.prize[i] > 0) {
                r.claimed[i] = true;
                amount += r.prize[i];
            }
        }
        pot[currentRound()] += amount;
        emit UnclaimedSwept(round, amount);
    }

    // ── Buyback and burn ────────────────────────────────────────────────────────

    /// Swaps `amount` of the buyback reserve for the game token in the buyback pool and burns it.
    function buybackAndBurn(uint256 amount, uint256 minTokenOut) external {
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        if (amount > buybackReserve) amount = buybackReserve;
        buybackReserve -= amount;
        bytes memory result_ = poolManager.unlock(abi.encode(false, amount, minTokenOut));
        uint256 burned = abi.decode(result_, (uint256));
        emit BuybackBurned(amount, burned);
    }

    /// Swaps `amount` of the host buyback reserve for the host token in the host buyback pool and burns it.
    function buybackAndBurnHost(uint256 amount, uint256 minHostOut) external {
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        if (amount > hostBuybackReserve) amount = hostBuybackReserve;
        hostBuybackReserve -= amount;
        bytes memory result_ = poolManager.unlock(abi.encode(true, amount, minHostOut));
        uint256 burned = abi.decode(result_, (uint256));
        emit HostBuybackBurned(amount, burned);
    }

    /// Both burns: `isHost` picks the pool, and the reserve a partial fill goes back to.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (bool isHost, uint256 amount, uint256 minOut) = abi.decode(data, (bool, uint256, uint256));
        PoolKey memory key = isHost ? hostBuybackPool() : buybackPool();
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 ethPaid = uint256(int256(-delta.amount0()));
        uint256 out = uint256(int256(delta.amount1()));
        if (out < minOut) revert TooLittleOut();
        poolManager.settle{value: ethPaid}();
        poolManager.take(key.currency1, DEAD, out);
        if (ethPaid < amount) {
            // a partial fill keeps the rest
            if (isHost) hostBuybackReserve += amount - ethPaid;
            else buybackReserve += amount - ethPaid;
        }
        return abi.encode(out);
    }

    /// Reclaims the fee of a Dice request that was never revealed (after Dice's refund delay) into the buyback reserve.
    function refundDiceRequest(uint64 sequence) external {
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        dice.refundRequest(diceProvider, sequence); // the refund arrives through receive()
    }

    /// @notice Where the buyback share is swapped for the game token and burned: the existing ETH/token
    /// 1% pool, no hook. In the host token's own game that is the holder pool (hostBuybackPool).
    function buybackPool() public view returns (PoolKey memory) {
        if (!hostEnabled) return hostBuybackPool();
        return PoolKey(Currency.wrap(address(0)), token, BURN_POOL_FEE, BURN_POOL_TICK_SPACING, IHooks(address(0)));
    }

    /// @notice Where the host buyback share is swapped for the host token and burned: the ETH/host
    /// holder pool, a dynamic-fee pool with Hookr's holder hook.
    function hostBuybackPool() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), host, HOST_POOL_FEE, HOST_POOL_TICK_SPACING, IHooks(HOST_POOL_HOOK));
    }

    // ── Admin: who owns the hook and who runs buybacks. Nothing else. ───────────

    /// Names the next owner, who takes over with acceptOwner. Nothing changes until they do, so a
    /// wrong address is harmless; naming address(0) cancels a pending handover.
    function setOwner(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnerProposed(next);
    }

    /// The named next owner takes over.
    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = msg.sender;
        delete pendingOwner;
        emit OwnerChanged(msg.sender);
    }

    function setOperator(address next) external onlyOwner {
        operator = next;
        emit OperatorChanged(next);
    }

    // ── Views for the site ──────────────────────────────────────────────────────

    function playerCount(uint256 round) external view returns (uint256) {
        return _players[round].length;
    }

    function playersPage(uint256 round, uint256 start, uint256 count)
        external
        view
        returns (address[] memory players, int256[] memory pts)
    {
        address[] storage all = _players[round];
        uint256 end = start + count > all.length ? all.length : start + count;
        uint256 n = end > start ? end - start : 0;
        players = new address[](n);
        pts = new int256[](n);
        for (uint256 i; i < n; ++i) {
            players[i] = all[start + i];
            pts[i] = points[round][players[i]];
        }
    }

    function leader(uint256 round) external view returns (address) {
        return _leader[round];
    }

    /// The last (up to) 10 players of the round, most recent first: who Robin Hood can pay.
    function recentPlayers(uint256 round) external view returns (address[] memory players) {
        uint256 count = _recentCount[round];
        uint256 n = count < RECENT ? count : RECENT;
        players = new address[](n);
        for (uint256 i; i < n; ++i) {
            players[i] = _recent[round][(count - 1 - i) % RECENT];
        }
    }

    /// @notice A settled round's top three and King of the Hill: who, their points (seconds at #1 for
    /// the King), what they won after forfeits, and whether it has been claimed (or swept).
    function result(uint256 round)
        external
        view
        returns (
            bool settled,
            address[3] memory top,
            int256[3] memory topPoints,
            uint256[3] memory prize,
            bool[3] memory claimed,
            address king,
            uint256 kingReign,
            uint256 kingPrize,
            bool kingClaimed
        )
    {
        Result storage r = _results[round];
        for (uint256 i; i < 3; ++i) {
            prize[i] = r.prize[i];
            claimed[i] = r.claimed[i];
        }
        return (r.settled, r.top, r.topPoints, prize, claimed, r.king, r.kingReign, r.prize[3], r.claimed[3]);
    }

    /// @notice The tokens `player` must hold to claim their prizes for `round`: what they held at settlement.
    function heldToClaim(uint256 round, address player) external view returns (uint256) {
        Result storage r = _results[round];
        for (uint256 i; i < 4; ++i) {
            if (_winner(r, i) == player && r.prize[i] > 0) return r.held[i];
        }
        return 0;
    }

    /// @notice Whether `player` holds an unused shield charge this round (0 or 1).
    function shieldCharges(uint256 round, address player) external view returns (uint256) {
        return shieldStats[round][player].charge ? 1 : 0;
    }

    /// @notice STEAL charges `player` has banked now.
    function stealsLeft(address player) external view returns (uint256) {
        return _charges(_stealClock[player], STEAL_RECHARGE, STEAL_MAX_CHARGES);
    }

    /// @notice ROBIN_HOOD charges `player` has banked now.
    function robinsLeft(address player) external view returns (uint256) {
        return _charges(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES);
    }

    /// @notice FLIP charges `player` has banked now.
    function flipsLeft(address player) external view returns (uint256) {
        return _charges(_flipClock[player], FLIP_RECHARGE, FLIP_MAX_CHARGES);
    }

    /// @notice When `player`'s next charge of each move lands (0 = the bank is full):
    /// STEAL, ROBIN_HOOD, FLIP.
    function nextCharges(address player) external view returns (uint256 steal, uint256 robin, uint256 flip) {
        steal = _nextCharge(_stealClock[player], STEAL_RECHARGE, STEAL_MAX_CHARGES);
        robin = _nextCharge(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES);
        flip = _nextCharge(_flipClock[player], FLIP_RECHARGE, FLIP_MAX_CHARGES);
    }

    function _nextCharge(uint256 clock, uint256 recharge, uint256 cap) internal view returns (uint256) {
        uint256 n = (block.timestamp - clock) / recharge;
        return n >= cap ? 0 : clock + (n + 1) * recharge;
    }

    /// @notice Who holds #1 in `round` right now (0 = nobody above zero).
    function reignHolder(uint256 round) external view returns (address) {
        return _reign[round].holder;
    }

    /// @notice Seconds `player` has held #1 in `round`, including the current holder's running reign
    /// (which stops counting at the round's end).
    function reignOf(uint256 round, address player) public view returns (uint256 s) {
        s = _reignSeconds[round][player];
        Reign storage g = _reign[round];
        if (player != address(0) && player == g.holder) s += _reignClock(round) - g.since;
    }

    /// @notice The King of the Hill of `round`: final once settled, otherwise who would be if it
    /// ended now. Scans every player of an open round, so it's meant for off-chain calls.
    function kingOfTheHill(uint256 round) external view returns (address best) {
        Result storage r = _results[round];
        if (r.settled) return r.king;
        address[] storage players = _players[round];
        uint256 bestReign;
        for (uint256 i; i < players.length; ++i) {
            address a = players[i];
            uint256 s = reignOf(round, a);
            if (_outreigns(round, a, s, best, bestReign)) (best, bestReign) = (a, s);
        }
    }

    // ── Unused hook callbacks ───────────────────────────────────────────────────

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
