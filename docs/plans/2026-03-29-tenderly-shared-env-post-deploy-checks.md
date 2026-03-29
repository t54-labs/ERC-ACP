# Tenderly Shared-Env Post-Deploy Checks

This record captures Task 5 from
`docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`.

## Deployment Under Test

- ACP proxy: `0xc435cC0619df16189502c389Ec8BEFEA21CF621c`
- Hook proxy: `0x4122A868aB76AFc1BE672D64EB504a2470844d39`
- Evaluator proxy: `0x7bd3d28371b0b12034D4eCc896E51128575115B9`
- Coordinator: `0x32904fCCf8f8A8FC81670eDf649aDA4d6495F798`
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
- Hook evaluator wiring: `0x7bd3d28371b0b12034D4eCc896E51128575115B9`
- Hook coordinator wiring: `0x32904fCCf8f8A8FC81670eDf649aDA4d6495F798`

## Outcome

Task 5 is complete:

- ACP whitelists the deployed underwriting hook
- the hook is pinned to Base USDC
- both hook and evaluator admin ownership resolve to the deployer
- hook evaluator and coordinator wiring match the fresh Task 4 deployment
