# Tenderly Forked Smoke Recovery Plan (v2)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Supersedes:** `docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`

**Goal:** Finish the live Tenderly proof for the underwriting shared environment without burning quota on repeated full-environment rebuilds. This version keeps local debugging out of Tenderly, stages one clean Tenderly baseline through deployment and operator setup, then runs each smoke scenario from that baseline via fork-first isolation.

**Why this version exists:** The original shared-VNet plan proved that Tasks 1 through 6 are executable and that the first two live smoke scenarios can succeed, but Task 7 stalled when Tenderly began returning `HTTP 403` quota errors on `eth_sendRawTransaction`. Tenderly's documented execution model is TU-based, not a documented fixed 50-block ceiling, so the recovery strategy must reduce Tenderly writes and isolate each scenario from baseline state drift.

**Current known state:**
- Tasks 1 through 6 were already completed at least once and recorded in the 2026-03-29 deployment, preparation, post-deploy, and operator-setup docs
- `script/TenderlySharedEnvSmoke.s.sol` exists and compiles
- one-stage happy path and two-stage happy path already landed on-chain on a prior fresh VNet
- the one-stage dispute path remains unproven live because Tenderly quota stopped the broadcast before any dispute tx landed

**Primary strategy changes from v1:**
- do not use Tenderly as the inner debug loop
- do not require one continuously mutated VNet for all three scenarios
- treat the staged deployment state as the canonical baseline
- run each live scenario from that same baseline lineage through a fresh fork, or use snapshot/revert only if fork creation is unavailable

**Tenderly assumptions validated on 2026-03-29:**
- each `eth_sendRawTransaction` on a Virtual TestNet mines a new block
- Virtual TestNet usage is quota-based in Tenderly Units rather than documented as a fixed 50-block cap
- `evm_snapshot` and `evm_revert` are supported
- Tenderly documents forking a TestNet and prefers fork-based disposable working copies over revert-based rewinds when possible

**References:**
- https://docs.tenderly.co/faq/virtual-testnets
- https://docs.tenderly.co/pricing
- https://docs.tenderly.co/virtual-testnets/admin-rpc
- https://docs.tenderly.co/virtual-testnets/develop/revert-state
- https://docs.tenderly.co/virtual-testnets/develop/fork-testnet

---

## Success Criteria

- a fresh baseline Tenderly VNet is staged through deployment and operator setup
- the staged baseline has all required addresses and operator config recorded in docs
- one-stage happy path lands live from baseline lineage
- two-stage happy path lands live from baseline lineage
- one-stage dispute path lands live from baseline lineage
- each live scenario produces a distinct broadcast artifact and a short result record
- the final doc set explains the baseline lineage clearly enough for another operator to reproduce it

---

## Non-Goals

- do not prove that all scenarios must run on one continuously mutated VNet
- do not spend Tenderly quota on repeated deployment retries when a local test or local fork can answer the same debugging question
- do not mutate the existing evidence VNet further once a new baseline lineage is chosen

---

## Execution Rules

1. Any logic bug, assertion failure, or parameter mismatch must be debugged locally first.
2. Tenderly is only for the final live proof run, baseline staging, and minimal state inspection.
3. Prefer fork-per-scenario from the same staged baseline VNet.
4. Use snapshot/revert only if fork creation is unavailable or slower than needed.
5. After any live failure, capture the broadcast artifact, inspect on-chain state with `cast`, write down the failure mode, and return to local debugging before attempting another Tenderly write.

---

## Inputs And Records

**Files:**
- Read: `script/load-tenderly-shared-env.sh`
- Read: `script/tenderly-shared-env.env.example`
- Read: `script/DeployUnderwritingSharedEnv.s.sol`
- Read: `script/RegisterUnderwriter.s.sol`
- Read: `script/ConfigureUnderwriterRecipients.s.sol`
- Read: `script/TenderlySharedEnvSmoke.s.sol`
- Read: `docs/plans/2026-03-29-tenderly-shared-env-vnet-preparation.md`
- Read: `docs/plans/2026-03-29-tenderly-shared-env-deployment.md`
- Read: `docs/plans/2026-03-29-tenderly-shared-env-post-deploy-checks.md`
- Read: `docs/plans/2026-03-29-tenderly-shared-env-operator-setup.md`
- Read: `docs/plans/2026-03-29-tenderly-shared-env-smoke-progress.md`
- Create: `docs/plans/2026-03-29-tenderly-forked-smoke-recovery-plan.md`
- Create later: `docs/plans/2026-03-29-tenderly-forked-smoke-results.md`

**Required env:**
- `TENDERLY_ACCESS_KEY`
- `TENDERLY_VIRTUAL_TESTNET_RPC`
- `TENDERLY_VIRTUAL_TESTNET_WSS`
- `TENDERLY_VERIFIER_URL`
- `DEPLOYER_PRIVATE_KEY`
- `UNDERWRITER_PRIVATE_KEY`
- `CLIENT_PRIVATE_KEY`
- `PROVIDER_PRIVATE_KEY`
- `BASE_USDC`
- `ACP_TREASURY`
- `CLIENT_CONFIRMATION_WINDOW`
- `PREMIUM_RECIPIENT`
- `RECOVERY_RECIPIENT`
- `MERCHANT_EXECUTION_WALLET`

**Verifier note:** use `TENDERLY_VERIFIER_URL="${TENDERLY_VIRTUAL_TESTNET_RPC}/verify"` unless Tenderly's current docs change again.

---

## Task 1: Freeze The Current Evidence And Choose A New Baseline Lineage

**Goal:** Preserve the existing 2026-03-29 evidence without depending on that VNet for further writes.

### Step 1: Treat the current evidence VNet as read-only

Expected:
- do not run more broadcasts against the VNet recorded in `2026-03-29-tenderly-shared-env-smoke-progress.md`
- preserve its happy-path artifacts as historical evidence only

### Step 2: Create a new baseline lineage

Preferred:
- create a fresh Tenderly VNet for the new baseline

Alternative:
- fork a clean point that already contains the staged deployment and operator setup, if such a source VNet exists and is known-good

Expected:
- record the new baseline RPC and WSS before any funding or deployment steps begin

---

## Task 2: Reconfirm The Local Debug Loop Before Spending Tenderly Writes

**Goal:** Make local runs the default inner loop so Tenderly only sees final proof attempts.

### Step 1: Re-run the local regression suites

Run:

```bash
forge test --match-path test/script/DeployUnderwritingSharedEnvSmoke.t.sol -vv
forge test --match-path test/integration/UnderwritingSharedEnvFlow.t.sol -vv
forge test --match-path test/hooks/underwriting/UnderwritingHookUpgradeable.t.sol -vv
forge test --match-path test/hooks/underwriting/UnderwritingHookParity.t.sol -vv
```

Expected:
- all four suites pass before any new Tenderly baseline work begins

### Step 2: Keep scenario debugging local

Rule:
- if a smoke scenario needs parameter tuning or code fixes, add or update local tests first
- only return to Tenderly once the relevant local assertions are green

---

## Task 3: Stage One Clean Tenderly Baseline Through Operator Setup

**Goal:** Build one canonical baseline state that every live scenario can inherit from.

### Step 1: Load the env and derive actor addresses

Run:

```bash
source script/load-tenderly-shared-env.sh .env.tenderly.shared
```

Expected:
- all actor addresses are derived locally
- `PRIVATE_KEY` switching remains explicit per script invocation

### Step 2: Fund actors and seed Base USDC exactly once

Run the Tenderly Admin RPC top-ups from the existing Task 3 process.

Rule:
- do not repeat top-ups unless a baseline must be discarded and recreated

Expected:
- deployer, underwriter, client, and provider all have enough gas
- client and provider have enough Base USDC for one scenario run each on forked descendants

### Step 3: Deploy and verify the canonical stack

Run:

```bash
export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"

forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --verify \
  --verifier custom \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --etherscan-api-key "$TENDERLY_ACCESS_KEY" \
  --slow
```

Expected:
- ACP, hook, and evaluator deploy behind proxies
- coordinator and collateral manager deploy directly
- verification succeeds or the exact verification failure is captured immediately

### Step 4: Run post-deploy checks and operator setup

Run the existing scripts and `cast` checks that were already proven in the 2026-03-29 baseline docs.

Expected:
- hook whitelisted in ACP
- settlement token equals Base USDC
- hook and evaluator admins equal `DEPLOYER_ADDRESS`
- underwriter registered
- premium and recovery recipients configured

### Step 5: Write the baseline record before running any scenario

Record:
- baseline RPC and WSS
- all deployed addresses
- register/configure tx hashes
- final verified baseline nonce for the coordinator if relevant

Expected:
- baseline state is fully documented before scenario forks begin

---

## Task 4: Fork The Baseline Per Scenario

**Goal:** Run each live scenario from the same baseline lineage without carrying scenario mutations into the next case.

### Step 1: Preferred path, create one fresh fork per scenario

Scenarios:
- one-stage happy
- two-stage happy
- one-stage dispute

Expected:
- each scenario receives its own RPC endpoint
- each scenario starts from identical deployed contracts and operator setup

### Step 2: Fallback path, use snapshot/revert on the baseline VNet

Only if fork creation is unavailable:
- take one baseline `evm_snapshot`
- revert to that snapshot before each scenario

Expected:
- baseline is restored before each live attempt

### Step 3: Record the scenario lineage

For each scenario, record:
- parent baseline VNet
- child fork RPC or snapshot identifier
- the exact script entry point used

Expected:
- the final artifact can explain that all scenarios shared the same staged deployment lineage

---

## Task 5: Run The Live Scenario Matrix

**Goal:** Prove all three smoke scenarios with minimal Tenderly spend and clear artifacts.

### Step 1: One-stage happy path

Run:

```bash
forge script script/TenderlySharedEnvSmoke.s.sol:TenderlySharedEnvSmoke \
  --sig 'runOneStageHappy()' \
  --rpc-url "<scenario-rpc>" \
  --broadcast \
  --slow
```

Expected:
- job creation, provider acceptance, completion, and collateral release all land live
- result doc records the job ID, escrow, and broadcast artifact

### Step 2: Two-stage happy path

Run:

```bash
forge script script/TenderlySharedEnvSmoke.s.sol:TenderlySharedEnvSmoke \
  --sig 'runTwoStageHappy()' \
  --rpc-url "<scenario-rpc>" \
  --broadcast \
  --slow
```

Expected:
- root job and close job both land live
- close-job budget remains smaller than the root job budget
- result doc records both job IDs, escrow, and broadcast artifact

### Step 3: One-stage dispute path

Run:

```bash
forge script script/TenderlySharedEnvSmoke.s.sol:TenderlySharedEnvSmoke \
  --sig 'runOneStageDispute()' \
  --rpc-url "<scenario-rpc>" \
  --broadcast \
  --slow
```

Expected:
- dispute path lands live
- full slash routes the recovery amount to `RECOVERY_RECIPIENT`
- result doc records the job ID, escrow, slash outcome, and broadcast artifact

---

## Task 6: Failure Handling Loop

**Goal:** Keep Tenderly retries rare and informed.

### Step 1: If a live scenario fails, stop after the first failed attempt

Capture:
- Foundry stderr
- broadcast artifact path
- relevant `cast` reads proving whether any tx landed

Expected:
- no blind reruns against the same scenario RPC

### Step 2: Reproduce or explain the failure locally

Rule:
- write or update a local regression if the failure reflects repo logic
- if the failure is infrastructure-only, document the infra condition and avoid code churn

### Step 3: Retry only from a clean lineage

Preferred:
- create a fresh sibling fork from the same baseline

Fallback:
- discard the compromised baseline and restage a new baseline VNet only if the baseline itself is no longer trustworthy

---

## Task 7: Publish Final Artifacts And Closure Notes

**Goal:** Leave behind a reproducible and quota-aware evidence trail.

### Step 1: Write the final results doc

Create:
- `docs/plans/2026-03-29-tenderly-forked-smoke-results.md`

Include:
- baseline VNet details
- scenario fork details
- tx hashes and broadcast artifacts
- pass or fail status per scenario
- any remaining limitations or infra notes

### Step 2: Update the closure summary

Expected:
- explicitly state that the smoke matrix was proven from one shared staged deployment lineage
- explicitly state whether scenario isolation came from forks or snapshot/revert
- explain any Tenderly quota constraints encountered and how the new workflow avoided repeated rebuild cost

---

## Exit Criteria

- the new baseline lineage is documented
- all three scenarios are either proven live or blocked with precise evidence
- any future operator can resume from this doc without re-learning the previous quota failure
