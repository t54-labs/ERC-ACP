// SPDX-License-Identifier: MIT
// ERC-ACP: Agentic Commerce — job escrow with evaluator attestation
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgenticCommerce
 * @dev Agentic Commerce protocol: Open -> Funded -> Submitted -> Completed | Rejected | Expired. Only evaluator can complete.
 */
contract AgenticCommerce is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Lifecycle states for ACP jobs.
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    /// @notice Job variants used to model standalone, open, and close flows.
    enum JobKind {
        Standalone,
        Open,
        Close
    }

    /// @notice Canonical ACP job record.
    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
    }

    IERC20 public paymentToken;
    uint256 public platformFeeBP; // 10000 = 100%
    address public platformTreasury;

    mapping(uint256 => Job) public jobs;
    mapping(uint256 => JobKind) internal jobKindByJobId;
    mapping(uint256 => uint256) internal parentJobIdByCloseJobId;
    mapping(uint256 => uint256) internal closeJobIdByParentJobId;
    uint256 public jobCounter;

    event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address evaluator, uint256 expiredAt);
    event LinkedJobCreated(uint256 indexed parentJobId, uint256 indexed closeJobId);
    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    error InvalidJob();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ExpiryTooShort();
    error ZeroBudget();
    error BudgetMismatch();
    error ProviderNotSet();
    error InvalidParentJob();
    error ParentJobNotCompleted();
    error CloseJobAlreadyExists();
    error SubmitNotAllowedForOpenJob();

    /// @notice Deploys the ACP kernel for a payment token and treasury.
    /// @param paymentToken_ The ERC20 token used for job funding and payout.
    /// @param treasury_ The treasury that receives platform fees.
    constructor(address paymentToken_, address treasury_) {
        if (paymentToken_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        paymentToken = IERC20(paymentToken_);
        platformTreasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /// @notice Updates the platform fee and fee treasury.
    /// @param feeBP_ The fee in basis points.
    /// @param treasury_ The treasury that should receive future fees.
    function setPlatformFee(uint256 feeBP_, address treasury_) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBP_ > 10000) revert InvalidJob();
        platformFeeBP = feeBP_;
        platformTreasury = treasury_;
    }

    /// @notice Creates a standalone ACP job.
    /// @param provider The provider assigned to the job, or zero to assign later.
    /// @param evaluator The evaluator allowed to complete or reject the job.
    /// @param expiredAt The timestamp after which refunds may be claimed.
    /// @param description The human-readable job description.
    /// @return jobId The newly created job id.
    function createJob(address provider, address evaluator, uint256 expiredAt, string calldata description) external returns (uint256 jobId) {
        jobId = _createJob(msg.sender, provider, evaluator, expiredAt, description);
        jobKindByJobId[jobId] = JobKind.Standalone;
    }

    /// @notice Creates an open parent job that may later spawn a close job.
    /// @param provider The provider assigned to the job, or zero to assign later.
    /// @param evaluator The evaluator allowed to complete or reject the job.
    /// @param expiredAt The timestamp after which refunds may be claimed.
    /// @param description The human-readable job description.
    /// @return jobId The newly created job id.
    function createOpenJob(address provider, address evaluator, uint256 expiredAt, string calldata description)
        external
        returns (uint256 jobId)
    {
        jobId = _createJob(msg.sender, provider, evaluator, expiredAt, description);
        jobKindByJobId[jobId] = JobKind.Open;
    }

    /// @notice Creates a close job linked to a completed open parent job.
    /// @param parentJobId The completed open parent job.
    /// @param expiredAt The timestamp after which refunds may be claimed.
    /// @param description The human-readable close-job description.
    /// @return jobId The newly created close job id.
    function createCloseJob(uint256 parentJobId, uint256 expiredAt, string calldata description)
        external
        returns (uint256 jobId)
    {
        Job storage parentJob = jobs[parentJobId];
        if (parentJob.id == 0 || jobKindByJobId[parentJobId] != JobKind.Open) revert InvalidParentJob();
        if (msg.sender != parentJob.client) revert Unauthorized();
        if (parentJob.status != JobStatus.Completed) revert ParentJobNotCompleted();
        uint256 existingCloseJobId = closeJobIdByParentJobId[parentJobId];
        if (existingCloseJobId != 0) {
            JobStatus existingCloseStatus = jobs[existingCloseJobId].status;
            if (existingCloseStatus != JobStatus.Rejected && existingCloseStatus != JobStatus.Expired) {
                revert CloseJobAlreadyExists();
            }
        }

        jobId = _createJob(msg.sender, parentJob.provider, parentJob.evaluator, expiredAt, description);
        jobKindByJobId[jobId] = JobKind.Close;
        parentJobIdByCloseJobId[jobId] = parentJobId;
        closeJobIdByParentJobId[parentJobId] = jobId;

        emit LinkedJobCreated(parentJobId, jobId);
    }

    /// @dev Creates and stores a new ACP job with common validation.
    function _createJob(
        address client_,
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description
    ) internal returns (uint256 jobId) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        jobId = ++jobCounter;
        jobs[jobId] = Job({
            id: jobId,
            client: client_,
            provider: provider,
            evaluator: evaluator,
            description: description,
            budget: 0,
            expiredAt: expiredAt,
            status: JobStatus.Open
        });
        emit JobCreated(jobId, client_, provider, evaluator, expiredAt);
    }

    /// @dev Client sets provider when job was created with provider == address(0). Must be set before fund.
    /// @param jobId The job to update.
    /// @param provider_ The provider address to assign.
    function setProvider(uint256 jobId, address provider_) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus(); // already set
        if (provider_ == address(0)) revert ZeroAddress();
        job.provider = provider_;
        emit ProviderSet(jobId, provider_);
    }

    /// @notice Sets or updates the budget for an open job.
    /// @param jobId The job to update.
    /// @param amount The desired budget amount.
    function setBudget(uint256 jobId, uint256 amount) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        job.budget = amount;
        emit BudgetSet(jobId, amount);
    }

    /// @notice Escrows the budget for a configured job.
    /// @param jobId The job to fund.
    /// @param expectedBudget The caller's expected budget guard.
    function fund(uint256 jobId, uint256 expectedBudget) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (job.budget == 0) revert ZeroBudget();
        if (job.budget != expectedBudget) revert BudgetMismatch();
        job.status = JobStatus.Funded;
        paymentToken.safeTransferFrom(job.client, address(this), job.budget);
        emit JobFunded(jobId, job.client, job.budget);
    }

    /// @dev Provider submits work, moving the job from Funded to Submitted for evaluator review.
    /// @param jobId The funded job being submitted.
    /// @param deliverable The deliverable hash or identifier.
    function submit(uint256 jobId, bytes32 deliverable) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Funded) revert WrongStatus();
        if (jobKindByJobId[jobId] == JobKind.Open) revert SubmitNotAllowedForOpenJob();
        if (msg.sender != job.provider) revert Unauthorized();
        job.status = JobStatus.Submitted;
        emit JobSubmitted(jobId, msg.sender, deliverable);
    }

    /// @notice Completes a funded or submitted job and releases escrowed payment.
    /// @param jobId The job to complete.
    /// @param reason The evaluator's completion reason code.
    function complete(uint256 jobId, bytes32 reason) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (msg.sender != job.evaluator) revert Unauthorized();
        if (jobKindByJobId[jobId] == JobKind.Open) {
            if (job.status != JobStatus.Funded) revert WrongStatus();
        } else {
            if (job.status != JobStatus.Submitted) revert WrongStatus();
        }
        job.status = JobStatus.Completed;
        uint256 amount = job.budget;
        uint256 fee = (amount * platformFeeBP) / 10000;
        uint256 net = amount - fee;
        if (fee > 0) {
            paymentToken.safeTransfer(platformTreasury, fee);
        }
        if (net > 0) {
            paymentToken.safeTransfer(job.provider, net);
        }
        emit JobCompleted(jobId, msg.sender, reason);
        emit PaymentReleased(jobId, job.provider, net);
    }

    /// @dev Client may reject only when Open; evaluator may reject when Funded or Submitted (refunds client).
    /// @param jobId The job to reject.
    /// @param reason The rejection reason code.
    function reject(uint256 jobId, bytes32 reason) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status == JobStatus.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (job.status == JobStatus.Funded || job.status == JobStatus.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }
        JobStatus prev = job.status;
        job.status = JobStatus.Rejected;
        if ((prev == JobStatus.Funded || prev == JobStatus.Submitted) && job.budget > 0) {
            paymentToken.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }
        emit JobRejected(jobId, msg.sender, reason);
    }

    /// @notice Refunds an expired funded or submitted job back to the client.
    /// @param jobId The job whose refund is being claimed.
    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Funded && job.status != JobStatus.Submitted) revert WrongStatus();
        if (block.timestamp < job.expiredAt) revert WrongStatus();
        job.status = JobStatus.Expired;
        if (job.budget > 0) {
            paymentToken.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }
        emit JobExpired(jobId);
    }

    /// @notice Returns the stored job record for `jobId`.
    /// @param jobId The job identifier to fetch.
    /// @return The ACP job struct.
    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    /// @notice Returns the recorded job kind for `jobId`.
    /// @param jobId The job identifier to inspect.
    /// @return The job kind.
    function getJobKind(uint256 jobId) external view returns (JobKind) {
        if (jobs[jobId].id == 0) revert InvalidJob();
        return jobKindByJobId[jobId];
    }

    /// @notice Returns the parent job id associated with a close job.
    /// @param jobId The close job identifier to inspect.
    /// @return The linked parent job id, or zero when unset.
    function getParentJobId(uint256 jobId) external view returns (uint256) {
        if (jobs[jobId].id == 0) revert InvalidJob();
        return parentJobIdByCloseJobId[jobId];
    }

    /// @notice Returns the active close job id associated with a parent job.
    /// @param jobId The parent job identifier to inspect.
    /// @return The linked close job id, or zero when unset.
    function getCloseJobId(uint256 jobId) external view returns (uint256) {
        if (jobs[jobId].id == 0) revert InvalidJob();
        return closeJobIdByParentJobId[jobId];
    }
}
