#!/usr/bin/env bash
# =============================================================================
# Vayu Module 04: Python & Glibc Runtime Optimizer
# =============================================================================
# Standalone usage: sudo ./modules/04-tune-python.sh [--revert]
# Purpose: Implements Pillar 4 (Process Guardrails): clamps glibc malloc
#          arena fragmentation via MALLOC_ARENA_MAX=2 for Python and runtime processes.
# =============================================================================

set -Eeuo pipefail

ENV_FILE="/etc/environment"
STATE_DIR="/var/lib/vayu"
BACKUP_DIR="/var/lib/vayu/backup"
STATE_FILE="/var/lib/vayu/state.env"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This module must be run as root (or with sudo)." >&2
        exit 1
    fi
}

revert_python() {
    require_root
    echo "==> [Module 04] Reverting Python runtime tuning..."

    if [[ -f "$ENV_FILE" ]]; then
        local removed_any=0

        # Selectively remove only Vayu-added lines without clobbering unrelated user changes
        if [[ -f "$STATE_FILE" ]] && grep -q "VAYU_ADDED_MALLOC_ARENA=1" "$STATE_FILE"; then
            sed -i '/^MALLOC_ARENA_MAX=2$/d' "$ENV_FILE"
            removed_any=1
        elif [[ ! -f "$BACKUP_DIR/environment" ]] || ! grep -q "^MALLOC_ARENA_MAX=" "$BACKUP_DIR/environment" 2>/dev/null; then
            sed -i '/^MALLOC_ARENA_MAX=2$/d' "$ENV_FILE"
            removed_any=1
        fi

        if [[ -f "$STATE_FILE" ]] && grep -q "VAYU_ADDED_BYTECODE=1" "$STATE_FILE"; then
            sed -i '/^PYTHONDONTWRITEBYTECODE=1$/d' "$ENV_FILE"
            removed_any=1
        elif [[ ! -f "$BACKUP_DIR/environment" ]] || ! grep -q "^PYTHONDONTWRITEBYTECODE=" "$BACKUP_DIR/environment" 2>/dev/null; then
            sed -i '/^PYTHONDONTWRITEBYTECODE=1$/d' "$ENV_FILE"
            removed_any=1
        fi

        # If /etc/environment did not exist before Vayu and is now completely empty, remove it
        if [[ ! -f "$BACKUP_DIR/environment" && ! -s "$ENV_FILE" ]]; then
            rm -f "$ENV_FILE"
        fi

        if (( removed_any )); then
            echo "  ✓ Cleanly removed Vayu glibc and Python environment entries from $ENV_FILE."
        else
            echo "  ✓ No Vayu-specific entries required removal in $ENV_FILE."
        fi
    fi
    exit 0
}

apply_python_tuning() {
    require_root
    echo "==> [Module 04: Python Runtime] Applying Glibc Arena & Bytecode Limits..."

    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
    touch "$STATE_FILE"

    # Snapshot baseline /etc/environment if not already backed up
    if [[ ! -f "$BACKUP_DIR/environment" && -f "$ENV_FILE" ]]; then
        cp -a "$ENV_FILE" "$BACKUP_DIR/environment"
    fi

    touch "$ENV_FILE"

    if ! grep -q "^MALLOC_ARENA_MAX=" "$ENV_FILE"; then
        echo "MALLOC_ARENA_MAX=2" >> "$ENV_FILE"
        echo "VAYU_ADDED_MALLOC_ARENA=1" >> "$STATE_FILE"
        echo "  ✓ Added MALLOC_ARENA_MAX=2 to $ENV_FILE (saves ~80-120MB fragmented RAM)."
    else
        echo "  ✓ MALLOC_ARENA_MAX already configured in $ENV_FILE."
    fi

    if ! grep -q "^PYTHONDONTWRITEBYTECODE=" "$ENV_FILE"; then
        echo "PYTHONDONTWRITEBYTECODE=1" >> "$ENV_FILE"
        echo "VAYU_ADDED_BYTECODE=1" >> "$STATE_FILE"
        echo "  ✓ Added PYTHONDONTWRITEBYTECODE=1 to $ENV_FILE."
    fi

    export MALLOC_ARENA_MAX=2
    export PYTHONDONTWRITEBYTECODE=1

    echo "  ℹ Note: /etc/environment applies to new login sessions and systemd services."
    echo "    To apply MALLOC_ARENA_MAX=2 to running Python/Hermes processes, restart them:"
    echo "    (e.g., pkill -f hermes && hermes gateway run)"

    if pgrep -x "python3" >/dev/null 2>&1 || pgrep -f "hermes" >/dev/null 2>&1; then
        echo "  ⚠ Notice: Detected active Python/Hermes processes running under old environment."
        echo "    Please restart them to realize the ~60-100 MB heap reduction."
    fi
}

if [[ "${1:-}" == "--revert" ]]; then
    revert_python
else
    apply_python_tuning
fi
