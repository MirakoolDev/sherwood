// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HoodRand, IEntropyConsumer} from "src/HoodRand.sol";

/// A consumer like Sherwood's hooks: requests through the Dice interface, records the callback.
contract Consumer is IEntropyConsumer {
    HoodRand public dice;
    uint64 public lastSequence;
    bytes32 public lastNumber;
    uint256 public calls;
    bool public revertOnCallback;
    uint256 public burn; // gas to burn in the callback
    uint256 public refunds;

    constructor(HoodRand d) {
        dice = d;
    }

    function ask(bytes32 userRandom, uint32 gasLimit) external payable returns (uint64) {
        return dice.requestV2{value: msg.value}(address(dice), userRandom, gasLimit);
    }

    function refund(uint64 sequence) external {
        dice.refundRequest(address(dice), sequence);
    }

    function setRevert(bool v) external {
        revertOnCallback = v;
    }

    function setBurn(uint256 g) external {
        burn = g;
    }

    function _entropyCallback(uint64 sequence, address provider, bytes32 randomNumber) external {
        require(msg.sender == address(dice) && provider == address(dice), "not dice");
        if (revertOnCallback) revert("nope");
        uint256 until = gasleft() > burn ? gasleft() - burn : 0;
        while (gasleft() > until) {}
        lastSequence = sequence;
        lastNumber = randomNumber;
        calls++;
    }

    receive() external payable {
        refunds += msg.value;
    }
}

contract HoodRandTest is Test {
    // Real drand evmnet rounds (api.drand.sh/v2/beacons/evmnet/rounds/<n>).
    uint64 constant R1 = 21899791;
    bytes constant SIG1 = hex"2999b68e34d5c5ee42111e1c78df599ccc27dcc00b283b8e2085f34d613cb5b51886183b80c1cb549cb59bf449f30f6aa4d08b63d44394edbfa275b4e26f16b6";
    uint64 constant R2 = 21899792;
    bytes constant SIG2 = hex"1d3e9924f1f07a1026e39d2f888980694220b8dd2586fe2da92b3961902904f81585712894e5c96da588454e1d44b03ffca23d50b715be3ea6ea5466b31ab3e9";
    uint64 constant R3 = 21899793;
    bytes constant SIG3 = hex"2cf52da6f3ad4613f8d8ba22cb53251566ad2eea67803a5f4b640517f8a76c171bd3f1cfa6249d78b8adf18204b1b9a261137f24f5f923f353b15a4bc2984d5e";
    uint64 constant R_EARLY = 2;
    bytes constant SIG_EARLY = hex"1dbfe644485f31e2a7978fb551b50933b0001e64397fd2b7dc4022e8e2fcdbc325798cea5506deec489c8db3b4697f6b1bb6be8934b95bd9c0db88923487d9ad";
    uint64 constant R_1000 = 1000;
    bytes constant SIG_1000 = hex"06fd5996329504d3a56b482d9222bf7205857d0a9559ddd216ca31a286f6a8cc0a120f021aac2f13553fb164f62bc3a5ca32c76dea88a777b39bcf3cac5fdbd6";

    uint128 constant FEE = 0.00002 ether;
    HoodRand dice;
    Consumer consumer;
    address owner = makeAddr("owner");

    function setUp() public {
        dice = new HoodRand(owner, FEE);
        consumer = new Consumer(dice);
        vm.deal(address(this), 10 ether);
    }

    /// Warp into the round that makes a request now land on `target`.
    function _warpToRequestFor(uint64 target) internal {
        vm.warp(dice.roundTime(target - dice.DELAY_ROUNDS()) + 1);
        assertEq(dice.currentRound() + dice.DELAY_ROUNDS(), target);
    }

    // ── The beacon check ─────────────────────────────────────────────────────

    function test_verifiesRealEvmnetRounds() public view {
        assertTrue(dice.verify(R1, SIG1));
        assertTrue(dice.verify(R2, SIG2));
        assertTrue(dice.verify(R3, SIG3));
        assertTrue(dice.verify(R_EARLY, SIG_EARLY));
        assertTrue(dice.verify(R_1000, SIG_1000));
    }

    function test_rejectsASignatureForAnotherRound() public view {
        assertFalse(dice.verify(R2, SIG1));
        assertFalse(dice.verify(R1 + 100, SIG1));
    }

    function test_rejectsATamperedSignature() public view {
        bytes memory bad = SIG1;
        bad[63] = bytes1(uint8(bad[63]) ^ 0x01);
        assertFalse(this.verifyExternal(R1, bad));
    }

    function verifyExternal(uint64 round, bytes calldata sig) external view returns (bool) {
        return dice.verify(round, sig);
    }

    function test_verificationGas() public {
        uint256 g = gasleft();
        dice.verify(R1, SIG1);
        uint256 used = g - gasleft();
        emit log_named_uint("verify gas", used);
        assertLt(used, 400_000);
    }

    // ── Requests and answers ─────────────────────────────────────────────────

    function test_requestIsTiedToAFutureRound() public {
        _warpToRequestFor(R1);
        uint64 seq = consumer.ask{value: FEE}(bytes32("user"), 100_000);
        (, uint64 round,,,,) = dice.requests(seq);
        assertEq(round, R1);
        assertGt(dice.roundTime(round), block.timestamp, "the round isn't published yet");
        assertEq(dice.waiting(R1), 1);
    }

    function test_revealAnswersWithTheRoundAndTheConsumersInput() public {
        _warpToRequestFor(R1);
        uint64 seq = consumer.ask{value: FEE}(bytes32("user"), 100_000);
        vm.warp(dice.roundTime(R1));
        uint256 answered = dice.reveal(R1, SIG1, 10);
        assertEq(answered, 1);
        assertEq(consumer.calls(), 1);
        assertEq(consumer.lastSequence(), seq);
        assertEq(consumer.lastNumber(), keccak256(abi.encode(sha256(SIG1), bytes32("user"), seq)));
        assertEq(dice.randomnessOf(R1), sha256(SIG1));
        assertEq(dice.earned(), FEE);
        (address c,,,,,) = dice.requests(seq);
        assertEq(c, address(0), "answered requests are deleted");
    }

    function test_twoRequestsOnOneRoundGetDifferentNumbers() public {
        _warpToRequestFor(R1);
        Consumer other = new Consumer(dice);
        consumer.ask{value: FEE}(bytes32("same"), 100_000);
        other.ask{value: FEE}(bytes32("same"), 100_000);
        dice.reveal(R1, SIG1, 10);
        assertTrue(consumer.lastNumber() != other.lastNumber());
    }

    function test_anyoneCanReveal() public {
        _warpToRequestFor(R1);
        consumer.ask{value: FEE}(bytes32("x"), 100_000);
        vm.prank(makeAddr("stranger"));
        dice.reveal(R1, SIG1, 10);
        assertEq(consumer.calls(), 1);
    }

    function test_aWrongSignatureIsRejected() public {
        _warpToRequestFor(R1);
        consumer.ask{value: FEE}(bytes32("x"), 100_000);
        vm.expectRevert(HoodRand.BadSignature.selector);
        dice.reveal(R1, SIG2, 10);
        vm.expectRevert(HoodRand.BadSignature.selector);
        dice.reveal(R1, hex"00", 10);
    }

    function test_aRevertingConsumerDoesntBlockTheRound() public {
        _warpToRequestFor(R1);
        Consumer bad = new Consumer(dice);
        bad.setRevert(true);
        bad.ask{value: FEE}(bytes32("a"), 100_000);
        consumer.ask{value: FEE}(bytes32("b"), 100_000);
        dice.reveal(R1, SIG1, 10);
        assertEq(bad.calls(), 0);
        assertEq(consumer.calls(), 1);
        assertEq(dice.waiting(R1), 0);
    }

    function test_theCallbackGetsTheGasItAskedFor() public {
        _warpToRequestFor(R1);
        consumer.setBurn(100_000); // a callback that really needs most of its 200k
        consumer.ask{value: FEE}(bytes32("a"), 200_000);
        dice.reveal(R1, SIG1, 0); // prove the round, answer nothing yet
        // Too little gas for the promised callback: answering reverts instead of starving it.
        (bool ok,) = address(dice).call{gas: 150_000}(abi.encodeCall(HoodRand.answer, (R1, 10)));
        assertFalse(ok);
        assertEq(consumer.calls(), 0);
        assertEq(dice.waiting(R1), 1, "still waiting");
        dice.answer(R1, 10);
        assertEq(consumer.calls(), 1);
    }

    function test_answeringInBatches() public {
        _warpToRequestFor(R1);
        for (uint256 i; i < 5; ++i) consumer.ask{value: FEE}(bytes32(i), 60_000);
        assertEq(dice.reveal(R1, SIG1, 2), 2);
        assertEq(dice.waiting(R1), 3);
        assertEq(dice.answer(R1, 10), 3);
        assertEq(consumer.calls(), 5);
        assertEq(dice.answer(R1, 10), 0);
    }

    function test_answerNeedsAProvenRound() public {
        vm.expectRevert(HoodRand.NotProven.selector);
        dice.answer(R1, 10);
    }

    // ── Fees and refunds ─────────────────────────────────────────────────────

    function test_feeMustMatch() public {
        _warpToRequestFor(R1);
        vm.expectRevert(HoodRand.WrongFee.selector);
        consumer.ask{value: FEE - 1}(bytes32("x"), 100_000);
        vm.expectRevert(HoodRand.GasLimitTooHigh.selector);
        consumer.ask{value: FEE}(bytes32("x"), 1_000_001);
        assertEq(dice.getFeeV2(address(0), 100_000), FEE);
    }

    function test_refundAfterADayIfUnanswered() public {
        _warpToRequestFor(R1);
        uint64 seq = consumer.ask{value: FEE}(bytes32("x"), 100_000);
        vm.expectRevert(HoodRand.TooEarly.selector);
        consumer.refund(seq);
        vm.expectRevert(HoodRand.NotConsumer.selector);
        dice.refundRequest(address(0), seq);
        vm.warp(block.timestamp + 1 days);
        consumer.refund(seq);
        assertEq(consumer.refunds(), FEE);
        // The round can still be proven; the refunded request is skipped.
        dice.reveal(R1, SIG1, 10);
        assertEq(consumer.calls(), 0);
        assertEq(dice.earned(), 0);
    }

    function test_noRefundOnceTheRoundIsProven() public {
        _warpToRequestFor(R1);
        Consumer bad = new Consumer(dice);
        bad.setRevert(true);
        uint64 seq = bad.ask{value: FEE}(bytes32("x"), 100_000);
        // Prove the round without answering (maxAnswers 0), then try to refund later.
        dice.reveal(R1, SIG1, 0);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(HoodRand.AlreadyProven.selector);
        bad.refund(seq);
    }

    function test_ownerSetsFeeWithinTheCapAndWithdrawsOnlyEarnedFees() public {
        vm.expectRevert(HoodRand.NotOwner.selector);
        dice.setFee(1);
        vm.startPrank(owner);
        vm.expectRevert(HoodRand.FeeTooHigh.selector);
        dice.setFee(0.0002 ether + 1);
        dice.setFee(0.00005 ether);
        vm.stopPrank();

        _warpToRequestFor(R1);
        consumer.ask{value: 0.00005 ether}(bytes32("a"), 100_000); // answered
        _warpToRequestFor(R2);
        consumer.ask{value: 0.00005 ether}(bytes32("b"), 100_000); // left open
        dice.reveal(R1, SIG1, 10);
        assertEq(dice.earned(), 0.00005 ether);

        address to = makeAddr("treasury");
        vm.prank(owner);
        dice.withdraw(to, 1 ether); // capped at earned
        assertEq(to.balance, 0.00005 ether);
        assertEq(address(dice).balance, 0.00005 ether, "the open request's fee stays refundable");
    }

    function test_twoStepOwnership() public {
        address next = makeAddr("next");
        vm.prank(owner);
        dice.setOwner(next);
        assertEq(dice.owner(), owner);
        vm.prank(next);
        dice.acceptOwner();
        assertEq(dice.owner(), next);
    }

    function testFuzz_numbersDependOnTheRoundRandomness(bytes32 userRandom) public {
        _warpToRequestFor(R1);
        uint64 seq = consumer.ask{value: FEE}(userRandom, 100_000);
        dice.reveal(R1, SIG1, 10);
        assertEq(consumer.lastNumber(), keccak256(abi.encode(sha256(SIG1), userRandom, seq)));
    }
}
