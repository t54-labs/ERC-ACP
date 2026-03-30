# Underwriting Query API

This backend materializes underwriting-specific ACP state into Postgres and serves a FastAPI query surface for underwriting jobs, lineage, disputes, timelines, underwriters, and dispute gateway actions.

The chain remains the source of truth. This service reads contracts, derives underwriting-only views, and stores the resulting snapshots in Postgres so list and search queries do not depend on live chain scans on every request.

## Stack

- FastAPI for the HTTP surface
- SQLAlchemy models for the serving layer
- Alembic for schema management
- `web3.py` for contract reads
- Postgres as the intended persistent backing store

## Required Environment Variables

Set the runtime addresses before running against a live deployment:

- `DATABASE_URL`
- `UNDERWRITING_RPC_URL`
- `ACP_ADDRESS`
- `UNDERWRITING_HOOK_ADDRESS`
- `UNDERWRITING_COORDINATOR_ADDRESS`
- `UNDERWRITING_EVALUATOR_ADDRESS`
- `UNDERWRITING_COLLATERAL_MANAGER_ADDRESS`

`DATABASE_URL` should point at Postgres for normal operation. SQLite is acceptable for local tests, but the intended serving path is Postgres plus Alembic-managed schema.

## Local Operator Workflow

1. Install the package dependencies for `backend/underwriting_query_api/`.
2. Apply schema migrations with Alembic:

```bash
cd backend/underwriting_query_api
alembic upgrade head
```

3. Start the API:

```bash
uvicorn app.main:app --reload
```

4. Run an initial full backfill before relying on list APIs.
5. Keep an incremental sync worker running so new chain activity continues to refresh the materialized views.

## Initial Backfill

The initial backfill walks ACP job ids from `jobCounter()`, hydrates underwriting jobs from contract reads, derives lineage/dispute/orchestration fields, and upserts the result into Postgres.

That flow is implemented as contract-read based hydration, not as a webhook replay. It is responsible for producing:

- underwriting job snapshots
- settlement-scoped dispute projections
- normalized timeline rows
- underwriter point-lookups touched by snapshots

## Incremental Sync Worker

After backfill, the incremental worker reads new logs, resolves touched job ids, re-hydrates affected snapshots, and updates Postgres in place. This is the steady-state freshness path for:

- snapshot refreshes
- settlement/dispute updates
- timeline materialization
- underwriter metadata touched by new activity

Internal async orchestration is required so this worker can keep the serving layer current without blocking request paths.

## Data Ownership

ACP core remains the generic job kernel, but this backend owns the underwriting-domain serving layer built on top of it.

This service owns:

- underwriting hook state materialization
- hook-managed parent-job linkage and close-job lineage views
- settlement-scoped dispute projections
- role-aware action hints for client, provider, and underwriter workflows

The current Virtuals ACP SDK can still inform off-chain orchestration patterns and client integration design, but it does not replace this repository's canonical contract model. The checked-in contracts remain the source of truth for runtime semantics.

## Query Model

Snapshots are contract-read based and materialized into Postgres. Point reads may re-hydrate from chain when a snapshot is missing, but list/search is intentionally served from Postgres.

That split gives the API two operating modes:

- point-accurate reads for a specific underwriting job
- indexed list/search queries for actor, lineage, dispute, and orchestration views

Role-aware action hints are derived from chain state and persisted alongside each snapshot so the API can tell clients which actor should act next and why.

## Dispute Gateway

The dispute gateway exposes prepare/submit flows for two actor-specific actions:

- client dispute-open
- underwriter dispute-slash resolution

Prepare endpoints create `underwriting_action_requests` rows and return the payload template or transaction intent the caller needs next.

Submit endpoints accept the signed payload or relay metadata, persist request status transitions, and store transaction metadata such as the resulting tx hash.

For shared-settlement close jobs, the gateway keeps the requested job identity in the API response but targets the settlement-owner job in the onchain payload template.

The slash-resolution prepare flow intentionally returns a template for underwriter-supplied fields such as `slashAmountUsdc`, `validUntil`, and `nonce` instead of guessing them from derived dispute state.

## Timeline Scope

Timeline rows normalize ACP, coordinator, collateral-manager, and escrow activity that can be resolved from the configured runtime. Timelines are partial for hook-only history because the hook does not emit a complete event stream for every internal state transition.

## Webhooks And Async Work

Internal async workers are required for backfill, log sync, and materialized snapshot freshness. Outbound webhooks may still be useful for downstream consumers, but webhooks are not required in v1.
