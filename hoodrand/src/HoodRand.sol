// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {BLS} from "./vendor/BLS.sol";

/// @notice What a consumer implements: the same callback Dice Protocol / Pyth Entropy call.
interface IEntropyConsumer {
    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external;
}

/// @title HoodRand
/// @notice Verifiable randomness on Robinhood Chain from drand's evmnet beacon (the League of
/// Entropy: a new BLS signature on BN254 every 3 seconds). Nobody, the owner included, can predict
/// or bias a result:
///   1. A request is tied to a drand round at least DELAY_ROUNDS in the future, so its signature
///      doesn't exist yet when the request is made.
///   2. Anyone can submit that round's signature (our relayer does; so can the consumer or a
///      stranger). The contract checks it against the evmnet public key with the BN254 pairing
///      precompile, so only the real beacon value is accepted.
///   3. Each request's number is keccak256(round randomness, the consumer's own random input,
///      sequence): unique per request, unknowable before the round is published.
/// What the owner can do: set the fee (up to MAX_FEE), withdraw fees from answered requests, and
/// hand over ownership in two steps. Nothing else.
/// @dev Drop-in for Dice Protocol's interface (requestV2 / getFeeV2 / refundRequest and the
/// _entropyCallback callback), so contracts built for Dice can point here unchanged. The `provider`
/// arguments are accepted and ignored: this contract is its own provider.
/// Trust note: drand's security assumes its League of Entropy nodes don't collude past the
/// threshold; Robinhood Chain's sequencer sets block.timestamp, and DELAY_ROUNDS is the margin
/// against a timestamp lagging real time.
contract HoodRand {
    // ── drand evmnet ────────────────────────────────────────────────────────────
    uint256 public constant DRAND_GENESIS = 1727521075;
    uint256 public constant DRAND_PERIOD = 3;
    bytes32 public constant DRAND_CHAIN_HASH = 0x04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3;
    bytes internal constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    // ── Rules ───────────────────────────────────────────────────────────────────
    /// @notice A request is answered by the round DELAY_ROUNDS after the one current at request time
    /// (15 to 18 seconds later).
    uint64 public constant DELAY_ROUNDS = 5;
    /// @notice An unanswered request can be refunded to its consumer after this long.
    uint256 public constant REFUND_AFTER = 1 days;
    /// @notice The most callback gas a request can ask for.
    uint32 public constant MAX_GAS_LIMIT = 1_000_000;
    /// @notice The highest fee the owner can set.
    uint128 public constant MAX_FEE = 0.0002 ether;
    /// @notice Gas kept back for the bookkeeping after a callback.
    uint256 internal constant CALLBACK_OVERHEAD = 20_000;

    struct Request {
        address consumer;
        uint64 round;
        uint64 requestedAt;
        uint32 gasLimit;
        uint128 fee;
        bytes32 userRandom;
    }

    /// @notice Open requests by sequence number (deleted once answered or refunded).
    mapping(uint64 => Request) public requests;
    /// @notice A proven round's randomness, sha256(signature) as drand defines it (0 = not proven yet).
    mapping(uint64 => bytes32) public randomnessOf;
    /// @dev Sequences waiting on each round, in request order.
    mapping(uint64 => uint64[]) internal _waiting;
    /// @dev How far each round's waiting list has been answered.
    mapping(uint64 => uint256) internal _answered;

    uint64 public nextSequence = 1;
    uint128 public fee;
    /// @notice Fees from answered requests, withdrawable by the owner. Fees of open requests stay
    /// refundable to their consumers.
    uint256 public earned;
    address public owner;
    address public pendingOwner;

    event Requested(uint64 indexed sequence, address indexed consumer, uint64 indexed round, bytes32 userRandom, uint128 fee);
    event RoundProven(uint64 indexed round, bytes32 randomness, bytes signature);
    event Revealed(uint64 indexed sequence, address indexed consumer, bytes32 randomNumber, bool callbackOk);
    event Refunded(uint64 indexed sequence, address indexed consumer, uint128 fee);
    event FeeSet(uint128 fee);
    event Withdrawn(address to, uint256 amount);
    event OwnerProposed(address pendingOwner);
    event OwnerChanged(address owner);

    error WrongFee();
    error GasLimitTooHigh();
    error BadSignature();
    error NotProven();
    error UnknownRequest();
    error NotConsumer();
    error TooEarly();
    error AlreadyProven();
    error NotOwner();
    error FeeTooHigh();
    error NotEnoughGas();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner, uint128 _fee) {
        if (_fee > MAX_FEE) revert FeeTooHigh();
        owner = _owner;
        fee = _fee;
        emit OwnerChanged(_owner);
        emit FeeSet(_fee);
    }

    // ── Dice-compatible interface ───────────────────────────────────────────────

    /// @notice The fee for one request (flat; the callback gas is paid by whoever answers).
    function getFeeV2(address, uint32 gasLimit) external view returns (uint128) {
        if (gasLimit > MAX_GAS_LIMIT) revert GasLimitTooHigh();
        return fee;
    }

    /// @notice Ask for a random number. The caller gets `_entropyCallback(sequence, this, number)`
    /// with `gasLimit` gas once the request's round is proven.
    function requestV2(address, bytes32 userRandomNumber, uint32 gasLimit) external payable returns (uint64 sequence) {
        if (msg.value != fee) revert WrongFee();
        if (gasLimit > MAX_GAS_LIMIT) revert GasLimitTooHigh();
        sequence = nextSequence++;
        uint64 round = currentRound() + DELAY_ROUNDS;
        requests[sequence] = Request({
            consumer: msg.sender,
            round: round,
            requestedAt: uint64(block.timestamp),
            gasLimit: gasLimit,
            fee: uint128(msg.value),
            userRandom: userRandomNumber
        });
        _waiting[round].push(sequence);
        emit Requested(sequence, msg.sender, round, userRandomNumber, uint128(msg.value));
    }

    /// @notice A request nobody answered within REFUND_AFTER: its consumer gets the fee back. Not
    /// possible once its round is proven (the request can be answered instead).
    function refundRequest(address, uint64 sequence) external {
        Request memory r = requests[sequence];
        if (r.consumer == address(0)) revert UnknownRequest();
        if (msg.sender != r.consumer) revert NotConsumer();
        if (randomnessOf[r.round] != 0) revert AlreadyProven();
        if (block.timestamp < r.requestedAt + REFUND_AFTER) revert TooEarly();
        delete requests[sequence];
        emit Refunded(sequence, r.consumer, r.fee);
        (bool ok,) = r.consumer.call{value: r.fee}("");
        if (!ok) revert TransferFailed();
    }

    // ── Answering ──────────────────────────────────────────────────────────────

    /// @notice Prove a drand evmnet round with its signature (anyone can), then answer up to
    /// `maxAnswers` of the requests waiting on it. Proving an already proven round only answers.
    function reveal(uint64 round, bytes calldata signature, uint256 maxAnswers) external returns (uint256 answered) {
        if (randomnessOf[round] == 0) {
            if (signature.length != 64 || !verify(round, signature)) revert BadSignature();
            bytes32 randomness = sha256(signature);
            randomnessOf[round] = randomness;
            emit RoundProven(round, randomness, signature);
        }
        return _answer(round, maxAnswers);
    }

    /// @notice Answer more requests of a proven round (for rounds with more requests than one
    /// transaction can carry).
    function answer(uint64 round, uint256 maxAnswers) external returns (uint256) {
        if (randomnessOf[round] == 0) revert NotProven();
        return _answer(round, maxAnswers);
    }

    function _answer(uint64 round, uint256 maxAnswers) internal returns (uint256 count) {
        uint64[] storage list = _waiting[round];
        uint256 i = _answered[round];
        bytes32 randomness = randomnessOf[round];
        for (; i < list.length && count < maxAnswers; ++i) {
            uint64 sequence = list[i];
            Request memory r = requests[sequence];
            if (r.consumer == address(0)) continue; // refunded
            // The callback must get the gas it asked for: a relayer can't starve it into failing.
            if (gasleft() < (uint256(r.gasLimit) * 64) / 63 + CALLBACK_OVERHEAD) revert NotEnoughGas();
            delete requests[sequence];
            earned += r.fee;
            bytes32 number = keccak256(abi.encode(randomness, r.userRandom, sequence));
            (bool ok,) = r.consumer.call{gas: r.gasLimit}(
                abi.encodeCall(IEntropyConsumer._entropyCallback, (sequence, address(this), number))
            );
            emit Revealed(sequence, r.consumer, number, ok);
            ++count;
        }
        _answered[round] = i;
    }

    /// @notice True when `signature` is drand evmnet's signature for `round`.
    function verify(uint64 round, bytes calldata signature) public view returns (bool) {
        BLS.PointG1 memory sig = BLS.g1Unmarshal(signature);
        if (!BLS.isValidPointG1(sig)) return false;
        (bool callOk, bool pairingOk) = BLS.verifySingle(
            sig, publicKey(), BLS.hashToPoint(DST, abi.encodePacked(keccak256(abi.encodePacked(round))))
        );
        return callOk && pairingOk;
    }

    /// @notice drand evmnet's group public key (G2), from api.drand.sh/v2/beacons/evmnet/info.
    function publicKey() public pure returns (BLS.PointG2 memory) {
        return BLS.PointG2(
            [
                0x557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f,
                0x7e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382
            ],
            [
                0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b,
                0x95685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6
            ]
        );
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    /// @notice The drand round published at or before now (0 before evmnet's genesis).
    function currentRound() public view returns (uint64) {
        if (block.timestamp < DRAND_GENESIS) return 0;
        return uint64((block.timestamp - DRAND_GENESIS) / DRAND_PERIOD + 1);
    }

    /// @notice When `round` is published (unix seconds).
    function roundTime(uint64 round) public pure returns (uint256) {
        return round == 0 ? DRAND_GENESIS : DRAND_GENESIS + (round - 1) * DRAND_PERIOD;
    }

    /// @notice How many requests on `round` are still waiting for an answer (refunded ones included
    /// until the round is answered past them).
    function waiting(uint64 round) external view returns (uint256) {
        return _waiting[round].length - _answered[round];
    }

    // ── Owner ─────────────────────────────────────────────────────────────────

    function setFee(uint128 next) external onlyOwner {
        if (next > MAX_FEE) revert FeeTooHigh();
        fee = next;
        emit FeeSet(next);
    }

    /// @notice Withdraw fees from answered requests. Open requests' fees stay in the contract.
    function withdraw(address to, uint256 amount) external onlyOwner {
        if (amount > earned) amount = earned;
        earned -= amount;
        emit Withdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function setOwner(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnerProposed(next);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerChanged(owner);
    }
}
