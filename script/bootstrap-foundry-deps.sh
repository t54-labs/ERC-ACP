#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

install_if_missing "lib/forge-std/src" "foundry-rs/forge-std"
install_if_missing "lib/openzeppelin-contracts/contracts" "OpenZeppelin/openzeppelin-contracts"
install_if_missing "lib/openzeppelin-contracts-upgradeable/contracts" "OpenZeppelin/openzeppelin-contracts-upgradeable"

echo "Foundry dependencies are ready."
