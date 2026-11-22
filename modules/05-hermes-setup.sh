#!/usr/bin/env bash
# =============================================================================
# Vayu Module 05: Hermes Agent Optimizer & Service Orchestrator
# =============================================================================
# Standalone usage: ./modules/05-hermes-setup.sh
# Purpose: Optional example workload tuning (Hermes Agent): enforces 1-worker
#          concurrency bounds and disables redundant local web dashboard.
# =============================================================================

set -Eeuo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
HERMES_DIR="$TARGET_HOME/.hermes"
CONFIG_FILE="$HERMES_DIR/config.yaml"

echo "==> [Module 05: Hermes Orchestrator] Configuring Hermes for user: $TARGET_USER"

if [[ ! -d "$HERMES_DIR" ]]; then
    echo "  ℹ Hermes Agent directory not detected at $HERMES_DIR."
    echo "  -> To install Hermes Agent from scratch, run:"
    echo "     curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-browser --skip-computer-use"
    exit 0
fi

echo "  ✓ Found Hermes Agent installation at $HERMES_DIR."

# 1. Terminate redundant standalone web dashboard if running
if pgrep -f "dashboard" >/dev/null 2>&1; then
    echo "  -> Terminating redundant standalone dashboard (saves ~35MB RAM)..."
    pkill -f -- "dashboard" 2>/dev/null || true
    echo "  ✓ Redundant dashboard stopped (Desktop App & Telegram are unaffected)."
fi

# 2. Check and configure worker concurrency limit
if [[ -f "$CONFIG_FILE" ]]; then
    echo "  ✓ Auditing $CONFIG_FILE for low-memory limits..."
    # Ensure child delegation concurrency is capped for low-memory VMs (default: 10, cap to 1)
    if grep -q "max_concurrent_children" "$CONFIG_FILE"; then
        sed -i 's/.*max_concurrent_children:.*/  max_concurrent_children: 1/' "$CONFIG_FILE"
    fi
    # Ensure legacy workers are capped to 1 for 1-2 vCPU VMs
    if grep -q "max_workers:" "$CONFIG_FILE"; then
        sed -i 's/max_workers:.*/max_workers: 1/' "$CONFIG_FILE"
    fi
fi

# 3. Report active Hermes processes
echo "  -> Active Hermes processes for $TARGET_USER:"
ps -eo pid,%cpu,%mem,rss,cmd -u "$TARGET_USER" | grep -E "gateway|serve" | grep -v grep | while read -r line; do
    echo "     $line"
done || echo "     (No active gateway/serve running right now)"

echo "  ✓ Hermes configuration audited successfully."
