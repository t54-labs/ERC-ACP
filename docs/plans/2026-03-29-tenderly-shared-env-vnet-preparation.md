# Tenderly Shared-Env Virtual TestNet Preparation

This record captures Task 3 from
`docs/plans/2026-03-28-tenderly-shared-env-deployment-test-plan.md`.

This version supersedes the earlier Task 3 run against the previous Tenderly
VNet. The current source of truth is the fresh VNet below.

## Loaded Inputs

- Tenderly admin RPC: `https://virtual.base.eu.rpc.tenderly.co/538b9b2f-dc98-4d74-b7ce-30a7fe843951`
- Tenderly admin WSS: `wss://virtual.base.eu.rpc.tenderly.co/cd9d703f-6140-4bde-a0e9-76badfa9acee`
- Base USDC: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Client confirmation window: `3600`

## Actor And Recipient Addresses

- Deployer: `0xFb471f732f12584C4c6e77F648B1545B117DA408`
- Underwriter: `0xfE46775BD5424B4A3A40B4ff529d581C54feE3Cd`
- Client: `0x05026f0842e702Bc8344CD74190d256C2831dB89`
- Provider: `0x9FfC22e77CEE36b09aaC87BfEAc6dBf4204E17e2`
- ACP treasury: `0x18A75aFFb35Cc35Cf9ec02De75f9601bc1834702`
- Premium recipient: `0x951DA72B1FC75F9f6FDbd7982B6123a5052D5e8d`
- Recovery recipient: `0xf3EdE7f0C0321660f02072195065E462Ac847891`
- Merchant execution wallet: `0x106B371Be93282C73A17a073F4152Acc3E7F6FDD`

## Admin RPC Funding Actions

Native balance top-up target:

- `0x56bc75e2d63100000` wei per actor (`100 ETH`)

ERC-20 balance targets:

- Client USDC: `0x77359400` (`2000000000`, `2000 USDC`)
- Provider USDC: `0x1dcd6500` (`500000000`, `500 USDC`)

Successful admin RPC results:

- `tenderly_setBalance`: `0x0a3f1fab775ef623b09651427f892ad6e98950232cc2e1cbf267e6bbbc4703ee`
- `tenderly_setErc20Balance` for client: `0x8a4cf54d1ca05397d3bb14d59a0fd084699683d1723c136afc4d5696d2821699`
- `tenderly_setErc20Balance` for provider: `0x68c8db7131c00820ce0a15adf49dc6292f454709ef9d0f09ff891e63f615e157`

## Connectivity Checks

- Chain ID: `9998453`
- Deployer native balance: `100000000000000000000`
- Underwriter native balance: `100000000000000000000`
- Client native balance: `100000000000000000000`
- Provider native balance: `100000000000000000000`
- Client USDC balance: `2000000000`
- Provider USDC balance: `500000000`

## Outcome

Task 3 is complete:

- Tenderly admin RPC accepted the native and ERC-20 top-ups
- the virtual testnet responds on the expected RPC URL
- all four actors have non-zero native gas balances
- client and provider both have non-zero Base USDC balances

## Task 4 Verification Decision

This deployment is for collaborative QA on Tenderly, so Task 4 should run with
`--verify` enabled.
