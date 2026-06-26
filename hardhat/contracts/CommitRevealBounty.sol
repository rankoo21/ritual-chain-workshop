// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CommitRevealBounty
/// @notice A privacy-preserving bounty judge using a commit-reveal scheme.
///         Participants first submit only a commitment hash, keeping their
///         answer hidden during the submission window. After the submission
///         deadline they reveal the plaintext answer + salt; the contract
///         verifies the commitment binds to (answer, salt, msg.sender,
///         bountyId). Only valid revealed answers are eligible for AI judging.
///
/// @dev    Works on any EVM chain. The AI-judging step is isolated behind the
///         internal `_runJudge` hook so the commit-reveal core is fully
///         testable on a plain EVM. On Ritual Chain, override `_runJudge` to
///         call the LLM inference precompile (0x0802) for batch judging.
contract CommitRevealBounty {
    // ----------------------------------------------------------------------
    // Constants
    // ----------------------------------------------------------------------

    uint256 public constant MAX_SUBMISSIONS = 50;
    uint256 public constant MAX_ANSWER_LENGTH = 4_000;

    // ----------------------------------------------------------------------
    // Types
    // ----------------------------------------------------------------------

    enum Phase {
        Submission, // accepting commitments
        Reveal, // submission deadline passed, accepting reveals
        Judged, // AI judging done, awaiting human finalization
        Finalized // winner paid out
    }

    struct Submission {
        address submitter;
        bytes32 commitment; // keccak256(answer, salt, submitter, bountyId)
        bool revealed;
        string answer; // empty until revealed
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commitments accepted strictly before this
        uint256 revealDeadline; // reveals accepted strictly before this
        bool judged;
        bool finalized;
        bytes aiReview; // raw AI output, kept for transparency/audit
        uint256 winnerIndex;
        Submission[] submissions;
    }

    // ----------------------------------------------------------------------
    // Storage
    // ----------------------------------------------------------------------

    uint256 public nextBountyId = 1;

    mapping(uint256 => Bounty) internal bounties;

    /// @dev Enforces one commitment per address per bounty. Prevents an
    ///      attacker from spamming multiple commitments to crowd out the slots.
    mapping(uint256 => mapping(address => bool)) public hasCommitted;

    // ----------------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------------

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ----------------------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------------------

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    // ----------------------------------------------------------------------
    // Lifecycle: create
    // ----------------------------------------------------------------------

    /// @notice Create a bounty funded with the attached reward.
    /// @param title              Human-readable bounty title.
    /// @param rubric             Public judging criteria the AI applies.
    /// @param submissionDeadline Timestamp; commitments accepted before it.
    /// @param revealDeadline     Timestamp; reveals accepted before it.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(
            submissionDeadline > block.timestamp,
            "submission deadline in past"
        );
        require(
            revealDeadline > submissionDeadline,
            "reveal must follow submission"
        );

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    // ----------------------------------------------------------------------
    // Lifecycle: commit
    // ----------------------------------------------------------------------

    /// @notice Submit a hidden answer as a commitment hash.
    /// @dev    The commitment MUST equal
    ///         keccak256(abi.encode(answer, salt, msg.sender, bountyId)).
    ///         Nothing about the answer is observable on-chain at this stage.
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp < bounty.submissionDeadline,
            "submissions closed"
        );
        require(commitment != bytes32(0), "empty commitment");
        require(!hasCommitted[bountyId][msg.sender], "already committed");
        require(
            bounty.submissions.length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        hasCommitted[bountyId][msg.sender] = true;

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                revealed: false,
                answer: ""
            })
        );

        emit CommitmentSubmitted(
            bountyId,
            bounty.submissions.length - 1,
            msg.sender,
            commitment
        );
    }

    // ----------------------------------------------------------------------
    // Lifecycle: reveal
    // ----------------------------------------------------------------------

    /// @notice Reveal a previously committed answer.
    /// @dev    Allowed only after the submission deadline and before the reveal
    ///         deadline. Verifies the commitment binds the answer to the salt,
    ///         the caller, and the bounty id — so no one can reveal on behalf
    ///         of another participant or replay a commitment across bounties.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.submissionDeadline,
            "reveal not started"
        );
        require(block.timestamp < bounty.revealDeadline, "reveal closed");
        require(!bounty.judged, "already judged");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 index = _findCommitment(bounty, msg.sender);

        Submission storage submission = bounty.submissions[index];
        require(!submission.revealed, "already revealed");

        bytes32 expected = computeCommitment(
            answer,
            salt,
            msg.sender,
            bountyId
        );
        require(expected == submission.commitment, "commitment mismatch");

        submission.revealed = true;
        submission.answer = answer;

        emit AnswerRevealed(bountyId, index, msg.sender);
    }

    // ----------------------------------------------------------------------
    // Lifecycle: judge
    // ----------------------------------------------------------------------

    /// @notice Run AI judging over every revealed answer in one batch.
    /// @dev    Only the bounty owner can trigger judging, only after the reveal
    ///         window closes, and only if at least one answer was revealed.
    ///         `llmInput` is the pre-encoded batch request the AI executor
    ///         consumes (one call for all answers, not one per answer).
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.revealDeadline,
            "reveal still open"
        );
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(_revealedCount(bounty) > 0, "no revealed answers");

        bytes memory aiReview = _runJudge(bountyId, llmInput);

        bounty.judged = true;
        bounty.aiReview = aiReview;

        emit AllAnswersJudged(bountyId, aiReview);
    }

    // ----------------------------------------------------------------------
    // Lifecycle: finalize
    // ----------------------------------------------------------------------

    /// @notice Finalize the human-chosen winner (informed by the AI review)
    ///         and release the reward. The winning submission must have been
    ///         revealed and valid.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");

        Submission storage winning = bounty.submissions[winnerIndex];
        require(winning.revealed, "winner not revealed");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = winning.submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ----------------------------------------------------------------------
    // AI judging hook (overridable)
    // ----------------------------------------------------------------------

    /// @notice Override on Ritual Chain to call the LLM inference precompile
    ///         (0x0802) with the batch `llmInput`. The base implementation is a
    ///         pass-through so commit-reveal logic stays chain-agnostic and
    ///         unit-testable on any EVM.
    function _runJudge(
        uint256 /* bountyId */,
        bytes calldata llmInput
    ) internal virtual returns (bytes memory) {
        return llmInput;
    }

    // ----------------------------------------------------------------------
    // Pure helpers
    // ----------------------------------------------------------------------

    /// @notice Canonical commitment derivation. Clients hash the same tuple
    ///         off-chain before calling `submitCommitment`.
    function computeCommitment(
        string memory answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(answer, salt, submitter, bountyId));
    }

    function _findCommitment(
        Bounty storage bounty,
        address submitter
    ) internal view returns (uint256) {
        uint256 length = bounty.submissions.length;
        for (uint256 i = 0; i < length; i++) {
            if (bounty.submissions[i].submitter == submitter) {
                return i;
            }
        }
        revert("no commitment");
    }

    function _revealedCount(
        Bounty storage bounty
    ) internal view returns (uint256 count) {
        uint256 length = bounty.submissions.length;
        for (uint256 i = 0; i < length; i++) {
            if (bounty.submissions[i].revealed) {
                count++;
            }
        }
    }

    // ----------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 totalSubmissions,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submissionDeadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    function currentPhase(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (Phase) {
        Bounty storage bounty = bounties[bountyId];
        if (bounty.finalized) return Phase.Finalized;
        if (bounty.judged) return Phase.Judged;
        if (block.timestamp < bounty.submissionDeadline) {
            return Phase.Submission;
        }
        return Phase.Reveal;
    }

    /// @notice Returns the commitment metadata for a submission. The plaintext
    ///         answer is only non-empty after a valid reveal — during the
    ///         submission window callers can see that a commitment exists but
    ///         never its contents.
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");
        Submission storage submission = bounty.submissions[index];
        return (
            submission.submitter,
            submission.commitment,
            submission.revealed,
            submission.answer
        );
    }

    function submissionCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return bounties[bountyId].submissions.length;
    }

    function revealedCount(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (uint256) {
        return _revealedCount(bounties[bountyId]);
    }
}
