#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FORGE_STD_REF="foundry-rs/forge-std@rev=4540e4aadda88eeb19a54d2b5ad2117c2c7632ec"
OPENZEPPELIN_CONTRACTS_REF="OpenZeppelin/openzeppelin-contracts@rev=9cfdccd35350f7bcc585cf2ede08cd04e7f0ec10"
OPENZEPPELIN_UPGRADEABLE_REF="OpenZeppelin/openzeppelin-contracts-upgradeable@rev=25780dbcea4d5124fd517f002f0f8984881c5198"

cd "$ROOT_DIR"

echo "Initializing tracked submodules..."
git submodule update --init --recursive contracts/acp

install_if_missing() {
    local path="$1"
    local dependency="$2"

    if [ -d "$path" ]; then
        echo "Already present: $path"
        return
    fi

    echo "Installing $dependency..."
    forge install --no-git "$dependency"
}

install_if_missing "lib/forge-std/src" "$FORGE_STD_REF"
install_if_missing "lib/openzeppelin-contracts/contracts" "$OPENZEPPELIN_CONTRACTS_REF"
install_if_missing "lib/openzeppelin-contracts-upgradeable/contracts" "$OPENZEPPELIN_UPGRADEABLE_REF"

echo "Foundry dependencies are ready."
