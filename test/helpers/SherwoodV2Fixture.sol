// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SherwoodV2, IDiceEntropy} from "src/SherwoodV2.sol";

/// Test-controlled Dice transport. Callback gas and per-request fees are recorded at request time.
/// Refund eligibility is controlled by the test: this does not model the live provider's refund delay.
contract AuditDice {
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
            r.consumer.call{gas: r.gasLimit}(abi.encodeCall(SherwoodV2._entropyCallback, (seq, r.provider, random)));
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

/// Real v4 core, real unlock/settle/take accounting, and ordinary local ERC20s. No fork or storage edits.
abstract contract SherwoodV2Fixture is Test {
    using PoolIdLibrary for PoolKey;

    receive() external payable {}

    IPoolManager internal manager;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidityRouter;
    MockERC20 internal gameToken;
    MockERC20 internal hostToken;
    AuditDice internal dice;
    SherwoodV2 internal game;
    PoolKey internal gameKey;
    PoolKey internal burnKey;
    PoolKey internal hostKey;

    uint256 internal constant GENESIS = 1_791_835_200;
    uint160 internal constant PRICE_ONE = 79228162514264337593543950336;
    uint256 internal constant HOST_MIN = 100_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Game constants the hook keeps internal (its revision 2 made them so to fit under EIP-170); the
    // README documents the values. Pinned here so a silent change in the hook fails these tests.
    uint256 internal constant MIN_BUY = 0.001 ether;
    uint256 internal constant MAX_DICE_FEE = 0.0005 ether;
    uint256 internal constant FLIP_TIMEOUT = 10 minutes;
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
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        gameToken = new MockERC20("Game", "GAME", 18);
        hostToken = new MockERC20("Host", "HOST", 18);
        dice = new AuditDice();
        address hookAddress = address(uint160(0xA11D0000) | uint160(0x20CC));
        deployCodeTo(
            "SherwoodV2.sol:SherwoodV2",
            abi.encode(
                manager,
                Currency.wrap(address(gameToken)),
                Currency.wrap(address(hostToken)),
                HOST_MIN,
                IDiceEntropy(address(dice)),
                makeAddr("audit provider"),
                owner,
                GENESIS
            ),
            hookAddress
        );
        game = SherwoodV2(payable(hookAddress));
        gameKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(gameToken)), 9000, 180, IHooks(hookAddress));
        burnKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(gameToken)), 10_000, 100, IHooks(address(0)));
        hostKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(hostToken)), 3000, 60, IHooks(address(0)));
        vm.prank(owner);
        manager.initialize(gameKey, PRICE_ONE);
        manager.initialize(burnKey, PRICE_ONE);
        manager.initialize(hostKey, PRICE_ONE);
        gameToken.mint(address(this), 1e30);
        hostToken.mint(address(this), 1e30);
        gameToken.approve(address(liquidityRouter), type(uint256).max);
        hostToken.approve(address(liquidityRouter), type(uint256).max);
        _liquidity(gameKey, -59400, 59400, 10_000e18);
        _liquidity(burnKey, -60000, 60000, 1_000e18);
        _liquidity(hostKey, -60000, 60000, 1_000e18);
    }

    function _liquidity(PoolKey memory key_, int24 lower, int24 upper, int256 liquidity) internal {
        vm.deal(address(this), 50_000 ether);
        liquidityRouter.modifyLiquidity{value: 25_000 ether}(
            key_, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), ""
        );
    }

    function _configureBurns() internal {
        vm.startPrank(owner);
        game.setBuybackPool(burnKey);
        game.setHostBuybackPool(hostKey);
        vm.stopPrank();
    }

    function _buy(address who, uint256 amount, SherwoodV2.Move move) internal returns (BalanceDelta) {
        return _buyData(who, amount, abi.encode(uint256(move)));
    }

    function _buyData(address who, uint256 amount, bytes memory data) internal returns (BalanceDelta) {
        vm.deal(who, who.balance + amount);
        vm.prank(who, who);
        return router.swap{value: amount}(
            gameKey,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
    }

    function _sell(address who, uint256 amount) internal returns (BalanceDelta delta) {
        vm.startPrank(who, who);
        gameToken.approve(address(router), type(uint256).max);
        delta = router.swap(
            gameKey,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
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
