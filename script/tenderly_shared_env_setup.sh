#!/usr/bin/env bash

tenderly_shared_env_require() {
    local name="$1"
    local value
    eval "value=\${$name-}"

    if [[ -z "$value" ]]; then
        echo "Missing required environment variable: $name" >&2
        return 1
    fi
}

tenderly_use_actor_key() {
    local actor="${1:-}"
    local key_var

    case "$actor" in
        deployer) key_var="DEPLOYER_PRIVATE_KEY" ;;
        underwriter) key_var="UNDERWRITER_PRIVATE_KEY" ;;
        client) key_var="CLIENT_PRIVATE_KEY" ;;
        provider) key_var="PROVIDER_PRIVATE_KEY" ;;
        *)
            echo "Usage: tenderly_use_actor_key <deployer|underwriter|client|provider>" >&2
            return 1
            ;;
    esac

    tenderly_shared_env_require "$key_var" || return 1
    eval "export PRIVATE_KEY=\${$key_var}"
    echo "PRIVATE_KEY is now set from $key_var"
}

tenderly_print_success_criteria() {
    cat <<'EOF'
Success criteria before deploy:
  - Proxy-backed ACP, hook, and evaluator deploy successfully.
  - The hook is whitelisted in ACP.
  - The hook settlement token is pinned to BASE_USDC.
  - The hook admin and evaluator admin both equal DEPLOYER_ADDRESS.
  - Underwriter registration succeeds.
  - Underwriter recipient configuration succeeds.
  - The one-stage happy path reaches releaseCollateral(...).
  - The two-stage happy path succeeds with a smaller close-job budget than the root job.
  - The one-stage dispute path succeeds with a full slash to RECOVERY_RECIPIENT.
EOF
}

TENDERLY_VIRTUAL_TESTNET_RPC_DEFAULT="https://virtual.base.eu.rpc.tenderly.co/d6ac0a5d-d160-4385-91bf-a0d56e80daf5"
TENDERLY_VIRTUAL_TESTNET_WSS_DEFAULT="wss://virtual.base.eu.rpc.tenderly.co/bd7ddccd-9725-4362-891b-c17de416fae3"

is_tenderly_shared_env_sourced() {
    if [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
        [[ "$ZSH_EVAL_CONTEXT" == *:file ]]
        return
    fi

    [[ -n "${BASH_SOURCE:-}" && "${BASH_SOURCE[0]}" != "$0" ]]
}

tenderly_shared_env_setup() {
    export TENDERLY_VIRTUAL_TESTNET_RPC="${TENDERLY_VIRTUAL_TESTNET_RPC:-$TENDERLY_VIRTUAL_TESTNET_RPC_DEFAULT}"
    export TENDERLY_VIRTUAL_TESTNET_WSS="${TENDERLY_VIRTUAL_TESTNET_WSS:-$TENDERLY_VIRTUAL_TESTNET_WSS_DEFAULT}"
    export TENDERLY_VERIFIER_URL="${TENDERLY_VERIFIER_URL:-${TENDERLY_VIRTUAL_TESTNET_RPC}/verify/etherscan}"
    export CLIENT_CONFIRMATION_WINDOW="${CLIENT_CONFIRMATION_WINDOW:-3600}"

    for required_var in \
        TENDERLY_ACCESS_KEY \
        DEPLOYER_PRIVATE_KEY \
        UNDERWRITER_PRIVATE_KEY \
        CLIENT_PRIVATE_KEY \
        PROVIDER_PRIVATE_KEY \
        BASE_USDC \
        ACP_TREASURY \
        PREMIUM_RECIPIENT \
        RECOVERY_RECIPIENT \
        MERCHANT_EXECUTION_WALLET
    do
        tenderly_shared_env_require "$required_var" || return 1
    done

    if ! command -v cast >/dev/null 2>&1; then
        echo "Missing required dependency: cast" >&2
        return 1
    fi

    export DEPLOYER_ADDRESS
    DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
    export UNDERWRITER_ADDRESS
    UNDERWRITER_ADDRESS="$(cast wallet address --private-key "$UNDERWRITER_PRIVATE_KEY")"
    export CLIENT_ADDRESS
    CLIENT_ADDRESS="$(cast wallet address --private-key "$CLIENT_PRIVATE_KEY")"
    export PROVIDER_ADDRESS
    PROVIDER_ADDRESS="$(cast wallet address --private-key "$PROVIDER_PRIVATE_KEY")"

    cat <<EOF
Tenderly shared-environment shell is ready.

RPC URL:      $TENDERLY_VIRTUAL_TESTNET_RPC
Verifier URL: $TENDERLY_VERIFIER_URL

Derived actor addresses:
  DEPLOYER_ADDRESS=$DEPLOYER_ADDRESS
  UNDERWRITER_ADDRESS=$UNDERWRITER_ADDRESS
  CLIENT_ADDRESS=$CLIENT_ADDRESS
  PROVIDER_ADDRESS=$PROVIDER_ADDRESS

Use tenderly_use_actor_key <actor> before each forge script invocation:
  tenderly_use_actor_key deployer
  forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv ...

  tenderly_use_actor_key deployer
  forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter ...

  tenderly_use_actor_key underwriter
  forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients ...
EOF

    tenderly_print_success_criteria
}

if ! tenderly_shared_env_setup; then
    if is_tenderly_shared_env_sourced; then
        return 1
    fi

    exit 1
fi
