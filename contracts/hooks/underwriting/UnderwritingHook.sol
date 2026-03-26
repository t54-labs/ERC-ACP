// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../AgenticCommerceHooked.sol";
import "../../BaseACPHook.sol";
import "./IUnderwritingHookView.sol";
import "./UnderwritingTypes.sol";
import "./UnderwritingWorkflowCore.sol";

/**
 * @title IUnderwritingWiringTarget
 * @notice Minimal wiring compatibility surface required by the underwriting hook.
 */
interface IUnderwritingWiringTarget {
    /// @notice Returns the ACP contract the target is wired against.
    function acp() external view returns (address);

    /// @notice Returns the hook contract the target is wired against.
    function hook() external view returns (address);
}

interface IUnderwritingSettlementCoordinatorTarget is IUnderwritingWiringTarget {
    function collateralManager() external view returns (address);
    function disputeWindowSeconds() external view returns (uint64);
}

/**
 * @title UnderwritingHook
 * @notice ACP hook that enforces underwriting commits, evidence checks, and close-job linkage.
 * @dev The hook owns workflow legitimacy while delegating settlement-side economics
 *      to a coordinator and signed decision execution to an evaluator.
 */
contract UnderwritingHook is BaseACPHook, IUnderwritingHookView, UnderwritingWorkflowCore {
    error OnlyAdmin();
    error OnlyCoordinator();
    error WiringAlreadySet();
    error WiringIncomplete();
    error InvalidWiring();

    AgenticCommerceHooked public immutable acp;
    address public immutable admin;
    address public evaluator;
    address public coordinator;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert OnlyCoordinator();
        _;
    }

    /// @notice Deploys the underwriting hook for a specific ACP contract and admin.
    /// @param acpContract_ The hooked ACP contract address.
    /// @param admin_ The address allowed to wire dependencies and manage underwriters.
    constructor(address acpContract_, address admin_) BaseACPHook(acpContract_) {
        if (admin_ == address(0)) revert ZeroAddress();
        acp = AgenticCommerceHooked(acpContract_);
        admin = admin_;
    }

    /// @notice Wires the hook to its evaluator and coordinator exactly once.
    /// @param evaluator_ The evaluator that will execute signed decisions.
    /// @param coordinator_ The coordinator that will advance protected settlements.
    function setWiring(address evaluator_, address coordinator_) external onlyAdmin {
        if (evaluator != address(0) || coordinator != address(0)) revert WiringAlreadySet();
        if (evaluator_ == address(0) || coordinator_ == address(0)) revert ZeroAddress();

        _assertWiringTarget(evaluator_);
        _assertSettlementCoordinatorTarget(coordinator_);

        evaluator = evaluator_;
        coordinator = coordinator_;
    }

    /// @notice Registers an underwriter that may author new standalone commitments.
    /// @param underwriter The underwriter address to register.
    function registerUnderwriter(address underwriter) external onlyAdmin {
        _registerUnderwriter(underwriter);
    }

    /// @notice Unregisters an underwriter from future standalone commitments.
    /// @param underwriter The underwriter address to unregister.
    function unregisterUnderwriter(address underwriter) external onlyAdmin {
        _unregisterUnderwriter(underwriter);
    }

    /// @notice Returns whether an address is a registered underwriter.
    /// @param underwriter The address to inspect.
    /// @return True when the address is registered.
    function registeredUnderwriters(address underwriter) external view returns (bool) {
        return _isRegisteredUnderwriter(underwriter);
    }

    /// @inheritdoc IUnderwritingHookView
    function getCommit(uint256 jobId) external view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return _getCommit(jobId);
    }

    /// @inheritdoc IUnderwritingHookView
    function jobUnderwriter(uint256 jobId) external view returns (address) {
        return _getUnderwriter(jobId);
    }

    /// @inheritdoc IUnderwritingHookView
    function jobSidecarState(uint256 jobId) external view returns (UnderwritingTypes.SidecarState) {
        return _getSidecarState(jobId);
    }

    /// @inheritdoc IUnderwritingHookView
    function jobSettlementJobId(uint256 jobId) external view returns (uint256) {
        return _getSettlementJobId(jobId);
    }

    /// @inheritdoc IUnderwritingHookView
    function isAwaitingClose(uint256 jobId) external view returns (bool) {
        return _isAwaitingClose(jobId);
    }

    /// @inheritdoc IUnderwritingHookView
    function getParentJobId(uint256 closeJobId) external view returns (uint256) {
        return _getParentJobId(closeJobId);
    }

    /// @inheritdoc IUnderwritingHookView
    function getActiveCloseJobId(uint256 parentJobId) external view returns (uint256) {
        return _getActiveCloseJobId(parentJobId);
    }

    /// @notice Marks a funded underwriting job as protected after settlement orchestration.
    /// @param jobId The funded job to transition.
    function markProtected(uint256 jobId) external onlyCoordinator {
        _markProtectedWorkflow(jobId);
    }

    /// @dev Validates and stores an underwriting commit during `setBudget`.
    function _preSetBudget(uint256 jobId, uint256 amount, bytes memory optParams) internal override {
        _requireWiring();
        _preSetBudgetWorkflow(acp, evaluator, jobId, amount, optParams);
    }

    /// @dev Ensures a committed underwriting job is ready to be funded.
    function _preFund(uint256 jobId, bytes memory) internal view override {
        _preFundWorkflow(acp, jobId);
    }

    /// @dev Marks a funded underwriting job as fee-escrowed.
    function _postFund(uint256 jobId, bytes memory) internal override {
        _postFundWorkflow(jobId);
    }

    /// @dev Ensures a protected underwriting job is ready to be submitted.
    function _preSubmit(uint256 jobId, bytes32, bytes memory) internal view override {
        _preSubmitWorkflow(acp, jobId);
    }

    /// @dev Validates submitted evidence against the stored underwriting commit.
    function _postSubmit(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal override {
        _postSubmitWorkflow(jobId, deliverable, optParams);
    }

    /// @dev Transitions successful jobs into close-awaiting or success-pending state.
    function _postComplete(uint256 jobId, bytes32, bytes memory) internal override {
        _postCompleteWorkflow(jobId);
    }

    /// @dev Ensures complete decisions only execute from the valid underwriting state.
    function _preComplete(uint256 jobId, bytes32, bytes memory) internal view override {
        _preDecisionWorkflow(acp, jobId);
    }

    /// @dev Ensures reject decisions only execute from the valid underwriting state.
    function _preReject(uint256 jobId, bytes32, bytes memory) internal view override {
        _preRejectWorkflow(acp, jobId);
    }

    /// @dev Finalizes hook-side state for rejected jobs.
    function _postReject(uint256 jobId, bytes32, bytes memory) internal override {
        _postRejectWorkflow(jobId);
    }

    /// @dev Reverts until both the evaluator and coordinator have been wired.
    function _requireWiring() internal view {
        if (evaluator == address(0) || coordinator == address(0)) revert WiringIncomplete();
    }

    /// @dev Validates that a target exposes the expected ACP and hook wiring.
    function _assertWiringTarget(address target) internal view {
        IUnderwritingWiringTarget wiringTarget = IUnderwritingWiringTarget(target);

        try wiringTarget.acp() returns (address targetAcp) {
            if (targetAcp != address(acp)) revert InvalidWiring();
        } catch {
            revert InvalidWiring();
        }

        try wiringTarget.hook() returns (address targetHook) {
            if (targetHook != address(this)) revert InvalidWiring();
        } catch {
            revert InvalidWiring();
        }
    }

    /// @dev Validates that a coordinator exposes the settlement-specific wiring surface.
    function _assertSettlementCoordinatorTarget(address target) internal view {
        _assertWiringTarget(target);

        IUnderwritingSettlementCoordinatorTarget coordinatorTarget = IUnderwritingSettlementCoordinatorTarget(target);

        try coordinatorTarget.collateralManager() returns (address targetCollateralManager) {
            if (targetCollateralManager == address(0)) revert InvalidWiring();
        } catch {
            revert InvalidWiring();
        }

        try coordinatorTarget.disputeWindowSeconds() returns (uint64) {} catch {
            revert InvalidWiring();
        }
    }

}
