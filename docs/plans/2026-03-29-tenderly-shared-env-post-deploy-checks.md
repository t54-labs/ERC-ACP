# Tenderly Shared-Env Post-Deploy Checks

This record captures Task 5 from
`docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`.

This version supersedes the earlier Task 5 run against the previous Tenderly
VNet. The current source of truth is the fresh VNet deployment below.

## Deployment Under Test

- ACP proxy: `0x995E21FB605A2714760318d35c058f3968446682`
- Hook proxy: `0x95B66dF83C29175A78E56ce8ECbdc3690b64E8a7`
- Evaluator proxy: `0x703f8EE31bd89C169b2BcbCb33E6697C0C6d3cd3`
- Coordinator: `0xa2a3A13c8cEe2eD43b44822Fe98a1c2CCA1b085e`
- Expected deployer/admin: `0xFb471f732f12584C4c6e77F648B1545B117DA408`
- Expected settlement token: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

## Commands

```bash
cast call "$ACP_PROXY" "whitelistedHooks(address)(bool)" "$HOOK_PROXY" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"

cast call "$HOOK_PROXY" "allowedSettlementToken()(address)" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"

cast call "$HOOK_PROXY" "admin()(address)" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"

cast call "$EVALUATOR_PROXY" "admin()(address)" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"

cast call "$HOOK_PROXY" "evaluator()(address)" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"

cast call "$HOOK_PROXY" "coordinator()(address)" \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC"
```

## Results

- ACP hook whitelist for hook proxy: `true`
- Hook allowed settlement token: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Hook admin: `0xFb471f732f12584C4c6e77F648B1545B117DA408`
- Evaluator admin: `0xFb471f732f12584C4c6e77F648B1545B117DA408`
- Hook evaluator wiring: `0x703f8EE31bd89C169b2BcbCb33E6697C0C6d3cd3`
- Hook coordinator wiring: `0xa2a3A13c8cEe2eD43b44822Fe98a1c2CCA1b085e`

## Outcome

Task 5 is complete:

- ACP whitelists the deployed underwriting hook
- the hook is pinned to Base USDC
- both hook and evaluator admin ownership resolve to the deployer
- hook evaluator and coordinator wiring match the fresh Task 4 deployment
