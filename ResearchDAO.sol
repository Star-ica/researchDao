// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ResearchDAO
/// @notice Modules in one contract: researcher registry, proposal factory, round manager,
/// treasury + contribution accounting, governance voting, milestone manager, disbursement, refunds.
/// Voting is WALLET-based (one vote per address per proposal). It is NOT proof of unique humans.
/// Only hashes/URIs are stored onchain; never put confidential research or personal data here.
contract ResearchDAO is ReentrancyGuard {
    using SafeERC20 for IERC20;
    enum Status { None, Voting, Funding, Active, Completed, Rejected, Failed, Cancelled }
    enum MState { Pending, Submitted, Verified, Paid }

    struct Researcher { string name; string profileURI; bytes32 profileHash; bool registered; }
    struct Round { string name; IERC20 token; uint256 maxBudget; uint64 votingPeriod; uint64 fundingPeriod;
        uint256 quorum; uint8 reviewThreshold; bool open; }
    struct Milestone { string description; uint256 amount; MState state; bytes32 evidenceHash; string evidenceURI; uint8 approvals; }
    struct Proposal { uint256 roundId; address researcher; string title; string category; string metadataURI;
        bytes32 metadataHash; uint256 budget; uint256 raised; uint256 paid; Status status;
        uint64 voteEnd; uint64 fundEnd; uint256 yes; uint256 no; uint8 reviewApprovals; }

    address public admin;
    mapping(address => bool) public reviewers;
    mapping(address => Researcher) public researchers;
    Round[] public rounds;
    Proposal[] internal proposals;
    mapping(uint256 => Milestone[]) internal milestones;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public hasReviewed;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasVerified;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => mapping(address => bool)) public refunded;

    event ResearcherRegistered(address indexed who, bytes32 profileHash);
    event RoundCreated(uint256 indexed id, string name, address token);
    event ProposalCreated(uint256 indexed id, uint256 indexed roundId, address indexed researcher, uint256 budget);
    event Voted(uint256 indexed id, address indexed voter, bool support);
    event Reviewed(uint256 indexed id, address indexed reviewer, bool approve);
    event StatusChanged(uint256 indexed id, Status status);
    event Contributed(uint256 indexed id, address indexed funder, uint256 amount);
    event MilestoneSubmitted(uint256 indexed id, uint256 index, bytes32 evidenceHash);
    event MilestoneVerified(uint256 indexed id, uint256 index);
    event Disbursed(uint256 indexed id, uint256 index, address indexed to, uint256 amount);
    event Refunded(uint256 indexed id, address indexed funder, uint256 amount);

    modifier onlyAdmin() { require(msg.sender == admin, "admin"); _; }
    modifier onlyReviewer() { require(reviewers[msg.sender], "reviewer"); _; }
    constructor() { admin = msg.sender; }

    // ---- administration ----
    function setReviewer(address r, bool on) external onlyAdmin { reviewers[r] = on; }
    function transferAdmin(address a) external onlyAdmin { require(a != address(0)); admin = a; }
    function createRound(string calldata name, IERC20 token, uint256 maxBudget, uint64 votingPeriod,
        uint64 fundingPeriod, uint256 quorum, uint8 reviewThreshold) external onlyAdmin returns (uint256 id) {
        require(address(token) != address(0) && maxBudget > 0 && votingPeriod > 0 && fundingPeriod > 0 && reviewThreshold > 0, "cfg");
        rounds.push(Round(name, token, maxBudget, votingPeriod, fundingPeriod, quorum, reviewThreshold, true));
        id = rounds.length - 1; emit RoundCreated(id, name, address(token));
    }
    function closeRound(uint256 id) external onlyAdmin { rounds[id].open = false; }

    // ---- researcher registry ----
    function registerResearcher(string calldata name, string calldata uri, bytes32 h) external {
        require(bytes(name).length > 0, "name");
        researchers[msg.sender] = Researcher(name, uri, h, true); emit ResearcherRegistered(msg.sender, h);
    }

    // ---- proposal factory ----
    function submitProposal(uint256 roundId, string calldata title, string calldata category, string calldata uri,
        bytes32 h, string[] calldata descs, uint256[] calldata amounts) external returns (uint256 id) {
        require(researchers[msg.sender].registered, "register first");
        Round storage r = rounds[roundId]; require(r.open, "round closed");
        require(descs.length > 0 && descs.length == amounts.length && descs.length <= 20, "milestones");
        uint256 total; for (uint256 i; i < amounts.length; i++) { require(amounts[i] > 0, "zero"); total += amounts[i]; }
        require(total <= r.maxBudget, "over round cap");
        id = proposals.length;
        proposals.push(Proposal(roundId, msg.sender, title, category, uri, h, total, 0, 0, Status.Voting,
            uint64(block.timestamp) + r.votingPeriod, 0, 0, 0, 0));
        for (uint256 i; i < descs.length; i++) milestones[id].push(Milestone(descs[i], amounts[i], MState.Pending, 0, "", 0));
        emit ProposalCreated(id, roundId, msg.sender, total);
    }

    // ---- governance ----
    function vote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        require(p.status == Status.Voting && block.timestamp <= p.voteEnd, "not voting");
        require(!hasVoted[id][msg.sender], "voted"); hasVoted[id][msg.sender] = true;
        if (support) p.yes++; else p.no++;
        emit Voted(id, msg.sender, support);
    }
    function review(uint256 id, bool approve) external onlyReviewer {
        Proposal storage p = proposals[id]; require(p.status == Status.Voting, "not voting");
        require(!hasReviewed[id][msg.sender], "reviewed"); hasReviewed[id][msg.sender] = true;
        if (approve) p.reviewApprovals++; else { p.status = Status.Rejected; emit StatusChanged(id, Status.Rejected); }
        emit Reviewed(id, msg.sender, approve);
    }
    function finalizeVoting(uint256 id) external {
        Proposal storage p = proposals[id]; Round storage r = rounds[p.roundId];
        require(p.status == Status.Voting && block.timestamp > p.voteEnd, "early");
        if (p.yes + p.no >= r.quorum && p.yes > p.no && p.reviewApprovals >= r.reviewThreshold) {
            p.status = Status.Funding; p.fundEnd = uint64(block.timestamp) + r.fundingPeriod;
        } else p.status = Status.Rejected;
        emit StatusChanged(id, p.status);
    }

    // ---- treasury & contributions ----
    function contribute(uint256 id, uint256 amount) external nonReentrant {
        Proposal storage p = proposals[id];
        require(p.status == Status.Funding && block.timestamp <= p.fundEnd, "not funding");
        require(amount > 0 && p.raised + amount <= p.budget, "over budget");
        p.raised += amount; contributions[id][msg.sender] += amount;
        rounds[p.roundId].token.safeTransferFrom(msg.sender, address(this), amount);
        emit Contributed(id, msg.sender, amount);
        if (p.raised == p.budget) { p.status = Status.Active; emit StatusChanged(id, Status.Active); }
    }
    function finalizeFunding(uint256 id) external {
        Proposal storage p = proposals[id];
        require(p.status == Status.Funding && block.timestamp > p.fundEnd, "early");
        p.status = Status.Failed; emit StatusChanged(id, Status.Failed);
    }
    function cancel(uint256 id) external {
        Proposal storage p = proposals[id];
        require(msg.sender == p.researcher || msg.sender == admin, "auth");
        require(p.status == Status.Voting || p.status == Status.Funding || p.status == Status.Active, "final");
        p.status = Status.Cancelled; emit StatusChanged(id, Status.Cancelled);
    }

    // ---- milestones ----
    function submitMilestone(uint256 id, uint256 i, bytes32 evidenceHash, string calldata uri) external {
        Proposal storage p = proposals[id]; require(msg.sender == p.researcher && p.status == Status.Active, "auth");
        Milestone storage m = milestones[id][i]; require(m.state == MState.Pending, "state");
        require(i == 0 || milestones[id][i - 1].state == MState.Paid, "sequential");
        m.state = MState.Submitted; m.evidenceHash = evidenceHash; m.evidenceURI = uri;
        emit MilestoneSubmitted(id, i, evidenceHash);
    }
    function verifyMilestone(uint256 id, uint256 i, bool approve) external onlyReviewer {
        Milestone storage m = milestones[id][i]; require(m.state == MState.Submitted, "state");
        require(!hasVerified[id][i][msg.sender], "verified"); hasVerified[id][i][msg.sender] = true;
        if (!approve) { m.state = MState.Pending; m.approvals = 0; return; } // researcher must resubmit
        if (++m.approvals >= rounds[proposals[id].roundId].reviewThreshold) { m.state = MState.Verified; emit MilestoneVerified(id, i); }
    }
    /// @notice Admin authorizes payment; each milestone can only be paid once.
    function authorizePayment(uint256 id, uint256 i) external onlyAdmin nonReentrant {
        Proposal storage p = proposals[id]; Milestone storage m = milestones[id][i];
        require(p.status == Status.Active && m.state == MState.Verified, "not payable");
        require(p.paid + m.amount <= p.raised, "over budget");
        m.state = MState.Paid; p.paid += m.amount;
        if (p.paid == p.budget) { p.status = Status.Completed; emit StatusChanged(id, Status.Completed); }
        rounds[p.roundId].token.safeTransfer(p.researcher, m.amount);
        emit Disbursed(id, i, p.researcher, m.amount);
    }

    // ---- refunds (rejected / failed / cancelled): pro-rata share of undisbursed funds ----
    function refund(uint256 id) external nonReentrant {
        Proposal storage p = proposals[id];
        require(p.status == Status.Rejected || p.status == Status.Failed || p.status == Status.Cancelled, "no refund");
        require(!refunded[id][msg.sender], "claimed");
        uint256 c = contributions[id][msg.sender]; require(c > 0, "none");
        refunded[id][msg.sender] = true;
        uint256 amt = (c * (p.raised - p.paid)) / p.raised;
        rounds[p.roundId].token.safeTransfer(msg.sender, amt); emit Refunded(id, msg.sender, amt);
    }

    // ---- views ----
    function proposalCount() external view returns (uint256) { return proposals.length; }
    function roundCount() external view returns (uint256) { return rounds.length; }
    function getProposal(uint256 id) external view returns (Proposal memory) { return proposals[id]; }
    function getMilestones(uint256 id) external view returns (Milestone[] memory) { return milestones[id]; }
}
