# Underwriting Query Snapshots And Backend API Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an underwriting domain backend that integrates with ACP core while owning underwriting-hook state, hook-managed parent-job linkage, underwriting query APIs, and dispute-flow orchestration gateways for client and underwriter actions.

**Architecture:** Use a single Python stack for the underwriting service: FastAPI for HTTP, SQLAlchemy for models, Alembic for local Postgres schema management, and `web3.py` for chain access. ACP core remains the generic job kernel, but this service owns the underwriting-domain projection on top of it: hook state, hook-managed parent/close linkage, settlement linkage, dispute state, and action gateways for the actors that participate in the underwriting flow. The chain remains the source of truth, but the backend serves underwriting-only snapshots, lineage views, dispute views, and workflow actions from a Postgres-backed domain model.

**Tech Stack:** Python 3.12, FastAPI, Pydantic, SQLAlchemy, Alembic, Postgres, `psycopg`, `web3.py`, pytest, Base/Tenderly JSON-RPC.

**Git note:** Do not create commits unless the user explicitly asks for them.

---

## Current Project Fit

This repo does **not** currently contain a backend API package. It also does **not** contain an on-chain "snapshot" primitive for underwriting state. The current read model is fragmented across several contracts:

- `contracts/interfaces/IAgenticCommerceKernel.sol`
- `contracts/hooks/underwriting/IUnderwritingHookView.sol`
- `contracts/settlement/UnderwritingSettlementCoordinator.sol`
- `contracts/settlement/UnderwritingEvaluator.sol`
- `contracts/settlement/UnderwritingCollateralManager.sol`

That means this work should be treated as a **new underwriting domain backend** plus a **local Postgres materialization layer**, not as a replacement for ACP core and not as a small extension to an existing server.

## Ownership Boundary

This plan assumes the following split:

- **ACP core** remains the generic kernel for base job lifecycle and escrow semantics.
- **Our underwriting service** owns:
  - underwriting-hook state reads
  - hook-managed parent/close linkage
  - underwriting-specific job and dispute query APIs
  - dispute-flow orchestration gateways for client and underwriter actions

This service should therefore behave as an underwriting domain layer integrated with ACP core, not as a full ACP backend rebuild.

## Decision Summary

- V1 should expose underwriting read APIs plus limited dispute-flow action gateways for client and underwriter actions.
- V1 should use **Python**, not Node.js, so the API, indexer, and Alembic migrations all live in one stack.
- V1 should use **local Postgres** as the serving layer for underwriting-only snapshots, lineage views, disputes, timelines, and action-request tracking.
- V1 should define a **snapshot** as an off-chain aggregated view of underwriting state for a single ACP `jobId`.
- V1 should use direct contract reads as the **source of truth** when hydrating or refreshing a snapshot.
- V1 should use log polling only to discover which jobs need to be refreshed and to build timelines.
- V1 should treat underwriting-hook-managed parent/close linkage as an underwriting-owned concern, not as a dependency on ACP-owned lineage semantics.
- V1 should support **internal async orchestration** for client, provider, and underwriter flows, but it does **not** require external webhook delivery to ship the underwriting service.
- V1 should support point-accurate underwriting job reads, actor-based query APIs for client and provider, lineage-based queries for parent/close flows, dispute query APIs, and dispute action gateways for client and underwriter flows.

## Virtuals ACP SDK Reference Alignment

The current Virtuals ACP SDK is a useful **workflow reference** for the off-chain layer, but it is **not** a direct ABI or contract-state reference for this repo.

Useful references from the current SDK/docs:

- package: `@virtuals-protocol/acp-node`
- actor-oriented lifecycle methods such as:
  - initiate job
  - accept or reject
  - pay
  - deliver
- callback-oriented orchestration through:
  - `onNewTask`
  - `onEvaluate`
- documented support for both:
  - reactive/event-based handling
  - polling mode

What to borrow from the SDK:

- role-aware orchestration patterns for buyer/client, seller/provider, and evaluator-like actors
- persistent off-chain job state
- callback or polling driven background processing
- idempotent handling of asynchronous job transitions

What **not** to borrow blindly:

- exact SDK job abstractions as if they were the canonical model for this repo
- assumptions that plain ACP lifecycle alone captures underwriting behavior
- any expectation that SDK callbacks fully cover:
  - underwriting commit state
  - `jobSettlementJobId`
  - client confirmation windows
  - underwriter adjudication
  - settlement coordinator or collateral manager flows

In this design doc, the Virtuals ACP SDK should be treated as a reference for **off-chain orchestration ergonomics**, while the canonical source of truth for workflow state remains the contracts in this repo.

## Why Python, Not Node.js

Use Python here for three practical reasons:

1. The user already chose **Alembic** for schema management, which strongly favors a Python service.
2. The backend is mostly an indexer plus a query API, not a browser-facing runtime where Node brings a clear advantage.
3. One-language ownership for HTTP, DB models, migrations, and sync jobs is simpler than mixing TypeScript and Python in the same repo.

Node.js would still be viable if the main priority were `viem` ergonomics or reuse of an existing TS service, but this repo has no existing backend to reuse and the Postgres/Alembic requirement makes Python the cleaner choice.

## Why Webhooks Are Optional In V1

An asynchronous orchestration layer **is** needed for the full client/provider/underwriter experience. A webhook layer is **not strictly required** to ship v1 of the query snapshot API.

- The chain data source is pull-based, not push-based.
- The backend can keep itself current with a polling/indexing worker.
- Consumers can query snapshots and timelines over HTTP without needing outbound notifications.
- Internal role-specific workers can react to DB state changes without requiring HTTP webhook delivery between services.

When outbound webhooks become useful:

- client, provider, and underwriter are deployed as separate services
- external systems need near-real-time push notifications
- humans or agents need immediate prompts for:
  - `job submitted`
  - `client confirmation window opened`
  - `underwriter action required`
  - `job rejected`
  - `job expired`
  - `dispute opened`
  - `collateral slashed`

Recommended stance for this plan:

- V1: build DB-backed snapshots, timelines, and internal async orchestration
- V2: add optional outbound webhooks on top of the materialized event model if external integration needs them

## Actor Orchestration Model

The query API should be designed so it can later support orchestration for three operational actors:

1. **Client**
- funds jobs
- observes provider submission
- may confirm within the confirmation window
- may open a post-success dispute

2. **Provider**
- watches for protected jobs that have been funded and orchestrated
- submits evidence before `expiredAt`
- may later request collateral release

3. **Underwriter**
- monitors committed and protected jobs
- configures recipients
- acts after the client confirmation window when adjudication is required
- may participate in dispute slash resolution

For v1, this plan should support those actors through:

- materialized snapshots
- timelines
- internal background workers or scheduled checks
- durable DB state for retry-safe processing

For later phases, the same model should support:

- outbound webhooks
- notification fanout
- role-specific action queues

The design should therefore treat webhooks as a **delivery mechanism layered on top of normalized DB events**, not as the primary source of truth or the primary workflow engine.

## Canonical On-Chain Sources

The backend must compose the following sources explicitly:

1. **ACP job state** from `IAgenticCommerceKernel.getJob(jobId)` and `AgenticCommerce.jobCounter()`
2. **Underwriting hook-owned lineage and sidecar state** from `IUnderwritingHookView`
3. **Settlement orchestration state** from `UnderwritingSettlementCoordinator`
4. **Evaluator metadata** from `UnderwritingEvaluator`
5. **Underwriter recipient configuration** from `UnderwritingCollateralManager`

The backend must **not** assume `settlementJobId == jobId`. It must always call `hook.jobSettlementJobId(jobId)` and join settlement records using that value.

For underwriting-specific parent/close behavior, the backend should treat the hook-owned lineage model as authoritative:

- `hook.getParentJobId(closeJobId)`
- `hook.getActiveCloseJobId(parentJobId)`
- `hook.isAwaitingClose(jobId)`
- `hook.getCommit(jobId).parentJobId`
- `hook.getCommit(jobId).allowCloseJob`

ACP kernel lineage fields may still be recorded for compatibility or debugging, but they should not be the primary source of truth for underwriting-owned parent/close flows.

## Snapshot Definition

The snapshot returned by the backend should be an assembled object with this minimum shape:

```python
class UnderwritingJobSnapshot(BaseModel):
    chain_id: int
    as_of_block: int
    job_id: int
    settlement_job_id: int
    job: dict
    lineage: dict
    hook: dict
    settlement: dict
    dispute: dict
    underwriter: dict
    derived: dict
    orchestration: dict
```

The normalized payload should include:

- `job.id`, `client`, `provider`, `evaluator`, `description`, `budget`, `expiredAt`, `status`, `hook`, `paymentToken`, `providerAgentId`, `submittedAt`
- `job.kind`
- `lineage.parentJobId`, `lineage.activeCloseJobId`, `lineage.rootJobId`, `lineage.isAwaitingClose`, `lineage.allowCloseJob`
- `hook.hasCommit`, `underwriter`, `sidecarState`, `isAwaitingClose`, `submittedAt`
- `hook.commit.parentJobId`, `underwriter`, `validUntil`, `policyHash`, `quoteIdHash`, `termsHash`, `allowCloseJob`
- `settlement.state`, `unlockAt`, `escrow`
- `dispute.isOpen`, `dispute.reasonCode`, `dispute.openedBy`, `dispute.openedAt`, `dispute.resolvedAt`, `dispute.slashAmountUsdc`, `dispute.status`
- `underwriter.registered`, `premiumRecipient`, `recoveryRecipient`
- derived booleans such as:
  - `isProtected`
  - `clientConfirmationOpen`
  - `awaitingUnderwriterDecision`
  - `canSettleExpiry`
  - `canReleaseCollateral`
  - `canOpenSuccessDispute`
- orchestration hints such as:
  - `nextActionRole`
  - `nextActionReason`
  - `nextActionDeadline`
  - `clientActionRequired`
  - `providerActionRequired`
  - `underwriterActionRequired`

This object is an **off-chain projection**, not a stored Solidity struct.

## Orchestration Derivation Rules

The backend should not stop at raw state projection. It should also derive actionable workflow hints from the current ACP + underwriting runtime.

Minimum v1 derived orchestration rules:

- if a job is funded, protected, and evidence has not been submitted before `expiredAt`, mark:
  - `nextActionRole = "provider"`
  - `providerActionRequired = true`
  - `nextActionReason = "submit evidence before expiry"`
- if evidence has been submitted and the client confirmation window is still open, mark:
  - `nextActionRole = "client"`
  - `clientActionRequired = true`
  - `nextActionReason = "confirm during confirmation window"`
- if evidence has been submitted and the client confirmation window has elapsed without completion, mark:
  - `nextActionRole = "underwriter"`
  - `underwriterActionRequired = true`
  - `nextActionReason = "adjudicate with complete or reject"`
- if a job is completed and settlement state is `SuccessPendingRelease`, mark either:
  - `nextActionRole = "provider"` when collateral release is available, or
  - `nextActionRole = "client"` when dispute remains openable before `unlockAt`
- if a dispute is open, mark:
  - `nextActionRole = "underwriter"`
  - `underwriterActionRequired = true`
  - `nextActionReason = "resolve success dispute"`

These hints are not a replacement for contract reads. They are an operator-facing projection that helps local services, bots, or future webhook handlers know who should act next.

## Dispute Gateway Model

This service should expose dispute flow not only as query state, but also as an orchestration gateway for the actions currently owned by the client and underwriter.

Minimum dispute gateway coverage:

- client-side dispute open flow
- underwriter-side dispute slash resolution flow

Because the underlying on-chain actions have different authorization models, the gateway should support both of these patterns:

1. **prepare**
- validate current workflow state
- compute the expected action payload
- record an action request row
- return the payload that must be signed or submitted

2. **submit**
- accept a signed payload or an authenticated relay request
- broadcast or relay the action if the deployment model allows it
- persist request status, tx hash, and terminal result

The gateway should not assume a single signer model for all actions:

- client-triggered dispute opens may require a client-controlled signer or wallet session
- underwriter dispute resolution may be expressible as a signed attestation plus relay

## Database Model

Use local Postgres with Alembic-managed schema migrations.

### Required tables

1. `sync_state`
- one row per sync cursor or background job
- fields:
  - `key`
  - `value`
  - `updated_at`

2. `underwriting_job_snapshots`
- one row per `job_id`
- searchable scalar columns copied out of the normalized snapshot
- full normalized snapshot persisted as `jsonb`
- minimum fields:
  - `job_id`
  - `settlement_job_id`
  - `parent_job_id`
  - `active_close_job_id`
  - `root_job_id`
  - `is_awaiting_close`
  - `allow_close_job`
  - `chain_id`
  - `job_status`
  - `sidecar_state`
  - `settlement_state`
  - `dispute_status`
  - `next_action_role`
  - `next_action_reason`
  - `next_action_deadline`
  - `client_action_required`
  - `provider_action_required`
  - `underwriter_action_required`
  - `client`
  - `provider`
  - `underwriter`
  - `payment_token`
  - `expired_at`
  - `submitted_at`
  - `as_of_block`
  - `snapshot_json`
  - `updated_at`

3. `underwriting_timeline_events`
- one row per normalized event
- minimum fields:
  - `chain_id`
  - `job_id`
  - `settlement_job_id`
  - `block_number`
  - `transaction_hash`
  - `log_index`
  - `source`
  - `event_name`
  - `payload_json`
  - `inserted_at`

4. `underwriting_disputes`
- one row per settlement-scoped dispute projection
- minimum fields:
  - `job_id`
  - `settlement_job_id`
  - `status`
  - `reason_code`
  - `opened_by`
  - `opened_at`
  - `resolved_at`
  - `slash_amount_usdc`
  - `tx_hash`
  - `dispute_json`
  - `updated_at`

5. `underwriting_action_requests`
- one row per orchestration gateway request
- minimum fields:
  - `request_id`
  - `job_id`
  - `settlement_job_id`
  - `actor_role`
  - `action_type`
  - `status`
  - `request_payload_json`
  - `signed_payload_json`
  - `tx_hash`
  - `error_message`
  - `created_at`
  - `updated_at`

6. `underwriters`
- point-lookup table populated opportunistically when a snapshot or explicit underwriter query touches an address
- minimum fields:
  - `address`
  - `registered`
  - `premium_recipient`
  - `recovery_recipient`
  - `last_checked_block`
  - `updated_at`

### Important limitation

Do **not** promise a complete underwriter registry table in v1. The hook exposes `registeredUnderwriters(address)` as a point lookup, but there is no emitted registration event or enumerable registry in the current contracts.

### Future-compatible extension

Do **not** add webhook delivery tables in v1 unless there is a real external integration requirement. If webhook delivery is later required, add a separate outbox-style table such as `workflow_notifications` or `webhook_deliveries` on top of the materialized snapshot/event model.

## Sync Strategy

### Initial backfill

The first sync pass should:

1. Read `AgenticCommerce.jobCounter()`
2. Iterate job ids from `1..jobCounter`
3. For each job:
   - read the ACP job
   - keep only jobs whose `hook` equals the configured underwriting hook address
   - hydrate the full underwriting snapshot from live contract calls
   - upsert `underwriting_job_snapshots`
4. Backfill ACP and settlement logs for those jobs into `underwriting_timeline_events`

### Incremental sync

After backfill, a polling worker should:

1. Read the last processed block from `sync_state`
2. Fetch logs from:
   - `AgenticCommerce`
   - `UnderwritingSettlementCoordinator`
   - `UnderwritingSettlementEscrow`
   - `UnderwritingCollateralManager`
3. Derive affected `job_id` or `settlement_job_id` values from those logs
4. Re-hydrate only the touched jobs from live contract reads
5. Upsert the refreshed snapshots and timeline rows
6. Advance the sync cursor in `sync_state`

### No webhook requirement

The indexer should be a simple polling worker or scheduled task inside the Python service. No inbound webhook flow is required for v1, and outbound webhook delivery should remain optional rather than mandatory.

## Known Constraints To Encode In The Plan

- `IUnderwritingHookView.getCommit(jobId)` is not a complete existence proof by itself; the backend must not treat an all-zero commit as a real underwriting commitment.
- Some internal hook fields are not directly queryable today, including:
  - `commitHashByJobId`
  - `committedPaymentTokenByJobId`
  - `committedBudgetByJobId`
- The underwriting hook does not emit a complete event stream, so historical hook-side transitions cannot be reconstructed perfectly from logs alone.
- There is no complete on-chain enumerable underwriter registry.
- `AgenticCommerce.jobCounter()` exists, so full-job backfill is feasible even though the kernel does not expose a jobs list endpoint.

## Target API Surface

### Required v1 endpoints

- `GET /underwriting/health`
- `GET /underwriting/jobs/{job_id}`
- `GET /underwriting/jobs`
- `GET /underwriting/jobs/{job_id}/related`
- `GET /underwriting/jobs/{job_id}/timeline`
- `GET /underwriting/jobs/{job_id}/dispute`
- `GET /underwriting/disputes`
- `GET /underwriters/{address}`
- `POST /underwriting/jobs/{job_id}/disputes/open/prepare`
- `POST /underwriting/jobs/{job_id}/disputes/open/submit`
- `POST /underwriting/jobs/{job_id}/disputes/resolve-slash/prepare`
- `POST /underwriting/jobs/{job_id}/disputes/resolve-slash/submit`

### Endpoint semantics

`GET /underwriting/health`
- Returns:
  - `ok`
  - `chainId`
  - `latestRpcBlock`
  - `lastIndexedBlock`
  - `dbStatus`

`GET /underwriting/jobs/{job_id}`
- Returns the authoritative current underwriting snapshot for one job.
- If the row is missing or stale, the backend may synchronously re-hydrate it from chain before responding.
- Must include `chainId` and `asOfBlock`.
- Must return `404` when the job does not exist.
- Must return `409` or a clear typed error when the job exists but is not an underwriting-hooked job for the configured runtime.

`GET /underwriting/jobs`
- Reads from Postgres, not from a live bounded chain scan.
- Supports filters such as:
  - `status`
  - `sidecarState`
  - `settlementState`
  - `parentJobId`
  - `rootJobId`
  - `isAwaitingClose`
  - `nextActionRole`
  - `clientActionRequired`
  - `providerActionRequired`
  - `underwriterActionRequired`
  - `underwriter`
  - `client`
  - `provider`
  - `paymentToken`
- Supports cursor or offset pagination.
- Returns `asOfBlock` for the materialized result set.

`GET /underwriting/jobs/{job_id}/related`
- Returns the underwriting-owned lineage view for the queried job:
  - parent job
  - active close job
  - root job
  - settlement identity

`GET /underwriting/jobs/{job_id}/timeline`
- Returns normalized ACP and settlement events for a single job.
- Reads from `underwriting_timeline_events`.
- Must document that hook-side history is partial because the hook does not emit a full event stream.

`GET /underwriting/jobs/{job_id}/dispute`
- Returns the current dispute projection for one underwriting job.
- Reads from `underwriting_disputes` plus the latest snapshot.

`GET /underwriting/disputes`
- Reads from Postgres.
- Supports filters such as:
  - `status`
  - `client`
  - `provider`
  - `underwriter`
  - `jobId`
  - `settlementJobId`

`GET /underwriters/{address}`
- Returns:
  - `registeredUnderwriters(address)` from the hook
  - `recipientsByUnderwriter(address)` from the collateral manager
- This is a point lookup only, not a complete registry listing.

`POST /underwriting/jobs/{job_id}/disputes/open/prepare`
- Validates whether the client-side dispute open action is currently allowed.
- Creates an `underwriting_action_requests` row.
- Returns the payload or transaction intent needed for the client-side action.

`POST /underwriting/jobs/{job_id}/disputes/open/submit`
- Accepts the signed or authenticated client action request.
- Broadcasts or relays it when supported by the deployment model.
- Persists request status and tx metadata.

`POST /underwriting/jobs/{job_id}/disputes/resolve-slash/prepare`
- Validates whether the underwriter-side slash resolution is currently allowed.
- Creates an `underwriting_action_requests` row.
- Returns the slash attestation payload to sign or submit.

`POST /underwriting/jobs/{job_id}/disputes/resolve-slash/submit`
- Accepts the signed slash payload or relay request.
- Broadcasts or relays it when supported by the deployment model.
- Persists request status, tx hash, and terminal result.

## Event Sources For Timelines

The timeline index should normalize logs from:

- `contracts/acp/contracts/AgenticCommerce.sol`
  - `JobCreated`
  - `ProviderSet`
  - `BudgetSet`
  - `JobFunded`
  - `JobSubmitted`
  - `JobCompleted`
  - `JobRejected`
  - `JobExpired`
  - `PaymentReleased`
  - `Refunded`
- `contracts/settlement/UnderwritingSettlementCoordinator.sol`
  - `FundingOrchestrated`
  - `CollateralReleaseRequested`
  - `CollateralReleased`
  - `ExpirySettled`
  - `RejectedJobFinalized`
  - `SuccessDisputeOpened`
  - `DisputeSlashApplied`
- `contracts/settlement/UnderwritingSettlementEscrow.sol`
  - `EscrowConfigured`
  - `CollateralPullRequested`
  - `PrincipalPullRequested`
  - `CollateralLockRequested`
  - `PrincipalReleaseRequested`
  - `DeliveryConfirmationRequested`
  - `CollateralReleaseRequested`
  - `TimeoutClaimRequested`
  - `SlashExecuted`
- `contracts/settlement/UnderwritingCollateralManager.sol`
  - `UnderwriterRecipientsSet`
  - `CollateralLocked`
  - `PrincipalReleasedToMerchant`
  - `CollateralReleased`
  - `TimeoutClaimed`
  - `CollateralSlashed`

The timeline row shape should be normalized to:

```python
class TimelineEvent(BaseModel):
    block_number: int
    transaction_hash: str
    log_index: int
    source: Literal["acp", "coordinator", "escrow", "collateral_manager"]
    event_name: str
    payload: dict[str, Any]
```

## Out Of Scope For V1

- New on-chain snapshot contracts
- Third-party webhook subscription management and delivery infrastructure
- Generic ACP write endpoints for completion, rejection, funding, or settlement outside the underwriting dispute gateway
- Full historical reconstruction of hook-only transitions that were never emitted as events
- Multi-chain aggregation
- Realtime streaming transports such as websockets or SSE
- A complete underwriter discovery/indexing system

---

## Phase Overview

The implementation should be executed in five larger phases:

### Phase 1: Backend Foundation

Goal:
- stand up the Python service skeleton, local Postgres integration, and Alembic-managed schema

Tasks:
- Task 1: Scaffold The Python Backend Package
- Task 2: Add SQLAlchemy Models And Alembic Migration

Exit criteria:
- FastAPI app boots locally
- health endpoint works
- Postgres schema exists and migrations run cleanly

### Phase 2: Hook, Lineage, And Workflow Projection

Goal:
- turn live ACP + underwriting contract reads into normalized snapshots, hook-owned lineage views, dispute projections, and role-aware action hints

Tasks:
- Task 3: Implement Contract Readers And Snapshot Hydration
- Task 4: Persist Derived Orchestration Fields

Exit criteria:
- single-job hydration works from live contract reads or test doubles
- snapshots include both raw state and derived orchestration hints
- snapshot persistence model supports filtering by actor/action state

### Phase 3: Sync And Query API

Goal:
- keep Postgres up to date from chain activity and expose stable underwriting, lineage, and dispute query endpoints

Tasks:
- Task 5: Add Backfill And Incremental Sync Workers
- Task 6: Add Snapshot, List, Timeline, And Underwriter Endpoints

Exit criteria:
- initial backfill from `jobCounter()` succeeds
- incremental sync updates touched jobs and timelines
- API serves underwriting job, lineage, dispute, timeline, and underwriter queries from Postgres

### Phase 4: Dispute Gateway

Goal:
- expose the client and underwriter dispute actions through a controlled orchestration gateway

Tasks:
- Task 7: Add Dispute Gateway Action APIs

Exit criteria:
- dispute prepare and submit flows exist for client dispute-open and underwriter slash resolution
- action requests are persisted with status and tx metadata

### Phase 5: Documentation And Verification

Goal:
- document the operator workflow and prove the backend matches the current underwriting runtime

Tasks:
- Task 8: Add Documentation And Local Operator Workflow
- Task 9: Add Integration Coverage Against A Controlled Runtime

Exit criteria:
- backend README documents setup, sync flow, lineage ownership, dispute gateway, and orchestration model
- integration tests verify snapshots and dispute flows against controlled ACP + underwriting scenarios

---

## Phase 1: Backend Foundation

### Task 1: Scaffold The Python Backend Package

**Files:**
- Create: `backend/underwriting_query_api/pyproject.toml`
- Create: `backend/underwriting_query_api/alembic.ini`
- Create: `backend/underwriting_query_api/app/config.py`
- Create: `backend/underwriting_query_api/app/main.py`
- Create: `backend/underwriting_query_api/app/api/health.py`
- Create: `backend/underwriting_query_api/tests/test_health.py`

**Step 1: Write the failing health-route test**

```python
def test_health_returns_chain_and_index_status(client):
    response = client.get("/underwriting/health")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert "chainId" in body
    assert "lastIndexedBlock" in body
```

**Step 2: Run test to verify it fails**

Run: `pytest backend/underwriting_query_api/tests/test_health.py -v`

Expected: FAIL because the backend package and route do not exist yet.

**Step 3: Write the minimal server scaffold**

Implement:
- FastAPI app factory
- config loading for:
  - `DATABASE_URL`
  - `UNDERWRITING_RPC_URL`
  - `ACP_ADDRESS`
  - `UNDERWRITING_HOOK_ADDRESS`
  - `UNDERWRITING_COORDINATOR_ADDRESS`
  - `UNDERWRITING_EVALUATOR_ADDRESS`
  - `UNDERWRITING_COLLATERAL_MANAGER_ADDRESS`
- `/underwriting/health` route that reads DB health plus RPC chain id/head

**Step 4: Run test to verify it passes**

Run: `pytest backend/underwriting_query_api/tests/test_health.py -v`

Expected: PASS

---

### Task 2: Add SQLAlchemy Models And Alembic Migration

**Files:**
- Create: `backend/underwriting_query_api/alembic/env.py`
- Create: `backend/underwriting_query_api/alembic/versions/0001_create_underwriting_query_tables.py`
- Create: `backend/underwriting_query_api/app/db/base.py`
- Create: `backend/underwriting_query_api/app/db/models.py`
- Create: `backend/underwriting_query_api/tests/test_models.py`

**Step 1: Write the failing model test**

```python
def test_snapshot_model_exposes_search_columns():
    columns = UnderwritingJobSnapshotRow.__table__.columns.keys()
    assert "job_id" in columns
    assert "sidecar_state" in columns
    assert "snapshot_json" in columns
```

**Step 2: Run test to verify it fails**

Run: `pytest backend/underwriting_query_api/tests/test_models.py -v`

Expected: FAIL because the DB models and migration do not exist yet.

**Step 3: Implement the schema**

Implementation requirements:
- add `sync_state`
- add `underwriting_job_snapshots`
- add `underwriting_timeline_events`
- add `underwriters`
- add indexes for:
  - `job_status`
  - `sidecar_state`
  - `settlement_state`
  - `underwriter`
  - `client`
  - `provider`
  - `(block_number, log_index)` on timeline rows

**Step 4: Run the migration locally**

Run:
- `alembic -c backend/underwriting_query_api/alembic.ini upgrade head`

Expected: PASS and local Postgres contains the new tables.

**Step 5: Run test to verify it passes**

Run: `pytest backend/underwriting_query_api/tests/test_models.py -v`

Expected: PASS

---

## Phase 2: Hook, Lineage, And Workflow Projection

### Task 3: Implement Contract Readers And Snapshot Hydration

**Files:**
- Create: `backend/underwriting_query_api/app/chain/abi.py`
- Create: `backend/underwriting_query_api/app/chain/client.py`
- Create: `backend/underwriting_query_api/app/schemas/snapshots.py`
- Create: `backend/underwriting_query_api/app/services/derive_flags.py`
- Create: `backend/underwriting_query_api/app/services/derive_orchestration.py`
- Create: `backend/underwriting_query_api/app/services/derive_lineage.py`
- Create: `backend/underwriting_query_api/app/services/derive_dispute.py`
- Create: `backend/underwriting_query_api/app/services/hydrate_snapshot.py`
- Create: `backend/underwriting_query_api/tests/test_hydrate_snapshot.py`

**Step 1: Write the failing hydration test**

```python
def test_hydrate_snapshot_joins_acp_hook_and_settlement_reads(fake_chain):
    snapshot = hydrate_underwriting_snapshot(job_id=42, chain=fake_chain)
    assert snapshot.job_id == 42
    assert snapshot.settlement_job_id == 4200
    assert snapshot.hook["underwriter"] == "0x0000000000000000000000000000000000000042"
    assert snapshot.settlement["state"] == "PrincipalReleased"
```

**Step 2: Run test to verify it fails**

Run: `pytest backend/underwriting_query_api/tests/test_hydrate_snapshot.py -v`

Expected: FAIL because the chain readers and hydrator do not exist yet.

**Step 3: Implement the hydrator**

Implementation requirements:
- read `acp.getJob(jobId)`
- require the configured underwriting hook runtime for this API
- read `hook.getCommit(jobId)`, `jobUnderwriter(jobId)`, `jobSidecarState(jobId)`, `jobSettlementJobId(jobId)`, `isAwaitingClose(jobId)`, `jobSubmittedAt(jobId)`
- derive hook-owned lineage from:
  - `hook.getParentJobId(closeJobId)`
  - `hook.getActiveCloseJobId(parentJobId)`
  - `hook.isAwaitingClose(jobId)`
  - `hook.getCommit(jobId).parentJobId`
  - `hook.getCommit(jobId).allowCloseJob`
- read `coordinator.jobSettlementState(jobId)`, `unlockAtByJobId(jobId)`, `settlementEscrow(jobId)`
- read `hook.registeredUnderwriters(underwriter)` and `manager.recipientsByUnderwriter(underwriter)`
- derive dispute projection from settlement state plus latest dispute-related events
- compute the `derived` flags in one place
- compute role-aware orchestration hints in one place
- do not expose internal hook fields that are not queryable today

**Step 4: Run test to verify it passes**

Run: `pytest backend/underwriting_query_api/tests/test_hydrate_snapshot.py -v`

Expected: PASS

---

### Task 4: Persist Lineage, Dispute, And Orchestration Fields

**Files:**
- Modify: `backend/underwriting_query_api/app/db/models.py`
- Modify: `backend/underwriting_query_api/alembic/versions/0001_create_underwriting_query_tables.py`
- Create: `backend/underwriting_query_api/tests/test_derive_orchestration.py`

**Step 1: Write the failing orchestration-derivation test**

```python
def test_submitted_job_with_open_confirmation_window_requires_client_action():
    orchestration = derive_orchestration(
        {
            "job": {"status": "Submitted"},
            "hook": {"sidecarState": "EvidenceSubmitted", "submittedAt": 100},
            "settlement": {"state": "PrincipalReleased", "unlockAt": 0},
            "derived": {"clientConfirmationOpen": True},
        },
        now=120,
    )
    assert orchestration["nextActionRole"] == "client"
    assert orchestration["clientActionRequired"] is True
```

**Step 2: Run test to verify it fails**

Run: `pytest backend/underwriting_query_api/tests/test_derive_orchestration.py -v`

Expected: FAIL because orchestration derivation does not exist yet.

**Step 3: Implement orchestration derivation and persistence**

Implementation requirements:
- derive `next_action_role`, `next_action_reason`, and actor-required booleans
- persist parent/close lineage scalars into `underwriting_job_snapshots`
- persist dispute-status scalars into `underwriting_job_snapshots`
- persist those scalars into `underwriting_job_snapshots`
- persist the full orchestration block inside `snapshot_json`
- persist a dispute projection row into `underwriting_disputes`
- keep derivation deterministic and fully recomputable from live state

**Step 4: Run test to verify it passes**

Run: `pytest backend/underwriting_query_api/tests/test_derive_orchestration.py -v`

Expected: PASS

---

## Phase 3: Sync And Query API

### Task 5: Add Backfill And Incremental Sync Workers

**Files:**
- Create: `backend/underwriting_query_api/app/services/backfill.py`
- Create: `backend/underwriting_query_api/app/services/sync_logs.py`
- Create: `backend/underwriting_query_api/app/services/upsert_snapshot.py`
- Create: `backend/underwriting_query_api/app/services/upsert_timeline.py`
- Create: `backend/underwriting_query_api/tests/test_backfill.py`
- Create: `backend/underwriting_query_api/tests/test_sync_logs.py`

**Step 1: Write the failing backfill and sync tests**

```python
def test_backfill_scans_job_counter_and_persists_underwriting_snapshots(db_session, fake_chain):
    run_backfill(chain=fake_chain, db=db_session)
    assert db_session.query(UnderwritingJobSnapshotRow).count() == 2

def test_incremental_sync_refreshes_jobs_touched_by_logs(db_session, fake_chain):
    run_incremental_sync(chain=fake_chain, db=db_session)
    assert db_session.query(UnderwritingTimelineEventRow).count() > 0
```

**Step 2: Run test to verify it fails**

Run:
- `pytest backend/underwriting_query_api/tests/test_backfill.py -v`
- `pytest backend/underwriting_query_api/tests/test_sync_logs.py -v`

Expected: FAIL because the sync workers do not exist yet.

**Step 3: Implement the workers**

Implementation requirements:
- initial backfill uses `AgenticCommerce.jobCounter()`
- incremental sync reads logs after `lastIndexedBlock`
- derive touched job ids or settlement job ids from ACP and settlement logs
- re-hydrate affected jobs from live reads
- upsert snapshot and timeline rows
- upsert dispute projection rows when dispute-related events appear
- advance the cursor in `sync_state`

**Step 4: Run tests to verify they pass**

Run:
- `pytest backend/underwriting_query_api/tests/test_backfill.py -v`
- `pytest backend/underwriting_query_api/tests/test_sync_logs.py -v`

Expected: PASS

---

### Task 6: Add Underwriting, Lineage, Dispute, Timeline, And Underwriter Endpoints

**Files:**
- Create: `backend/underwriting_query_api/app/api/jobs.py`
- Create: `backend/underwriting_query_api/app/api/disputes.py`
- Create: `backend/underwriting_query_api/app/api/underwriters.py`
- Create: `backend/underwriting_query_api/app/services/query_jobs.py`
- Create: `backend/underwriting_query_api/app/services/query_disputes.py`
- Create: `backend/underwriting_query_api/app/services/query_timeline.py`
- Create: `backend/underwriting_query_api/app/services/query_underwriter.py`
- Create: `backend/underwriting_query_api/tests/test_jobs_api.py`
- Create: `backend/underwriting_query_api/tests/test_disputes_api.py`
- Create: `backend/underwriting_query_api/tests/test_underwriters_api.py`

**Step 1: Write the failing API tests**

```python
def test_get_job_returns_materialized_snapshot(client, seeded_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_snapshot.job_id}")
    assert response.status_code == 200
    assert response.json()["jobId"] == str(seeded_snapshot.job_id)

def test_list_jobs_filters_by_sidecar_state(client, seeded_snapshot):
    response = client.get("/underwriting/jobs?sidecarState=EvidenceSubmitted")
    assert response.status_code == 200
    assert len(response.json()["items"]) == 1

def test_list_jobs_filters_by_next_action_role(client, seeded_snapshot):
    response = client.get("/underwriting/jobs?nextActionRole=underwriter")
    assert response.status_code == 200
    assert len(response.json()["items"]) == 1

def test_get_related_jobs_returns_parent_and_close_linkage(client, seeded_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_snapshot.job_id}/related")
    assert response.status_code == 200
    assert "lineage" in response.json()

def test_get_underwriter_is_point_lookup_only(client, seeded_underwriter):
    response = client.get(f"/underwriters/{seeded_underwriter.address}")
    assert response.status_code == 200
    assert response.json()["registered"] is True
```

**Step 2: Run test to verify it fails**

Run:
- `pytest backend/underwriting_query_api/tests/test_jobs_api.py -v`
- `pytest backend/underwriting_query_api/tests/test_disputes_api.py -v`
- `pytest backend/underwriting_query_api/tests/test_underwriters_api.py -v`

Expected: FAIL because the routes and query services do not exist yet.

**Step 3: Implement the routes**

Implementation requirements:
- `GET /underwriting/jobs/{job_id}` reads the materialized row and may refresh if stale
- `GET /underwriting/jobs` filters via Postgres query, not live chain scan
- `GET /underwriting/jobs/{job_id}/related` returns hook-owned lineage and settlement relationships
- `GET /underwriting/jobs/{job_id}/timeline` reads normalized events from Postgres
- `GET /underwriting/jobs/{job_id}/dispute` reads dispute projection from Postgres
- `GET /underwriting/disputes` filters dispute projections by actor and status
- `GET /underwriters/{address}` performs point lookup and may refresh from chain
- include orchestration hints in job responses and list filters
- return typed errors for:
  - missing job
  - non-underwriting job
  - invalid filters

**Step 4: Run tests to verify they pass**

Run:
- `pytest backend/underwriting_query_api/tests/test_jobs_api.py -v`
- `pytest backend/underwriting_query_api/tests/test_disputes_api.py -v`
- `pytest backend/underwriting_query_api/tests/test_underwriters_api.py -v`

Expected: PASS

---

## Phase 4: Dispute Gateway

### Task 7: Add Dispute Gateway Action APIs

**Files:**
- Create: `backend/underwriting_query_api/app/api/actions.py`
- Create: `backend/underwriting_query_api/app/services/prepare_dispute_open.py`
- Create: `backend/underwriting_query_api/app/services/submit_dispute_open.py`
- Create: `backend/underwriting_query_api/app/services/prepare_slash_resolution.py`
- Create: `backend/underwriting_query_api/app/services/submit_slash_resolution.py`
- Create: `backend/underwriting_query_api/tests/test_dispute_gateway_api.py`

**Step 1: Write the failing gateway tests**

```python
def test_prepare_dispute_open_creates_action_request(client, seeded_disputeable_job):
    response = client.post(f"/underwriting/jobs/{seeded_disputeable_job.job_id}/disputes/open/prepare")
    assert response.status_code == 200
    assert response.json()["actionType"] == "open_dispute"

def test_prepare_slash_resolution_creates_action_request(client, seeded_open_dispute):
    response = client.post(f"/underwriting/jobs/{seeded_open_dispute.job_id}/disputes/resolve-slash/prepare")
    assert response.status_code == 200
    assert response.json()["actionType"] == "resolve_dispute_slash"
```

**Step 2: Run test to verify it fails**

Run: `pytest backend/underwriting_query_api/tests/test_dispute_gateway_api.py -v`

Expected: FAIL because the gateway routes and services do not exist yet.

**Step 3: Implement the dispute gateway**

Implementation requirements:
- validate current state before preparing or submitting actions
- create `underwriting_action_requests` rows for every gateway request
- support client dispute-open prepare and submit
- support underwriter dispute-slash prepare and submit
- persist tx hash, status transitions, and failure reasons
- keep signer assumptions explicit:
  - client dispute-open may require client-controlled signing
  - underwriter slash resolution may use signed attestation plus relay

**Step 4: Run test to verify it passes**

Run: `pytest backend/underwriting_query_api/tests/test_dispute_gateway_api.py -v`

Expected: PASS

---

## Phase 5: Documentation And Verification

### Task 8: Add Documentation And Local Operator Workflow

**Files:**
- Create: `backend/underwriting_query_api/README.md`
- Modify: `README.md`
- Create: `backend/underwriting_query_api/tests/test_readme_examples.py`

**Step 1: Write the failing docs test**

```python
def test_readme_mentions_postgres_alembic_and_no_webhooks():
    readme = Path("backend/underwriting_query_api/README.md").read_text()
    assert "Postgres" in readme
    assert "Alembic" in readme
    assert "webhooks are not required in v1" in readme
```

**Step 2: Run test to verify it fails**

Run: `pytest backend/underwriting_query_api/tests/test_readme_examples.py -v`

Expected: FAIL because the backend README does not exist yet.

**Step 3: Write the docs**

Documentation requirements:
- explain required env vars:
  - `DATABASE_URL`
  - `UNDERWRITING_RPC_URL`
  - `ACP_ADDRESS`
  - `UNDERWRITING_HOOK_ADDRESS`
  - `UNDERWRITING_COORDINATOR_ADDRESS`
  - `UNDERWRITING_EVALUATOR_ADDRESS`
  - `UNDERWRITING_COLLATERAL_MANAGER_ADDRESS`
- explain the initial backfill flow
- explain the incremental sync worker
- explain how the current Virtuals ACP SDK informs off-chain orchestration patterns without replacing this repo's canonical contract model
- explain that underwriting hook state and parent-job linkage are owned by this service layer
- explain that snapshots are contract-read based and materialized into Postgres
- explain that list/search comes from Postgres
- explain that role-aware action hints are derived from chain state and persisted for client/provider/underwriter workflows
- explain the dispute gateway prepare/submit model for client and underwriter actions
- explain that timelines are partial for hook-only history
- explain that internal async orchestration is required, while outbound webhooks are optional in v1

**Step 4: Run test to verify it passes**

Run: `pytest backend/underwriting_query_api/tests/test_readme_examples.py -v`

Expected: PASS

---

### Task 9: Add Integration Coverage Against A Controlled Runtime

**Files:**
- Create: `backend/underwriting_query_api/tests/integration/test_underwriting_api_integration.py`

**Step 1: Write the failing integration test**

```python
def test_materialized_snapshot_matches_live_contract_state(integration_client, seeded_chain_runtime):
    response = integration_client.get(f"/underwriting/jobs/{seeded_chain_runtime.job_id}")
    assert response.status_code == 200
    body = response.json()
    assert body["job"]["status"] == "Submitted"
    assert body["hook"]["sidecarState"] == "EvidenceSubmitted"
    assert body["orchestration"]["nextActionRole"] in {"client", "underwriter", "provider", None}

def test_dispute_gateway_flows_match_runtime(integration_client, seeded_open_dispute_runtime):
    response = integration_client.get(f"/underwriting/jobs/{seeded_open_dispute_runtime.job_id}/dispute")
    assert response.status_code == 200
    assert response.json()["status"] in {"open", "resolved", "none"}
```

**Step 2: Run test to verify it fails**

Run: `pytest backend/underwriting_query_api/tests/integration/test_underwriting_api_integration.py -v`

Expected: FAIL because the integration harness does not exist yet.

**Step 3: Implement the integration harness**

Integration requirements:
- run against a controlled local runtime or a dedicated test RPC
- seed known success, reject, timeout, and dispute-slash scenarios
- verify that materialized snapshots match live contract reads
- verify that timeline rows contain the expected ACP and settlement events
- verify that dispute projection and gateway action models align with the current coordinator flow

**Step 4: Run the full backend suite**

Run: `pytest backend/underwriting_query_api/tests -v`

Expected: PASS

---

## Verification Matrix

Before calling the backend API plan complete, verify against these Solidity-side sources:

- `contracts/interfaces/IAgenticCommerceKernel.sol`
- `contracts/hooks/underwriting/IUnderwritingHookView.sol`
- `contracts/settlement/UnderwritingSettlementCoordinator.sol`
- `contracts/settlement/UnderwritingEvaluator.sol`
- `contracts/settlement/UnderwritingCollateralManager.sol`
- `test/integration/UnderwritingSharedEnvFlow.t.sol`
- `test/settlement/UnderwritingSettlementCoordinator.t.sol`
- `test/settlement/UnderwritingCollateralManager.t.sol`
- `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`

## Canonical References

- `README.md`
- `contracts/README.md`
- `contracts/settlement/README.md`
- `script/DeployUnderwritingSharedEnv.s.sol`
- `contracts/interfaces/IAgenticCommerceKernel.sol`
- `contracts/hooks/underwriting/IUnderwritingHookView.sol`
- `contracts/settlement/UnderwritingSettlementCoordinator.sol`
- `contracts/settlement/UnderwritingEvaluator.sol`
- `contracts/settlement/UnderwritingCollateralManager.sol`
