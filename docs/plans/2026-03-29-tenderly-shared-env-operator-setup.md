# Tenderly Shared-Env Operator Setup

This record captures Task 6 from
`docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`.

## Deployment Under Test

- Hook proxy: `0x4122A868aB76AFc1BE672D64EB504a2470844d39`
- Collateral manager: `0x0905Daa07eA5ca11578fe1FcA3FA780DB14F6165`
- Deployer/hook admin: `0xFb471f732f12584C4c6e77F648B1545B117DA408`
- Underwriter: `0xfE46775BD5424B4A3A40B4ff529d581C54feE3Cd`
- Premium recipient: `0x951DA72B1FC75F9f6FDbd7982B6123a5052D5e8d`
- Recovery recipient: `0xf3EdE7f0C0321660f02072195065E462Ac847891`

## Register Underwriter

Command shape used:

```bash
source script/load-tenderly-shared-env.sh .env.tenderly.shared
export UNDERWRITING_HOOK="0x4122A868aB76AFc1BE672D64EB504a2470844d39"
use_actor_key deployer

forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --slow
```

Recorded transaction hash:

- `0x2ebbb16d7550df0a06109452165a995ce645b0ae39668a9e5d1a00282723bdf3`

Verification:

- `registeredUnderwriters(underwriter)`: `true`

## Configure Underwriter Recipients

Command shape used:

```bash
source script/load-tenderly-shared-env.sh .env.tenderly.shared
export COLLATERAL_MANAGER="0x0905Daa07eA5ca11578fe1FcA3FA780DB14F6165"
use_actor_key underwriter

forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url "$TENDERLY_VIRTUAL_TESTNET_RPC" \
  --broadcast \
  --slow
```

Recorded transaction hash:

- `0xddfc2398f4223fa90cc2d05e7bfeeeadc496485263c72e925b3945f9e116575b`

Verification:

- `recipientsByUnderwriter(underwriter).premium`: `0x951DA72B1FC75F9f6FDbd7982B6123a5052D5e8d`
- `recipientsByUnderwriter(underwriter).recovery`: `0xf3EdE7f0C0321660f02072195065E462Ac847891`

## Outcome

Task 6 is complete:

- the deployer-admin registered the live underwriter on the hook without access-control failure
- the underwriter configured premium and recovery recipients on the collateral manager
- storage reads confirm the expected underwriter registration and recipient values
