// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

/// @notice The one swap the arena makes: spend all the ETH sent on the game token and deliver it to
/// `recipient`, reverting if that's less than `minOut`. Implemented by an adapter around the router
/// the game's pool trades through (Hookr's router for the $PFWA arena). ETH it doesn't spend may be
/// sent back to the caller.
interface IArenaRouter {
    function buy(uint256 minOut, address recipient) external payable returns (uint256 out);
}

/// @notice Where the pool's buy tax waits until someone pays it out (Hookr's buy queue): payCreator()
/// sends what the pot is owed to the queue's fixed recipient, and reverts when nothing is owed.
interface IArenaTaxQueue {
    function payCreator() external returns (uint256 amount);
}

/// @title Sherwood Arena
/// @notice Sherwood v2.1's game (SherwoodV21.sol) as a plain contract instead of a Uniswap v4 hook, for
/// the $PFWA game on Hookr: the pool is an ETH/$PFWA pool on Hookr's root hook, every move buys through
/// that pool's router (via IArenaRouter), and the pool's buy tax is paid into the pot. What changed:
///   1. A move is a call to play(), not a swap with hook data. The player is msg.sender (not
///      tx.origin), so a wallet, an agent or another contract can play. The ETH sent buys $PFWA for the
///      player through the router; an optional play fee (playFeeBps, at most 5%) is kept for the pot.
///   2. The pot is funded by the play fee, by ETH anyone sends (the pool's buy tax, pushed here), and by
///      fundPot seeding. Buys made elsewhere score nothing.
///   3. Selling: the arena can't see sells, so a sell no longer wipes the seller's points. It costs them
///      at settlement instead, as in v2.1: a winner holding less than they bought through the arena that
///      round keeps only that share of the prize (sold 20%, lose 20%), and must still hold what they held
///      at settlement to claim.
///   4. The $PFWA game only: no host token. The 17% buyback burns $PFWA through the router.
///   5. The owner can switch Flip off (flipsEnabled) while Dice Protocol is unreliable: a FLIP then plays
///      as a BUY and spends no charge.
/// Everything else is v2.1, except that the round length is an owner setting (5 min to 20 h, from the next
/// round boundary; v2.1's 20 h by default): 1 point per 0.001 ETH (up to 100 a move);
/// BUY, STEAL, ROBIN_HOOD, FLIP and SHIELD with their charges and shield blocks; the holder, welcome and
/// referral bonuses; King of the Hill; settlement 40/20/10% to the top three, 8% to the King, 17% to the
/// burn, 5% (plus anything unawarded) rolled over; 7 days to claim.
contract SherwoodArena {
    // ── Game constants ──────────────────────────────────────────────────────────
    uint256 internal constant MAX_PLAY_FEE_BPS = 500;
    uint256 internal constant MIN_BUY = 0.001 ether;
    uint256 internal constant POINT_UNIT = 0.001 ether;
    uint256 internal constant MAX_POINTS_PER_BUY = 100;
    uint256 internal constant STEAL_BPS_MIN = 2000;
    uint256 internal constant STEAL_BPS_MAX = 4000;
    uint256 internal constant ROBIN_BPS_MIN = 1000;
    uint256 internal constant ROBIN_BPS_MAX = 3300;
    uint256 internal constant FLIP_WIN_BPS_MIN = 20_000;
    uint256 internal constant FLIP_WIN_BPS_MAX = 30_000;
    // Still holding all the tokens you bought here last round when you play this one: +25% points.
    uint256 internal constant HOLDER_BONUS_BPS = 12_500;
    uint256 internal constant REFERRAL_POINTS_BPS = 1000;
    uint256 internal constant REFERRAL_PRIZE_BPS = 500;
    uint256 internal constant WELCOME_BONUS_BPS = 1000;
    uint256 internal constant RECENT = 10;
    uint256 public constant SETTLE_DELAY = 15 minutes;
    uint256 internal constant CLAIM_WINDOW = 7 days;
    uint256 internal constant FLIP_TIMEOUT = 10 minutes;
    uint256 internal constant MAX_SEED_AHEAD = 365;
    uint32 internal constant FLIP_CALLBACK_GAS = 200_000;
    // Hookr's queue pulls a pending claim with exactly 500,000 gas and needs about 513,000 at that point.
    uint256 internal constant TAX_PULL_GAS = 600_000;
    uint256 internal constant MAX_DICE_FEE = 0.0005 ether;
    // A flip never costs the pot more than this share of its move's ETH (v2.1's 5% pot fee; the arena's
    // play fee can be lower, the pool's buy tax makes up the rest).
    uint256 internal constant FLIP_FEE_CAP_BPS = 500;
    uint256 internal constant MAX_LEADER_SCAN = 1500;
    uint256 internal constant LEADER_SCAN_CHUNK = 200;
    uint256 internal constant LEADER_SCAN_RESERVE = 1_000_000;
    uint256 internal constant MAX_CALLBACK_SCAN = 12;
    address internal constant UNKNOWN_REIGN = address(1);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;


    uint256 internal constant SHIELD_CHARGE_ETH = 0.01 ether;
    uint256 internal constant MAX_SHIELD_BLOCKS = 5;
    uint256 internal constant SHIELD_DURATION = 30 minutes;
    uint256 internal constant STEAL_RECHARGE = 10 minutes;
    uint256 internal constant STEAL_MAX_CHARGES = 18;
    uint256 internal constant ROBIN_RECHARGE = 1 hours;
    uint256 internal constant ROBIN_MAX_CHARGES = 3;
    uint256 internal constant FLIP_MAX_CHARGES = 6;

    // How a settled pot is split. Sums to 10_000.
    uint256 public constant FIRST_BPS = 4000;
    uint256 public constant SECOND_BPS = 2000;
    uint256 public constant THIRD_BPS = 1000;
    uint256 public constant KING_BPS = 800;
    /// @notice Share of the pot that goes to the buyback reserve and burns $PFWA (v2.1's 10% plus the
    /// 7% host burn, which in $PFWA's own game burns with it).
    uint256 public constant BURN_BPS = 1700;
    uint256 public constant ROLLOVER_BPS = 500;

    // Transient slots: 0 the reentrancy lock, 1 ETH credited to pots this transaction, 2 a router swap
    // in progress (ETH the router sends back then is a refund, accounted by the swap).
    uint256 internal constant INBOUND_SLOT = 1;
    uint256 internal constant SWAPPING_SLOT = 2;

    enum Move {
        BUY,
        STEAL,
        ROBIN_HOOD,
        FLIP,
        SHIELD
    }

    // ── Wiring ──────────────────────────────────────────────────────────────────
    /// Tokens each player bought through the arena, per round: the settlement sell rule and the holder
    /// bonus read it against the player's balance.
    mapping(uint256 round => mapping(address player => uint256)) public bought;
    mapping(address player => address) public referrerOf;
    mapping(address player => uint256) public firstRoundPlus1;
    mapping(address referrer => uint256) public referralEarnings;

    /// @notice The game token ($PFWA).
    address public immutable token;
    /// @notice Where every move and the burn buy the token.
    IArenaRouter public immutable router;
    IDiceEntropy public immutable dice;
    address public immutable diceProvider;
    /// @notice When round 0 starts. Before it, play() still buys and its fee goes to round 0's pot,
    /// but nothing is scored.
    uint256 public immutable GENESIS;
    /// @notice Share of each move's ETH kept for the round's pot (the rest buys the token).
    uint256 public immutable playFeeBps;

    address public owner;
    address public pendingOwner;
    address public operator; // runs buybacks and Dice refunds
    /// @notice Whether FLIP asks Dice for a coin flip (off: it plays as a BUY). Owner-set.
    bool public flipsEnabled;

    /// A stretch of rounds of one length: rounds firstRound, firstRound + 1, ... start at `start`, each
    /// `length` long, until the next period's first round. Period 0 starts at GENESIS with the deploy
    /// length; setRoundLength adds the next period from the next round boundary.
    struct Period {
        uint64 firstRound;
        uint64 start;
        uint64 length;
    }

    Period[] internal _periods;
    /// @notice The pool's buy-tax queue, pulled at every move and settlement so the live pot stays
    /// current. Set once, after the pool launches (the queue only exists then). Unset: nothing is pulled.
    address public taxQueue;

    // ── Game state ──────────────────────────────────────────────────────────────
    mapping(uint256 round => mapping(address player => int256)) public points;
    mapping(uint256 round => address[]) internal _players;
    mapping(uint256 round => mapping(address player => bool)) internal _joined;
    mapping(uint256 round => uint256) public pot;
    mapping(uint256 round => address) public lastPlayer;
    mapping(uint256 round => address) internal _leader;
    mapping(uint256 round => bool) internal _leaderStale;
    mapping(uint256 round => uint256) internal _scanCursor;
    mapping(uint256 round => address[RECENT]) internal _recent;
    mapping(uint256 round => uint256) internal _recentCount;

    struct PendingFlip {
        address player;
        address previous;
        uint64 round;
        uint64 requestedAt;
        uint96 stake;
        uint96 win;
    }

    mapping(uint64 sequence => PendingFlip) public flips;
    mapping(uint256 round => uint256) public pendingFlips;

    struct ShieldStats {
        uint128 played;
        uint64 used;
        uint8 charges;
    }

    mapping(uint256 round => mapping(address player => ShieldStats)) public shieldStats;
    mapping(address player => uint256) public shieldUntil;
    mapping(address player => uint256) public shieldBlocks;
    mapping(address player => uint256) internal _stealClock;
    mapping(address player => uint256) internal _robinClock;
    mapping(address player => uint256) internal _flipClock;

    struct Reign {
        address holder;
        uint64 since;
    }

    mapping(uint256 round => Reign) internal _reign;
    mapping(uint256 round => mapping(address player => uint256)) internal _reignSeconds;

    struct Result {
        bool settled;
        uint64 cursor;
        address[3] top;
        int256[3] topPoints;
        address king;
        uint64 kingReign;
        uint256[4] prize;
        bool[4] claimed;
        bool swept;
        uint64 settledAt;
        uint256[4] held;
    }

    mapping(uint256 round => Result) internal _results;
    uint256 public buybackReserve;

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
    /// @notice A move bought `tokenOut` for `player` (scored or not).
    event Bought(uint256 indexed round, address indexed player, uint256 ethSwapped, uint256 tokenOut);
    event FlipRequested(uint64 indexed sequence, uint256 indexed round, address indexed player, uint256 stake);
    event FlipResolved(uint64 indexed sequence, address indexed player, bool won, address paidTo, uint256 points);
    /// @notice ETH into a round's pot: a move's play fee, or ETH sent straight here (the pool's buy tax).
    event PotFunded(uint256 indexed round, uint256 amount, bool fromSell);
    event PotSeeded(uint256 indexed round, address indexed from, uint256 amount);
    /// @notice `hostBuyback` is always 0 here (kept so readers of v2's event keep working).
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
    event OwnerChanged(address owner);
    event OwnerProposed(address pendingOwner);
    event OperatorChanged(address operator);
    event FlipsEnabledSet(bool enabled);
    event TaxQueueSet(address indexed queue);
    event RoundLengthSet(uint256 length, uint256 fromRound, uint256 fromTime);
    event ShieldArmed(uint256 indexed round, address indexed player, uint256 until);
    event Reflected(
        uint256 indexed round, address indexed attacker, address indexed defender, uint256 points, Move move
    );
    event ReignChanged(uint256 indexed round, address indexed newHolder, uint256 at);

    error NotOwner();
    error NotOperator();
    error NotDice();
    error BadPlayFee();
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
    error NothingToBurn();
    error TransferFailed();
    error TaxQueueAlreadySet();
    error BadRoundLength();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner) revert NotOperator();
        _;
    }

    /// Guards everything that moves ETH out or calls the router (play, claims, sweeps, the burn) against each other.
    modifier nonReentrant() {
        if (_tget(0) != 0) revert Reentered();
        _tset(0, 1);
        _;
        _tset(0, 0);
    }

    function _tget(uint256 slot) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tset(uint256 slot, uint256 v) internal {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    constructor(
        address _token,
        IArenaRouter _router,
        IDiceEntropy _dice,
        address _diceProvider,
        address _owner,
        uint256 _genesis,
        uint256 _playFeeBps,
        bool _flipsEnabled,
        uint256 _roundLength
    ) {
        if (_playFeeBps > MAX_PLAY_FEE_BPS) revert BadPlayFee();
        if (!_allowedLength(_roundLength)) revert BadRoundLength();
        _periods.push(Period(0, uint64(_genesis), uint64(_roundLength)));
        token = _token;
        router = _router;
        dice = _dice;
        diceProvider = _diceProvider;
        owner = _owner;
        operator = _owner;
        GENESIS = _genesis;
        playFeeBps = _playFeeBps;
        flipsEnabled = _flipsEnabled;
    }

    /// Inbound ETH: a Dice refund goes to the buyback reserve (as on v2.1); ETH the router sends back
    /// during one of the arena's own swaps is a refund that swap accounts for; anything else (the pool's
    /// buy tax, pushed here, or anyone's gift) goes into the live round's pot.
    receive() external payable {
        if (msg.sender == address(dice)) {
            buybackReserve += msg.value;
        } else if (msg.sender != address(router) || _tget(SWAPPING_SLOT) == 0) {
            uint256 round = currentRound();
            _creditPot(round, msg.value);
            emit PotFunded(round, msg.value, false);
        }
    }

    /// Anyone can add ETH to the current round's pot or a future round's (within MAX_SEED_AHEAD rounds).
    function fundPot(uint256 round) external payable {
        uint256 current = currentRound();
        if (round < current || round > current + MAX_SEED_AHEAD) revert RoundPassed();
        _creditPot(round, msg.value);
        emit PotSeeded(round, msg.sender, msg.value);
    }

    /// @notice Pays the pool's waiting buy tax into the live round's pot (anyone can call; moves and
    /// settlements do it too). Tax that reaches the pot during a round is that round's.
    function pullTax() external {
        _pullTax();
    }

    /// Asks the queue to pay out, ignoring every failure: nothing owed reverts, and a move or a
    /// settlement must never depend on the queue. Whatever it pays arrives through receive().
    function _pullTax() internal {
        address q = taxQueue;
        if (q == address(0)) return;
        try IArenaTaxQueue(q).payCreator{gas: TAX_PULL_GAS}() {} catch {}
    }

    /// Every ETH credit to a pot goes through here, so a router swap can tell its own refunds apart
    /// from ETH that reached a pot while it ran.
    function _creditPot(uint256 round, uint256 amount) internal {
        pot[round] += amount;
        _tset(INBOUND_SLOT, _tget(INBOUND_SLOT) + amount);
    }

    /// @notice The round being played now (0 before GENESIS too).
    function currentRound() public view returns (uint256) {
        if (block.timestamp < GENESIS) return 0;
        uint256 i = _periods.length - 1;
        while (_periods[i].start > block.timestamp) --i; // a change waiting for the next boundary
        Period memory p = _periods[i];
        return p.firstRound + (block.timestamp - p.start) / p.length;
    }

    function roundStart(uint256 round) public view returns (uint256) {
        Period memory p = _periodOf(round);
        return p.start + (round - p.firstRound) * p.length;
    }

    function roundEnd(uint256 round) public view returns (uint256) {
        Period memory p = _periodOf(round);
        return p.start + (round - p.firstRound + 1) * p.length;
    }

    /// @notice The length of the round being played now (v2.1 readers know it as a constant).
    function ROUND_LENGTH() public view returns (uint256) {
        return roundEnd(currentRound()) - roundStart(currentRound());
    }

    /// @notice The schedule: period `i` runs rounds from firstRound on, from `start`, `length` seconds each.
    function periodCount() external view returns (uint256) {
        return _periods.length;
    }

    function period(uint256 i) external view returns (uint256 firstRound, uint256 start, uint256 length) {
        Period memory p = _periods[i];
        return (p.firstRound, p.start, p.length);
    }

    function _periodOf(uint256 round) internal view returns (Period memory) {
        uint256 i = _periods.length - 1;
        while (_periods[i].firstRound > round) --i;
        return _periods[i];
    }

    function _allowedLength(uint256 length) internal pure returns (bool) {
        return length == 5 minutes || length == 15 minutes || length == 30 minutes || length == 1 hours
            || length == 20 hours;
    }

    /// Flip charges come back three times a round, whatever the round's length.
    function _flipRecharge() internal view returns (uint256) {
        return ROUND_LENGTH() / 3;
    }

    // ── Moves ───────────────────────────────────────────────────────────────────

    /// @notice Plays `move` (0 BUY, 1 STEAL, 2 ROBIN_HOOD, 3 FLIP, 4 SHIELD; anything else is a BUY) with
    /// the ETH sent: playFeeBps of it goes to the round's pot, the rest buys the token for the caller
    /// through the router, reverting if that's less than `minOut` or doesn't spend all of it. `referrer`
    /// counts on the caller's first play only (0 = none). Moves of at least 0.001 ETH score, from GENESIS.
    function play(uint8 move, uint256 minOut, address referrer) external payable nonReentrant {
        _pullTax();
        uint256 ethIn = msg.value;
        uint256 round = currentRound();
        uint256 fee = (ethIn * playFeeBps) / 10_000;
        if (fee > 0) {
            _creditPot(round, fee);
            emit PotFunded(round, fee, false);
        }
        bool scores = ethIn >= MIN_BUY && block.timestamp >= GENESIS;
        // Scored before the swap, so the holder bonus reads what the player held before this buy.
        if (scores) _play(round, msg.sender, ethIn, move, referrer);
        (uint256 out, uint256 refund) = _buy(ethIn - fee, minOut, msg.sender);
        // Points were scored on all of the ETH, so all of it must have been spent.
        if (refund > 0) revert PartialFill();
        if (scores) bought[round][msg.sender] += out;
        emit Bought(round, msg.sender, ethIn - fee, out);
    }

    /// Buys the token with `amount` ETH through the router for `recipient`. Returns what `recipient`
    /// received (measured, not the router's word) and the ETH the router sent back.
    function _buy(uint256 amount, uint256 minOut, address recipient) internal returns (uint256 out, uint256 refund) {
        uint256 balanceBefore = address(this).balance;
        uint256 inboundBefore = _tget(INBOUND_SLOT);
        uint256 tokensBefore = IBalanceOf(token).balanceOf(recipient);
        _tset(SWAPPING_SLOT, 1);
        router.buy{value: amount}(minOut, recipient);
        _tset(SWAPPING_SLOT, 0);
        out = IBalanceOf(token).balanceOf(recipient) - tokensBefore;
        if (out < minOut) revert TooLittleOut();
        // balance now = before - amount + refund + ETH credited to pots meanwhile (e.g. the buy tax).
        refund = address(this).balance + amount - balanceBefore - (_tget(INBOUND_SLOT) - inboundBefore);
    }

    function _play(uint256 round, address player, uint256 ethIn, uint8 rawMove, address referrer_) internal {
        _resumeScan(round);
        uint256 base = ethIn / POINT_UNIT;
        if (base > MAX_POINTS_PER_BUY) base = MAX_POINTS_PER_BUY;
        Move move = rawMove <= uint8(Move.SHIELD) ? Move(rawMove) : Move.BUY;
        if (firstRoundPlus1[player] == 0) {
            firstRoundPlus1[player] = round + 1;
            if (referrer_ != address(0) && referrer_ != player && referrerOf[referrer_] != player) {
                referrerOf[player] = referrer_;
                emit ReferrerSet(player, referrer_);
            }
        }
        move = _limit(round, player, ethIn, move);
        uint256 bonusBps = 10_000;
        if (holderBonusActive(round, player)) bonusBps += HOLDER_BONUS_BPS - 10_000;
        if (welcomeBonusActive(round, player)) bonusBps += WELCOME_BONUS_BPS;
        uint256 scored = (base * bonusBps) / 10_000;
        address previous = lastPlayer[round];
        address target;
        uint256 moved;

        if (move == Move.FLIP && _requestFlip(round, player, previous, scored, base, ethIn)) {
            emit Played(round, player, move, ethIn, 0, previous, 0);
        } else {
            if (move == Move.FLIP) move = Move.BUY;
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
                address leader_ = _currentLeader(round);
                if (uint160(leader_) > uint160(UNKNOWN_REIGN) && leader_ != player) {
                    target = _lowestRecent(round, leader_);
                    if (target != address(0)) {
                        _robinClock[player] = _spend(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES);
                        moved = (_positive(round, leader_) * scaledBps(ROBIN_BPS_MIN, ROBIN_BPS_MAX, base)) / 10_000;
                        if (shieldActive(leader_)) {
                            _reflect(round, player, leader_, moved, move);
                            (target, moved) = (leader_, 0);
                        } else if (moved > 0) {
                            _debit(round, leader_, moved);
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

    /// Counts this play towards shield blocks, then applies the move limits (v2.1): a SHIELD with no
    /// block, or a STEAL, ROBIN_HOOD or FLIP with no charge, plays as a BUY; so does a FLIP while flips
    /// are switched off (spending no charge).
    function _limit(uint256 round, address player, uint256 ethIn, Move move) internal returns (Move) {
        ShieldStats storage s = shieldStats[round][player];
        uint256 played = s.played;
        s.played = uint128(played + ethIn);
        uint256 earned = (played + ethIn) / SHIELD_CHARGE_ETH - played / SHIELD_CHARGE_ETH;
        if (earned > 0) {
            uint256 banked = s.charges + earned;
            s.charges = uint8(banked < MAX_SHIELD_BLOCKS ? banked : MAX_SHIELD_BLOCKS);
        }
        if (move == Move.SHIELD) {
            uint256 charges = s.charges;
            if (charges == 0) return Move.BUY;
            uint256 blocks = (shieldActive(player) ? shieldBlocks[player] : 0) + charges;
            if (blocks > MAX_SHIELD_BLOCKS) blocks = MAX_SHIELD_BLOCKS;
            s.charges = 0;
            s.used += uint64(charges);
            shieldBlocks[player] = blocks;
            uint256 until = block.timestamp + SHIELD_DURATION;
            shieldUntil[player] = until;
            emit ShieldArmed(round, player, until);
        } else if (move == Move.STEAL) {
            if (_charges(_stealClock[player], STEAL_RECHARGE, STEAL_MAX_CHARGES) == 0) return Move.BUY;
        } else if (move == Move.ROBIN_HOOD) {
            if (_charges(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES) == 0) return Move.BUY;
        } else if (move == Move.FLIP) {
            if (!flipsEnabled || _charges(_flipClock[player], _flipRecharge(), FLIP_MAX_CHARGES) == 0) return Move.BUY;
        }
        return move;
    }

    function _charges(uint256 clock, uint256 recharge, uint256 cap) internal view returns (uint256) {
        uint256 n = (block.timestamp - clock) / recharge;
        return n < cap ? n : cap;
    }

    function _spend(uint256 clock, uint256 recharge, uint256 cap) internal view returns (uint256) {
        uint256 full = block.timestamp - cap * recharge;
        return (clock > full ? clock : full) + recharge;
    }

    function _reflect(uint256 round, address attacker, address defender, uint256 amount, Move move) internal {
        if (amount == 0) return;
        uint256 blocks = shieldBlocks[defender];
        if (blocks > 1) {
            shieldBlocks[defender] = blocks - 1;
        } else {
            delete shieldBlocks[defender];
            delete shieldUntil[defender];
        }
        _debit(round, attacker, amount);
        _credit(round, defender, amount);
        emit Reflected(round, attacker, defender, amount, move);
    }

    function shieldActive(address player) public view returns (bool) {
        return block.timestamp < shieldUntil[player] && shieldBlocks[player] > 0;
    }

    function welcomeBonusActive(uint256 round, address player) public view returns (bool) {
        return referrerOf[player] != address(0) && firstRoundPlus1[player] == round + 1;
    }

    /// True when `player` played last round and still holds everything they bought through the arena then.
    function holderBonusActive(uint256 round, address player) public view returns (bool) {
        if (round == 0) return false;
        uint256 held = bought[round - 1][player];
        return held > 0 && IBalanceOf(token).balanceOf(player) >= held;
    }

    /// Always false: the $PFWA game has no host token (kept for readers of v2's ABI).
    function hostBonusActive(address) external pure returns (bool) {
        return false;
    }

    function scaledBps(uint256 min, uint256 max, uint256 scored) public pure returns (uint256) {
        if (scored > MAX_POINTS_PER_BUY) scored = MAX_POINTS_PER_BUY;
        return min + ((max - min) * scored) / MAX_POINTS_PER_BUY;
    }

    /// Pays the Dice fee out of the round's pot and records the pending flip. False (the move scores as
    /// a buy) if the fee is above MAX_DICE_FEE or FLIP_FEE_CAP_BPS of the move, the pot can't cover it,
    /// or Dice can't take the request.
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
        if (diceFee > MAX_DICE_FEE || diceFee > (ethIn * FLIP_FEE_CAP_BPS) / 10_000 || pot[round] < diceFee) {
            return false;
        }
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
        _flipClock[player] = _spend(_flipClock[player], _flipRecharge(), FLIP_MAX_CHARGES);
        _join(round, player);
        emit FlipRequested(sequence, round, player, stake);
        return true;
    }

    /// Dice calls this with the revealed random number. Must not revert.
    function _entropyCallback(uint64 sequence, address, bytes32 randomNumber) external {
        if (msg.sender != address(dice)) revert NotDice();
        PendingFlip memory f = flips[sequence];
        if (f.player == address(0)) return;
        delete flips[sequence];
        pendingFlips[f.round] -= 1;
        if (_results[f.round].settled) return;
        bool won = uint256(randomNumber) % 2 == 0;
        address paidTo = won ? f.player : f.previous;
        uint256 amount = won ? f.win : f.stake;
        if (!won) _debit(f.round, f.player, f.stake);
        if (paidTo != address(0)) _credit(f.round, paidTo, amount);
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

    // ── Points bookkeeping (v2.1) ───────────────────────────────────────────────

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
        address leader_ = _leader[round];
        if (leader_ == address(0) || updated > points[round][leader_]) _leader[round] = player;
    }

    function _debit(uint256 round, address player, uint256 amount) internal {
        _join(round, player);
        points[round][player] -= int256(amount);
        if (player == _leader[round]) {
            _leaderStale[round] = true;
            _scanCursor[round] = 0;
        }
    }

    function _currentLeader(uint256 round) internal returns (address) {
        if (!_leaderStale[round]) return _leader[round];
        if (_players[round].length > MAX_LEADER_SCAN) return UNKNOWN_REIGN;
        return _scan(round, true);
    }

    function _resumeScan(uint256 round) internal {
        if (_leaderStale[round]) _setReign(round, _scan(round, _players[round].length <= MAX_LEADER_SCAN));
    }

    function _scan(uint256 round, bool all) internal returns (address leader_) {
        leader_ = _leader[round];
        address[] storage players = _players[round];
        uint256 n = players.length;
        uint256 i = _scanCursor[round];
        uint256 atLeast = all ? n : i + LEADER_SCAN_CHUNK;
        int256 best = points[round][leader_];
        for (; i < n; ++i) {
            if (i >= atLeast && gasleft() < LEADER_SCAN_RESERVE) break;
            address a = players[i];
            int256 p = points[round][a];
            if (p > best) (best, leader_) = (p, a);
        }
        if (i < n) {
            _scanCursor[round] = i;
            _leader[round] = leader_;
            return UNKNOWN_REIGN;
        }
        if (best <= 0) leader_ = address(0);
        _leader[round] = leader_;
        _leaderStale[round] = false;
    }

    function _updateReign(uint256 round) internal {
        _setReign(round, _currentLeader(round));
    }

    function _setReign(uint256 round, address leader_) internal {
        if (uint160(leader_) > uint160(UNKNOWN_REIGN) && points[round][leader_] <= 0) leader_ = address(0);
        Reign storage g = _reign[round];
        address holder = g.holder;
        uint256 at = _reignClock(round);
        if (holder == UNKNOWN_REIGN) {
            if (leader_ == UNKNOWN_REIGN) {
                g.since = uint64(at);
                return;
            }
            at = g.since;
        } else {
            if (leader_ == holder) return;
            if (holder != address(0)) _reignSeconds[round][holder] += at - g.since;
        }
        g.holder = leader_;
        g.since = uint64(at);
        emit ReignChanged(round, leader_, at);
    }

    function _reignClock(uint256 round) internal view returns (uint256) {
        uint256 end = roundEnd(round);
        return block.timestamp < end ? block.timestamp : end;
    }

    function _positive(uint256 round, address player) internal view returns (uint256) {
        int256 p = points[round][player];
        return p > 0 ? uint256(p) : 0;
    }

    function _pushRecent(uint256 round, address player) internal {
        uint256 count = _recentCount[round];
        _recent[round][count % RECENT] = player;
        _recentCount[round] = count + 1;
    }

    function _lowestRecent(uint256 round, address leader_) internal view returns (address lowest) {
        uint256 count = _recentCount[round];
        uint256 n = count < RECENT ? count : RECENT;
        int256 low = type(int256).max;
        for (uint256 i; i < n; ++i) {
            address a = _recent[round][i];
            if (a == leader_) continue;
            int256 p = points[round][a];
            if (p < low) (low, lowest) = (p, a);
        }
    }

    function _outreigns(uint256 round, address a, uint256 sa, address b, uint256 sb) internal view returns (bool) {
        return sa > sb || (sa == sb && sa > 0 && points[round][a] > points[round][b]);
    }

    // ── Settlement and prizes ───────────────────────────────────────────────────

    /// Ranks a finished round, picks its King of the Hill and splits its pot (v2.1). A winner holding
    /// less than they bought through the arena that round keeps that share of the prize.
    function settle(uint256 round, uint256 maxPlayers) external returns (bool done) {
        if (block.timestamp < roundEnd(round) + SETTLE_DELAY) revert RoundNotOver();
        _pullTax();
        Result storage r = _results[round];
        if (r.settled) revert AlreadySettled();
        if (pendingFlips[round] > 0) revert FlipsPending();

        Reign storage g = _reign[round];
        if (uint160(g.holder) > uint160(UNKNOWN_REIGN)) {
            uint256 end = roundEnd(round);
            _reignSeconds[round][g.holder] += end - g.since;
            g.since = uint64(end);
        }

        address[] storage players = _players[round];
        uint256 end_ = players.length;
        if (end_ - r.cursor > maxPlayers) end_ = r.cursor + maxPlayers;
        address king = r.king;
        uint256 kingReign = r.kingReign;
        for (uint256 i = r.cursor; i < end_; ++i) {
            address a = players[i];
            uint256 s = _reignSeconds[round][a];
            if (_outreigns(round, a, s, king, kingReign)) (king, kingReign) = (a, s);
            int256 p = points[round][a];
            if (p <= 0) continue;
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
        uint256 awarded;
        for (uint256 i; i < 4; ++i) {
            address winner = _winner(r, i);
            if (winner == address(0)) continue;
            uint256 prize = shares[i];
            uint256 owed = bought[round][winner];
            uint256 balance = IBalanceOf(token).balanceOf(winner);
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
            address ref = referrerOf[winner];
            if (ref != address(0) && _joined[round][ref]) {
                uint256 cut = (prize * REFERRAL_PRIZE_BPS) / 10_000;
                referralEarnings[ref] += cut;
                awarded += cut;
                emit ReferralPrize(round, ref, winner, cut);
            }
        }
        uint256 rollover = total - awarded - buyback;
        r.settled = true;
        r.settledAt = uint64(block.timestamp);
        buybackReserve += buyback;
        if (rollover > 0) pot[currentRound()] += rollover;
        emit RoundSettled(round, r.top, r.king, r.prize, buyback, rollover, 0);
        return true;
    }

    function _winner(Result storage r, uint256 i) internal view returns (address) {
        return i < 3 ? r.top[i] : r.king;
    }

    /// Pays `msg.sender` everything they won in `round` (rank and King of the Hill together).
    function claim(uint256 round) external nonReentrant {
        Result storage r = _results[round];
        if (!r.settled) revert NotSettled();
        if (block.timestamp > claimDeadline(round)) revert ClaimWindowClosed();
        uint256 amount;
        uint256 balance = IBalanceOf(token).balanceOf(msg.sender);
        for (uint256 i; i < 4; ++i) {
            if (_winner(r, i) == msg.sender && !r.claimed[i] && r.prize[i] > 0) {
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

    function claimDeadline(uint256 round) public view returns (uint256) {
        uint256 end = roundEnd(round);
        uint256 settledAt = _results[round].settledAt;
        return (settledAt > end ? settledAt : end) + CLAIM_WINDOW;
    }

    function claimReferral() external nonReentrant {
        uint256 amount = referralEarnings[msg.sender];
        if (amount == 0) revert NothingToClaim();
        referralEarnings[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ReferralClaimed(msg.sender, amount);
    }

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

    /// Buys the token with `amount` of the buyback reserve through the router and sends it to 0x…dEaD.
    /// ETH the router doesn't spend goes back to the reserve.
    function buybackAndBurn(uint256 amount, uint256 minTokenOut) external onlyOperator nonReentrant {
        if (amount > buybackReserve) amount = buybackReserve;
        if (amount == 0) revert NothingToBurn();
        buybackReserve -= amount;
        (uint256 burned, uint256 refund) = _buy(amount, minTokenOut, DEAD);
        if (refund > 0) buybackReserve += refund;
        emit BuybackBurned(amount - refund, burned);
    }

    /// Reclaims the fee of a Dice request that was never revealed into the buyback reserve.
    function refundDiceRequest(uint64 sequence) external onlyOperator {
        dice.refundRequest(diceProvider, sequence);
    }

    /// Always 0: no host burn in the $PFWA game (kept for readers of v2's ABI).
    function hostBuybackReserve() external pure returns (uint256) {
        return 0;
    }

    // ── Admin: ownership, the operator, and the Flip switch. Nothing else. ───────

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

    function setOperator(address next) external onlyOwner {
        operator = next;
        emit OperatorChanged(next);
    }

    /// Switches Flip on or off (off while Dice Protocol is unreliable: a FLIP then plays as a BUY).
    /// Pending flips are unaffected: they still resolve or expire.
    function setFlipsEnabled(bool enabled) external onlyOwner {
        flipsEnabled = enabled;
        emit FlipsEnabledSet(enabled);
    }

    /// Sets the length of rounds from the next round boundary on (5 min, 15 min, 30 min, 1 h or 20 h):
    /// the round being played keeps its end. Before GENESIS it sets round 0's length. A second call before
    /// the boundary replaces the first.
    function setRoundLength(uint256 length) external onlyOwner {
        if (!_allowedLength(length)) revert BadRoundLength();
        if (block.timestamp < GENESIS) {
            _periods[0].length = uint64(length);
            emit RoundLengthSet(length, 0, GENESIS);
            return;
        }
        uint256 next = currentRound() + 1;
        uint256 boundary = roundEnd(next - 1);
        if (_periods[_periods.length - 1].start > block.timestamp) _periods.pop(); // the change not yet in force
        if (_periods[_periods.length - 1].length != length) {
            _periods.push(Period(uint64(next), uint64(boundary), uint64(length)));
        }
        emit RoundLengthSet(length, next, boundary);
    }

    /// Points the arena at the pool's buy-tax queue, once (the queue's recipient is fixed at launch, so
    /// this only decides which contract the arena asks to pay out, never where the tax goes).
    function setTaxQueue(address queue) external onlyOwner {
        if (taxQueue != address(0)) revert TaxQueueAlreadySet();
        taxQueue = queue;
        emit TaxQueueSet(queue);
    }

    // ── Views for the site (v2.1's) ─────────────────────────────────────────────

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

    function recentPlayers(uint256 round) external view returns (address[] memory players) {
        uint256 count = _recentCount[round];
        uint256 n = count < RECENT ? count : RECENT;
        players = new address[](n);
        for (uint256 i; i < n; ++i) {
            players[i] = _recent[round][(count - 1 - i) % RECENT];
        }
    }

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

    function heldToClaim(uint256 round, address player) external view returns (uint256) {
        Result storage r = _results[round];
        for (uint256 i; i < 4; ++i) {
            if (_winner(r, i) == player && r.prize[i] > 0) return r.held[i];
        }
        return 0;
    }

    function shieldCharges(uint256 round, address player) external view returns (uint256) {
        return shieldStats[round][player].charges;
    }

    function stealsLeft(address player) external view returns (uint256) {
        return _charges(_stealClock[player], STEAL_RECHARGE, STEAL_MAX_CHARGES);
    }

    function robinsLeft(address player) external view returns (uint256) {
        return _charges(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES);
    }

    function flipsLeft(address player) external view returns (uint256) {
        return _charges(_flipClock[player], _flipRecharge(), FLIP_MAX_CHARGES);
    }

    function nextCharges(address player) external view returns (uint256 steal, uint256 robin, uint256 flip) {
        steal = _nextCharge(_stealClock[player], STEAL_RECHARGE, STEAL_MAX_CHARGES);
        robin = _nextCharge(_robinClock[player], ROBIN_RECHARGE, ROBIN_MAX_CHARGES);
        flip = _nextCharge(_flipClock[player], _flipRecharge(), FLIP_MAX_CHARGES);
    }

    function _nextCharge(uint256 clock, uint256 recharge, uint256 cap) internal view returns (uint256) {
        uint256 n = (block.timestamp - clock) / recharge;
        return n >= cap ? 0 : clock + (n + 1) * recharge;
    }

    function reignHolder(uint256 round) external view returns (address) {
        return _reign[round].holder;
    }

    function reignOf(uint256 round, address player) public view returns (uint256 s) {
        s = _reignSeconds[round][player];
        Reign storage g = _reign[round];
        if (player != address(0) && player == g.holder) s += _reignClock(round) - g.since;
    }

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
}
