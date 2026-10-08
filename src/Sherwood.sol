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

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Dice Protocol randomness (a Pyth Entropy fork on Robinhood Chain).
interface IDiceEntropy {
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 assignedSequenceNumber);
    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint128 feeAmount);
    function refundRequest(address provider, uint64 sequenceNumber) external;
}

/// @title Sherwood
/// @notice A daily leaderboard game played with buys on an ETH/$PFWA Uniswap v4 pool.
///
/// Every exact-input swap pays 5% of its ETH side into the day's pot. Buys of at
/// least 0.001 ETH score 1 point per 0.001 ETH (up to 100 per buy), with one of
/// four moves picked on sherwood.pfwa.fun and passed as hook data:
///   BUY        your points.
///   STEAL      your points, plus 20% of the previous player's.
///   ROBIN_HOOD your points, and 10% of the leader's go to the lowest of the last 10 players.
///   FLIP       a Dice Protocol coin flip: win double this buy's points, or lose them to the
///              previous player. A loss comes off your total, so it can take you below zero.
/// Selling wipes the seller's points for the day if they're above zero (a negative score
/// stays). Steal and Robin Hood only take from players above zero. A swap with no hook
/// data is a BUY.
/// The player is the wallet that signed the transaction (tx.origin): hooks only see the router.
///
/// Days run 00:00 to 00:00 UTC. After a day ends anyone can settle it: 50/20/10% of
/// its pot go to the top three to claim within 7 days, 10% buys back and burns $PFWA
/// through the buyback pool, and 10% (plus any unawarded share) rolls into the current day.
contract Sherwood is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // ── Game constants ──────────────────────────────────────────────────────────
    uint256 public constant FEE_BPS = 500; // 5% of every swap's ETH side → pot
    uint256 public constant MIN_BUY = 0.001 ether;
    uint256 public constant POINT_UNIT = 0.001 ether;
    uint256 public constant MAX_POINTS_PER_BUY = 100;
    // Steal, Robin Hood and a flip win all grow with the buy, like points do: from the MIN share
    // at the smallest buy up to the MAX share at MAX_POINTS_PER_BUY.
    uint256 public constant STEAL_BPS_MIN = 2000; // 20% of the previous player's points...
    uint256 public constant STEAL_BPS_MAX = 4000; // ...up to 40%
    uint256 public constant ROBIN_BPS_MIN = 1000; // 10% of the leader's points...
    uint256 public constant ROBIN_BPS_MAX = 3300; // ...up to 33%
    uint256 public constant FLIP_WIN_BPS_MIN = 20_000; // a won flip pays 2x its points...
    uint256 public constant FLIP_WIN_BPS_MAX = 30_000; // ...up to 3x
    // Still holding all the $PFWA you bought here yesterday when you play today: +25% points.
    uint256 public constant HOLDER_BONUS_BPS = 12_500;
    // Referrals, only on days the referrer played too: 10% of each of their player's buys in bonus
    // points, and 5% of that player's prize from the rollover. Nothing is taken from the player.
    uint256 public constant REFERRAL_POINTS_BPS = 1000;
    uint256 public constant REFERRAL_PRIZE_BPS = 500;
    // A referred player's first day: +10% points.
    uint256 public constant WELCOME_BONUS_BPS = 1000;
    uint256 public constant RECENT = 10; // Robin Hood pays the lowest of the last 10 players
    uint256 public constant SETTLE_DELAY = 15 minutes; // lets flips from the last minutes resolve
    uint256 public constant CLAIM_WINDOW = 7 days;
    uint256 public constant FLIP_TIMEOUT = 10 minutes; // an unrevealed flip then scores as a plain buy
    uint32 public constant FLIP_CALLBACK_GAS = 200_000;
    uint256 public constant MAX_DICE_FEE = 0.0005 ether; // 20x Dice's fee at launch; above it a flip scores as a buy
    uint256 internal constant MAX_LEADER_SCAN = 1500; // bound on the leader rescan inside a swap
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    enum Move {
        BUY,
        STEAL,
        ROBIN_HOOD,
        FLIP
    }

    // ── Wiring ──────────────────────────────────────────────────────────────────
    /// $PFWA each player bought through this pool, per day. A winner keeps the share of the prize
    /// matching the share of that day's buys they still hold, and holding yesterday's buys earns
    /// the holder bonus today.
    mapping(uint256 day => mapping(address player => uint256)) public bought;

    /// Who referred each player. Set once, from the first play that names one, and never changed.
    mapping(address player => address) public referrerOf;
    /// The day of each player's first play, plus one (0 = never played). A referrer can only be
    /// named on that first play, and a referred player's welcome bonus lasts that day.
    mapping(address player => uint256) public firstDayPlus1;
    /// Referral prize shares waiting to be claimed.
    mapping(address referrer => uint256) public referralEarnings;

    IPoolManager public immutable poolManager;
    Currency public immutable pfwa;
    IDiceEntropy public immutable dice;
    address public immutable diceProvider;

    address public owner;
    address public operator; // runs buybacks and Dice refunds
    PoolId public poolId; // the one ETH/$PFWA pool this hook serves
    PoolKey public buybackPool; // where the buyback share is swapped for $PFWA (another ETH/$PFWA pool)

    // ── Game state ──────────────────────────────────────────────────────────────
    mapping(uint256 day => mapping(address player => int256)) public points; // can go negative
    mapping(uint256 day => address[]) internal _players;
    mapping(uint256 day => mapping(address player => bool)) internal _joined;
    mapping(uint256 day => uint256) public pot;
    mapping(uint256 day => address) public lastPlayer;
    mapping(uint256 day => address) internal _leader;
    mapping(uint256 day => bool) internal _leaderStale;
    mapping(uint256 day => address[RECENT]) internal _recent;
    mapping(uint256 day => uint256) internal _recentCount;

    struct PendingFlip {
        address player;
        address previous;
        uint64 day;
        uint64 requestedAt;
        uint96 stake; // points riding on the flip
        uint96 win; // points a win pays: the stake times a multiplier set by the buy size
    }

    mapping(uint64 sequence => PendingFlip) public flips;
    mapping(uint256 day => uint256) public pendingFlips; // requested that day, not yet revealed or expired

    // ── Settlement ──────────────────────────────────────────────────────────────
    struct Result {
        bool settled;
        uint64 cursor; // players scanned so far (settlement can run in batches)
        address[3] top;
        int256[3] topPoints;
        uint256[3] prize;
        bool[3] claimed;
        bool swept;
        uint64 settledAt;
        uint256[3] held; // $PFWA each winner must still hold to claim (what they held at settlement)
    }

    mapping(uint256 day => Result) internal _results;
    uint256 public buybackReserve;

    // ── Events ──────────────────────────────────────────────────────────────────
    event Played(
        uint256 indexed day,
        address indexed player,
        Move move,
        uint256 ethIn,
        uint256 pointsScored,
        address indexed target,
        uint256 pointsMoved
    );
    event FlipRequested(uint64 indexed sequence, uint256 indexed day, address indexed player, uint256 stake);
    event FlipResolved(uint64 indexed sequence, address indexed player, bool won, address paidTo, uint256 points);
    event PointsWiped(uint256 indexed day, address indexed player, uint256 points);
    event PotFunded(uint256 indexed day, uint256 amount, bool fromSell);
    event PotSeeded(uint256 indexed day, address indexed from, uint256 amount);
    event DaySettled(uint256 indexed day, address[3] top, uint256[3] prize, uint256 buyback, uint256 rollover);
    event PrizeClaimed(uint256 indexed day, address indexed player, uint256 amount);
    event PrizeForfeited(uint256 indexed day, address indexed player, uint256 amount);
    event ReferrerSet(address indexed player, address indexed referrer);
    event ReferralPoints(uint256 indexed day, address indexed referrer, address indexed player, uint256 points);
    event ReferralPrize(uint256 indexed day, address indexed referrer, address indexed player, uint256 amount);
    event ReferralClaimed(address indexed referrer, uint256 amount);
    event UnclaimedSwept(uint256 indexed day, uint256 amount);
    event BuybackBurned(uint256 ethIn, uint256 pfwaBurned);
    event OwnerChanged(address owner);
    event OperatorChanged(address operator);
    event BuybackPoolChanged(PoolId id);

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
    error DayNotOver();
    error DayPassed();
    error MustHoldToClaim();
    error AlreadySettled();
    error NotSettled();
    error NothingToClaim();
    error ClaimWindowOpen();
    error ClaimWindowClosed();
    error FlipNotExpired();
    error TooLittleOut();
    error BadBuybackPool();
    error TransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _poolManager, Currency _pfwa, IDiceEntropy _dice, address _diceProvider, address _owner) {
        poolManager = _poolManager;
        pfwa = _pfwa;
        dice = _dice;
        diceProvider = _diceProvider;
        owner = _owner;
        operator = _owner;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// ETH from the PoolManager (fees taken) and Dice (refunds) is accounted where it's received.
    /// Anything else sent straight here goes into today's pot instead of getting stuck.
    receive() external payable {
        if (msg.sender == address(dice)) buybackReserve += msg.value; // a refunded flip fee
        else if (msg.sender != address(poolManager)) _seed(currentDay(), msg.value);
    }

    /// Anyone can add ETH to today's pot or a future day's, e.g. to seed launch week.
    function fundPot(uint256 day) external payable {
        if (day < currentDay()) revert DayPassed();
        _seed(day, msg.value);
    }

    function _seed(uint256 day, uint256 amount) internal {
        pot[day] += amount;
        emit PotSeeded(day, msg.sender, amount);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function currentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    // ── Hook callbacks ──────────────────────────────────────────────────────────

    /// One pool only: native ETH / $PFWA with this hook, created by the owner. Anyone can trade in
    /// it; only creating it is restricted, so nobody can claim the hook between deploy and setup.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != owner) revert NotOwner();
        if (PoolId.unwrap(poolId) != bytes32(0)) revert PoolAlreadySet();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != Currency.unwrap(pfwa)) {
            revert WrongPool();
        }
        poolId = key.toId();
        return IHooks.beforeInitialize.selector;
    }

    /// Buys (ETH in): take the pot fee from the ETH paid in, then play the move.
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
        uint256 day = currentDay();
        if (fee > 0) {
            poolManager.take(key.currency0, address(this), fee);
            pot[day] += fee;
            emit PotFunded(day, fee, false);
        }
        if (ethIn >= MIN_BUY) _play(day, tx.origin, ethIn, hookData);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// Sells ($PFWA in): take the pot fee from the ETH paid out and wipe the seller's points.
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
            int128 pfwaOut = delta.amount1();
            if (pfwaOut > 0 && uint256(-params.amountSpecified) >= MIN_BUY) {
                bought[currentDay()][tx.origin] += uint256(int256(pfwaOut));
            }
            return (IHooks.afterSwap.selector, 0);
        }
        int128 ethOut = delta.amount0();
        uint256 day = currentDay();
        uint256 fee;
        if (ethOut > 0) {
            fee = (uint256(int256(ethOut)) * FEE_BPS) / 10_000;
            if (fee > 0) {
                poolManager.take(key.currency0, address(this), fee);
                pot[day] += fee;
                emit PotFunded(day, fee, true);
            }
        }
        int256 had = points[day][tx.origin];
        if (had > 0) {
            _debit(day, tx.origin, uint256(had));
            emit PointsWiped(day, tx.origin, uint256(had));
        }
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ── Moves ───────────────────────────────────────────────────────────────────

    function _play(uint256 day, address player, uint256 ethIn, bytes calldata hookData) internal {
        uint256 base = ethIn / POINT_UNIT;
        if (base > MAX_POINTS_PER_BUY) base = MAX_POINTS_PER_BUY;
        // This swap's $PFWA hasn't reached the player yet, so the balance is what they already held.
        Move move = hookData.length >= 32 ? _decodeMove(hookData) : Move.BUY;
        if (firstDayPlus1[player] == 0) {
            firstDayPlus1[player] = day + 1;
            if (hookData.length >= 64) {
                (, address referrer) = abi.decode(hookData, (uint256, address));
                if (referrer != address(0) && referrer != player && referrerOf[referrer] != player) {
                    referrerOf[player] = referrer;
                    emit ReferrerSet(player, referrer);
                }
            }
        }
        uint256 bonusBps = 10_000;
        if (holderBonusActive(day, player)) bonusBps += HOLDER_BONUS_BPS - 10_000;
        if (welcomeBonusActive(day, player)) bonusBps += WELCOME_BONUS_BPS;
        uint256 scored = (base * bonusBps) / 10_000;
        address previous = lastPlayer[day];
        address target;
        uint256 moved;

        if (move == Move.FLIP && _requestFlip(day, player, previous, scored, base, ethIn)) {
            // Points are credited when Dice reveals the flip.
            emit Played(day, player, move, ethIn, 0, previous, 0);
        } else {
            if (move == Move.FLIP) move = Move.BUY; // pot couldn't cover the Dice fee
            _credit(day, player, scored);
            if (move == Move.STEAL && previous != address(0) && previous != player) {
                target = previous;
                moved = (_positive(day, previous) * scaledBps(STEAL_BPS_MIN, STEAL_BPS_MAX, base)) / 10_000;
                if (moved > 0) {
                    _debit(day, previous, moved);
                    _credit(day, player, moved);
                }
            } else if (move == Move.ROBIN_HOOD) {
                address leader = _currentLeader(day);
                if (leader != address(0) && leader != player) {
                    target = _lowestRecent(day, leader);
                    if (target != address(0)) {
                        moved = (_positive(day, leader) * scaledBps(ROBIN_BPS_MIN, ROBIN_BPS_MAX, base)) / 10_000;
                        if (moved > 0) {
                            _debit(day, leader, moved);
                            _credit(day, target, moved);
                        }
                    }
                }
            }
            emit Played(day, player, move, ethIn, scored, target, moved);
        }
        address ref = referrerOf[player];
        if (ref != address(0) && _joined[day][ref]) {
            uint256 bonus = (scored * REFERRAL_POINTS_BPS) / 10_000;
            if (bonus > 0) {
                _credit(day, ref, bonus);
                emit ReferralPoints(day, ref, player, bonus);
            }
        }
        lastPlayer[day] = player;
        _pushRecent(day, player);
    }

    /// True on a referred player's first day.
    function welcomeBonusActive(uint256 day, address player) public view returns (bool) {
        return referrerOf[player] != address(0) && firstDayPlus1[player] == day + 1;
    }

    /// True when `player` played yesterday and still holds everything they bought here then.
    function holderBonusActive(uint256 day, address player) public view returns (bool) {
        if (day == 0) return false;
        uint256 held = bought[day - 1][player];
        return held > 0 && IBalanceOf(Currency.unwrap(pfwa)).balanceOf(player) >= held;
    }

    /// The share a move with `scored` points gets: `min` scaled linearly up to `max` at a full-size buy.
    function scaledBps(uint256 min, uint256 max, uint256 scored) public pure returns (uint256) {
        if (scored > MAX_POINTS_PER_BUY) scored = MAX_POINTS_PER_BUY;
        return min + ((max - min) * scored) / MAX_POINTS_PER_BUY;
    }

    function _decodeMove(bytes calldata hookData) internal pure returns (Move) {
        uint256 raw = abi.decode(hookData, (uint256));
        return raw <= uint256(Move.FLIP) ? Move(raw) : Move.BUY;
    }

    /// Pays the Dice fee out of today's pot and records the pending flip. False if the pot can't
    /// cover it or Dice can't take the request (paused, out of randomness, ...): the move then
    /// scores as a plain buy, so a Dice outage never blocks a swap.
    function _requestFlip(uint256 day, address player, address previous, uint256 stake, uint256 base, uint256 ethIn)
        internal
        returns (bool)
    {
        uint256 diceFee;
        try dice.getFeeV2(diceProvider, FLIP_CALLBACK_GAS) returns (uint128 fee) {
            diceFee = fee;
        } catch {
            return false;
        }
        if (diceFee > MAX_DICE_FEE || pot[day] < diceFee) return false;
        bytes32 userRandom = keccak256(abi.encode(player, ethIn, block.number, block.timestamp, gasleft()));
        uint64 sequence;
        try dice.requestV2{value: diceFee}(diceProvider, userRandom, FLIP_CALLBACK_GAS) returns (uint64 seq) {
            sequence = seq;
        } catch {
            return false;
        }
        pot[day] -= diceFee;
        flips[sequence] = PendingFlip({
            player: player,
            previous: previous == player ? address(0) : previous,
            day: uint64(day),
            requestedAt: uint64(block.timestamp),
            stake: uint96(stake),
            win: uint96((stake * scaledBps(FLIP_WIN_BPS_MIN, FLIP_WIN_BPS_MAX, base)) / 10_000)
        });
        pendingFlips[day] += 1;
        _join(day, player);
        emit FlipRequested(sequence, day, player, stake);
        return true;
    }

    /// Dice calls this with the revealed random number. Must not revert.
    function _entropyCallback(uint64 sequence, address, bytes32 randomNumber) external {
        if (msg.sender != address(dice)) revert NotDice();
        PendingFlip memory f = flips[sequence];
        if (f.player == address(0)) return; // already expired or unknown
        delete flips[sequence];
        pendingFlips[f.day] -= 1;
        if (_results[f.day].settled) return; // revealed after its day was settled
        bool won = uint256(randomNumber) % 2 == 0;
        address paidTo = won ? f.player : f.previous;
        uint256 amount = won ? f.win : f.stake;
        if (!won) _debit(f.day, f.player, f.stake); // can go below zero
        if (paidTo != address(0)) _credit(f.day, paidTo, amount);
        emit FlipResolved(sequence, f.player, won, paidTo, amount);
    }

    /// A flip Dice never revealed scores as a plain buy after FLIP_TIMEOUT. Anyone can call this.
    function expireFlip(uint64 sequence) external {
        PendingFlip memory f = flips[sequence];
        if (f.player == address(0) || block.timestamp < f.requestedAt + FLIP_TIMEOUT) revert FlipNotExpired();
        delete flips[sequence];
        pendingFlips[f.day] -= 1;
        if (!_results[f.day].settled) _credit(f.day, f.player, f.stake);
        emit FlipResolved(sequence, f.player, true, f.player, f.stake);
    }

    // ── Points bookkeeping ──────────────────────────────────────────────────────

    function _join(uint256 day, address player) internal {
        if (!_joined[day][player]) {
            _joined[day][player] = true;
            _players[day].push(player);
        }
    }

    function _credit(uint256 day, address player, uint256 amount) internal {
        _join(day, player);
        int256 updated = points[day][player] + int256(amount);
        points[day][player] = updated;
        // Even while the cached leader is stale (debited), anyone credited above them takes over: on
        // a day too big to rescan this keeps the cache moving instead of frozen until midnight.
        address leader = _leader[day];
        if (leader == address(0) || updated > points[day][leader]) _leader[day] = player;
    }

    function _debit(uint256 day, address player, uint256 amount) internal {
        _join(day, player);
        points[day][player] -= int256(amount);
        if (player == _leader[day]) _leaderStale[day] = true;
    }

    /// The day's leader, rescanning the board if the cached one lost points.
    function _currentLeader(uint256 day) internal returns (address leader) {
        if (!_leaderStale[day]) return _leader[day];
        address[] storage players = _players[day];
        uint256 n = players.length;
        if (n > MAX_LEADER_SCAN) return _leader[day]; // too big to rescan inside a swap; keep the cached one
        int256 best;
        for (uint256 i; i < n; ++i) {
            int256 p = points[day][players[i]];
            if (p > best) (best, leader) = (p, players[i]);
        }
        _leader[day] = leader;
        _leaderStale[day] = false;
    }

    /// A player's points if above zero, else 0: what Steal and Robin Hood can take.
    function _positive(uint256 day, address player) internal view returns (uint256) {
        int256 p = points[day][player];
        return p > 0 ? uint256(p) : 0;
    }

    function _pushRecent(uint256 day, address player) internal {
        uint256 count = _recentCount[day];
        _recent[day][count % RECENT] = player;
        _recentCount[day] = count + 1;
    }

    /// The lowest-scoring of the last 10 players, other than the leader. That can be the player
    /// making the move: Robin Hood for yourself is allowed, so moves can be chained.
    function _lowestRecent(uint256 day, address leader) internal view returns (address lowest) {
        uint256 count = _recentCount[day];
        uint256 n = count < RECENT ? count : RECENT;
        int256 low = type(int256).max;
        for (uint256 i; i < n; ++i) {
            address a = _recent[day][i];
            if (a == leader) continue;
            int256 p = points[day][a];
            if (p < low) (low, lowest) = (p, a);
        }
    }

    // ── Settlement and prizes ───────────────────────────────────────────────────

    /// Ranks a finished day and splits its pot. Big days can be settled in batches of `maxPlayers`.
    function settle(uint256 day, uint256 maxPlayers) external returns (bool done) {
        if (block.timestamp < (day + 1) * 1 days + SETTLE_DELAY) revert DayNotOver();
        Result storage r = _results[day];
        if (r.settled) revert AlreadySettled();
        // A reveal between batches would change scores already ranked. Every flip of a finished day
        // can be expired by the time settlement opens (FLIP_TIMEOUT < SETTLE_DELAY).
        if (pendingFlips[day] > 0) revert FlipsPending();

        address[] storage players = _players[day];
        uint256 end = r.cursor + maxPlayers;
        if (end > players.length) end = players.length;
        for (uint256 i = r.cursor; i < end; ++i) {
            address a = players[i];
            int256 p = points[day][a];
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
        r.cursor = uint64(end);
        if (end < players.length) return false;

        uint256 total = pot[day];
        uint256[3] memory shares = [total * 50 / 100, total * 20 / 100, total * 10 / 100];
        uint256 buyback = total * 10 / 100;
        uint256 awarded;
        for (uint256 i; i < 3; ++i) {
            address winner = r.top[i];
            if (winner == address(0)) continue;
            // Sold part of that day's buys (in any pool) before settlement: the same share of the
            // prize rolls into today's pot. Sold 20%, lose 20%.
            uint256 prize = shares[i];
            uint256 owed = bought[day][winner];
            uint256 balance = IBalanceOf(Currency.unwrap(pfwa)).balanceOf(winner);
            if (balance < owed) {
                uint256 kept = (prize * balance) / owed;
                emit PrizeForfeited(day, winner, prize - kept);
                prize = kept;
                owed = balance;
            }
            if (prize == 0) continue;
            r.prize[i] = prize;
            r.held[i] = owed;
            awarded += prize;
            // The referrer's share comes out of the rollover (always 6% or more), not the prize.
            address ref = referrerOf[winner];
            if (ref != address(0) && _joined[day][ref]) {
                uint256 cut = (prize * REFERRAL_PRIZE_BPS) / 10_000;
                referralEarnings[ref] += cut;
                awarded += cut;
                emit ReferralPrize(day, ref, winner, cut);
            }
        }
        uint256 rollover = total - awarded - buyback;
        r.settled = true;
        r.settledAt = uint64(block.timestamp);
        buybackReserve += buyback;
        uint256 today = currentDay();
        if (rollover > 0) pot[today] += rollover;
        emit DaySettled(day, r.top, r.prize, buyback, rollover);
        return true;
    }

    function claim(uint256 day) external {
        Result storage r = _results[day];
        if (!r.settled) revert NotSettled();
        if (block.timestamp > claimDeadline(day)) revert ClaimWindowClosed();
        uint256 amount;
        uint256 balance = IBalanceOf(Currency.unwrap(pfwa)).balanceOf(msg.sender);
        for (uint256 i; i < 3; ++i) {
            if (r.top[i] == msg.sender && !r.claimed[i] && r.prize[i] > 0) {
                // Winners keep what they held at settlement until they claim. Sold more since, in
                // this pool or anywhere else? The prize stays put and goes back to the pot after the
                // claim window, unless they buy it back first.
                if (balance < r.held[i]) revert MustHoldToClaim();
                r.claimed[i] = true;
                amount += r.prize[i];
            }
        }
        if (amount == 0) revert NothingToClaim();
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit PrizeClaimed(day, msg.sender, amount);
    }

    /// Winners have CLAIM_WINDOW from the end of the day, or from settlement if that came later.
    function claimDeadline(uint256 day) public view returns (uint256) {
        uint256 dayEnd = (day + 1) * 1 days;
        uint256 settledAt = _results[day].settledAt;
        return (settledAt > dayEnd ? settledAt : dayEnd) + CLAIM_WINDOW;
    }

    /// Referrers withdraw their prize shares any time.
    function claimReferral() external {
        uint256 amount = referralEarnings[msg.sender];
        if (amount == 0) revert NothingToClaim();
        referralEarnings[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ReferralClaimed(msg.sender, amount);
    }

    /// Prizes left unclaimed after the claim window go back into the current day's pot.
    function sweepUnclaimed(uint256 day) external {
        Result storage r = _results[day];
        if (!r.settled || r.swept) revert NotSettled();
        if (block.timestamp <= claimDeadline(day)) revert ClaimWindowOpen();
        r.swept = true;
        uint256 amount;
        for (uint256 i; i < 3; ++i) {
            if (!r.claimed[i] && r.prize[i] > 0) {
                r.claimed[i] = true;
                amount += r.prize[i];
            }
        }
        pot[currentDay()] += amount;
        emit UnclaimedSwept(day, amount);
    }

    // ── Buyback and burn ────────────────────────────────────────────────────────

    /// Swaps `amount` of the buyback reserve for $PFWA in the buyback pool and burns it.
    function buybackAndBurn(uint256 amount, uint256 minPfwaOut) external {
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        if (amount > buybackReserve) amount = buybackReserve;
        buybackReserve -= amount;
        bytes memory result = poolManager.unlock(abi.encode(amount, minPfwaOut));
        uint256 burned = abi.decode(result, (uint256));
        emit BuybackBurned(amount, burned);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint256 amount, uint256 minOut) = abi.decode(data, (uint256, uint256));
        PoolKey memory key = buybackPool;
        BalanceDelta delta = poolManager.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
        );
        uint256 ethPaid = uint256(int256(-delta.amount0()));
        uint256 pfwaOut = uint256(int256(delta.amount1()));
        if (pfwaOut < minOut) revert TooLittleOut();
        poolManager.settle{value: ethPaid}();
        poolManager.take(key.currency1, DEAD, pfwaOut);
        if (ethPaid < amount) buybackReserve += amount - ethPaid; // a partial fill keeps the rest
        return abi.encode(pfwaOut);
    }

    /// Reclaims the fee of a Dice request that was never revealed (after Dice's refund delay) into the buyback reserve.
    function refundDiceRequest(uint64 sequence) external {
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        dice.refundRequest(diceProvider, sequence); // the refund arrives through receive()
    }

    // ── Admin: who runs buybacks, and (once) which pool they use. Nothing else. ─

    function setOwner(address next) external onlyOwner {
        owner = next;
        emit OwnerChanged(next);
    }

    function setOperator(address next) external onlyOwner {
        operator = next;
        emit OperatorChanged(next);
    }

    /// Set once, at launch: after that nobody can redirect the buyback reserve.
    function setBuybackPool(PoolKey calldata key) external onlyOwner {
        if (Currency.unwrap(buybackPool.currency1) != address(0)) revert PoolAlreadySet();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != Currency.unwrap(pfwa)) {
            revert BadBuybackPool();
        }
        if (PoolId.unwrap(key.toId()) == PoolId.unwrap(poolId) || address(key.hooks) == address(this)) {
            revert BadBuybackPool();
        }
        buybackPool = key;
        emit BuybackPoolChanged(key.toId());
    }

    // ── Views for the site ──────────────────────────────────────────────────────

    function playerCount(uint256 day) external view returns (uint256) {
        return _players[day].length;
    }

    function playersPage(uint256 day, uint256 start, uint256 count)
        external
        view
        returns (address[] memory players, int256[] memory pts)
    {
        address[] storage all = _players[day];
        uint256 end = start + count > all.length ? all.length : start + count;
        uint256 n = end > start ? end - start : 0;
        players = new address[](n);
        pts = new int256[](n);
        for (uint256 i; i < n; ++i) {
            players[i] = all[start + i];
            pts[i] = points[day][players[i]];
        }
    }

    function leader(uint256 day) external view returns (address) {
        return _leader[day];
    }

    /// The last (up to) 10 players of the day, most recent first: who Robin Hood can pay.
    function recentPlayers(uint256 day) external view returns (address[] memory players) {
        uint256 count = _recentCount[day];
        uint256 n = count < RECENT ? count : RECENT;
        players = new address[](n);
        for (uint256 i; i < n; ++i) {
            players[i] = _recent[day][(count - 1 - i) % RECENT];
        }
    }

    function result(uint256 day)
        external
        view
        returns (bool settled, address[3] memory top, int256[3] memory topPoints, uint256[3] memory prize, bool[3] memory claimed)
    {
        Result storage r = _results[day];
        return (r.settled, r.top, r.topPoints, r.prize, r.claimed);
    }

    /// The $PFWA `player` must hold to claim their prize for `day`: what they held at settlement.
    function heldToClaim(uint256 day, address player) external view returns (uint256) {
        Result storage r = _results[day];
        for (uint256 i; i < 3; ++i) {
            if (r.top[i] == player && r.prize[i] > 0) return r.held[i];
        }
        return 0;
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
