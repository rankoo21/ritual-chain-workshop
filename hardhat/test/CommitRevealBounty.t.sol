// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealBounty} from "../contracts/CommitRevealBounty.sol";

/// @dev Test harness: makes the AI-judging hook deterministic so we can test
///      the commit-reveal core without a live LLM precompile. The override
///      simply echoes the batch input (the base behavior) and records the call.
contract HarnessBounty is CommitRevealBounty {
    uint256 public judgeCalls;
    bytes public lastInput;

    function _runJudge(
        uint256 bountyId,
        bytes calldata llmInput
    ) internal override returns (bytes memory) {
        judgeCalls++;
        lastInput = llmInput;
        return abi.encodePacked("review:", llmInput);
    }
}

contract CommitRevealBountyTest is Test {
    HarnessBounty internal bounty;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant REWARD = 1 ether;
    uint256 internal submissionDeadline;
    uint256 internal revealDeadline;

    function setUp() public {
        bounty = new HarnessBounty();
        vm.deal(owner, 10 ether);
        submissionDeadline = block.timestamp + 1 days;
        revealDeadline = block.timestamp + 2 days;
    }

    // --- helpers -----------------------------------------------------------

    function _createBounty() internal returns (uint256 id) {
        vm.prank(owner);
        id = bounty.createBounty{value: REWARD}(
            "Best haiku",
            "Judge on creativity and form.",
            submissionDeadline,
            revealDeadline
        );
    }

    function _commit(
        uint256 id,
        address who,
        string memory answer,
        bytes32 salt
    ) internal returns (bytes32 commitment) {
        commitment = bounty.computeCommitment(answer, salt, who, id);
        vm.prank(who);
        bounty.submitCommitment(id, commitment);
    }

    // --- creation ----------------------------------------------------------

    function test_CreateBounty_StoresStateAndPhase() public {
        uint256 id = _createBounty();
        (
            address bOwner,
            string memory title,
            ,
            uint256 reward,
            ,
            ,
            bool judged,
            bool finalized,
            uint256 count,
            ,

        ) = bounty.getBounty(id);

        assertEq(bOwner, owner);
        assertEq(title, "Best haiku");
        assertEq(reward, REWARD);
        assertFalse(judged);
        assertFalse(finalized);
        assertEq(count, 0);
        assertEq(
            uint256(bounty.currentPhase(id)),
            uint256(CommitRevealBounty.Phase.Submission)
        );
    }

    function test_CreateBounty_RevertNoReward() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reward required"));
        bounty.createBounty("t", "r", submissionDeadline, revealDeadline);
    }

    function test_CreateBounty_RevertBadDeadlines() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reveal must follow submission"));
        bounty.createBounty{value: REWARD}(
            "t",
            "r",
            submissionDeadline,
            submissionDeadline // reveal not after submission
        );
    }

    // --- commit phase ------------------------------------------------------

    function test_Commit_HidesAnswer() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a secret poem", keccak256("salt-a"));

        (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        ) = bounty.getSubmission(id, 0);

        assertEq(submitter, alice);
        assertTrue(commitment != bytes32(0));
        assertFalse(revealed);
        // The plaintext is NOT observable during submission.
        assertEq(bytes(answer).length, 0);
    }

    function test_Commit_RevertDoubleCommit() public {
        uint256 id = _createBounty();
        _commit(id, alice, "poem", keccak256("salt-a"));

        bytes32 c = bounty.computeCommitment("poem2", keccak256("s2"), alice, id);
        vm.prank(alice);
        vm.expectRevert(bytes("already committed"));
        bounty.submitCommitment(id, c);
    }

    function test_Commit_RevertEmptyCommitment() public {
        uint256 id = _createBounty();
        vm.prank(alice);
        vm.expectRevert(bytes("empty commitment"));
        bounty.submitCommitment(id, bytes32(0));
    }

    function test_Commit_RevertAfterDeadline() public {
        uint256 id = _createBounty();
        vm.warp(submissionDeadline);
        bytes32 c = bounty.computeCommitment("x", keccak256("s"), alice, id);
        vm.prank(alice);
        vm.expectRevert(bytes("submissions closed"));
        bounty.submitCommitment(id, c);
    }

    // --- reveal: happy path ------------------------------------------------

    function test_Reveal_Valid() public {
        uint256 id = _createBounty();
        bytes32 salt = keccak256("salt-a");
        _commit(id, alice, "winning answer", salt);

        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "winning answer", salt);

        (, , bool revealed, string memory answer) = bounty.getSubmission(id, 0);
        assertTrue(revealed);
        assertEq(answer, "winning answer");
        assertEq(bounty.revealedCount(id), 1);
    }

    // --- reveal: failure cases ---------------------------------------------

    function test_Reveal_RevertWrongSalt() public {
        uint256 id = _createBounty();
        _commit(id, alice, "answer", keccak256("right-salt"));

        vm.warp(submissionDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        bounty.revealAnswer(id, "answer", keccak256("wrong-salt"));
    }

    function test_Reveal_RevertWrongAnswer() public {
        uint256 id = _createBounty();
        bytes32 salt = keccak256("salt");
        _commit(id, alice, "real answer", salt);

        vm.warp(submissionDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        bounty.revealAnswer(id, "tampered answer", salt);
    }

    function test_Reveal_RevertImpersonation() public {
        // Bob cannot reveal Alice's answer: the commitment binds msg.sender.
        uint256 id = _createBounty();
        bytes32 salt = keccak256("salt");
        _commit(id, alice, "alice answer", salt);

        vm.warp(submissionDeadline);
        // Bob never committed at all.
        vm.prank(bob);
        vm.expectRevert(bytes("no commitment"));
        bounty.revealAnswer(id, "alice answer", salt);
    }

    function test_Reveal_RevertCrossBountyReplay() public {
        // A commitment from bounty 1 cannot be reused to reveal in bounty 2,
        // because bountyId is part of the hash.
        uint256 id1 = _createBounty();
        uint256 id2 = _createBounty();
        bytes32 salt = keccak256("salt");

        // Alice commits the SAME hash (computed for id1) into id2.
        bytes32 c1 = bounty.computeCommitment("answer", salt, alice, id1);
        vm.prank(alice);
        bounty.submitCommitment(id2, c1);

        vm.warp(submissionDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        bounty.revealAnswer(id2, "answer", salt);
    }

    function test_Reveal_RevertBeforeSubmissionDeadline() public {
        uint256 id = _createBounty();
        bytes32 salt = keccak256("salt");
        _commit(id, alice, "answer", salt);

        // Still in submission window — reveals not open yet.
        vm.prank(alice);
        vm.expectRevert(bytes("reveal not started"));
        bounty.revealAnswer(id, "answer", salt);
    }

    function test_Reveal_RevertAfterRevealDeadline() public {
        uint256 id = _createBounty();
        bytes32 salt = keccak256("salt");
        _commit(id, alice, "answer", salt);

        vm.warp(revealDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("reveal closed"));
        bounty.revealAnswer(id, "answer", salt);
    }

    function test_Reveal_RevertDoubleReveal() public {
        uint256 id = _createBounty();
        bytes32 salt = keccak256("salt");
        _commit(id, alice, "answer", salt);

        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "answer", salt);

        vm.prank(alice);
        vm.expectRevert(bytes("already revealed"));
        bounty.revealAnswer(id, "answer", salt);
    }

    function test_Reveal_RevertAnswerTooLong() public {
        uint256 id = _createBounty();
        bytes memory big = new bytes(bounty.MAX_ANSWER_LENGTH() + 1);
        string memory answer = string(big);
        bytes32 salt = keccak256("salt");
        // Commit to the oversized answer so the length check is what trips.
        bytes32 c = bounty.computeCommitment(answer, salt, alice, id);
        vm.prank(alice);
        bounty.submitCommitment(id, c);

        vm.warp(submissionDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("answer too long"));
        bounty.revealAnswer(id, answer, salt);
    }

    // --- judging -----------------------------------------------------------

    function test_JudgeAll_BatchesRevealedAnswers() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        _commit(id, bob, "b", keccak256("sb"));

        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));
        vm.prank(bob);
        bounty.revealAnswer(id, "b", keccak256("sb"));

        vm.warp(revealDeadline);
        vm.prank(owner);
        bounty.judgeAll(id, bytes("batch-llm-input"));

        // Exactly one batch judging call for all answers.
        assertEq(bounty.judgeCalls(), 1);
        (, , , , , , bool judged, , , , bytes memory review) = bounty.getBounty(id);
        assertTrue(judged);
        assertEq(review, abi.encodePacked("review:", bytes("batch-llm-input")));
    }

    function test_JudgeAll_RevertNotOwner() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(revealDeadline);

        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        bounty.judgeAll(id, bytes("x"));
    }

    function test_JudgeAll_RevertWhileRevealOpen() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));

        vm.prank(owner);
        vm.expectRevert(bytes("reveal still open"));
        bounty.judgeAll(id, bytes("x"));
    }

    function test_JudgeAll_RevertNoRevealedAnswers() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa")); // committed but never revealed
        vm.warp(revealDeadline);

        vm.prank(owner);
        vm.expectRevert(bytes("no revealed answers"));
        bounty.judgeAll(id, bytes("x"));
    }

    function test_JudgeAll_RevertDoubleJudge() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(revealDeadline);

        vm.prank(owner);
        bounty.judgeAll(id, bytes("x"));
        vm.prank(owner);
        vm.expectRevert(bytes("already judged"));
        bounty.judgeAll(id, bytes("x"));
    }

    // --- finalize ----------------------------------------------------------

    function test_FinalizeWinner_PaysRevealedWinner() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        _commit(id, bob, "b", keccak256("sb"));
        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));
        vm.prank(bob);
        bounty.revealAnswer(id, "b", keccak256("sb"));
        vm.warp(revealDeadline);
        vm.prank(owner);
        bounty.judgeAll(id, bytes("x"));

        uint256 before = bob.balance;
        vm.prank(owner);
        bounty.finalizeWinner(id, 1); // bob

        assertEq(bob.balance, before + REWARD);
        (, , , , , , , bool finalized, , uint256 winnerIndex, ) = bounty
            .getBounty(id);
        assertTrue(finalized);
        assertEq(winnerIndex, 1);
    }

    function test_FinalizeWinner_RevertBeforeJudge() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(revealDeadline);

        vm.prank(owner);
        vm.expectRevert(bytes("not judged yet"));
        bounty.finalizeWinner(id, 0);
    }

    function test_FinalizeWinner_RevertUnrevealedWinner() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        _commit(id, bob, "b", keccak256("sb"));
        vm.warp(submissionDeadline);
        // Only alice reveals.
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(revealDeadline);
        vm.prank(owner);
        bounty.judgeAll(id, bytes("x"));

        // Bob (index 1) never revealed — cannot win.
        vm.prank(owner);
        vm.expectRevert(bytes("winner not revealed"));
        bounty.finalizeWinner(id, 1);
    }

    function test_FinalizeWinner_RevertDoubleFinalize() public {
        uint256 id = _createBounty();
        _commit(id, alice, "a", keccak256("sa"));
        vm.warp(submissionDeadline);
        vm.prank(alice);
        bounty.revealAnswer(id, "a", keccak256("sa"));
        vm.warp(revealDeadline);
        vm.prank(owner);
        bounty.judgeAll(id, bytes("x"));
        vm.prank(owner);
        bounty.finalizeWinner(id, 0);

        vm.prank(owner);
        vm.expectRevert(bytes("already finalized"));
        bounty.finalizeWinner(id, 0);
    }

    // --- fuzz: commitment binding -----------------------------------------

    function testFuzz_OnlyMatchingRevealSucceeds(
        string calldata answer,
        bytes32 salt,
        bytes32 wrongSalt
    ) public {
        vm.assume(salt != wrongSalt);
        vm.assume(bytes(answer).length <= bounty.MAX_ANSWER_LENGTH());

        uint256 id = _createBounty();
        bytes32 c = bounty.computeCommitment(answer, salt, alice, id);
        vm.prank(alice);
        bounty.submitCommitment(id, c);

        vm.warp(submissionDeadline);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        bounty.revealAnswer(id, answer, wrongSalt);
    }
}
