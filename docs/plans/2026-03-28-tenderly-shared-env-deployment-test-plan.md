# Tenderly Shared-Environment Deployment Test Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy the canonical underwriting stack to a Tenderly Virtual TestNet, verify the deployed contracts, and run three live smoke scenarios that prove the shared-environment path is usable for success and dispute testing.

**Architecture:** This plan uses the current canonical `@acp`-based runtime already implemented in the repo, together with the repo's mixed proxy/direct deployment shape. `AgenticCommerce` comes from `@acp/AgenticCommerce.sol`, and `UnderwritingHook` plus the canonical `UnderwritingEvaluator` are already migrated to that runtime. `AgenticCommerce`, `UnderwritingHook`, and the canonical `UnderwritingEvaluator` deploy behind ERC-1967 proxies via `script/DeployUnderwritingSharedEnv.s.sol`, while `UnderwritingSettlementCoordinator` and `UnderwritingCollateralManager` remain direct-deployed. Tenderly is used as the execution and verification environment, and the post-deploy checks focus on wiring, admin ownership, hook whitelisting, underwriter setup, and three live smoke scenarios: one-stage happy path, two-stage happy path, and one-stage dispute path.

**Tech Stack:** Foundry, Tenderly Virtual TestNet Admin RPC, Tenderly contract verification API, `cast`, `forge script`, ERC-1967 proxies, EIP-712 signatures for permit/slash flows, Base USDC address configured for the target Tenderly environment.

---

### Task 1: Collect Tenderly And Operator Inputs

**Files:**
- Read: `README.md`
- Read: `script/DeployUnderwritingSharedEnv.s.sol`
- Read: `script/RegisterUnderwriter.s.sol`
- Read: `script/ConfigureUnderwriterRecipients.s.sol`
- Read: `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- Read: `test/hooks/underwriting/UnderwritingHookParity.t.sol`
- Create: `docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`

**Step 1: Create a deployment shell session with explicit environment variables**

```bash
export TENDERLY_ACCESS_KEY=<tenderly-access-key>
export TENDERLY_VIRTUAL_TESTNET_RPC="https://virtual.base.eu.rpc.tenderly.co/d6ac0a5d-d160-4385-91bf-a0d56e80daf5"
export TENDERLY_VIRTUAL_TESTNET_WSS="wss://virtual.base.eu.rpc.tenderly.co/bd7ddccd-9725-4362-891b-c17de416fae3"  # optional for future websocket tooling
export TENDERLY_VERIFIER_URL="${TENDERLY_VIRTUAL_TESTNET_RPC}/verify/etherscan"

export DEPLOYER_PRIVATE_KEY=<deployer-private-key>
export UNDERWRITER_PRIVATE_KEY=<underwriter-private-key>
export CLIENT_PRIVATE_KEY=<client-private-key>
export PROVIDER_PRIVATE_KEY=<provider-private-key>

export BASE_USDC=<canonical-base-usdc-address-on-this-vnet>
export ACP_TREASURY=<treasury-address>
export CLIENT_CONFIRMATION_WINDOW=3600

export PREMIUM_RECIPIENT=<premium-recipient-address>
export RECOVERY_RECIPIENT=<recovery-recipient-address>
export MERCHANT_EXECUTION_WALLET=<separate-fifth-address>
```

Current checked-in scripts still read `PRIVATE_KEY`, so set `PRIVATE_KEY` to the appropriate actor-specific key immediately before each `forge script` invocation.

**Step 2: Derive the actor addresses locally**

Run:

```bash
export DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
export UNDERWRITER_ADDRESS=$(cast wallet address --private-key "$UNDERWRITER_PRIVATE_KEY")
export CLIENT_ADDRESS=$(cast wallet address --private-key "$CLIENT_PRIVATE_KEY")
export PROVIDER_ADDRESS=$(cast wallet address --private-key "$PROVIDER_PRIVATE_KEY")
```

Expected:
- all four actor EOAs are derived locally before any Tenderly funding or deployment
- `DEPLOYER_ADDRESS` will become the hook admin and evaluator admin
- `UNDERWRITER_ADDRESS`, `CLIENT_ADDRESS`, and `PROVIDER_ADDRESS` are available for downstream setup and smoke assertions

**Step 3: Write down the success criteria before deploying**

Expected success criteria:
- proxy-backed ACP, hook, and evaluator deploy successfully
- hook is whitelisted in ACP
- hook settlement token is pinned to USDC
- hook and evaluator admin both equal `DEPLOYER_ADDRESS`
- underwriter registration succeeds
- underwriter recipient configuration succeeds
- one-stage happy path succeeds through `releaseCollateral(...)`
- two-stage happy path succeeds with a smaller close-job budget than the root job
- one-stage dispute path succeeds with a full slash to `RECOVERY_RECIPIENT`

---

### Task 2: Run Local Preflight Checks Before Touching Tenderly

**Files:**
- Read: `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- Read: `test/integration/UnderwritingSharedEnvFlow.t.sol`
- Read: `test/hooks/underwriting/UnderwritingHookUpgradeable.t.sol`
- Read: `test/hooks/underwriting/UnderwritingHookParity.t.sol`

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

**Step 4: Run the close-job parity suite**

Run:

```bash
forge test --match-path test/hooks/underwriting/UnderwritingHookParity.t.sol -vv
```

Expected: PASS

**Step 5: Stop if any local suite fails**

Expected:
- do not deploy to Tenderly until the local deployment, integration, upgradeability, and close-job parity invariants are green

---

### Task 3: Prepare The Tenderly Virtual TestNet

**Files:**
- External: Tenderly Virtual TestNet RPC and verification endpoint

**Step 1: Fund actor gas balances and seed Base USDC using the Tenderly Admin RPC**

Run:

```bash
curl "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"method\": \"tenderly_setBalance\",
    \"params\": [[\"$DEPLOYER_ADDRESS\", \"$UNDERWRITER_ADDRESS\", \"$CLIENT_ADDRESS\", \"$PROVIDER_ADDRESS\"], \"0x56bc75e2d63100000\"],
    \"id\": \"native-topup\"
  }"

curl "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"method\": \"tenderly_setErc20Balance\",
    \"params\": [\"$BASE_USDC\", \"$CLIENT_ADDRESS\", \"0x77359400\"],
    \"id\": \"client-usdc-topup\"
  }"

curl "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{
    \"jsonrpc\": \"2.0\",
    \"method\": \"tenderly_setErc20Balance\",
    \"params\": [\"$BASE_USDC\", \"$PROVIDER_ADDRESS\", \"0x1dcd6500\"],
    \"id\": \"provider-usdc-topup\"
  }"
```

Expected:
- JSON-RPC success responses for native balance and ERC-20 balance top-ups
- deployer, underwriter, client, and provider all have enough native gas to transact
- client has enough Base USDC to run one-stage happy path, two-stage happy path, and one-stage dispute path in one shared run
- provider has enough Base USDC to post collateral for all planned scenarios

**Step 2: Verify connectivity**

Run:

```bash
cast chain-id --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast balance "$DEPLOYER_ADDRESS" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast balance "$UNDERWRITER_ADDRESS" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast balance "$CLIENT_ADDRESS" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast balance "$PROVIDER_ADDRESS" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast call "$BASE_USDC" "balanceOf(address)(uint256)" "$CLIENT_ADDRESS" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast call "$BASE_USDC" "balanceOf(address)(uint256)" "$PROVIDER_ADDRESS" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected:
- RPC responds successfully
- all actor native balances are non-zero
- client and provider Base USDC balances are non-zero

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
export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"

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

**Step 3: If `--verify` fails but deployment succeeds, verify the correct address type separately**

Rule:
- distinguish **proxy addresses** from **implementation addresses**
- `AgenticCommerce`, `UnderwritingHook`, and `UnderwritingEvaluator` are deployed as **ERC-1967 proxy-backed contracts**
- `UnderwritingSettlementCoordinator` and `UnderwritingCollateralManager` are **direct-deployed contracts**
- for proxy-backed contracts, the runtime address used by operators is the **proxy address**, but the implementation source must be verified against the **implementation address**
- do not try to verify a proxy address using the implementation contract name

Verify the implementation contracts:

```bash
forge verify-contract <ACP_IMPLEMENTATION> contracts/acp/contracts/AgenticCommerce.sol:AgenticCommerce \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --watch

forge verify-contract <HOOK_IMPLEMENTATION> contracts/hooks/underwriting/UnderwritingHook.sol:UnderwritingHook \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --watch

forge verify-contract <EVALUATOR_IMPLEMENTATION> contracts/settlement/UnderwritingEvaluator.sol:UnderwritingEvaluator \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --watch
```

Verify the direct-deployed contracts:

```bash
forge verify-contract <COORDINATOR_ADDRESS> contracts/settlement/UnderwritingSettlementCoordinator.sol:UnderwritingSettlementCoordinator \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --watch

forge verify-contract <COLLATERAL_MANAGER_ADDRESS> contracts/settlement/UnderwritingCollateralManager.sol:UnderwritingCollateralManager \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --watch
```

Record for operator use:
- ACP proxy address
- Hook proxy address
- Evaluator proxy address
- ACP implementation address
- Hook implementation address
- Evaluator implementation address
- Coordinator address
- Collateral manager address

Expected:
- implementation contracts are verified against their implementation bytecode
- direct-deployed contracts are verified against their live addresses
- proxy addresses remain the canonical addresses used for all runtime interaction and post-deploy checks

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
export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"

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
- switch `PRIVATE_KEY` from the deployer key to `UNDERWRITER_PRIVATE_KEY` for this step

Run:

```bash
export PRIVATE_KEY="$UNDERWRITER_PRIVATE_KEY"
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

### Task 7: Run Three Live Smoke Scenarios On Tenderly

**Files:**
- Read: `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- Read: `test/integration/UnderwritingSharedEnvFlow.t.sol`
- Read: `test/hooks/underwriting/UnderwritingHookParity.t.sol`
- Create: `script/TenderlySharedEnvSmoke.s.sol`
- Optional future helper: `script/tenderly_shared_env_setup.sh`

**Step 1: Seed all actor balances on the Tenderly Admin RPC**

Use the hardcoded Tenderly Admin RPC default for this workflow unless explicitly overridden.

Seed native gas for:
- deployer
- underwriter
- client
- provider

Seed Base USDC for:
- client
- provider

Minimum recommended live balances:
- client: enough for all three scenarios in one run, including:
  - one-stage happy path
  - two-stage happy path
  - one-stage dispute path
- provider: enough to post collateral for all scenarios in one run
- underwriter: native gas only
- deployer: native gas only

Expected:
- all four EOAs can send transactions
- client and provider both hold non-zero Base USDC before the smoke starts

**Step 2: Run a one-stage happy-path smoke**

Use one standalone protected job with:
- `parentJobId = 0`
- `allowCloseJob = false`
- `budget = 40e6`
- `underwritingPremiumUsdc = 5e6`
- `fundedPrincipalUsdc = 500e6`
- `requiredCollateralUsdc = 100e6`
- `coverageCapUsdc = 250e6`
- `unlockAt = 0`
- separate `MERCHANT_EXECUTION_WALLET`

Execute:
- client creates the job
- client sets the underwriting budget with a valid standalone `UnderwriteCommit`
- client funds the ACP budget
- provider approves collateral pull
- client approves principal pull
- coordinator orchestrates funding with a valid underwriter-signed permit
- provider submits evidence
- client confirms by client
- settlement coordinator runs `requestCollateralRelease(...)`
- settlement coordinator runs `releaseCollateral(...)`

Expected:
- job creation succeeds
- `setBudget(...)` succeeds with the deployed hook and evaluator
- `orchestrateFunding(...)` succeeds
- premium is routed to `PREMIUM_RECIPIENT`
- funded principal is routed to `MERCHANT_EXECUTION_WALLET`
- collateral is returned to the provider
- job reaches `Completed`
- settlement reaches the successful release path without dispute

**Step 3: Run a two-stage happy-path smoke**

Use a root job followed by a linked close job.

Root job parameters:
- `parentJobId = 0`
- `allowCloseJob = true`
- `budget = 40e6`
- `underwritingPremiumUsdc = 5e6`
- `fundedPrincipalUsdc = 500e6`
- `requiredCollateralUsdc = 100e6`
- `coverageCapUsdc = 250e6`
- `unlockAt = 0`

Close job parameters:
- `parentJobId = <ROOT_JOB_ID>`
- `allowCloseJob = false`
- `budget = 20e6`

Execute:
- run the root job through funding, orchestration, submission, and completion
- verify the root job enters `AwaitingClose`
- create the close job with the same client, provider, evaluator, and hook
- set the close-job budget using a valid close commit that points at the root job
- fund the close job
- orchestrate close-job funding
- submit close-job evidence
- complete the close job
- settle the successful shared position through the close job by calling:
  - `requestCollateralRelease(<CLOSE_JOB_ID>)`
  - `releaseCollateral(<CLOSE_JOB_ID>)`

Expected:
- the root job enters `AwaitingClose` after root completion
- the close job is admitted and linked to the root job
- the close job carries a smaller budget than the root job
- the close job reuses the root settlement identity and escrow
- after close-job completion, both root and close workflow state advance out of the awaiting-close phase
- the final collateral release succeeds through the close-job settlement entrypoint

**Step 4: Run a one-stage dispute-path smoke**

Use one standalone protected job with:
- `parentJobId = 0`
- `allowCloseJob = false`
- `budget = 40e6`
- `underwritingPremiumUsdc = 5e6`
- `fundedPrincipalUsdc = 500e6`
- `requiredCollateralUsdc = 100e6`
- `coverageCapUsdc = 250e6`
- `unlockAt = block.timestamp + 1 hours`

Execute:
- client creates the job
- client sets budget with a valid standalone `UnderwriteCommit`
- client funds the ACP budget
- provider approves collateral pull
- client approves principal pull
- coordinator orchestrates funding with a valid underwriter-signed permit
- provider submits evidence
- client confirms by client
- settlement coordinator runs `requestCollateralRelease(...)`
- client opens a success dispute before `unlockAt`
- settlement coordinator applies a full slash using an underwriter-signed `SlashAttestation`
- set `slashAmountUsdc = 100e6`

Expected:
- dispute opens successfully before `unlockAt`
- full slash succeeds
- full collateral amount is sent to `RECOVERY_RECIPIENT`
- provider does not receive the slashed collateral back
- the dispute path proves the live deployment supports post-success recovery semantics

**Step 5: Record scenario outputs and transaction hashes**

Store:
- deployed addresses
- deployer address
- underwriter address
- client address
- provider address
- merchant execution wallet
- recipients
- verification status
- root job id and close job id for the two-stage flow
- transaction hashes for:
  - deployment
  - underwriter registration
  - recipient configuration
  - one-stage happy path
  - two-stage happy path
  - one-stage dispute path

Expected:
- all three scenarios can be replayed from the recorded inputs and transaction hashes
- the Tenderly shared environment is proven usable for both success and dispute testing

---

### Task 8: Define Exit Criteria And Rollback Rules

**Files:**
- Read: `docs/plans/2026-03-27-acp-submodule-b-now-delivery-summary.md`

**Exit criteria**

- Tenderly deployment completed successfully
- contract verification succeeded or was completed manually after deploy
- hook whitelist, admin ownership, settlement token pinning, and wiring checks all passed
- underwriter registration and recipient configuration passed
- one-stage happy path passed
- two-stage happy path passed
- one-stage dispute path passed

**Rollback rules**

- if deployment fails before addresses are emitted, fix locally and redeploy
- if deployment succeeds but wiring checks fail, do not reuse the deployment; redeploy and use the fresh addresses
- if operator setup fails because the wrong actor key is being used, stop and correct keys before retrying
- if a smoke transaction reveals semantic mismatch, treat the Tenderly deployment as disposable and fix the code/test gap before redeploying

---

## Notes

- The deploy script creates fresh instances every run. Treat each Tenderly deployment as a new stack and update all downstream references accordingly.
- The repo’s current shared-environment path is USDC-only for protected underwriting jobs.
- The plan assumes the Tenderly Virtual TestNet is a Base Virtual TestNet and `BASE_USDC` is the canonical Base USDC address on that environment.
- The plan assumes four signing EOAs (`deployer`, `underwriter`, `client`, `provider`) plus a separate `MERCHANT_EXECUTION_WALLET` address.
- Tenderly verification uses an Etherscan-compatible endpoint derived from the Virtual TestNet RPC URL:
  - `TENDERLY_VERIFIER_URL="${TENDERLY_VIRTUAL_TESTNET_RPC}/verify/etherscan"`
- Tenderly Admin RPC supports `tenderly_setBalance`, `tenderly_setErc20Balance`, `evm_increaseTime`, and `evm_setNextBlockTimestamp` if future timing assertions need explicit clock control.
- The most important local references for expected behavior are:
  - `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
  - `test/integration/UnderwritingSharedEnvFlow.t.sol`
  - `test/hooks/underwriting/UnderwritingHookUpgradeable.t.sol`
  - `test/hooks/underwriting/UnderwritingHookParity.t.sol`
