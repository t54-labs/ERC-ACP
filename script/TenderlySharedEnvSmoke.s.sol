// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "@acp/AgenticCommerce.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "contracts/interfaces/IAgenticCommerceKernel.sol";
import "contracts/interfaces/ICollateralManager.sol";
import "contracts/hooks/underwriting/UnderwritingHook.sol";
import "contracts/hooks/underwriting/UnderwritingTypes.sol";
import "contracts/settlement/SettlementTypes.sol";
import "contracts/settlement/UnderwritingSettlementCoordinator.sol";
import "contracts/settlement/UnderwritingEvaluator.sol";

contract TenderlySharedEnvSmoke is Script {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant UNDERWRITE_PERMIT_TYPEHASH = keccak256(
        "UnderwritePermit(uint256 jobId,uint256 settlementJobId,address safe,address user,address merchant,address underwriter,uint256 underwritingPremiumUsdc,address merchantExecutionWallet,uint256 requiredCollateralUsdc,uint256 fundedPrincipalUsdc,uint256 coverageCapUsdc,uint64 validUntil,uint64 executeUntil,bytes32 policyHash,uint256 nonce,uint64 unlockAt)"
    );
    bytes32 internal constant SLASH_ATTESTATION_TYPEHASH = keccak256(
        "SlashAttestation(uint256 settlementJobId,address safe,address user,address merchant,uint256 slashAmountUsdc,bytes32 reasonCode,uint64 validUntil,uint256 nonce)"
    );

    uint256 internal constant ROOT_BUDGET = 40e6;
    uint256 internal constant CLOSE_BUDGET = 20e6;
    uint256 internal constant UNDERWRITING_PREMIUM = 5e6;
    uint256 internal constant FUNDED_PRINCIPAL = 500e6;
    uint256 internal constant REQUIRED_COLLATERAL = 100e6;
    uint256 internal constant COVERAGE_CAP = 250e6;

    struct Config {
        uint256 deployerPk;
        uint256 underwriterPk;
        uint256 clientPk;
        uint256 providerPk;
        address deployer;
        address underwriter;
        address client;
        address provider;
        address merchantExecutionWallet;
        address premiumRecipient;
        address recoveryRecipient;
        address baseUsdc;
        AgenticCommerce acp;
        UnderwritingHook hook;
        UnderwritingEvaluator evaluator;
        UnderwritingSettlementCoordinator coordinator;
        address collateralManager;
        uint64 expiryDelta;
        uint64 executeDelta;
        uint64 unlockDelta;
        uint256 escrowNonceStart;
    }

    function runOneStageHappy() external {
        Config memory cfg = _loadConfig();
        _runOneStageHappy(cfg);
    }

    function runTwoStageHappy() external {
        Config memory cfg = _loadConfig();
        _runTwoStageHappy(cfg);
    }

    function runOneStageDispute() external {
        Config memory cfg = _loadConfig();
        _runOneStageDispute(cfg);
    }

    function _runOneStageHappy(Config memory cfg) internal {
        address escrow = vm.computeCreateAddress(address(cfg.coordinator), cfg.escrowNonceStart);

        uint256 premiumBefore = IERC20(cfg.baseUsdc).balanceOf(cfg.premiumRecipient);
        uint256 merchantBefore = IERC20(cfg.baseUsdc).balanceOf(cfg.merchantExecutionWallet);

        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(cfg, 0, false);
        uint256 jobId = _createJob(
            cfg,
            "task7 one-stage happy path"
        );

        ICollateralManager.UnderwritePermit memory permit = _buildPermit(cfg, jobId, escrow, commit, 7001, 0);
        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "task7-one-stage-happy");

        _approveAndFundRootJob(cfg, jobId, escrow, commit, ROOT_BUDGET);
        _orchestrateFunding(cfg, jobId, permit);
        _submitEvidence(cfg, jobId, evidence);
        _confirmByClient(cfg, jobId, keccak256("task7-one-stage-happy"));
        _requestAndReleaseCollateral(cfg, jobId);

        _requireEq(IERC20(cfg.baseUsdc).balanceOf(cfg.premiumRecipient) - premiumBefore, UNDERWRITING_PREMIUM, "premium");
        _requireEq(IERC20(cfg.baseUsdc).balanceOf(cfg.merchantExecutionWallet) - merchantBefore, FUNDED_PRINCIPAL, "principal");
        _requireCompleted(cfg, jobId, UnderwritingTypes.SidecarState.SuccessPendingConfirmation, SettlementTypes.SettlementState.SuccessSettled);

        console2.log("scenario=one-stage-happy");
        console2.log("jobId", jobId);
        console2.log("escrow", escrow);
    }

    function _runTwoStageHappy(Config memory cfg) internal {
        address escrow = vm.computeCreateAddress(address(cfg.coordinator), cfg.escrowNonceStart);

        UnderwritingTypes.UnderwriteCommit memory rootCommit = _buildCommit(cfg, 0, true);
        uint256 rootJobId = _createJob(cfg, "task7 two-stage root job");
        ICollateralManager.UnderwritePermit memory rootPermit = _buildPermit(cfg, rootJobId, escrow, rootCommit, 7002, 0);
        UnderwritingTypes.SubmitEvidence memory rootEvidence = _evidence(rootCommit, "task7-two-stage-root");

        _approveAndFundRootJob(cfg, rootJobId, escrow, rootCommit, ROOT_BUDGET);
        _orchestrateFunding(cfg, rootJobId, rootPermit);
        _submitEvidence(cfg, rootJobId, rootEvidence);
        _confirmByClient(cfg, rootJobId, keccak256("task7-two-stage-root"));

        _requireJobStatus(cfg.acp, rootJobId, IAgenticCommerceKernel.JobStatus.Completed, "root completed");
        _requireEq(uint256(cfg.hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.AwaitingClose), "root awaiting close");

        UnderwritingTypes.UnderwriteCommit memory closeCommit = _buildCommit(cfg, rootJobId, false);
        uint256 closeJobId = _createJob(cfg, "task7 two-stage close job");
        ICollateralManager.UnderwritePermit memory closePermit = _buildPermit(cfg, closeJobId, escrow, closeCommit, 7003, 0);
        UnderwritingTypes.SubmitEvidence memory closeEvidence = _evidence(closeCommit, "task7-two-stage-close");

        _approveAndFundCloseJob(cfg, closeJobId, closeCommit, CLOSE_BUDGET);
        _orchestrateFunding(cfg, closeJobId, closePermit);
        _submitEvidence(cfg, closeJobId, closeEvidence);
        _confirmByClient(cfg, closeJobId, keccak256("task7-two-stage-close"));
        _requestAndReleaseCollateral(cfg, closeJobId);

        _requireEq(cfg.hook.getParentJobId(closeJobId), rootJobId, "close parent");
        _requireEq(cfg.hook.jobSettlementJobId(closeJobId), rootJobId, "shared settlement job id");
        _requireEq(uint256(cfg.hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation), "root post-close state");
        _requireEq(uint256(cfg.hook.jobSidecarState(closeJobId)), uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation), "close state");
        _requireEq(cfg.hook.getActiveCloseJobId(rootJobId), 0, "active close cleared");
        _requireEq(uint256(cfg.coordinator.jobSettlementState(closeJobId)), uint256(SettlementTypes.SettlementState.SuccessSettled), "close settlement");

        console2.log("scenario=two-stage-happy");
        console2.log("rootJobId", rootJobId);
        console2.log("closeJobId", closeJobId);
        console2.log("escrow", escrow);
    }

    function _runOneStageDispute(Config memory cfg) internal {
        address escrow = vm.computeCreateAddress(address(cfg.coordinator), cfg.escrowNonceStart);

        uint256 recoveryBefore = IERC20(cfg.baseUsdc).balanceOf(cfg.recoveryRecipient);

        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(cfg, 0, false);
        uint256 jobId = _createJob(cfg, "task7 one-stage dispute path");
        ICollateralManager.UnderwritePermit memory permit = _buildPermit(cfg, jobId, escrow, commit, 7004, cfg.unlockDelta);
        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "task7-one-stage-dispute");

        _approveAndFundRootJob(cfg, jobId, escrow, commit, ROOT_BUDGET);
        _orchestrateFunding(cfg, jobId, permit);
        _submitEvidence(cfg, jobId, evidence);
        _confirmByClient(cfg, jobId, keccak256("task7-one-stage-dispute"));

        vm.startBroadcast(cfg.providerPk);
        cfg.coordinator.requestCollateralRelease(jobId);
        vm.stopBroadcast();

        vm.startBroadcast(cfg.clientPk);
        cfg.coordinator.openSuccessDispute(jobId, keccak256("task7-success-dispute"));
        vm.stopBroadcast();

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: jobId,
            safe: escrow,
            user: cfg.client,
            merchant: escrow,
            slashAmountUsdc: REQUIRED_COLLATERAL,
            reasonCode: keccak256("task7-dispute-reason"),
            validUntil: uint64(block.timestamp + cfg.executeDelta),
            nonce: 8001
        });

        bytes memory slashSig = _signSlash(cfg, attestation);

        vm.startBroadcast(cfg.underwriterPk);
        cfg.coordinator.applySuccessDisputeSlash(jobId, attestation, slashSig);
        vm.stopBroadcast();

        _requireCompleted(cfg, jobId, UnderwritingTypes.SidecarState.SuccessPendingConfirmation, SettlementTypes.SettlementState.RecoverySettled);
        _requireEq(IERC20(cfg.baseUsdc).balanceOf(cfg.recoveryRecipient) - recoveryBefore, REQUIRED_COLLATERAL, "recovery collateral");

        console2.log("scenario=one-stage-dispute");
        console2.log("jobId", jobId);
        console2.log("escrow", escrow);
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        cfg.underwriterPk = vm.envUint("UNDERWRITER_PRIVATE_KEY");
        cfg.clientPk = vm.envUint("CLIENT_PRIVATE_KEY");
        cfg.providerPk = vm.envUint("PROVIDER_PRIVATE_KEY");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.underwriter = vm.addr(cfg.underwriterPk);
        cfg.client = vm.addr(cfg.clientPk);
        cfg.provider = vm.addr(cfg.providerPk);
        cfg.merchantExecutionWallet = vm.envAddress("MERCHANT_EXECUTION_WALLET");
        cfg.premiumRecipient = vm.envAddress("PREMIUM_RECIPIENT");
        cfg.recoveryRecipient = vm.envAddress("RECOVERY_RECIPIENT");
        cfg.baseUsdc = vm.envAddress("BASE_USDC");
        cfg.acp = AgenticCommerce(vm.envAddress("ACP_PROXY"));
        cfg.hook = UnderwritingHook(vm.envAddress("UNDERWRITING_HOOK"));
        cfg.evaluator = UnderwritingEvaluator(vm.envAddress("EVALUATOR_PROXY"));
        cfg.coordinator = UnderwritingSettlementCoordinator(vm.envAddress("COORDINATOR"));
        cfg.collateralManager = vm.envAddress("COLLATERAL_MANAGER");
        cfg.expiryDelta = uint64(vm.envOr("TASK7_JOB_EXPIRY_SECONDS", uint256(1 days)));
        cfg.executeDelta = uint64(vm.envOr("TASK7_EXECUTE_WINDOW_SECONDS", uint256(2 days)));
        cfg.unlockDelta = uint64(vm.envOr("TASK7_UNLOCK_WINDOW_SECONDS", uint256(1 hours)));
        cfg.escrowNonceStart = vm.envUint("SETTLEMENT_ESCROW_NONCE_START");

        _requireEq(cfg.hook.allowedSettlementToken(), cfg.baseUsdc, "hook settlement token");
        _requireEq(cfg.hook.evaluator(), address(cfg.evaluator), "hook evaluator");
        _requireEq(cfg.hook.coordinator(), address(cfg.coordinator), "hook coordinator");
    }

    function _createJob(Config memory cfg, string memory description) internal returns (uint256 jobId) {
        vm.startBroadcast(cfg.clientPk);
        jobId = cfg.acp.createJob(
            cfg.provider,
            address(cfg.evaluator),
            block.timestamp + cfg.expiryDelta,
            description,
            address(cfg.hook),
            0
        );
        vm.stopBroadcast();
    }

    function _approveAndFundRootJob(
        Config memory cfg,
        uint256 jobId,
        address escrow,
        UnderwritingTypes.UnderwriteCommit memory commit,
        uint256 budget
    ) internal {
        vm.startBroadcast(cfg.clientPk);
        IERC20(cfg.baseUsdc).approve(address(cfg.acp), budget);
        IERC20(cfg.baseUsdc).approve(cfg.collateralManager, UNDERWRITING_PREMIUM);
        IERC20(cfg.baseUsdc).approve(escrow, FUNDED_PRINCIPAL);
        cfg.acp.setBudget(jobId, cfg.baseUsdc, budget, abi.encode(commit));
        cfg.acp.fund(jobId, budget, bytes(""));
        vm.stopBroadcast();

        vm.startBroadcast(cfg.providerPk);
        IERC20(cfg.baseUsdc).approve(escrow, REQUIRED_COLLATERAL);
        vm.stopBroadcast();
    }

    function _approveAndFundCloseJob(
        Config memory cfg,
        uint256 jobId,
        UnderwritingTypes.UnderwriteCommit memory commit,
        uint256 budget
    ) internal {
        vm.startBroadcast(cfg.clientPk);
        IERC20(cfg.baseUsdc).approve(address(cfg.acp), budget);
        cfg.acp.setBudget(jobId, cfg.baseUsdc, budget, abi.encode(commit));
        cfg.acp.fund(jobId, budget, bytes(""));
        vm.stopBroadcast();
    }

    function _orchestrateFunding(
        Config memory cfg,
        uint256 jobId,
        ICollateralManager.UnderwritePermit memory permit
    ) internal {
        bytes memory permitSig = _signPermit(cfg, permit);

        vm.startBroadcast(cfg.deployerPk);
        cfg.coordinator.orchestrateFunding(jobId, permit, permitSig);
        vm.stopBroadcast();
    }

    function _submitEvidence(Config memory cfg, uint256 jobId, UnderwritingTypes.SubmitEvidence memory evidence) internal {
        vm.startBroadcast(cfg.providerPk);
        cfg.acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));
        vm.stopBroadcast();
    }

    function _confirmByClient(Config memory cfg, uint256 jobId, bytes32 reason) internal {
        vm.startBroadcast(cfg.clientPk);
        cfg.evaluator.confirmByClient(jobId, reason);
        vm.stopBroadcast();
    }

    function _requestAndReleaseCollateral(Config memory cfg, uint256 jobId) internal {
        vm.startBroadcast(cfg.providerPk);
        cfg.coordinator.requestCollateralRelease(jobId);
        cfg.coordinator.releaseCollateral(jobId);
        vm.stopBroadcast();
    }

    function _buildCommit(Config memory cfg, uint256 parentJobId, bool allowCloseJob)
        internal
        view
        returns (UnderwritingTypes.UnderwriteCommit memory)
    {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: parentJobId,
            underwriter: cfg.underwriter,
            validUntil: uint64(block.timestamp + cfg.expiryDelta),
            policyHash: keccak256("task7-policy"),
            quoteIdHash: keccak256("task7-quote"),
            termsHash: keccak256("task7-terms"),
            allowCloseJob: allowCloseJob
        });
    }

    function _buildPermit(
        Config memory cfg,
        uint256 jobId,
        address escrow,
        UnderwritingTypes.UnderwriteCommit memory commit,
        uint256 nonce,
        uint64 unlockIn
    ) internal view returns (ICollateralManager.UnderwritePermit memory) {
        uint256 settlementJobId = commit.parentJobId == 0 ? jobId : commit.parentJobId;

        return ICollateralManager.UnderwritePermit({
            jobId: jobId,
            settlementJobId: settlementJobId,
            safe: escrow,
            user: cfg.client,
            merchant: escrow,
            underwriter: cfg.underwriter,
            underwritingPremiumUsdc: UNDERWRITING_PREMIUM,
            merchantExecutionWallet: cfg.merchantExecutionWallet,
            requiredCollateralUsdc: REQUIRED_COLLATERAL,
            fundedPrincipalUsdc: FUNDED_PRINCIPAL,
            coverageCapUsdc: COVERAGE_CAP,
            validUntil: commit.validUntil,
            executeUntil: uint64(block.timestamp + cfg.executeDelta),
            policyHash: commit.policyHash,
            nonce: nonce,
            unlockAt: uint64(block.timestamp + unlockIn)
        });
    }

    function _evidence(UnderwritingTypes.UnderwriteCommit memory commit, string memory bundleLabel)
        internal
        pure
        returns (UnderwritingTypes.SubmitEvidence memory)
    {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256(bytes(bundleLabel)),
            policyHash: commit.policyHash,
            quoteIdHash: commit.quoteIdHash,
            termsHash: commit.termsHash
        });
    }

    function _signPermit(Config memory cfg, ICollateralManager.UnderwritePermit memory permit)
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
                _domainSeparator("Underwriting Collateral Manager", cfg.collateralManager),
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cfg.underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSlash(Config memory cfg, ICollateralManager.SlashAttestation memory attestation)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                SLASH_ATTESTATION_TYPEHASH,
                attestation.settlementJobId,
                attestation.safe,
                attestation.user,
                attestation.merchant,
                attestation.slashAmountUsdc,
                attestation.reasonCode,
                attestation.validUntil,
                attestation.nonce
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator("Underwriting Settlement Coordinator", address(cfg.coordinator)),
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cfg.underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator(string memory name, address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _requireCompleted(
        Config memory cfg,
        uint256 jobId,
        UnderwritingTypes.SidecarState sidecarState,
        SettlementTypes.SettlementState settlementState
    ) internal view {
        _requireJobStatus(cfg.acp, jobId, IAgenticCommerceKernel.JobStatus.Completed, "job completed");
        _requireEq(uint256(cfg.hook.jobSidecarState(jobId)), uint256(sidecarState), "sidecar state");
        _requireEq(uint256(cfg.coordinator.jobSettlementState(jobId)), uint256(settlementState), "settlement state");
    }

    function _requireJobStatus(
        AgenticCommerce acp,
        uint256 jobId,
        IAgenticCommerceKernel.JobStatus expected,
        string memory label
    ) internal view {
        IAgenticCommerceKernel.Job memory job = IAgenticCommerceKernel(address(acp)).getJob(jobId);
        _requireEq(uint256(job.status), uint256(expected), label);
    }

    function _requireEq(uint256 actual, uint256 expected, string memory label) internal pure {
        if (actual != expected) {
            revert(string.concat("mismatch: ", label));
        }
    }

    function _requireEq(address actual, address expected, string memory label) internal pure {
        if (actual != expected) {
            revert(string.concat("mismatch: ", label));
        }
    }
}
