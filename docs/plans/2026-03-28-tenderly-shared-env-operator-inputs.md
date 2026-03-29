# Tenderly Shared-Env Operator Inputs

This Task 1 runbook captures the inputs and pre-deploy checks needed before the
live Tenderly deployment and smoke-flow tasks.

## Source Of Truth

- `README.md`
- `script/DeployUnderwritingSharedEnv.s.sol`
- `script/RegisterUnderwriter.s.sol`
- `script/ConfigureUnderwriterRecipients.s.sol`
- `test/script/DeployUnderwritingSharedEnvSmoke.t.sol`
- `test/hooks/underwriting/UnderwritingHookParity.t.sol`

## Required Inputs

Use `script/tenderly-shared-env.env.example` as the operator template. The
session requires:

- Tenderly access, RPC, WSS, and verifier inputs
- four actor private keys: deployer, underwriter, client, provider
- shared-env protocol inputs: `BASE_USDC`, `ACP_TREASURY`,
  `CLIENT_CONFIRMATION_WINDOW`
- settlement recipient inputs: `PREMIUM_RECIPIENT`,
  `RECOVERY_RECIPIENT`, `MERCHANT_EXECUTION_WALLET`

## Session Bootstrap

Load the filled env file into the current shell:

```bash
source script/load-tenderly-shared-env.sh .env.tenderly.shared
```

The loader:

- validates every Task 1 input is explicitly exported
- derives `DEPLOYER_ADDRESS`, `UNDERWRITER_ADDRESS`, `CLIENT_ADDRESS`, and
  `PROVIDER_ADDRESS` locally with `cast wallet address --private-key`
- exports `TENDERLY_VERIFIER_URL` from the configured Tenderly RPC URL
- exposes `use_actor_key <deployer|underwriter|client|provider>` so the current
  `forge script` entrypoints can keep using `PRIVATE_KEY`

## Script Invocation Mapping

The checked-in scripts still consume `PRIVATE_KEY`, so switch the active actor
immediately before each invocation:

```bash
use_actor_key deployer
forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast

use_actor_key deployer
forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast

use_actor_key underwriter
forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast
```

## Pre-Deploy Success Criteria

These are the criteria to confirm before running the live deployment:

- proxy-backed ACP, hook, and evaluator deploy successfully
- hook is whitelisted in ACP
- hook settlement token is pinned to USDC
- hook and evaluator admin both equal `DEPLOYER_ADDRESS`
- underwriter registration succeeds
- underwriter recipient configuration succeeds
- one-stage happy path succeeds through `releaseCollateral(...)`
- two-stage happy path succeeds with a smaller close-job budget than the root job
- one-stage dispute path succeeds with a full slash to `RECOVERY_RECIPIENT`

## Why These Criteria Match The Current Code

- `script/DeployUnderwritingSharedEnv.s.sol` deploys `AgenticCommerce`,
  `UnderwritingHook`, and `UnderwritingEvaluator` behind ERC-1967 proxies and
  wires the hook whitelist, allowed settlement token, coordinator, and
  evaluator.
- `test/script/DeployUnderwritingSharedEnvSmoke.t.sol` asserts the hook and
  evaluator admins equal the deployer, the hook is whitelisted, and the
  settlement token is pinned to USDC.
- `script/RegisterUnderwriter.s.sol` and
  `script/ConfigureUnderwriterRecipients.s.sol` define the operator actions
  required immediately after deploy.
- `test/hooks/underwriting/UnderwritingHookParity.t.sol` covers the root/close
  lifecycle where the close leg succeeds with a smaller budget than the root job.
