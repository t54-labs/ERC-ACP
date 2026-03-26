// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../AgenticCommerceHooked.sol";
import "../../BaseACPHook.sol";
import "./IUnderwritingHookView.sol";
import "./UnderwritingTypes.sol";
import "./UnderwritingWorkflowCore.sol";

interface IUnderwritingWiringTarget {
    function acp() external view returns (address);
    function hook() external view returns (address);
}

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

    constructor(address acpContract_, address admin_) BaseACPHook(acpContract_) {
        if (admin_ == address(0)) revert ZeroAddress();
        acp = AgenticCommerceHooked(acpContract_);
        admin = admin_;
    }

    function setWiring(address evaluator_, address coordinator_) external onlyAdmin {
        if (evaluator != address(0) || coordinator != address(0)) revert WiringAlreadySet();
        if (evaluator_ == address(0) || coordinator_ == address(0)) revert ZeroAddress();

        _assertWiringTarget(evaluator_);
        _assertWiringTarget(coordinator_);

        evaluator = evaluator_;
        coordinator = coordinator_;
    }

    function registerUnderwriter(address underwriter) external onlyAdmin {
        _registerUnderwriter(underwriter);
    }

    function unregisterUnderwriter(address underwriter) external onlyAdmin {
        _unregisterUnderwriter(underwriter);
    }

    function registeredUnderwriters(address underwriter) external view returns (bool) {
        return _isRegisteredUnderwriter(underwriter);
    }

    function getCommit(uint256 jobId) external view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return _getCommit(jobId);
    }

    function jobUnderwriter(uint256 jobId) external view returns (address) {
        return _getUnderwriter(jobId);
    }

    function jobSidecarState(uint256 jobId) external view returns (UnderwritingTypes.SidecarState) {
        return _getSidecarState(jobId);
    }

    function jobSettlementJobId(uint256 jobId) external view returns (uint256) {
        return _getSettlementJobId(jobId);
    }

    function isAwaitingClose(uint256 jobId) external view returns (bool) {
        return _isAwaitingClose(jobId);
    }

    function getParentJobId(uint256 closeJobId) external view returns (uint256) {
        return _getParentJobId(closeJobId);
    }

    function getActiveCloseJobId(uint256 parentJobId) external view returns (uint256) {
        return _getActiveCloseJobId(parentJobId);
    }

    function markProtected(uint256 jobId) external onlyCoordinator {
        _markProtectedWorkflow(jobId);
    }

    function _preSetBudget(uint256 jobId, uint256 amount, bytes memory optParams) internal override {
        _requireWiring();
        _preSetBudgetWorkflow(acp, evaluator, jobId, amount, optParams);
    }

    function _preFund(uint256 jobId, bytes memory) internal view override {
        _preFundWorkflow(acp, jobId);
    }

    function _postFund(uint256 jobId, bytes memory) internal override {
        _postFundWorkflow(jobId);
    }

    function _preSubmit(uint256 jobId, bytes32, bytes memory) internal view override {
        _preSubmitWorkflow(acp, jobId);
    }

    function _postSubmit(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal override {
        _postSubmitWorkflow(jobId, deliverable, optParams);
    }

    function _postComplete(uint256 jobId, bytes32, bytes memory) internal override {
        _postCompleteWorkflow(jobId);
    }

    function _preComplete(uint256 jobId, bytes32, bytes memory) internal view override {
        _preDecisionWorkflow(acp, jobId);
    }

    function _preReject(uint256 jobId, bytes32, bytes memory) internal view override {
        _preRejectWorkflow(acp, jobId);
    }

    function _postReject(uint256 jobId, bytes32, bytes memory) internal override {
        _postRejectWorkflow(jobId);
    }

    function _requireWiring() internal view {
        if (evaluator == address(0) || coordinator == address(0)) revert WiringIncomplete();
    }

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
}
