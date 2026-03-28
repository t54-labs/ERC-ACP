# Tenderly Shared-Environment Deployment Test Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy the canonical underwriting stack to a Tenderly Virtual TestNet, verify the deployed contracts, and run a small set of post-deploy checks that prove the shared-environment path is usable for testing.

**Architecture:** This plan uses the current canonical `@acp`-based runtime already implemented in the repo, together with the repo's mixed proxy/direct deployment shape. `AgenticCommerce` comes from `@acp/AgenticCommerce.sol`, and `UnderwritingHook` plus the canonical `UnderwritingEvaluator` are already migrated to that runtime. `AgenticCommerce`, `UnderwritingHook`, and the canonical `UnderwritingEvaluator` deploy behind ERC-1967 proxies via `script/DeployUnderwritingSharedEnv.s.sol`, while `UnderwritingSettlementCoordinator` and `UnderwritingCollateralManager` remain direct-deployed. Tenderly is used as the execution and verification environment, and the post-deploy checks focus on wiring, admin ownership, hook whitelisting, underwriter setup, and one minimal hooked-job smoke flow.

**Tech Stack:** Foundry, Tenderly Virtual TestNet RPC, Tenderly contract verification API, `cast`, `forge script`, ERC-1967 proxies, Base USDC address configured for the target Tenderly environment.

---

### Task 1: Collect Tenderly And Operator Inputs

**Files:**
- Read: `README.md`
- Read: `script/DeployUnderwritingSharedEnv.s.sol`
- Read: `script/RegisterUnderwriter.s.sol`
- Read: `script/ConfigureUnderwriterRecipients.s.sol`
- Read: `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- Create: `docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`

**Step 1: Create a deployment shell session with explicit environment variables**

```bash
export TENDERLY_ACCESS_KEY=<tenderly-access-key>
export TENDERLY_VIRTUAL_TESTNET_RPC=<tenderly-rpc-url>
export TENDERLY_VERIFIER_URL="${TENDERLY_VIRTUAL_TESTNET_RPC}/verify/etherscan"

export PRIVATE_KEY=<deployer-private-key>
export BASE_USDC=<usdc-address-for-the-target-tenderly-env>
export ACP_TREASURY=<treasury-address>
export CLIENT_CONFIRMATION_WINDOW=3600

export UNDERWRITER_ADDRESS=<underwriter-eoa>
export PREMIUM_RECIPIENT=<premium-recipient-address>
export RECOVERY_RECIPIENT=<recovery-recipient-address>
```

**Step 2: Derive the deployer address locally**

Run:

```bash
cast wallet address --private-key "$PRIVATE_KEY"
```

Expected:
- prints the EOA that will become the hook admin and evaluator admin
- save it as `DEPLOYER_ADDRESS` for later checks

**Step 3: Write down the success criteria before deploying**

Expected success criteria:
- proxy-backed ACP, hook, and evaluator deploy successfully
- hook is whitelisted in ACP
- hook settlement token is pinned to USDC
- hook and evaluator admin both equal the deployer derived from `PRIVATE_KEY`
- underwriter registration succeeds
- underwriter recipient configuration succeeds
- one minimal hooked job can be created and budgeted after deployment

---

### Task 2: Run Local Preflight Checks Before Touching Tenderly

**Files:**
- Read: `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- Read: `test/integration/UnderwritingSharedEnvFlow.t.sol`
- Read: `test/hooks/underwriting/UnderwritingHookUpgradeable.t.sol`

**Step 1: Run the deploy-script smoke suite**

Run:

```bash
forge test --match-path test/script/DeployUnderwritingSharedEnvSmoke.t.sol -vv
```

Expected: PASS

**Step 2: Run the shared-environment integration suite**

Run:

```bash
forge test --match-path test/integration/UnderwritingSharedEnvFlow.t.sol -vv
```

Expected: PASS

**Step 3: Run the canonical refund/expiry regression suite**

Run:

```bash
forge test --match-path test/hooks/underwriting/UnderwritingHookUpgradeable.t.sol -vv
```

Expected: PASS

**Step 4: Stop if any local suite fails**

Expected:
- do not deploy to Tenderly until the local deployment, integration, and canonical refund invariants are green

---

### Task 3: Prepare The Tenderly Virtual TestNet

**Files:**
- External: Tenderly Virtual TestNet RPC and verification endpoint

**Step 1: Fund the deployer account on Tenderly**

Run:

```bash
export DEPLOYER_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")

curl "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"method\": \"tenderly_setBalance\",
    \"params\": [[\"$DEPLOYER_ADDRESS\"], \"0x3635C9ADC5DEA00000\"],
    \"id\": \"deploy-fund\"
  }"
```

Expected:
- JSON-RPC success response
- deployer balance is high enough to deploy multiple contracts and run follow-up transactions

**Step 2: Verify connectivity**

Run:

```bash
cast chain-id --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast balance "$DEPLOYER_ADDRESS" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected:
- RPC responds successfully
- deployer balance is non-zero

**Step 3: Decide whether verification is required in the same run**

Rule:
- if this deployment is for collaborative QA in Tenderly, enable `--verify`
- if this deployment is only for a quick local smoke on the Virtual TestNet, verification can be deferred, but the preferred path is to verify during deployment

---

### Task 4: Deploy The Canonical Stack To Tenderly

**Files:**
- Run: `script/DeployUnderwritingSharedEnv.s.sol`
- Read: `script/DeployUnderwritingSharedEnv.s.sol`

**Step 1: Execute the deploy script against Tenderly**

Run:

```bash
forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --verify \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --slow
```

Expected:
- deployment succeeds without `AccessControlUnauthorizedAccount`
- script logs implementation/proxy addresses for ACP, hook, evaluator, coordinator, and collateral manager

**Step 2: Record the deployed addresses immediately**

Capture and store:
- ACP proxy
- ACP implementation
- Hook proxy
- Hook implementation
- Evaluator proxy
- Evaluator implementation
- `UnderwritingSettlementCoordinator`
- `UnderwritingCollateralManager`

Expected:
- every follow-up step references the exact fresh addresses from this run

**Step 3: If verification fails but deployment succeeds, verify contracts separately**

Run:

```bash
forge verify-contract <DEPLOYED_ADDRESS> <FullyQualifiedContractName> \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --watch
```

Example fully qualified names:
- `contracts/hooks/underwriting/UnderwritingHook.sol:UnderwritingHook`
- `contracts/settlement/UnderwritingEvaluator.sol:UnderwritingEvaluator`
- `contracts/settlement/UnderwritingSettlementCoordinator.sol:UnderwritingSettlementCoordinator`
- `contracts/settlement/UnderwritingCollateralManager.sol:UnderwritingCollateralManager`
- `contracts/acp/contracts/AgenticCommerce.sol:AgenticCommerce`

Expected:
- deployed contracts become inspectable in Tenderly

---

### Task 5: Verify Post-Deploy Wiring And Admin State

**Files:**
- Read: `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- Read: `script/DeployUnderwritingSharedEnv.s.sol`

**Step 1: Check ACP hook whitelist**

Run:

```bash
cast call <ACP_PROXY> "whitelistedHooks(address)(bool)" <HOOK_PROXY> \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected: `true`

**Step 2: Check the hook’s pinned settlement token**

Run:

```bash
cast call <HOOK_PROXY> "allowedSettlementToken()(address)" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected:
- equals `$BASE_USDC`

**Step 3: Check hook and evaluator admin ownership**

Run:

```bash
cast call <HOOK_PROXY> "admin()(address)" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast call <EVALUATOR_PROXY> "admin()(address)" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected:
- both return `$DEPLOYER_ADDRESS`

**Step 4: Check hook wiring**

Run:

```bash
cast call <HOOK_PROXY> "evaluator()(address)" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast call <HOOK_PROXY> "coordinator()(address)" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected:
- evaluator equals `<EVALUATOR_PROXY>`
- coordinator equals `<COORDINATOR_ADDRESS>`

---

### Task 6: Run Operator Setup On The Live Deployment

**Files:**
- Run: `script/RegisterUnderwriter.s.sol`
- Run: `script/ConfigureUnderwriterRecipients.s.sol`
- Read: `contracts/settlement/README.md`

**Step 1: Register the underwriter from the hook admin account**

Run:

```bash
export UNDERWRITING_HOOK=<HOOK_PROXY>

forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --slow
```

Expected:
- script logs the registered underwriter address
- no access-control revert

**Step 2: Verify the underwriter was registered**

Run:

```bash
cast call <HOOK_PROXY> "registeredUnderwriters(address)(bool)" "$UNDERWRITER_ADDRESS" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected: `true`

**Step 3: Configure premium and recovery recipients from the underwriter account**

Rule:
- switch `PRIVATE_KEY` from the deployer key to the underwriter’s key for this step

Run:

```bash
export PRIVATE_KEY=<underwriter-private-key>
export COLLATERAL_MANAGER=<COLLATERAL_MANAGER_ADDRESS>

forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --slow
```

Expected:
- script logs the premium and recovery recipients
- no access-control or validation revert

**Step 4: Verify recipient storage**

Run:

```bash
cast call <COLLATERAL_MANAGER_ADDRESS> "recipientsByUnderwriter(address)(address,address)" "$UNDERWRITER_ADDRESS" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected:
- premium recipient equals `$PREMIUM_RECIPIENT`
- recovery recipient equals `$RECOVERY_RECIPIENT`

---

### Task 7: Run A Minimal Live Smoke Test

**Files:**
- Read: `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- Read: `test/integration/UnderwritingSharedEnvFlow.t.sol`
- Optional future automation target: a dedicated live smoke script if repeated Tenderly testing becomes common

**Step 1: Prove the deployment supports one hooked job creation**

Minimum requirement:
- create a job against the deployed ACP using:
  - provider address
  - evaluator proxy address
  - hook proxy address
  - near-term `expiredAt`
- confirm the created job references the deployed hook and evaluator

Expected:
- job creation succeeds without whitelist or wiring failure

**Step 2: Prove the deployment supports one hooked budget commit**

Minimum requirement:
- submit a valid `UnderwriteCommit` through `setBudget(...)`
- use `$BASE_USDC` as the budget token
- confirm the hook stores the commit and enters the `Committed` sidecar state

Expected:
- no `UnderwriterNotRegistered`
- no settlement-token mismatch revert

**Step 3: Optional deeper economic smoke**

If more confidence is needed, replay one path from `test/integration/UnderwritingSharedEnvFlow.t.sol`:
- happy-path client confirmation flow, or
- timeout-to-recovery flow

Expected:
- the live Tenderly environment matches the same semantics asserted locally

**Step 4: Record the smoke-test outcome**

Store:
- deployed addresses
- deployer address
- underwriter address
- recipients
- whether verification succeeded
- which smoke path was executed
- transaction hashes for deployment and follow-up operator actions

---

### Task 8: Define Exit Criteria And Rollback Rules

**Files:**
- Read: `docs/plans/2026-03-27-acp-submodule-b-now-delivery-summary.md`

**Exit criteria**

- Tenderly deployment completed successfully
- contract verification succeeded or was completed manually after deploy
- hook whitelist, admin ownership, settlement token pinning, and wiring checks all passed
- underwriter registration and recipient configuration passed
- at least one minimal hooked-job smoke flow passed

**Rollback rules**

- if deployment fails before addresses are emitted, fix locally and redeploy
- if deployment succeeds but wiring checks fail, do not reuse the deployment; redeploy and use the fresh addresses
- if underwriter setup fails because the wrong key is being used, stop and correct operator keys before retrying
- if a smoke transaction reveals semantic mismatch, treat the Tenderly deployment as disposable and fix the code/test gap before redeploying

---

## Notes

- The deploy script creates fresh instances every run. Treat each Tenderly deployment as a new stack and update all downstream references accordingly.
- The repo’s current shared-environment path is USDC-only for protected underwriting jobs.
- Tenderly verification uses an Etherscan-compatible endpoint derived from the Virtual TestNet RPC URL:
  - `TENDERLY_VERIFIER_URL="${TENDERLY_VIRTUAL_TESTNET_RPC}/verify/etherscan"`
- The most important local references for expected behavior are:
  - `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
  - `test/integration/UnderwritingSharedEnvFlow.t.sol`
  - `test/hooks/underwriting/UnderwritingHookUpgradeable.t.sol`
