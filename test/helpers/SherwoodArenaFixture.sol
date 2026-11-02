// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SherwoodArena, IArenaRouter, IDiceEntropy} from "src/SherwoodArena.sol";

/// Pays ETH to a target from its own address: stands in for whatever Hookr contract pushes the pool's
/// buy tax to the arena (never the arena's router adapter).
contract TaxPusher {
    function push(address to) external payable {
        (bool ok,) = to.call{value: msg.value}("");
        require(ok, "tax push failed");
    }
}

/// Stand-in for the router adapter: buys the token at a fixed rate by minting it to the recipient.
/// Test knobs: a buy tax pushed to `taxTo` through a separate TaxPusher during the buy, ETH sent back
/// unspent (a partial fill), underpaying while ignoring `minOut`, pushing the tax from the router
/// itself, and a call made during the buy (re-entry attempts).
contract MockArenaRouter is IArenaRouter {
    MockERC20 public immutable token;
    TaxPusher public immutable pusher;
    uint256 public rate = 1e18; // tokens (18 decimals) per ETH
    uint256 public taxBps;
    address public taxTo;
    bool public taxFromRouter;
    uint256 public refundBps;
    bool public underpay;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentered;
    bytes public reentryError;
    uint256 public ethReceived;

    constructor(MockERC20 t) {
        token = t;
        pusher = new TaxPusher();
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setTax(uint256 bps, address to, bool fromRouter) external {
        (taxBps, taxTo, taxFromRouter) = (bps, to, fromRouter);
    }

    function setRefundBps(uint256 bps) external {
        refundBps = bps;
    }

    function setUnderpay(bool on) external {
        underpay = on;
    }

    function setReentry(address target, bytes calldata data) external {
        (reenterTarget, reenterData) = (target, data);
    }

    function buy(uint256 minOut, address recipient) external payable returns (uint256 out) {
        uint256 refund = (msg.value * refundBps) / 10_000;
        uint256 spent = msg.value - refund;
        uint256 tax = (spent * taxBps) / 10_000;
        if (tax > 0) {
            if (taxFromRouter) {
                (bool ok,) = taxTo.call{value: tax}("");
                require(ok, "router tax failed");
            } else {
                pusher.push{value: tax}(taxTo);
            }
        }
        if (reenterTarget != address(0)) {
            (bool ok, bytes memory err) = reenterTarget.call(reenterData);
            reentered = ok;
            reentryError = err;
        }
        out = ((spent - tax) * rate) / 1e18;
        if (underpay) out /= 2;
        else require(out >= minOut, "router: too little out");
        token.mint(recipient, out);
        ethReceived += spent - tax;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund failed");
        }
    }
}

/// Test-controlled Dice transport (as SherwoodV21Fixture's): callback gas and fees are recorded at
/// request time, refunds are test-controlled.
contract ArenaDice {
    struct Request {
        address consumer;
        address provider;
        uint128 paid;
        uint32 gasLimit;
        bool revealed;
        bool refunded;
    }

    uint128 public fee = 25_000_000_000_000;
    uint64 public nextSequence = 1;
    uint8 public failure; // 1: fee lookup fails, 2: request fails
    uint256 public received;
    uint256 public returned;
    mapping(uint64 => Request) public requests;

    function configure(uint128 nextFee, uint8 nextFailure) external {
        fee = nextFee;
        failure = nextFailure;
    }

    function getFeeV2(address, uint32) external view returns (uint128) {
        require(failure != 1, "fee lookup unavailable");
        return fee;
    }

    function requestV2(address provider, bytes32, uint32 gasLimit) external payable returns (uint64 seq) {
        require(failure != 2, "requests unavailable");
        require(msg.value == fee, "wrong fee");
        seq = nextSequence++;
        requests[seq] = Request(msg.sender, provider, fee, gasLimit, false, false);
        received += msg.value;
    }

    function reveal(uint64 seq, bytes32 random) external returns (bool success) {
        Request storage r = requests[seq];
        require(r.consumer != address(0) && !r.revealed && !r.refunded, "request closed");
        r.revealed = true;
        (success,) =
            r.consumer.call{gas: r.gasLimit}(abi.encodeCall(SherwoodArena._entropyCallback, (seq, r.provider, random)));
    }

    function refundRequest(address provider, uint64 seq) external {
        Request storage r = requests[seq];
        require(r.consumer == msg.sender && r.provider == provider, "wrong consumer/provider");
        require(!r.refunded && !r.revealed, "request closed");
        r.refunded = true;
        returned += r.paid;
        (bool ok,) = r.consumer.call{value: r.paid}("");
        require(ok, "refund failed");
    }
}

/// The arena with a mock router, a mock token and test-controlled Dice. No fork, no storage edits.
abstract contract SherwoodArenaFixture is Test {
    receive() external payable {}

    MockERC20 internal gameToken;
    MockArenaRouter internal router;
    ArenaDice internal dice;
    SherwoodArena internal game;

    uint256 internal constant GENESIS = 1_791_835_200;
    // Same 5% as v2.1's pot fee, so v2.1's pot arithmetic carries over.
    uint256 internal constant PLAY_FEE_BPS = 500;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MIN_BUY = 0.001 ether;
    uint256 internal constant MAX_DICE_FEE = 0.0005 ether;
    uint256 internal constant FLIP_TIMEOUT = 1 days;
    uint256 internal constant CLAIM_WINDOW = 7 days;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal referrer;

    function setUp() public virtual {
        vm.warp(GENESIS + 1);
        owner = makeAddr("audit owner");
        alice = makeAddr("audit alice");
        bob = makeAddr("audit bob");
        carol = makeAddr("audit carol");
        referrer = makeAddr("audit referrer");
        gameToken = new MockERC20("PFWA", "PFWA", 18);
        router = new MockArenaRouter(gameToken);
        dice = new ArenaDice();
        game = new SherwoodArena(
            address(gameToken),
            IArenaRouter(address(router)),
            IDiceEntropy(address(dice)),
            makeAddr("audit provider"),
            owner,
            GENESIS,
            PLAY_FEE_BPS,
            true, 20 hours
        );
    }

    function _buy(address who, uint256 amount, SherwoodArena.Move move) internal {
        _play(who, amount, uint8(move), address(0));
    }

    function _play(address who, uint256 amount, uint8 move, address ref) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        game.play{value: amount}(move, 0, ref);
    }

    /// v2.1's hook data, translated: abi.encode(move) or abi.encode(move, referrer word).
    function _buyData(address who, uint256 amount, bytes memory data) internal {
        uint256 move;
        address ref;
        if (data.length >= 32) move = abi.decode(data, (uint256));
        if (data.length >= 64) {
            (, uint256 word) = abi.decode(data, (uint256, uint256));
            if (word >> 160 == 0) ref = address(uint160(word));
        }
        _play(who, amount, move > 255 ? 255 : uint8(move), ref);
    }

    /// A sell: the player withdraws `amount` from their holdings and sells it elsewhere (the arena only
    /// sees the withdraw).
    function _sell(address who, uint256 amount) internal {
        vm.prank(who);
        game.withdraw(amount);
        gameToken.burn(who, amount);
    }

    function _finishRound(uint256 round) internal {
        vm.warp(game.roundEnd(round) + game.SETTLE_DELAY());
        assertTrue(game.settle(round, 100));
    }

    function _seed(uint256 round, uint256 amount) internal {
        vm.deal(address(this), amount);
        game.fundPot{value: amount}(round);
    }

    function _unpaid(uint256 round) internal view returns (uint256 amount) {
        (,,, uint256[3] memory prizes, bool[3] memory claimed,,, uint256 kingPrize, bool kingClaimed) =
            game.result(round);
        for (uint256 i; i < 3; ++i) {
            if (!claimed[i]) amount += prizes[i];
        }
        if (!kingClaimed) amount += kingPrize;
    }
}
