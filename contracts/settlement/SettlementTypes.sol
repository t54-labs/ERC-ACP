// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SettlementTypes
 * @notice Shared settlement orchestration types for protected underwriting jobs.
 */
library SettlementTypes {
    /// @notice Settlement lifecycle tracked by `UnderwritingSettlementCoordinator`.
    enum SettlementState {
        None,
        EscrowConfigured,
        CollateralLocked,
        PrincipalReleased,
        SuccessSettled,
        RejectSettled,
        ExpirySettled,
        RecoverySettled
    }
}
