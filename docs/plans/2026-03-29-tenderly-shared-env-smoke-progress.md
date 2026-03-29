# Tenderly Shared-Env Smoke Progress

This record captures the current Task 7 status for the fresh Tenderly Virtual
TestNet run after Tasks 3 through 6 were rerun on the fresh RPC.

## Fresh VNet Context

- Tenderly admin RPC: `https://virtual.base.eu.rpc.tenderly.co/538b9b2f-dc98-4d74-b7ce-30a7fe843951`
- ACP proxy: `0x995E21FB605A2714760318d35c058f3968446682`
- Hook proxy: `0x95B66dF83C29175A78E56ce8ECbdc3690b64E8a7`
- Evaluator proxy: `0x703f8EE31bd89C169b2BcbCb33E6697C0C6d3cd3`
- Coordinator: `0xa2a3A13c8cEe2eD43b44822Fe98a1c2CCA1b085e`
- Collateral manager: `0x7D1C260E06935cc31388bFA108d77C8D79587A19`

## Runner Status

- Live smoke runner implemented at `script/TenderlySharedEnvSmoke.s.sol`
- Compiles with:

```bash
forge build --force --skip test
```

- Entry points:
  - `runOneStageHappy()`
  - `runTwoStageHappy()`
  - `runOneStageDispute()`

## Completed Scenario Progress

### One-stage happy path

- Status: `Succeeded`
- Job ID: `1`
- Escrow: `0x9EEE438d6319af6dCA0cC2DBcFd748DdC13D8cBe`
- Broadcast log:
  - `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runOneStageHappy-latest.json`

### Two-stage happy path

- Status: `Succeeded`
- Root job ID: `2`
- Close job ID: `3`
- Escrow: `0x3E5e9F0D16e82442A7F210F644984F99b3b9bCBF`
- Broadcast log:
  - `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runTwoStageHappy-latest.json`

## Incomplete Scenario

### One-stage dispute path

- Status: `Blocked before any live tx landed`
- Broadcast log:
  - `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runOneStageDispute-latest.json`

Observed failure:

```text
HTTP 403
You've reached the quota limit for your current plan. Upgrade your plan in the dashboard or contact support to continue.
```

## Verified On-Chain State After The Block

- `jobCounter=3`
- `jobId=4` does not exist on-chain
- `premium=10000000`
- `merchant=1000000000`
- `recovery=0`
- `provider=600000000`

This confirms:

- both happy-path scenarios really landed on-chain
- the dispute path did not mutate the chain

## Blocker

Task 7 cannot be completed until Tenderly allows more broadcasts on this fresh
VNet. The immediate blocker is Tenderly quota exhaustion on
`eth_sendRawTransaction`.

## Impact On The Plan

- Task 7 remains incomplete because the dispute path has not landed
- Task 8 remains pending because the full smoke matrix has not been proven
- the current fresh VNet already contains the two successful happy-path runs

## Recommended Next Step

- Preferred: restore quota on this same fresh VNet, then run only the dispute
  path and commit the final Task 7 artifact
- Fallback: create another fresh VNet and rerun all three scenarios there to
  preserve the plan's one-shared-run intent
