// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ICollateralManager.sol";

/**
 * @title UnderwritingSettlementEscrow
 * @notice Per-settlement escrow that moves principal and collateral on behalf of the coordinator.
 * @dev The coordinator configures each escrow once, then uses it as the only caller
 *      allowed to pull funds, invoke collateral-manager actions, and sweep residual balances.
 */
contract UnderwritingSettlementEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyController();
    error Unauthorized();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidConfig();
    error PermitMismatch();

    IERC20 public immutable usdc;
    ICollateralManager public immutable collateralManager;
    address public immutable controller;

    uint256 public jobId;
    address public client;
    address public provider;
    address public merchantExecutionWallet;
    uint256 public settlementJobId;
    bool public configured;

    event EscrowConfigured(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        uint256 settlementJobId,
        address merchantExecutionWallet
    );
    event CollateralPullRequested(uint256 indexed jobId, address indexed provider, uint256 amount);
    event PrincipalPullRequested(uint256 indexed jobId, address indexed client, uint256 amount);
    event CollateralLockRequested(uint256 indexed jobId, uint256 indexed settlementJobId);
    event PrincipalReleaseRequested(uint256 indexed jobId, uint256 indexed settlementJobId, uint256 amount);
    event DeliveryConfirmationRequested(uint256 indexed jobId, uint256 indexed settlementJobId, uint256 deliveryNonce);
    event CollateralReleaseRequested(uint256 indexed jobId, uint256 indexed settlementJobId);
    event TimeoutClaimRequested(uint256 indexed jobId, uint256 indexed settlementJobId);
    event SlashExecuted(uint256 indexed jobId, uint256 indexed settlementJobId, uint256 slashAmountUsdc);
    event ResidualSweepRequested(uint256 indexed jobId, address indexed provider);

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    modifier onlyControllerOrProvider() {
        if (msg.sender != controller && msg.sender != provider) revert Unauthorized();
        _;
    }

    /// @notice Deploys an escrow bound to a controller and collateral manager.
    /// @param usdc_ The settlement token used for principal and collateral transfers.
    /// @param collateralManager_ The collateral manager adapter this escrow forwards to.
    /// @param controller_ The authorized settlement coordinator.
    constructor(address usdc_, ICollateralManager collateralManager_, address controller_) {
        if (usdc_ == address(0) || address(collateralManager_) == address(0) || controller_ == address(0)) {
            revert InvalidConfig();
        }

        usdc = IERC20(usdc_);
        collateralManager = collateralManager_;
        controller = controller_;

        usdc.forceApprove(address(collateralManager_), type(uint256).max);
    }

    /// @notice Configures the escrow for a specific settlement flow.
    /// @param jobId_ The ACP job id using this escrow.
    /// @param client_ The client funding the job.
    /// @param provider_ The provider posting collateral.
    /// @param settlementJobId_ The canonical settlement id for this flow.
    /// @param merchantExecutionWallet_ The merchant execution wallet recorded in the permit.
    function configure(
        uint256 jobId_,
        address client_,
        address provider_,
        uint256 settlementJobId_,
        address merchantExecutionWallet_
    ) external onlyController {
        if (configured) revert AlreadyConfigured();
        if (
            client_ == address(0) || provider_ == address(0) || settlementJobId_ == 0
                || merchantExecutionWallet_ == address(0)
        ) {
            revert InvalidConfig();
        }

        configured = true;
        jobId = jobId_;
        client = client_;
        provider = provider_;
        settlementJobId = settlementJobId_;
        merchantExecutionWallet = merchantExecutionWallet_;

        emit EscrowConfigured(jobId_, client_, provider_, settlementJobId_, merchantExecutionWallet_);
    }

    /// @notice Pulls provider collateral into the escrow.
    /// @param amount The collateral amount to transfer from the provider.
    function pullCollateralFromProvider(uint256 amount) external onlyController nonReentrant {
        _requireConfigured();
        if (amount > 0) {
            usdc.safeTransferFrom(provider, address(this), amount);
        }
        emit CollateralPullRequested(jobId, provider, amount);
    }

    /// @notice Pulls client principal into the escrow.
    /// @param amount The principal amount to transfer from the client.
    function pullPrincipalFromClient(uint256 amount) external onlyController nonReentrant {
        _requireConfigured();
        if (amount > 0) {
            usdc.safeTransferFrom(client, address(this), amount);
        }
        emit PrincipalPullRequested(jobId, client, amount);
    }

    /// @notice Locks provider collateral through the collateral manager.
    /// @param permit The permit payload describing the protected settlement.
    /// @param permitSig The signature authorizing `permit`.
    function lockCollateral(ICollateralManager.UnderwritePermit calldata permit, bytes calldata permitSig)
        external
        onlyController
        nonReentrant
    {
        _requireConfigured();
        _assertPermitMatches(permit);

        collateralManager.lockCollateral(permit, permit.user, permit.unlockAt, permitSig);
        emit CollateralLockRequested(jobId, settlementJobId);
    }

    /// @notice Releases funded principal to the merchant execution wallet.
    /// @param permit The permit payload describing the protected settlement.
    /// @param permitSig The signature authorizing `permit`.
    function releasePrincipalToMerchant(ICollateralManager.UnderwritePermit calldata permit, bytes calldata permitSig)
        external
        onlyController
        nonReentrant
    {
        _requireConfigured();
        _assertPermitMatches(permit);

        collateralManager.releasePrincipalToMerchant(permit, permitSig);
        emit PrincipalReleaseRequested(jobId, settlementJobId, permit.fundedPrincipalUsdc);
    }

    /// @notice Forwards a signed delivery confirmation to the collateral manager.
    /// @param deliveryNonce The delivery nonce being confirmed.
    /// @param sig The signature authorizing the delivery confirmation.
    function confirmDeliveryBySig(uint256 deliveryNonce, bytes calldata sig) external onlyController nonReentrant {
        _requireConfigured();

        collateralManager.confirmDeliveryBySig(settlementJobId, deliveryNonce, sig);
        emit DeliveryConfirmationRequested(jobId, settlementJobId, deliveryNonce);
    }

    /// @notice Releases locked collateral and forwards the released balance to the provider.
    function releaseCollateralAndForward() external onlyController nonReentrant {
        _requireConfigured();

        uint256 balanceBefore = usdc.balanceOf(address(this));
        collateralManager.releaseCollateral(settlementJobId);
        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 releasedAmount = balanceAfter - balanceBefore;

        if (releasedAmount > 0) {
            usdc.safeTransfer(provider, releasedAmount);
        }

        emit CollateralReleaseRequested(jobId, settlementJobId);
    }

    /// @notice Slashes locked collateral through the collateral manager and returns any remainder to the provider.
    /// @param attestation The slash attestation describing the collateral seizure.
    /// @param slashSig The signature authorizing the slash (verified upstream by the coordinator).
    function slashCollateral(ICollateralManager.SlashAttestation calldata attestation, bytes calldata slashSig)
        external
        onlyController
        nonReentrant
    {
        _requireConfigured();

        collateralManager.slash(attestation, slashSig);

        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.safeTransfer(provider, balance);
        }

        emit SlashExecuted(jobId, settlementJobId, attestation.slashAmountUsdc);
    }

    /// @notice Claims the timeout path for this settlement through the collateral manager.
    function claimTimeout() external onlyController nonReentrant {
        _requireConfigured();

        collateralManager.claimTimeout(settlementJobId);
        emit TimeoutClaimRequested(jobId, settlementJobId);
    }

    /// @notice Sweeps any residual token balance back to the provider.
    /// @dev Callable by the coordinator or provider to clean up terminal settlements.
    function sweepResidualToProvider() external onlyControllerOrProvider nonReentrant {
        _requireConfigured();

        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.safeTransfer(provider, balance);
        }

        emit ResidualSweepRequested(jobId, provider);
    }

    /// @dev Ensures the escrow has been configured before use.
    function _requireConfigured() internal view {
        if (!configured) revert NotConfigured();
    }

    /// @dev Verifies that an underwriting permit matches this escrow's immutable configuration.
    function _assertPermitMatches(ICollateralManager.UnderwritePermit calldata permit) internal view {
        if (
            permit.jobId != jobId || permit.settlementJobId != settlementJobId || permit.safe != address(this)
                || permit.merchant != address(this) || permit.user != client
                || permit.merchantExecutionWallet != merchantExecutionWallet
        ) {
            revert PermitMismatch();
        }
    }
}
