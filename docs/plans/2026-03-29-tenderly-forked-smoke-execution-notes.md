# Tenderly Forked Smoke Execution Notes

This note is for the next operator. It records what was done, which blockers
appeared, how they were resolved, and which behaviors mattered in practice.

## Executive Summary

The Tenderly smoke workflow eventually succeeded, but only after changing the
execution model:

- local testing stayed the debug loop
- Tenderly was reduced to baseline staging and final proof
- happy paths were taken on one parent lineage
- dispute was completed later on a clean child fork from a newly restaged
  parent after the earlier parent became quota-blocked

## What Was Done

### 1. Original shared-VNet execution

- staged a Tenderly shared environment
- deployed and verified the underwriting stack
- configured underwriter registration and recipients
- proved one-stage happy and two-stage happy
- hit `HTTP 403` quota rejection during the dispute path

### 2. v2 recovery plan creation

- wrote `docs/plans/2026-03-29-tenderly-forked-smoke-recovery-plan.md`
- changed the strategy from one continuously mutated VNet to:
  - clean parent baseline
  - fork-per-scenario or snapshot-per-scenario
  - local-first debugging

### 3. Baseline-plus-snapshot validation

- created a fresh parent baseline
- reran Tasks 3 to 6 successfully
- took a baseline snapshot
- proved:
  - one-stage happy
  - two-stage happy
- hit quota again during dispute broadcast

### 4. Fork and recovery attempts

- checked whether the existing parent could be reverted to the clean snapshot
- Tenderly rejected `evm_revert` with the same quota gate
- checked whether the first child fork was a clean dispute target
- it was not; it already had `jobCounter=1`

### 5. Final clean-parent recovery

- created a brand-new parent baseline
- stopped before any smoke scenario
- validated fork-readiness
- forked that clean parent
- ran only `runOneStageDispute()` on the clean child fork
- dispute path succeeded

## Blockers And Resolutions

### Blocker 1: Tenderly quota exhaustion on live dispute run

Observed failure:

```text
HTTP 403
You've reached the quota limit for your current plan. Upgrade your plan in the dashboard or contact support to continue.
```

What it blocked:

- the one-stage dispute broadcast on the earlier parent baseline
- later, even `evm_revert` on that parent

How it was resolved:

- stop treating Tenderly as the inner loop
- restage a clean parent only when necessary
- use a clean child fork for the remaining scenario instead of replaying the
  whole workflow again

### Blocker 2: Wrong child fork lineage

Observed condition:

- first child fork had `jobCounter=1`
- clean dispute child should have `jobCounter=0`

Why this mattered:

- it meant the child inherited a parent that already had scenario mutation
- that child was not a valid clean dispute-only retry target

How it was resolved:

- create a fresh parent baseline
- stop before any smoke scenario
- fork that clean parent immediately

### Blocker 3: Bad clean-parent assumption about coordinator nonce

Initial assumption:

- clean parent should have `coordinator_nonce=0`

Observed reality:

- clean parent after Tasks 3 to 6 had:
  - `jobCounter=0`
  - `coordinator_nonce=1`

Why this mattered:

- the dispute child needed `SETTLEMENT_ESCROW_NONCE_START=1`
- using `0` would have predicted the wrong escrow address

Resolution:

- treat `jobCounter=0` as the clean-parent invariant for ACP jobs
- read the live coordinator nonce and export
  `SETTLEMENT_ESCROW_NONCE_START` from that value before a child scenario run

### Blocker 4: No confirmed REST path for VNet-to-VNet forking

What was learned:

- Tenderly's documented REST API clearly supports creating fresh VNets from a
  base network fork config
- the docs clearly describe UI-based VNet forking
- no documented REST endpoint was confirmed for forking one existing VNet into
  another existing VNet directly

Operational takeaway:

- create fresh baseline VNets via REST if needed
- use the Tenderly UI `Fork` button for parent-to-child forking

## What Worked Reliably

- `script/load-tenderly-shared-env.sh`
- deterministic deployment addresses across clean parent restages
- `script/TenderlySharedEnvSmoke.s.sol`
- local regression suites as the safety gate
- parent validation with:
  - `jobCounter`
  - coordinator nonce
  - contract code existence
  - whitelist and wiring checks

## What To Check Before Any Future Child Scenario Run

Use these checks before spending any live writes:

```bash
cast chain-id --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast call "$ACP_PROXY" "jobCounter()(uint256)" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast nonce "$COORDINATOR" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast code "$ACP_PROXY" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast code "$UNDERWRITING_HOOK" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
cast code "$COORDINATOR" --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

Expected clean child values for a dispute-only retry:

- `jobCounter=0`
- deployed contract code present
- `SETTLEMENT_ESCROW_NONCE_START` equals the live coordinator nonce

## Recommended Operator Workflow Going Forward

1. Run local regression first.
2. Stage one clean parent baseline only through Tasks 3 to 6.
3. Record:
   - parent RPC and WSS
   - deployment addresses
   - underwriter setup tx hashes
   - `jobCounter`
   - coordinator nonce
4. Fork the clean parent immediately in Tenderly UI.
5. On the child fork, export `SETTLEMENT_ESCROW_NONCE_START` from the live
   coordinator nonce.
6. Run exactly one smoke scenario per child fork.
7. If any child run fails, do not reuse that child. Fork a new clean child.

## Current Progress

- deployment staging workflow: `Stable`
- operator setup workflow: `Stable`
- one-stage happy live proof: `Complete`
- two-stage happy live proof: `Complete`
- one-stage dispute live proof: `Complete`
- final artifact documentation: `Complete`

## Key Files To Review

- `docs/plans/2026-03-29-tenderly-forked-smoke-recovery-plan.md`
- `docs/plans/2026-03-29-tenderly-forked-smoke-results.md`
- `docs/plans/2026-03-29-tenderly-shared-env-smoke-progress.md`
- `script/TenderlySharedEnvSmoke.s.sol`
- `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runOneStageHappy-latest.json`
- `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runTwoStageHappy-latest.json`
- `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runOneStageDispute-latest.json`

## Bottom Line

The repo code was not the blocker. Tenderly quota behavior and parent-lineage
cleanliness were the blockers. Once execution was narrowed to:

- clean parent
- clean child
- one scenario per child
- live nonce-derived escrow prediction

the remaining dispute proof succeeded cleanly.
