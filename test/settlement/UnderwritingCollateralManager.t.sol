// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/settlement/UnderwritingCollateralManager.sol";
import "../../contracts/interfaces/ICollateralManager.sol";
import "../mocks/MockERC20.sol";

contract UnderwritingCollateralManagerTest is Test {
    uint256 internal constant JOB_ID = 1;
    uint256 internal constant SETTLEMENT_JOB_ID = 42;
    uint256 internal constant COLLATERAL_AMOUNT = 100e6;
    uint256 internal constant PRINCIPAL_AMOUNT = 80e6;
    uint256 internal constant PREMIUM_AMOUNT = 5e6;
    uint256 internal constant COVERAGE_CAP = 100e6;

    uint256 internal underwriterPk;
    address internal underwriter;

    address internal escrow = makeAddr("escrow");
    address internal user = makeAddr("user");
    address internal premiumRecipient = makeAddr("premiumRecipient");
    address internal recoveryRecipient = makeAddr("recoveryRecipient");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");

    MockERC20 internal usdc;
    UnderwritingCollateralManager internal cm;

    // ── domain separator for EIP-712 signatures ─────────────────────────

    bytes32 internal constant UNDERWRITE_PERMIT_TYPEHASH = keccak256(
        "UnderwritePermit(uint256 jobId,uint256 settlementJobId,address safe,address user,address merchant,address underwriter,uint256 underwritingPremiumUsdc,address merchantExecutionWallet,uint256 requiredCollateralUsdc,uint256 fundedPrincipalUsdc,uint256 coverageCapUsdc,uint64 validUntil,uint64 executeUntil,bytes32 policyHash,uint256 nonce,uint64 unlockAt)"
    );

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        usdc = new MockERC20("Mock USDC", "mUSDC");
        cm = new UnderwritingCollateralManager(usdc);

        // Seed balances
        usdc.mint(escrow, 1_000e6);
        usdc.mint(user, 1_000e6);

        // Approve the collateral manager from escrow and user
        vm.prank(escrow);
        usdc.approve(address(cm), type(uint256).max);
        vm.prank(user);
        usdc.approve(address(cm), type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test: Underwriter signer can set recipients
    // ══════════════════════════════════════════════════════════════════════

    function testUnderwriterSignerCanSetRecipients() public {
        vm.prank(underwriter);
        cm.setUnderwriterRecipients(premiumRecipient, recoveryRecipient);

        (address storedPremium, address storedRecovery) = cm.recipientsByUnderwriter(underwriter);
        assertEq(storedPremium, premiumRecipient, "premium recipient mismatch");
        assertEq(storedRecovery, recoveryRecipient, "recovery recipient mismatch");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test: lockCollateral pays premium immediately and stores position
    // ══════════════════════════════════════════════════════════════════════

    function testLockCollateralPaysPremiumImmediatelyAndStoresPosition() public {
        _setRecipients();

        ICollateralManager.UnderwritePermit memory permit = _permit();
        bytes memory sig = _signPermit(permit, underwriterPk);

        uint256 escrowBefore = usdc.balanceOf(escrow);
        uint256 userBefore = usdc.balanceOf(user);
        uint256 premiumRecipientBefore = usdc.balanceOf(premiumRecipient);

        vm.prank(escrow);
        cm.lockCollateral(permit, user, permit.unlockAt, sig);

        // Collateral moved from escrow to CM
        assertEq(usdc.balanceOf(escrow), escrowBefore - COLLATERAL_AMOUNT, "escrow balance wrong");
        assertEq(usdc.balanceOf(address(cm)), COLLATERAL_AMOUNT, "CM collateral balance wrong");

        // Premium paid directly from user to premiumRecipient
        assertEq(usdc.balanceOf(user), userBefore - PREMIUM_AMOUNT, "user balance wrong");
        assertEq(usdc.balanceOf(premiumRecipient), premiumRecipientBefore + PREMIUM_AMOUNT, "premium recipient balance wrong");

        // Position stored correctly
        (
            address posUnderwriter,
            address posSafe,
            address posUser,
            address posMerchantWallet,
            uint256 posLocked,
            uint64 posUnlockAt,
            address posClaimant,
            bool posPremiumPaid,
            bool posPrincipalReleased,
            bool posCollateralRecovered,
            bool posCollateralReleased
        ) = cm.positionBySettlementJobId(SETTLEMENT_JOB_ID);

        assertEq(posUnderwriter, underwriter, "position underwriter wrong");
        assertEq(posSafe, escrow, "position safe should be the escrow (msg.sender)");
        assertEq(posUser, user, "position user wrong");
        assertEq(posMerchantWallet, merchantExecutionWallet, "position merchant wallet wrong");
        assertEq(posLocked, COLLATERAL_AMOUNT, "position locked amount wrong");
        assertEq(posUnlockAt, permit.unlockAt, "position unlockAt wrong");
        assertEq(posClaimant, user, "position claimant wrong");
        assertTrue(posPremiumPaid, "premium should be marked paid");
        assertFalse(posPrincipalReleased, "principal should not be released yet");
        assertFalse(posCollateralRecovered, "collateral should not be recovered yet");
        assertFalse(posCollateralReleased, "collateral should not be released yet");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test: claimTimeout routes locked collateral to recovery recipient
    // ══════════════════════════════════════════════════════════════════════

    function testClaimTimeoutRoutesLockedCollateralToRecoveryRecipient() public {
        _setRecipients();
        _lockCollateral();

        uint256 recoveryBefore = usdc.balanceOf(recoveryRecipient);

        vm.prank(escrow);
        cm.claimTimeout(SETTLEMENT_JOB_ID);

        assertEq(usdc.balanceOf(recoveryRecipient), recoveryBefore + COLLATERAL_AMOUNT, "recovery recipient should receive collateral");
        assertEq(usdc.balanceOf(address(cm)), 0, "CM should have zero balance after timeout");

        // Position should be marked as recovered
        (,,,,,,, , , bool posCollateralRecovered,) = cm.positionBySettlementJobId(SETTLEMENT_JOB_ID);
        assertTrue(posCollateralRecovered, "collateral should be marked recovered");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Test: releaseCollateral returns locked collateral to escrow caller
    // ══════════════════════════════════════════════════════════════════════

    function testReleaseCollateralReturnsLockedCollateralToEscrowCaller() public {
        _setRecipients();
        _lockCollateral();

        uint256 escrowBefore = usdc.balanceOf(escrow);

        vm.prank(escrow);
        cm.releaseCollateral(SETTLEMENT_JOB_ID);

        assertEq(usdc.balanceOf(escrow), escrowBefore + COLLATERAL_AMOUNT, "escrow should get collateral back");
        assertEq(usdc.balanceOf(address(cm)), 0, "CM should have zero balance after release");

        // Position should be marked as released
        (,,,,,,,,,, bool posCollateralReleased) = cm.positionBySettlementJobId(SETTLEMENT_JOB_ID);
        assertTrue(posCollateralReleased, "collateral should be marked released");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Additional coverage: invalid permit signature reverts
    // ══════════════════════════════════════════════════════════════════════

    function testLockCollateralRevertsOnInvalidSignature() public {
        _setRecipients();

        ICollateralManager.UnderwritePermit memory permit = _permit();
        // Sign with a wrong key
        (, uint256 wrongPk) = makeAddrAndKey("wrong-signer");
        bytes memory sig = _signPermit(permit, wrongPk);

        vm.prank(escrow);
        vm.expectRevert(UnderwritingCollateralManager.InvalidPermitSignature.selector);
        cm.lockCollateral(permit, user, permit.unlockAt, sig);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Additional coverage: recipients not set reverts
    // ══════════════════════════════════════════════════════════════════════

    function testLockCollateralRevertsWhenRecipientsNotSet() public {
        ICollateralManager.UnderwritePermit memory permit = _permit();
        bytes memory sig = _signPermit(permit, underwriterPk);

        vm.prank(escrow);
        vm.expectRevert(UnderwritingCollateralManager.RecipientsNotSet.selector);
        cm.lockCollateral(permit, user, permit.unlockAt, sig);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Additional coverage: slash routes to recovery recipient
    // ══════════════════════════════════════════════════════════════════════

    function testSlashRoutesCollateralToRecoveryRecipient() public {
        _setRecipients();
        _lockCollateral();

        uint256 recoveryBefore = usdc.balanceOf(recoveryRecipient);

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: SETTLEMENT_JOB_ID,
            safe: escrow,
            user: user,
            merchant: escrow,
            slashAmountUsdc: COLLATERAL_AMOUNT,
            reasonCode: keccak256("fraud"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 1
        });

        vm.prank(escrow);
        cm.slash(attestation, bytes(""));

        assertEq(usdc.balanceOf(recoveryRecipient), recoveryBefore + COLLATERAL_AMOUNT, "recovery should receive slashed collateral");
        assertEq(usdc.balanceOf(address(cm)), 0, "CM should have zero balance after slash");

        (,,,,,,,,, bool posCollateralRecovered,) = cm.positionBySettlementJobId(SETTLEMENT_JOB_ID);
        assertTrue(posCollateralRecovered, "collateral should be marked recovered after slash");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Additional coverage: double release reverts
    // ══════════════════════════════════════════════════════════════════════

    function testDoubleReleaseCollateralReverts() public {
        _setRecipients();
        _lockCollateral();

        vm.prank(escrow);
        cm.releaseCollateral(SETTLEMENT_JOB_ID);

        vm.prank(escrow);
        vm.expectRevert(UnderwritingCollateralManager.CollateralAlreadyReleased.selector);
        cm.releaseCollateral(SETTLEMENT_JOB_ID);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Additional coverage: release principal to merchant
    // ══════════════════════════════════════════════════════════════════════

    function testReleasePrincipalToMerchantTransfersFromCallerToMerchantWallet() public {
        _setRecipients();
        _lockCollateral();

        ICollateralManager.UnderwritePermit memory permit = _permit();
        bytes memory sig = _signPermit(permit, underwriterPk);

        usdc.mint(escrow, PRINCIPAL_AMOUNT); // ensure escrow has principal

        vm.prank(escrow);
        cm.releasePrincipalToMerchant(permit, sig);

        assertEq(usdc.balanceOf(merchantExecutionWallet), PRINCIPAL_AMOUNT, "merchant should receive principal");
    }

    // ══════════════════════════════════════════════════════════════════════
    // Access control: releaseCollateral requires escrow
    // ══════════════════════════════════════════════════════════════════════

    function testReleaseCollateralRevertsForNonEscrow() public {
        _setRecipients();
        _lockCollateral();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(UnderwritingCollateralManager.CallerNotEscrow.selector);
        cm.releaseCollateral(SETTLEMENT_JOB_ID);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Access control: claimTimeout requires escrow
    // ══════════════════════════════════════════════════════════════════════

    function testClaimTimeoutRevertsForNonEscrow() public {
        _setRecipients();
        _lockCollateral();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(UnderwritingCollateralManager.CallerNotEscrow.selector);
        cm.claimTimeout(SETTLEMENT_JOB_ID);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Access control: slash requires escrow
    // ══════════════════════════════════════════════════════════════════════

    function testSlashRevertsForNonEscrow() public {
        _setRecipients();
        _lockCollateral();

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: SETTLEMENT_JOB_ID,
            safe: escrow,
            user: user,
            merchant: escrow,
            slashAmountUsdc: COLLATERAL_AMOUNT,
            reasonCode: keccak256("fraud"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 1
        });

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(UnderwritingCollateralManager.CallerNotEscrow.selector);
        cm.slash(attestation, bytes(""));
    }

    // ══════════════════════════════════════════════════════════════════════
    // Double claimTimeout reverts
    // ══════════════════════════════════════════════════════════════════════

    function testDoubleClaimTimeoutReverts() public {
        _setRecipients();
        _lockCollateral();

        vm.prank(escrow);
        cm.claimTimeout(SETTLEMENT_JOB_ID);

        vm.prank(escrow);
        vm.expectRevert(UnderwritingCollateralManager.CollateralAlreadyRecovered.selector);
        cm.claimTimeout(SETTLEMENT_JOB_ID);
    }

    // ══════════════════════════════════════════════════════════════════════
    // claimTimeout then releaseCollateral reverts
    // ══════════════════════════════════════════════════════════════════════

    function testClaimTimeoutThenReleaseCollateralReverts() public {
        _setRecipients();
        _lockCollateral();

        vm.prank(escrow);
        cm.claimTimeout(SETTLEMENT_JOB_ID);

        vm.prank(escrow);
        vm.expectRevert(UnderwritingCollateralManager.CollateralAlreadyRecovered.selector);
        cm.releaseCollateral(SETTLEMENT_JOB_ID);
    }

    // ══════════════════════════════════════════════════════════════════════
    // releaseCollateral then claimTimeout reverts
    // ══════════════════════════════════════════════════════════════════════

    function testReleaseCollateralThenClaimTimeoutReverts() public {
        _setRecipients();
        _lockCollateral();

        vm.prank(escrow);
        cm.releaseCollateral(SETTLEMENT_JOB_ID);

        vm.prank(escrow);
        vm.expectRevert(UnderwritingCollateralManager.CollateralAlreadyReleased.selector);
        cm.claimTimeout(SETTLEMENT_JOB_ID);
    }

    // ══════════════════════════════════════════════════════════════════════
    // slash then releaseCollateral reverts
    // ══════════════════════════════════════════════════════════════════════

    function testSlashThenReleaseCollateralReverts() public {
        _setRecipients();
        _lockCollateral();

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: SETTLEMENT_JOB_ID,
            safe: escrow,
            user: user,
            merchant: escrow,
            slashAmountUsdc: COLLATERAL_AMOUNT,
            reasonCode: keccak256("fraud"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 1
        });

        vm.prank(escrow);
        cm.slash(attestation, bytes(""));

        vm.prank(escrow);
        vm.expectRevert(UnderwritingCollateralManager.CollateralAlreadyRecovered.selector);
        cm.releaseCollateral(SETTLEMENT_JOB_ID);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Partial slash returns remainder to escrow
    // ══════════════════════════════════════════════════════════════════════

    function testPartialSlashReturnsRemainderToEscrow() public {
        _setRecipients();
        _lockCollateral();

        uint256 slashAmount = 40e6;
        uint256 remainder = COLLATERAL_AMOUNT - slashAmount;

        uint256 recoveryBefore = usdc.balanceOf(recoveryRecipient);
        uint256 escrowBefore = usdc.balanceOf(escrow);

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: SETTLEMENT_JOB_ID,
            safe: escrow,
            user: user,
            merchant: escrow,
            slashAmountUsdc: slashAmount,
            reasonCode: keccak256("partial-fraud"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 1
        });

        vm.prank(escrow);
        cm.slash(attestation, bytes(""));

        assertEq(usdc.balanceOf(recoveryRecipient), recoveryBefore + slashAmount, "recovery should receive slash amount");
        assertEq(usdc.balanceOf(escrow), escrowBefore + remainder, "escrow should receive remainder");
        assertEq(usdc.balanceOf(address(cm)), 0, "CM should have zero balance after partial slash");
    }

    // ══════════════════════════════════════════════════════════════════════
    // helpers
    // ══════════════════════════════════════════════════════════════════════

    function _setRecipients() internal {
        vm.prank(underwriter);
        cm.setUnderwriterRecipients(premiumRecipient, recoveryRecipient);
    }

    function _lockCollateral() internal {
        ICollateralManager.UnderwritePermit memory permit = _permit();
        bytes memory sig = _signPermit(permit, underwriterPk);

        vm.prank(escrow);
        cm.lockCollateral(permit, user, permit.unlockAt, sig);
    }

    function _permit() internal view returns (ICollateralManager.UnderwritePermit memory permit) {
        permit = ICollateralManager.UnderwritePermit({
            jobId: JOB_ID,
            settlementJobId: SETTLEMENT_JOB_ID,
            safe: escrow,
            user: user,
            merchant: escrow,
            underwriter: underwriter,
            underwritingPremiumUsdc: PREMIUM_AMOUNT,
            merchantExecutionWallet: merchantExecutionWallet,
            requiredCollateralUsdc: COLLATERAL_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: COVERAGE_CAP,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            policyHash: keccak256("policy"),
            nonce: 1,
            unlockAt: uint64(block.timestamp + 3 days)
        });
    }

    function _signPermit(ICollateralManager.UnderwritePermit memory permit, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                UNDERWRITE_PERMIT_TYPEHASH,
                permit.jobId,
                permit.settlementJobId,
                permit.safe,
                permit.user,
                permit.merchant,
                permit.underwriter,
                permit.underwritingPremiumUsdc,
                permit.merchantExecutionWallet,
                permit.requiredCollateralUsdc,
                permit.fundedPrincipalUsdc,
                permit.coverageCapUsdc,
                permit.validUntil,
                permit.executeUntil,
                permit.policyHash,
                permit.nonce,
                permit.unlockAt
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Underwriting Collateral Manager")),
                keccak256(bytes("1")),
                block.chainid,
                address(cm)
            )
        );
    }
}
