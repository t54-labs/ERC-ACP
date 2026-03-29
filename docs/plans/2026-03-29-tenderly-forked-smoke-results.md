# Tenderly Forked Smoke Results

This record closes out the v2 recovery workflow in
`docs/plans/2026-03-29-tenderly-forked-smoke-recovery-plan.md`.

## Final Status

- Local preflight remained green in the same repo state used for live execution.
- A clean parent baseline was staged successfully through deployment and operator
  setup.
- All three smoke scenarios were proven live.
- The final dispute proof required a clean child fork because the earlier parent
  lineage was quota-blocked before a clean dispute retry could be taken.

## Final Outcome

The smoke matrix is complete:

- one-stage happy path: `Passed`
- two-stage happy path: `Passed`
- one-stage dispute path: `Passed`

## Environment Lineage

### Historical happy-path parent

- Parent VNet RPC: `https://virtual.base.eu.rpc.tenderly.co/12b6bbee-bf14-428a-8073-f1f1f8ca3b94`
- Parent VNet WSS: `wss://virtual.base.eu.rpc.tenderly.co/979957e1-1bdb-43e6-9195-601e5bbae917`
- Execution mode: parent baseline plus `evm_snapshot` and `evm_revert`
- Result:
  - one-stage happy succeeded
  - two-stage happy succeeded
  - dispute path was blocked by Tenderly quota before completion

### Final clean parent used for dispute recovery

- Parent VNet RPC: `https://virtual.base.eu.rpc.tenderly.co/c1afaed9-c407-4a9e-9b76-a8c64c9738f4`
- Parent VNet WSS: `wss://virtual.base.eu.rpc.tenderly.co/8f36d7a2-f971-4e8a-a7f6-b514ac4f79df`
- Purpose: stage a clean parent through Tasks 3 to 6 only
- Parent fork-readiness checks:
  - `jobCounter=0`
  - `coordinator_nonce=1`
  - whitelist and wiring checks all passed

### Final child fork used for dispute

- Child VNet RPC: `https://virtual.base.eu.rpc.tenderly.co/9e554f6e-b753-4d9e-b544-dfb21c9d91f6`
- Child VNet WSS: `wss://virtual.base.eu.rpc.tenderly.co/2031d219-6823-4bc1-86e4-9c84b56e942f`
- Required run override: `SETTLEMENT_ESCROW_NONCE_START=1`
- Child validation before the run:
  - `jobCounter=0`
  - `coordinator_nonce=1`
  - deployed contracts present

## Shared Deployment Addresses

These addresses were reproduced deterministically across the clean parent
deployments:

- `ACP proxy = 0x995E21FB605A2714760318d35c058f3968446682`
- `Hook proxy = 0x95B66dF83C29175A78E56ce8ECbdc3690b64E8a7`
- `Evaluator proxy = 0x703f8EE31bd89C169b2BcbCb33E6697C0C6d3cd3`
- `Coordinator = 0xa2a3A13c8cEe2eD43b44822Fe98a1c2CCA1b085e`
- `Collateral manager = 0x7D1C260E06935cc31388bFA108d77C8D79587A19`

## Baseline Deployment And Setup Artifacts

- Deploy stack artifact:
  - `broadcast/DeployUnderwritingSharedEnv.s.sol/9998453/run-latest.json`
- Register underwriter artifact:
  - `broadcast/RegisterUnderwriter.s.sol/9998453/run-latest.json`
- Configure recipients artifact:
  - `broadcast/ConfigureUnderwriterRecipients.s.sol/9998453/run-latest.json`

Current setup tx hashes:

- deploy ACP implementation:
  - `0x552beda403688e0950f9c4b336dc926d4e722b0641167bf34fe5530985aec819`
- deploy ACP proxy:
  - `0xe42d374a2fbe88755dd6d87ba18432367e73f788061cb7989313266c0636aba4`
- deploy collateral manager:
  - `0x8a163d887e77b88da1bdb0e58743df29f7ead07a888a80d8b6310d87a92c888a`
- deploy hook implementation:
  - `0x029106a74d69cf0c9db6f5f5d2ea8ffc5d46a165622f4030190b4b668a950585`
- deploy hook proxy:
  - `0x0c76b6809cbc0dcbb02788e212c9cd0302e839d297bc2c2a4b2c26625b8fb327`
- deploy coordinator:
  - `0x9d137c5693bc500b846bbee2194f146e7598ecb2f838f249dbe4f9d1ebe0d289`
- deploy evaluator implementation:
  - `0x66da32948394a7cb0411800cb11b6a17d5f472fe75f73d01d90e455bf68b7dce`
- deploy evaluator proxy:
  - `0x3430b18c6b6c3d2281316138513a3addabdf234abae4f3e6c6acd77ba1dd21c0`
- register underwriter:
  - `0x24b9eeeaa66b5d8f16c948402f6a860a6d0b5a1ec6c2b202c224c61a3d00140f`
- configure recipients:
  - `0x34cd657353455635ab2101337c9991820356c724174f0bab21a8f5cfbc76d8a2`

## Scenario Results

### One-stage happy path

- Environment:
  - historical happy-path parent `12b6bbee-bf14-428a-8073-f1f1f8ca3b94`
- Status: `Passed`
- Script output:
  - `jobId=1`
  - `escrow=0x9EEE438d6319af6dCA0cC2DBcFd748DdC13D8cBe`
- Terminal transaction:
  - `0x657de95c5b512f78b86c3d69998d6b07ee2e803db72000aba0e2e3d9661aab98`
- Artifact:
  - `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runOneStageHappy-latest.json`

### Two-stage happy path

- Environment:
  - historical happy-path parent `12b6bbee-bf14-428a-8073-f1f1f8ca3b94`
- Status: `Passed`
- Script output:
  - `rootJobId=1`
  - `closeJobId=2`
  - `escrow=0x9EEE438d6319af6dCA0cC2DBcFd748DdC13D8cBe`
- Terminal transaction:
  - `0x75ad0cdabd2a79eb742966c75be5480606fd4196cd39a4bf6d88684d693491b6`
- Artifact:
  - `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runTwoStageHappy-latest.json`

### One-stage dispute path

- Environment:
  - child fork `9e554f6e-b753-4d9e-b544-dfb21c9d91f6`
- Status: `Passed`
- Script output:
  - `jobId=1`
  - `escrow=0x9EEE438d6319af6dCA0cC2DBcFd748DdC13D8cBe`
- Post-state:
  - `jobCounter=1`
  - `settlement_state=9`
  - `sidecar_state=6`
  - `recovery_recipient_usdc_delta=100000000`
- Terminal transaction:
  - `0xb6188c0ccd39a80d19bd962735d66195c26c4709710e5c862692f00a4d2c6abe`
- Artifact:
  - `broadcast/TenderlySharedEnvSmoke.s.sol/9998453/runOneStageDispute-latest.json`

## Dispute Transaction List

The successful dispute run landed 13 transactions:

1. `0x546c8d74e38f026709d826116b25c5c7f63b00967dde1ca32e568248ac7b51b6` `createJob(...)`
2. `0xd38894cba51079632b451682d1d7878abeb516176b377ac5256668f56b1bb222` `approve(...)`
3. `0xc526e294d31a906749a29073787358d11a942cce638499da2b4ee9b5bd2b3d70` `approve(...)`
4. `0xc63ca5b20994de554284e7545c4540a73713f58c994cfeb9e5f0f5534b0e57ce` `approve(...)`
5. `0xdbde09fd7f5a37a4a0667e08acbc21aeb7758f44a7b23923892e1ae5a68851d4` `setBudget(...)`
6. `0xfd2127d68054ace4eb9f3d837259ee300d9374eb7627930693169b47f206d7ae` `fund(...)`
7. `0x18d0c326a1a13be9f148551c006eec0af90514e26e73e9b19f8cc10b2bdc4b66` `approve(...)`
8. `0x670ed59f5ce3ee395759d3bf5eabc944dce01fb75a6f0b7c099c27a65215ea98` `orchestrateFunding(...)`
9. `0xd12d7c01296913c8e19d7a176c9104781ac35d8f12ead6a07defa7550e20241e` `submit(...)`
10. `0x1dfb62891923f4aed1309f0993f011992ec3505e2488d6a9e6f173fc1c9f7ddb` `confirmByClient(...)`
11. `0xa02c35e3246c0773a1e507570c8c391704562e712e3f3448361ff2b384cdc335` `requestCollateralRelease(...)`
12. `0xe30ce7981884b9d793b8b029676f23240b6213224d40363126cf79023831355c` `openSuccessDispute(...)`
13. `0xb6188c0ccd39a80d19bd962735d66195c26c4709710e5c862692f00a4d2c6abe` `applySuccessDisputeSlash(...)`

## Deviation From The Original v2 Ideal

The original v2 ideal was:

- one clean parent baseline
- all scenarios executed from that same parent lineage through snapshot or fork

What actually happened:

- happy paths were proven on the earlier parent
- the parent became quota-blocked before a clean dispute retry could be taken
- `evm_revert` was later blocked by the same Tenderly quota gate
- the dispute scenario was completed on a child fork from a newly restaged clean
  parent

This means the full matrix was proven with the same deployment recipe and the
same deterministic contract addresses, but not from one uninterrupted parent
lineage.

## Current Progress

- v2 recovery strategy: `Completed`
- live smoke matrix: `Completed`
- operator evidence docs from this run: `Completed with companion notes`
