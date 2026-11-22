#!/usr/bin/env bash
# =============================================================================
# Vayu Module 02: Essential Developer & System Tooling
# =============================================================================
# Standalone usage: sudo ./modules/02-system-base.sh
# Purpose: Idempotently provisions core CLI packages (git, nano, curl, jq, etc.)
#          without reinstalling packages that already exist.
# =============================================================================

set -Eeuo pipefail

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This module must be run as root (or with sudo)." >&2
        exit 1
    fi
}

install_base_tools() {
    require_root

    echo "==> [Module 02: Base Tooling] Checking core packages..."

    local PACKAGES=(git nano curl wget jq ca-certificates software-properties-common bc)
    local TO_INSTALL=()

    for pkg in "${PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            TO_INSTALL+=("$pkg")
        fi
    done

    if [[ ${#TO_INSTALL[@]} -eq 0 ]]; then
        echo "  ✓ All base developer tools (git, nano, curl, jq, etc.) are already installed."
        return 0
    fi

    echo "  -> Installing missing packages: ${TO_INSTALL[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${TO_INSTALL[@]}"
    echo "  ✓ Base tools installed successfully."
}

install_base_tools
