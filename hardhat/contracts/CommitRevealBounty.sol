// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CommitRevealBounty
 * @author RafliRealm (Discord: arokmub)
 * @github https://github.com/RafliRealm/ritual-chain-workshop
 * @notice Privacy-preserving AI Bounty Judge using commit-reveal scheme.
 *         Answers stay hidden during submission phase; revealed only after
 *         submission deadline. AI (Ritual) judges all revealed answers in
 *         one batch call. Human owner finalizes the winner.
 *
 * Lifecycle:
 *   createBounty → submitCommitment (x N) → [submissionDeadline] →
 *   revealAnswer (x N) → [revealDeadline] → judgeAll → finalizeWinner
 */
contract CommitRevealBounty {

    // -------------------------------------------------------------------------
    // Data structures
    // -------------------------------------------------------------------------

    struct Bounty {
        address owner;
        string  description;
        uint256 reward;               // wei locked in contract
        uint256 submissionDeadline;   // unix timestamp
        uint256 revealDeadline;       // unix timestamp, must be > submissionDeadline
        bool    judged;               // judgeAll() has been called
        bool    finalized;            // winner has been paid
        address winner;
        address[] participants;       // ordered list of committers
    }

    struct Submission {
        bytes32 commitment;   // keccak256(answer ++ salt ++ sender ++ bountyId)
        string  answer;       // empty until reveal
        bool    committed;
        bool    revealed;
        bool    eligible;     // revealed AND hash matched
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    uint256 public bountyCount;

    /// bountyId => Bounty
    mapping(uint256 => Bounty) private bounties;

    /// bountyId => participant address => Submission
    mapping(uint256 => mapping(address => Submission)) private submissions;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event BountyCreated(uint256 indexed bountyId, address indexed owner, uint256 reward);
    event CommitmentSubmitted(uint256 indexed bountyId, address indexed participant);
    event AnswerRevealed(uint256 indexed bountyId, address indexed participant);
    event RevealInvalid(uint256 indexed bountyId, address indexed participant, string reason);
    event BountyJudged(uint256 indexed bountyId);
    event WinnerFinalized(uint256 indexed bountyId, address indexed winner, uint256 reward);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotOwner();
    error BountyNotFound();
    error InvalidDeadlines();
    error InsufficientReward();
    error SubmissionPhaseClosed();
    error AlreadyCommitted();
    error RevealPhaseNotOpen();
    error RevealPhaseClosed();
    error NotCommitted();
    error AlreadyRevealed();
    error RevealPhaseStillOpen();
    error AlreadyJudged();
    error JudgingNotDone();
    error AlreadyFinalized();
    error InvalidWinnerIndex();
    error WinnerNotEligible();
    error TransferFailed();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner(uint256 bountyId) {
        if (bounties[bountyId].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        if (bounties[bountyId].owner == address(0)) revert BountyNotFound();
        _;
    }

    // -------------------------------------------------------------------------
    // Phase 0: Create bounty
    // -------------------------------------------------------------------------

    /**
     * @notice Create a new bounty. Send ETH/RITUAL as the reward.
     * @param description  Human-readable bounty prompt / question.
     * @param submissionDeadline  Unix timestamp after which no new commitments accepted.
     * @param revealDeadline      Unix timestamp after which no new reveals accepted.
     *                            Must be strictly greater than submissionDeadline.
     */
    function createBounty(
        string calldata description,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        if (submissionDeadline <= block.timestamp) revert InvalidDeadlines();
        if (revealDeadline <= submissionDeadline)  revert InvalidDeadlines();
        if (msg.value == 0) revert InsufficientReward();

        bountyId = ++bountyCount;
        Bounty storage b = bounties[bountyId];
        b.owner               = msg.sender;
        b.description         = description;
        b.reward              = msg.value;
        b.submissionDeadline  = submissionDeadline;
        b.revealDeadline      = revealDeadline;

        emit BountyCreated(bountyId, msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------
    // Phase 1: Commit
    // -------------------------------------------------------------------------

    /**
     * @notice Submit a commitment hash. Does NOT reveal the answer.
     * @dev    commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *         Compute off-chain, paste the bytes32 here.
     */
    function submitCommitment(uint256 bountyId, bytes32 commitment)
        external
        bountyExists(bountyId)
    {
        Bounty storage b = bounties[bountyId];

        if (block.timestamp >= b.submissionDeadline) revert SubmissionPhaseClosed();

        Submission storage s = submissions[bountyId][msg.sender];
        if (s.committed) revert AlreadyCommitted();

        s.commitment = commitment;
        s.committed  = true;

        b.participants.push(msg.sender);

        emit CommitmentSubmitted(bountyId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Phase 2: Reveal
    // -------------------------------------------------------------------------

    /**
     * @notice Reveal your answer and salt. Contract verifies against stored commitment.
     * @param answer  Your actual answer string (plaintext).
     * @param salt    Random bytes32 you used when hashing.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        // Reveal window: after submission deadline, before reveal deadline
        if (block.timestamp <= b.submissionDeadline) revert RevealPhaseNotOpen();
        if (block.timestamp >  b.revealDeadline)     revert RevealPhaseClosed();

        Submission storage s = submissions[bountyId][msg.sender];
        if (!s.committed)  revert NotCommitted();
        if (s.revealed)    revert AlreadyRevealed();

        s.revealed = true;

        // Verify hash
        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        if (expected == s.commitment) {
            s.answer   = answer;
            s.eligible = true;
            emit AnswerRevealed(bountyId, msg.sender);
        } else {
            // Invalid reveal — participant is ineligible but we don't revert
            // so they can't grief by submitting garbage repeatedly
            emit RevealInvalid(bountyId, msg.sender, "Hash mismatch");
        }
    }

    // -------------------------------------------------------------------------
    // Phase 3: Judge
    // -------------------------------------------------------------------------

    /**
     * @notice Call Ritual AI to judge all eligible revealed answers in one batch.
     * @dev    llmInput is the ABI-encoded or JSON payload passed to the Ritual
     *         Infernet compute node. In Remix testing you can pass any bytes.
     *         Only callable by owner after reveal deadline.
     *
     *         NOTE: In a full Ritual integration this function would call the
     *         Infernet Coordinator precompile to trigger an off-chain LLM job.
     *         For this homework the event signals that judging was requested;
     *         finalizeWinner carries the result.
     */
    function judgeAll(uint256 bountyId, bytes calldata llmInput)
        external
        bountyExists(bountyId)
        onlyOwner(bountyId)
    {
        Bounty storage b = bounties[bountyId];

        if (block.timestamp <= b.revealDeadline) revert RevealPhaseStillOpen();
        if (b.judged)    revert AlreadyJudged();
        if (b.finalized) revert AlreadyFinalized();

        // Suppress unused variable warning in Remix
        // In production: pass llmInput to Infernet coordinator call
        llmInput;

        b.judged = true;
        emit BountyJudged(bountyId);
    }

    // -------------------------------------------------------------------------
    // Phase 4: Finalize
    // -------------------------------------------------------------------------

    /**
     * @notice Owner picks the winner (by index in participants array) and pays out.
     * @param winnerIndex  Index into bounties[bountyId].participants array.
     */
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex)
        external
        bountyExists(bountyId)
        onlyOwner(bountyId)
    {
        Bounty storage b = bounties[bountyId];

        if (!b.judged)    revert JudgingNotDone();
        if (b.finalized)  revert AlreadyFinalized();
        if (winnerIndex >= b.participants.length) revert InvalidWinnerIndex();

        address winner = b.participants[winnerIndex];
        Submission storage ws = submissions[bountyId][winner];
        if (!ws.eligible) revert WinnerNotEligible();

        b.winner    = winner;
        b.finalized = true;

        uint256 reward = b.reward;

        (bool ok, ) = winner.call{value: reward}("");
        if (!ok) revert TransferFailed();

        emit WinnerFinalized(bountyId, winner, reward);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    function getBounty(uint256 bountyId) external view returns (
        address owner,
        string memory description,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline,
        bool judged,
        bool finalized,
        address winner,
        uint256 participantCount
    ) {
        Bounty storage b = bounties[bountyId];
        return (
            b.owner,
            b.description,
            b.reward,
            b.submissionDeadline,
            b.revealDeadline,
            b.judged,
            b.finalized,
            b.winner,
            b.participants.length
        );
    }

    function getParticipant(uint256 bountyId, uint256 index)
        external view returns (address)
    {
        return bounties[bountyId].participants[index];
    }

    function getSubmission(uint256 bountyId, address participant) external view returns (
        bytes32 commitment,
        string memory answer,
        bool committed,
        bool revealed,
        bool eligible
    ) {
        Submission storage s = submissions[bountyId][participant];
        return (s.commitment, s.answer, s.committed, s.revealed, s.eligible);
    }

    /**
     * @notice Helper to compute the commitment hash off-chain equivalent.
     *         Call this view function from Remix to generate your commitment
     *         before calling submitCommitment().
     */
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address sender,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, sender, bountyId));
    }

    /**
     * @notice Returns all eligible revealed answers for a bounty.
     *         Used to build the llmInput payload for judgeAll().
     */
    function getEligibleAnswers(uint256 bountyId) external view returns (
        address[] memory participants,
        string[] memory answers
    ) {
        Bounty storage b = bounties[bountyId];
        uint256 count = 0;

        for (uint256 i = 0; i < b.participants.length; i++) {
            if (submissions[bountyId][b.participants[i]].eligible) count++;
        }

        participants = new address[](count);
        answers      = new string[](count);
        uint256 idx  = 0;

        for (uint256 i = 0; i < b.participants.length; i++) {
            address p = b.participants[i];
            if (submissions[bountyId][p].eligible) {
                participants[idx] = p;
                answers[idx]      = submissions[bountyId][p].answer;
                idx++;
            }
        }
    }
}
