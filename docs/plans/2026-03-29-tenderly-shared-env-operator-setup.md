# Tenderly Shared-Env Operator Setup

This record captures Task 6 from
`docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`.

This version supersedes the earlier Task 6 run against the previous Tenderly
VNet. The current source of truth is the fresh VNet operator setup below.

## Deployment Under Test

- Hook proxy: `0x95B66dF83C29175A78E56ce8ECbdc3690b64E8a7`
- Collateral manager: `0x7D1C260E06935cc31388bFA108d77C8D79587A19`
- Deployer/hook admin: `0xFb471f732f12584C4c6e77F648B1545B117DA408`
- Underwriter: `0xfE46775BD5424B4A3A40B4ff529d581C54feE3Cd`
- Premium recipient: `0x951DA72B1FC75F9f6FDbd7982B6123a5052D5e8d`
- Recovery recipient: `0xf3EdE7f0C0321660f02072195065E462Ac847891`

## Register Underwriter

Command shape used:

```bash
source script/load-tenderly-shared-env.sh .env.tenderly.shared
export UNDERWRITING_HOOK="0x95B66dF83C29175A78E56ce8ECbdc3690b64E8a7"
use_actor_key deployer

forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --slow
```

Recorded transaction hash:

- `0xe2e78fe6a8f05a108a002412b0eec86790c45b2a4361861be2092aab651310c6`

Verification:

- `registeredUnderwriters(underwriter)`: `true`

## Configure Underwriter Recipients

Command shape used:

```bash
source script/load-tenderly-shared-env.sh .env.tenderly.shared
export COLLATERAL_MANAGER="0x7D1C260E06935cc31388bFA108d77C8D79587A19"
use_actor_key underwriter

forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --slow
```

Recorded transaction hash:

- `0x41c6375989add414673a6b51c8bc15a8f16f01c820df51ebbcdd1e1e088edcd0`

Verification:

- `recipientsByUnderwriter(underwriter).premium`: `0x951DA72B1FC75F9f6FDbd7982B6123a5052D5e8d`
- `recipientsByUnderwriter(underwriter).recovery`: `0xf3EdE7f0C0321660f02072195065E462Ac847891`

## Outcome

Task 6 is complete:

- the deployer-admin registered the live underwriter on the hook without access-control failure
- the underwriter configured premium and recovery recipients on the collateral manager
- storage reads confirm the expected underwriter registration and recipient values
