#!/usr/bin/env bash

is_tenderly_shared_env_sourced() {
  if [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
    [[ "${ZSH_EVAL_CONTEXT}" == *:file ]]
    return
  fi

  [[ -n "${BASH_SOURCE:-}" && "${BASH_SOURCE[0]}" != "$0" ]]
}

use_actor_key() {
  local actor="${1:-}"

  case "${actor}" in
    deployer)
      export PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY}"
      ;;
    underwriter)
      export PRIVATE_KEY="${UNDERWRITER_PRIVATE_KEY}"
      ;;
    client)
      export PRIVATE_KEY="${CLIENT_PRIVATE_KEY}"
      ;;
    provider)
      export PRIVATE_KEY="${PROVIDER_PRIVATE_KEY}"
      ;;
    *)
      echo "usage: use_actor_key <deployer|underwriter|client|provider>" >&2
      return 1
      ;;
  esac

  export ACTIVE_ACTOR="${actor}"
}

print_shared_env_success_criteria() {
  cat <<'EOF'
- proxy-backed ACP, hook, and evaluator deploy successfully
- hook is whitelisted in ACP
- hook settlement token is pinned to USDC
- hook and evaluator admin both equal DEPLOYER_ADDRESS
- underwriter registration succeeds
- underwriter recipient configuration succeeds
- one-stage happy path succeeds through releaseCollateral(...)
- two-stage happy path succeeds with a smaller close-job budget than the root job
- one-stage dispute path succeeds with a full slash to RECOVERY_RECIPIENT
EOF
}

load_tenderly_shared_env() {
  local env_file="${1:-.env.tenderly.shared}"
  local required_vars
  local var_name
  local var_value

  if [[ ! -f "${env_file}" ]]; then
    echo "missing env file: ${env_file}" >&2
    return 1
  fi

  if ! command -v cast >/dev/null 2>&1; then
    echo "missing required dependency: cast" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "${env_file}"

  required_vars=(
    TENDERLY_ACCESS_KEY
    TENDERLY_VIRTUAL_TESTNET_RPC
    TENDERLY_VIRTUAL_TESTNET_WSS
    DEPLOYER_PRIVATE_KEY
    UNDERWRITER_PRIVATE_KEY
    CLIENT_PRIVATE_KEY
    PROVIDER_PRIVATE_KEY
    BASE_USDC
    ACP_TREASURY
    CLIENT_CONFIRMATION_WINDOW
    PREMIUM_RECIPIENT
    RECOVERY_RECIPIENT
    MERCHANT_EXECUTION_WALLET
  )

  for var_name in "${required_vars[@]}"; do
    eval "var_value=\${$var_name-}"
    if [[ -z "${var_value}" ]]; then
      echo "missing required env var: ${var_name}" >&2
      return 1
    fi
  done

  export TENDERLY_VERIFIER_URL="${TENDERLY_VERIFIER_URL:-${TENDERLY_VIRTUAL_TESTNET_RPC}/verify/etherscan}"
  export DEPLOYER_ADDRESS="$(cast wallet address --private-key "${DEPLOYER_PRIVATE_KEY}")"
  export UNDERWRITER_ADDRESS="$(cast wallet address --private-key "${UNDERWRITER_PRIVATE_KEY}")"
  export CLIENT_ADDRESS="$(cast wallet address --private-key "${CLIENT_PRIVATE_KEY}")"
  export PROVIDER_ADDRESS="$(cast wallet address --private-key "${PROVIDER_PRIVATE_KEY}")"

  echo "Loaded Tenderly shared-env inputs from ${env_file}"
  echo "Derived addresses:"
  echo "  DEPLOYER_ADDRESS=${DEPLOYER_ADDRESS}"
  echo "  UNDERWRITER_ADDRESS=${UNDERWRITER_ADDRESS}"
  echo "  CLIENT_ADDRESS=${CLIENT_ADDRESS}"
  echo "  PROVIDER_ADDRESS=${PROVIDER_ADDRESS}"
  echo
  echo "Current forge scripts still read PRIVATE_KEY."
  echo "Use 'use_actor_key deployer' before DeployUnderwritingSharedEnv or RegisterUnderwriter."
  echo "Use 'use_actor_key underwriter' before ConfigureUnderwriterRecipients."
  echo
  echo "Success criteria before deploy:"
  print_shared_env_success_criteria
}

if ! load_tenderly_shared_env "$@"; then
  if is_tenderly_shared_env_sourced; then
    return 1
  fi

  echo "source this file instead of executing it:" >&2
  echo "  source script/load-tenderly-shared-env.sh [env-file]" >&2
  exit 1
fi
