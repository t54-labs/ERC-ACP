// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IBondManager.sol";

contract MCUJobAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyController();
    error Unauthorized();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidConfig();
    error PermitMismatch();

    IERC20 public immutable usdc;
    IBondManager public immutable bondManager;
    address public immutable controller;

    uint256 public jobId;
    address public client;
    address public provider;
    address public merchantExecutionWallet;
    bytes32 public memoId;
    bool public configured;

    event AdapterConfigured(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        bytes32 memoId,
        address merchantExecutionWallet
    );
    event BondPullRequested(uint256 indexed jobId, address indexed provider, uint256 amount);
    event PrincipalPullRequested(uint256 indexed jobId, address indexed client, uint256 amount);
    event BondLockRequested(uint256 indexed jobId, bytes32 indexed memoId);
    event PrincipalReleaseRequested(uint256 indexed jobId, bytes32 indexed memoId, uint256 amount);
    event DeliveryConfirmationRequested(uint256 indexed jobId, bytes32 indexed memoId, uint256 deliveryNonce);
    event BondReleaseRequested(uint256 indexed jobId, bytes32 indexed memoId);
    event BondSlashRequested(uint256 indexed jobId, bytes32 indexed memoId, uint256 slashAmountUsdc, bytes32 reasonCode);
    event TimeoutClaimRequested(uint256 indexed jobId, bytes32 indexed memoId);
    event ResidualSweepRequested(uint256 indexed jobId, address indexed provider);

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    modifier onlyControllerOrProvider() {
        if (msg.sender != controller && msg.sender != provider) revert Unauthorized();
        _;
    }

    constructor(address usdc_, IBondManager bondManager_, address controller_) {
        if (usdc_ == address(0) || address(bondManager_) == address(0) || controller_ == address(0)) {
            revert InvalidConfig();
        }

        usdc = IERC20(usdc_);
        bondManager = bondManager_;
        controller = controller_;

        // BondManager pulls bond/principal from the adapter, so pre-approve it once.
        usdc.forceApprove(address(bondManager_), type(uint256).max);
    }

    function configure(
        uint256 jobId_,
        address client_,
        address provider_,
        bytes32 memoId_,
        address merchantExecutionWallet_
    ) external onlyController {
        if (configured) revert AlreadyConfigured();
        if (
            client_ == address(0) || provider_ == address(0) || memoId_ == bytes32(0)
                || merchantExecutionWallet_ == address(0)
        ) {
            revert InvalidConfig();
        }

        configured = true;
        jobId = jobId_;
        client = client_;
        provider = provider_;
        memoId = memoId_;
        merchantExecutionWallet = merchantExecutionWallet_;

        emit AdapterConfigured(jobId_, client_, provider_, memoId_, merchantExecutionWallet_);
    }

    function pullBondFromProvider(uint256 amount) external onlyController nonReentrant {
        _requireConfigured();
        if (amount > 0) {
            usdc.safeTransferFrom(provider, address(this), amount);
        }
        emit BondPullRequested(jobId, provider, amount);
    }

    function pullPrincipalFromClient(uint256 amount) external onlyController nonReentrant {
        _requireConfigured();
        if (amount > 0) {
            usdc.safeTransferFrom(client, address(this), amount);
        }
        emit PrincipalPullRequested(jobId, client, amount);
    }

    function lockBond(IBondManager.UnderwritePermit calldata permit, bytes calldata permitSig)
        external
        onlyController
        nonReentrant
    {
        _requireConfigured();
        _assertPermitMatches(permit);

        bondManager.lockBond(permit, permit.user, permit.unlockAt, permitSig);
        emit BondLockRequested(jobId, memoId);
    }

    function releasePrincipal(IBondManager.UnderwritePermit calldata permit, bytes calldata permitSig)
        external
        onlyController
        nonReentrant
    {
        _requireConfigured();
        _assertPermitMatches(permit);

        bondManager.releasePrincipalToMerchant(permit, permitSig);
        emit PrincipalReleaseRequested(jobId, memoId, permit.fundedPrincipalUsdc);
    }

    function confirmDeliveryBySig(uint256 deliveryNonce, bytes calldata sig) external onlyController nonReentrant {
        _requireConfigured();

        bondManager.confirmDeliveryBySig(memoId, deliveryNonce, sig);
        emit DeliveryConfirmationRequested(jobId, memoId, deliveryNonce);
    }

    function releaseBondAndForward() external onlyController nonReentrant {
        _requireConfigured();

        uint256 balanceBefore = usdc.balanceOf(address(this));
        bondManager.releaseBond(memoId);
        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 releasedAmount = balanceAfter - balanceBefore;

        if (releasedAmount > 0) {
            usdc.safeTransfer(provider, releasedAmount);
        }

        emit BondReleaseRequested(jobId, memoId);
    }

    function slashBond(IBondManager.SlashAttestation calldata attestation, bytes calldata slashSig)
        external
        onlyController
        nonReentrant
    {
        _requireConfigured();
        if (attestation.jobId != jobId || attestation.memoId != memoId || attestation.safe != address(this)) {
            revert PermitMismatch();
        }

        bondManager.slash(attestation, slashSig);
        emit BondSlashRequested(jobId, memoId, attestation.slashAmountUsdc, attestation.reasonCode);
    }

    function claimTimeout() external onlyController nonReentrant {
        _requireConfigured();

        bondManager.claimTimeout(memoId);
        emit TimeoutClaimRequested(jobId, memoId);
    }

    function sweepResidualToProvider() external onlyControllerOrProvider nonReentrant {
        _requireConfigured();

        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.safeTransfer(provider, balance);
        }

        emit ResidualSweepRequested(jobId, provider);
    }

    function _requireConfigured() internal view {
        if (!configured) revert NotConfigured();
    }

    function _assertPermitMatches(IBondManager.UnderwritePermit calldata permit) internal view {
        if (
            permit.jobId != jobId || permit.memoId != memoId || permit.safe != address(this)
                || permit.merchant != address(this) || permit.user != client
                || permit.merchantExecutionWallet != merchantExecutionWallet
        ) {
            revert PermitMismatch();
        }
    }
}
