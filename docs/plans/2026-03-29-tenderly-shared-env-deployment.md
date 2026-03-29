# Tenderly Shared-Env Deployment

This record captures Task 4 from
`docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`.

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
- Verifier URL: `https://virtual.base.eu.rpc.tenderly.co/d6ac0a5d-d160-4385-91bf-a0d56e80daf5/verify`

## Fresh Deployed Addresses

- ACP implementation: `0x9b9271c04E438a5D4f135B52870021f56ca78b1A`
- ACP proxy: `0xc435cC0619df16189502c389Ec8BEFEA21CF621c`
- Hook implementation: `0xB445f6C9edBF239554dF69f1710A049473e9fBe9`
- Hook proxy: `0x4122A868aB76AFc1BE672D64EB504a2470844d39`
- Evaluator implementation: `0x89423e7f66b9E25adeaB51243282a45fFEd5d369`
- Evaluator proxy: `0x7bd3d28371b0b12034D4eCc896E51128575115B9`
- UnderwritingSettlementCoordinator: `0x32904fCCf8f8A8FC81670eDf649aDA4d6495F798`
- UnderwritingCollateralManager: `0x0905Daa07eA5ca11578fe1FcA3FA780DB14F6165`

## Deployment Transactions

- ACP implementation deployment: `0xf3dab87c19837a6cec78a049fd952718a9cb1f3b636d33f92712abd56304d080`
- ACP proxy deployment: `0xb61bbf30e7ceac92e3f99d3f650f3b456c664e38118650719edc9449f58b0d2c`
- Collateral manager deployment: `0x4008b2dfb7be29ef5bb03e520ac276f00e345e5ffaed63a8e466b2e06b768242`
- Hook implementation deployment: `0xa213daf142a3d48db4e321e83009cb13b8ff7466671835aa8814ac5c5f8c7559`
- Hook proxy deployment: `0xefdeb0e77939401c0103a65b2c91da31949313a707833c94c93c3457b748e103`
- ACP whitelist call: `0x456b5152c4203427ef3dbb4b4c1792f11313c30f3a3409a667ec6d10bfe35e31`
- Hook settlement-token pin call: `0xac7973815cdf887ca415f375ae3ceeba72cf9018f83d687de107a764ce1ef4e1`
- Settlement coordinator deployment: `0x2189b4bb0ead60a61673bf0564554d54f1433b340c4b307a44cbde83d47e4b0b`
- Evaluator implementation deployment: `0x62b60315e03d151a6449f55ac3a8b3fba6e9d6032ed3a89f575e6d110a423166`
- Evaluator proxy deployment: `0xb66fb9fe9b6c2bf9bd6d064abc6bca6c24b83d7757e1dfeef44506fcc765f863`
- Hook wiring call: `0x43d37ff23a23dd2461a92478d429ffe35ce6b806634134183315a11eb8238ad7`

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
