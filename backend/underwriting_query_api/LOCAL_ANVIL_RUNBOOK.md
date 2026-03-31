# Local Anvil Runbook For ACP Underwriting

This runbook shows how to stand up a fully local ACP underwriting environment with:

- `anvil` as the local EVM
- `MockUSDC` as the settlement token
- the canonical underwriting runtime deployed from `script/DeployUnderwritingSharedEnv.s.sol`
- `underwriting_query_api` pointed at that runtime
- a local Postgres instance for materialized snapshots

Use this as the default inner-loop workflow for underwriting development and debugging. It is faster, cheaper, and easier to reset than Tenderly or a public testnet.

## Scope

This flow is meant to verify:

- the onchain underwriting runtime
- the backend backfill and incremental sync flows
- snapshot, timeline, dispute, and underwriter query responses
- action-payload preparation for dispute flows

This flow is not a replacement for a final Tenderly or public testnet proof. It is the recommended local-first development path.

## Important Limitations

- The backend `prepare` endpoints generate action payload templates, but the current `submit` endpoints do not broadcast transactions onchain by themselves.
- For now, execute onchain actions with `forge script`, `cast send`, or dedicated tests.
- The backend is intended to run against Postgres in operator mode.
- The easiest workflow is one fresh `anvil` instance per scenario.

## Prerequisites

From the repo root:

- `anvil`
- `forge`
- `cast`
- Python `3.12`
- Docker

Examples below assume you are in `ERC-ACP/`.

## Step 1: Start Anvil

Open a terminal and start a fresh local chain:

```bash
anvil --host 127.0.0.1 --port 8545 --chain-id 31337
```

Leave this process running. Use a fresh Anvil instance for each clean scenario run.

## Step 2: Start Postgres

Open another terminal and start a local Postgres container:

```bash
docker run --rm \
  --name underwriting-pg \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=underwriting_query_api \
  -p 5432:5432 \
  postgres:16
```

If you already have a local Postgres instance, that is fine. Just adjust `DATABASE_URL` later.

## Step 3: Export Local Actor Keys

Take the first seven private keys printed by `anvil` and export them:

```bash
export RPC_URL=http://127.0.0.1:8545

export DEPLOYER_PRIVATE_KEY=<anvil account 0 private key>
export UNDERWRITER_PRIVATE_KEY=<anvil account 1 private key>
export CLIENT_PRIVATE_KEY=<anvil account 2 private key>
export PROVIDER_PRIVATE_KEY=<anvil account 3 private key>
export PREMIUM_RECIPIENT_PRIVATE_KEY=<anvil account 4 private key>
export RECOVERY_RECIPIENT_PRIVATE_KEY=<anvil account 5 private key>
export MERCHANT_EXECUTION_PRIVATE_KEY=<anvil account 6 private key>
```

Derive the actor addresses:

```bash
export DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
export UNDERWRITER_ADDRESS=$(cast wallet address --private-key "$UNDERWRITER_PRIVATE_KEY")
export CLIENT_ADDRESS=$(cast wallet address --private-key "$CLIENT_PRIVATE_KEY")
export PROVIDER_ADDRESS=$(cast wallet address --private-key "$PROVIDER_PRIVATE_KEY")
export PREMIUM_RECIPIENT=$(cast wallet address --private-key "$PREMIUM_RECIPIENT_PRIVATE_KEY")
export RECOVERY_RECIPIENT=$(cast wallet address --private-key "$RECOVERY_RECIPIENT_PRIVATE_KEY")
export MERCHANT_EXECUTION_WALLET=$(cast wallet address --private-key "$MERCHANT_EXECUTION_PRIVATE_KEY")
```

Set the remaining deploy-time variables:

```bash
export ACP_TREASURY=$DEPLOYER_ADDRESS
export CLIENT_CONFIRMATION_WINDOW=3600
```

## Step 4: Deploy MockUSDC

Deploy the local 6-decimal test token:

```bash
forge create contracts/acp/contracts/mocks/MockUSDC.sol:MockUSDC \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY"
```

Copy the `Deployed to:` address and export it:

```bash
export BASE_USDC=<MockUSDC deployed address>
```

Mint balances to the client and provider:

```bash
cast send "$BASE_USDC" \
  "mint(address,uint256)" \
  "$CLIENT_ADDRESS" \
  1000000000000 \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --rpc-url "$RPC_URL"

cast send "$BASE_USDC" \
  "mint(address,uint256)" \
  "$PROVIDER_ADDRESS" \
  1000000000000 \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --rpc-url "$RPC_URL"
```

The amount above is `1,000,000 USDC` with 6 decimals.

## Step 5: Deploy The Underwriting Runtime

Deploy the canonical shared environment:

```bash
export PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY

forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Export the printed addresses:

```bash
export ACP_PROXY=<ACP proxy address>
export UNDERWRITING_HOOK=<UnderwritingHook proxy address>
export COORDINATOR=<UnderwritingSettlementCoordinator address>
export EVALUATOR_PROXY=<UnderwritingEvaluator proxy address>
export COLLATERAL_MANAGER=<UnderwritingCollateralManager address>
```

## Step 6: Register The Underwriter

Register the underwriter as the hook admin:

```bash
export PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY

forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Configure underwriter recipients as the underwriter:

```bash
export PRIVATE_KEY=$UNDERWRITER_PRIVATE_KEY

forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Capture the next coordinator nonce for escrow creation:

```bash
export SETTLEMENT_ESCROW_NONCE_START=$(cast nonce "$COORDINATOR" --rpc-url "$RPC_URL")
```

## Step 7: Run A Smoke Scenario

### Option A: One-stage happy path

This is the best first scenario because it exercises deployment wiring, funding, evidence submission, client confirmation, and collateral release.

```bash
forge script script/TenderlySharedEnvSmoke.s.sol:TenderlySharedEnvSmoke \
  --sig "runOneStageHappy()" \
  --rpc-url "$RPC_URL" \
  --broadcast
```

### Option B: One-stage dispute path

For dispute testing, the cleanest path is to restart `anvil`, redeploy, and then run:

```bash
forge script script/TenderlySharedEnvSmoke.s.sol:TenderlySharedEnvSmoke \
  --sig "runOneStageDispute()" \
  --rpc-url "$RPC_URL" \
  --broadcast
```

### Option C: Two-stage happy path

To validate root-job and close-job linkage:

```bash
forge script script/TenderlySharedEnvSmoke.s.sol:TenderlySharedEnvSmoke \
  --sig "runTwoStageHappy()" \
  --rpc-url "$RPC_URL" \
  --broadcast
```

## Step 8: Install And Configure The Backend

Open a new terminal:

```bash
cd backend/underwriting_query_api

python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

Export the backend runtime configuration:

```bash
export DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/underwriting_query_api
export UNDERWRITING_RPC_URL=http://127.0.0.1:8545
export ACP_ADDRESS=$ACP_PROXY
export UNDERWRITING_HOOK_ADDRESS=$UNDERWRITING_HOOK
export UNDERWRITING_COORDINATOR_ADDRESS=$COORDINATOR
export UNDERWRITING_EVALUATOR_ADDRESS=$EVALUATOR_PROXY
export UNDERWRITING_COLLATERAL_MANAGER_ADDRESS=$COLLATERAL_MANAGER
```

Apply migrations:

```bash
alembic upgrade head
```

## Step 9: Run Initial Backfill

The current backend does not yet ship a standalone CLI entrypoint for backfill, so run it with a Python snippet:

```bash
python - <<'PY'
from app.config import Settings
from app.chain.client import UnderwritingChainClient
from app.db.session import build_session_factory
from app.services.backfill import run_backfill

settings = Settings()
Session = build_session_factory(settings.database_url)
chain = UnderwritingChainClient(settings)

with Session() as db:
    run_backfill(chain=chain, db=db)

print("backfill complete")
PY
```

## Step 10: Start The API

```bash
uvicorn app.main:app --reload
```

The API will be available at `http://127.0.0.1:8000`.

## Step 11: Verify Backend Health

```bash
curl http://127.0.0.1:8000/underwriting/health
```

You should see:

- `ok: true`
- the local `chainId`
- a non-null `latestRpcBlock`
- a reachable database

## Step 12: Query The Materialized Snapshot

On a fresh Anvil chain, the first scenario usually creates `jobId = 1`.

Inspect the job:

```bash
curl http://127.0.0.1:8000/underwriting/jobs/1 | jq
```

Inspect the timeline:

```bash
curl http://127.0.0.1:8000/underwriting/jobs/1/timeline | jq
```

Inspect the dispute projection:

```bash
curl http://127.0.0.1:8000/underwriting/jobs/1/dispute | jq
```

Inspect the underwriter lookup:

```bash
curl "http://127.0.0.1:8000/underwriters/$UNDERWRITER_ADDRESS" | jq
```

## Step 13: Run Incremental Sync After New Onchain Activity

If you execute more transactions after the initial backfill, refresh the serving layer with:

```bash
python - <<'PY'
from app.config import Settings
from app.chain.client import UnderwritingChainClient
from app.db.session import build_session_factory
from app.services.sync_logs import run_incremental_sync

settings = Settings()
Session = build_session_factory(settings.database_url)
chain = UnderwritingChainClient(settings)

with Session() as db:
    run_incremental_sync(chain=chain, db=db)

print("incremental sync complete")
PY
```

Then repeat the API queries above.

## Expected Results

### After `runOneStageHappy()`

You should expect:

- a materialized underwriting snapshot for the created job
- timeline rows including ACP and settlement events
- a registered underwriter lookup with the configured recipients
- a completed success-path state in the snapshot and settlement projection

### After `runOneStageDispute()`

You should expect:

- a dispute projection for the settlement owner job
- timeline rows including `SuccessDisputeOpened`
- settlement-side slash or recovery progress reflected in the snapshot and dispute view

### After `runTwoStageHappy()`

You should expect:

- correct hook-owned parent and close linkage
- the close job sharing the parent settlement identity
- a lineage response that reflects root, parent, and active close relationships

## Recommended Workflow

For daily development:

1. Start a fresh `anvil`.
2. Deploy `MockUSDC`.
3. Deploy the underwriting runtime.
4. Run exactly one smoke scenario.
5. Backfill the backend.
6. Verify the API responses.
7. If you need another clean scenario, restart `anvil` and repeat.

This keeps the local chain easy to reason about and makes backend verification deterministic.

## Troubleshooting

### `job not found` from the API

- Confirm the smoke scenario actually created a job.
- Confirm backfill completed successfully.
- Confirm the backend is pointing at the same `anvil` instance that the scenario used.

### `ok: false` from `/underwriting/health`

- Check that Postgres is running.
- Check that all five contract addresses are exported.
- Check that `UNDERWRITING_RPC_URL` points to the active local chain.

### Empty timeline

- Re-run initial backfill if the scenario happened before the first backend sync.
- Re-run incremental sync if the scenario happened after backfill.

### Wrong addresses after restarting Anvil

- A fresh `anvil` wipes all chain state.
- Re-deploy `MockUSDC` and the underwriting runtime.
- Re-export every deployed contract address before restarting the backend.

## Notes On Privacy

This local runbook is fully private:

- no public explorer verification is required
- no contract source publication is required
- no public RPC is involved

That makes it the best place to iterate before using Tenderly or Base Sepolia for higher-confidence external proof.
