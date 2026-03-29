# Tenderly Shared-Env Deployment

This record captures Task 4 from
`docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`.

This version supersedes the earlier Task 4 run against the previous Tenderly
VNet. The current source of truth is the fresh VNet deployment below.

## Deployment Command

This deployment used the current Tenderly-compatible Foundry verifier flow and
the verifier URL loaded from `.env.tenderly.shared`:

```bash
source script/load-tenderly-shared-env.sh .env.tenderly.shared
use_actor_key deployer

forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --verify \
  --verifier custom \
  --verifier-api-key "$TENDERLY_ACCESS_KEY" \
  --verifier-url "$TENDERLY_VERIFIER_URL" \
  --slow
```

Loaded values used for this run:

- Deployer: `0xFb471f732f12584C4c6e77F648B1545B117DA408`
- Verifier URL: `https://virtual.base.eu.rpc.tenderly.co/538b9b2f-dc98-4d74-b7ce-30a7fe843951/verify`

## Fresh Deployed Addresses

- ACP implementation: `0x0588DB5e76Ccff3254729Bf7f53Ae8e083dD821F`
- ACP proxy: `0x995E21FB605A2714760318d35c058f3968446682`
- Hook implementation: `0x5e226A8F60b4Ee0E71b7C258e319637254295ff3`
- Hook proxy: `0x95B66dF83C29175A78E56ce8ECbdc3690b64E8a7`
- Evaluator implementation: `0x5C382400239be3a224e1639376525c1647b73DEa`
- Evaluator proxy: `0x703f8EE31bd89C169b2BcbCb33E6697C0C6d3cd3`
- UnderwritingSettlementCoordinator: `0xa2a3A13c8cEe2eD43b44822Fe98a1c2CCA1b085e`
- UnderwritingCollateralManager: `0x7D1C260E06935cc31388bFA108d77C8D79587A19`

## Deployment Transactions

- ACP implementation deployment: `0x29b66a217f49dd5c577bf5669292c52739f8239a16b2e2348a4fd259e2a4539d`
- ACP proxy deployment: `0x67b34fa31b0128b1b790fa125a697067cdbbf0f9ce0a8d87af5b95f16c48f252`
- Collateral manager deployment: `0x541cf56b3121eaf4670de64a29dc0026f9210554563b2da11dadbc95f0371d5f`
- Hook implementation deployment: `0x7bf2a3ba10842220c84c0b897b51fa936a0a1010c3dd923511e0c066c7b3db94`
- Hook proxy deployment: `0x6d84dce531393263f10f0f30d1c267b31d5ccd3b6f958874d600c6d4ca417526`
- ACP whitelist call: `0xd6995bd90693d5cc8d76ec510861f0c98b4eb23409bd78f540221aa010cbb96f`
- Hook settlement-token pin call: `0xf8c1ed09220b3693f67fea850dcc1adb4c5b92f2fa001c4c405624e1603b97a6`
- Settlement coordinator deployment: `0x7be95ff9a25e9fa0d8e8ef5b72a6ef413b720929f0dbe89d3dad8d74936028e8`
- Evaluator implementation deployment: `0x5473c7e805264c50e3f6ff2e665e1b3a2cb7aaa1b71f2ea10cfe25e3c6e381e7`
- Evaluator proxy deployment: `0x19bcba28ae367158890b2fcbb0009c71c48594ec044f3e48c422343ef77d1e36`
- Hook wiring call: `0x1ce5e4d007a84638bbf8df8a3ad0c2eeec92e913dc960342e152de47d774f705`

## Verification Status

Inline verification succeeded during the deployment run. No separate fallback
verification step was required.

- AgenticCommerce implementation: `Pass - Verified`
- ACP proxy: `Pass - Verified`
- UnderwritingCollateralManager: `Pass - Verified`
- UnderwritingHook implementation: `Pass - Verified`
- Hook proxy: `Pass - Verified`
- UnderwritingSettlementCoordinator: `Pass - Verified`
- UnderwritingEvaluator implementation: `Pass - Verified`
- Evaluator proxy: `Pass - Verified`

## Outcome

Task 4 is complete:

- the canonical stack deployed successfully to Tenderly Virtual TestNet chain `9998453`
- the full proxy and implementation address set was captured immediately
- inline Tenderly verification succeeded for every deployed contract in the run
