#!/usr/bin/env bash
# =============================================================================
# Vayu Module 03: Tiered Virtual Memory & Kernel Optimization Engine
# =============================================================================
# Standalone usage: sudo ./modules/03-tune-memory.sh [--revert]
# Purpose: Implements Pillars 1-3: Tier 1 (In-RAM ZRAM compression),
#          Tier 2 (Fallback disk swap), and Kernel Reclaim & VM Tuning
#          (MGLRU, zero page-cluster, swappiness, and cache pressure).
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSCTL_CONF="/etc/sysctl.d/99-vayu-performance.conf"
BBR_CONF="/etc/sysctl.d/99-vayu-bbr.conf"
JOURNALD_CONF="/etc/systemd/journald.conf.d/99-vayu-cap.conf"
KSM_UNIT="/etc/systemd/system/vayu-ksm.service"
THP_UNIT="/etc/systemd/system/vayu-thp.service"
MGLRU_UNIT="/etc/systemd/system/vayu-mglru.service"
ZRAM_CONF="/etc/default/zramswap"

# Backup & State Persistence
STATE_DIR="/var/lib/vayu"
BACKUP_DIR="/var/lib/vayu/backup"
RUNTIME_BACKUP_DIR="/var/lib/vayu/backup/runtime"
STATE_FILE="/var/lib/vayu/state.env"

# Load config if exists
CONFIG_FILE="${VAYU_CONFIG:-/etc/vayu/vayu.conf}"
[[ ! -f "$CONFIG_FILE" && -f "$SCRIPT_DIR/../config/vayu.conf.example" ]] && CONFIG_FILE="$SCRIPT_DIR/../config/vayu.conf.example"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Source detector if available
if [[ -f "$SCRIPT_DIR/01-detect.sh" ]]; then
    source "$SCRIPT_DIR/01-detect.sh"
else
    detect_system() { true; }
    DETECT_RAM_MB=1024; REC_ZRAM_PERCENT=100; REC_SWAPFILE_MB=2048
    REC_MIN_FREE_KB=8192; REC_KSM_PAGES=600; REC_KSM_SLEEP_MS=30
fi

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This module must be run as root (or with sudo)." >&2
        exit 1
    fi
}

snapshot_memory_state() {
    # Preserve original pre-Vayu baseline across repeated runs
    if [[ -d "$BACKUP_DIR" ]]; then
        return 0
    fi

    echo "  -> Snapshotting baseline system configuration to $BACKUP_DIR..."
    mkdir -p "$RUNTIME_BACKUP_DIR"

    # 1. Config files snapshot
    [[ -f /etc/fstab ]] && cp -a /etc/fstab "$BACKUP_DIR/fstab"
    [[ -f "$ZRAM_CONF" ]] && cp -a "$ZRAM_CONF" "$BACKUP_DIR/zramswap"
    [[ -f "$SYSCTL_CONF" ]] && cp -a "$SYSCTL_CONF" "$BACKUP_DIR/99-vayu-performance.conf"
    [[ -f "$BBR_CONF" ]] && cp -a "$BBR_CONF" "$BACKUP_DIR/99-vayu-bbr.conf"
    [[ -f "$JOURNALD_CONF" ]] && cp -a "$JOURNALD_CONF" "$BACKUP_DIR/99-vayu-cap.conf"

    # 2. Runtime THP & KSM states
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        grep -o '\[.*\]' /sys/kernel/mm/transparent_hugepage/enabled | tr -d '[]' > "$RUNTIME_BACKUP_DIR/thp_enabled" 2>/dev/null || true
    fi
    if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
        grep -o '\[.*\]' /sys/kernel/mm/transparent_hugepage/defrag | tr -d '[]' > "$RUNTIME_BACKUP_DIR/thp_defrag" 2>/dev/null || true
    fi
    if [[ -f /sys/kernel/mm/ksm/run ]]; then
        cat /sys/kernel/mm/ksm/run > "$RUNTIME_BACKUP_DIR/ksm_run" 2>/dev/null || true
        cat /sys/kernel/mm/ksm/pages_to_scan > "$RUNTIME_BACKUP_DIR/ksm_pages_to_scan" 2>/dev/null || true
        cat /sys/kernel/mm/ksm/sleep_millisecs > "$RUNTIME_BACKUP_DIR/ksm_sleep_millisecs" 2>/dev/null || true
    fi

    # 3. Runtime MGLRU state
    if [[ -d /sys/kernel/mm/lru_gen ]]; then
        cat /sys/kernel/mm/lru_gen/enabled > "$RUNTIME_BACKUP_DIR/mglru_enabled" 2>/dev/null || true
        cat /sys/kernel/mm/lru_gen/min_ttl_ms > "$RUNTIME_BACKUP_DIR/mglru_min_ttl_ms" 2>/dev/null || true
    fi

    # 4. Runtime sysctl baseline
    cat <<SYSCTL_EOF > "$RUNTIME_BACKUP_DIR/sysctls.env"
ORIG_SWAPPINESS="$(sysctl -n vm.swappiness 2>/dev/null || echo 60)"
ORIG_PAGE_CLUSTER="$(sysctl -n vm.page-cluster 2>/dev/null || echo 3)"
ORIG_VFS_CACHE_PRESSURE="$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo 100)"
ORIG_WATERMARK_SCALE_FACTOR="$(sysctl -n vm.watermark_scale_factor 2>/dev/null || echo 10)"
ORIG_WATERMARK_BOOST_FACTOR="$(sysctl -n vm.watermark_boost_factor 2>/dev/null || echo 15000)"
ORIG_MIN_FREE_KBYTES="$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo 8192)"
ORIG_DIRTY_RATIO="$(sysctl -n vm.dirty_ratio 2>/dev/null || echo 20)"
ORIG_DIRTY_BG_RATIO="$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo 10)"
ORIG_DEFAULT_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq_codel)"
ORIG_TCP_CONGESTION="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
SYSCTL_EOF

    # Initialize state tracking file
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
}

revert_memory() {
    require_root
    echo "==> [Module 03] Reverting Vayu memory configurations..."

    # 1. Disable and remove Vayu-managed systemd units
    systemctl disable --now vayu-ksm.service vayu-thp.service vayu-mglru.service 2>/dev/null || true
    rm -f "$KSM_UNIT" "$THP_UNIT" "$MGLRU_UNIT"
    systemctl daemon-reload || true

    # 2. Swapfile & /etc/fstab clean rollback
    local created_swapfile=0
    if [[ -f "$STATE_FILE" ]] && grep -q "VAYU_CREATED_SWAPFILE=1" "$STATE_FILE"; then
        created_swapfile=1
    elif [[ -f /swapfile && -f "$BACKUP_DIR/fstab" ]] && ! grep -q '^/swapfile' "$BACKUP_DIR/fstab"; then
        # Fallback check: swapfile exists now but was NOT in pre-Vayu fstab
        created_swapfile=1
    fi

    if (( created_swapfile )); then
        echo "  -> Deactivating and removing Vayu-created /swapfile..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        if [[ -f "$BACKUP_DIR/fstab" ]]; then
            cp -a "$BACKUP_DIR/fstab" /etc/fstab
        else
            sed -i '\#^/swapfile\s\+#d' /etc/fstab 2>/dev/null || true
        fi
        echo "  ✓ Vayu fallback swapfile removed and /etc/fstab restored."
    else
        echo "  ✓ Pre-existing disk swap left untouched."
    fi

    # 3. ZRAM rollback
    if [[ -f "$BACKUP_DIR/zramswap" ]]; then
        echo "  -> Restoring original ZRAM configuration..."
        cp -a "$BACKUP_DIR/zramswap" "$ZRAM_CONF"
        systemctl restart zramswap.service 2>/dev/null || true
        echo "  ✓ Restored pre-Vayu ZRAM configuration."
    elif [[ -f "$ZRAM_CONF" ]]; then
        systemctl stop zramswap.service 2>/dev/null || true
        systemctl disable zramswap.service 2>/dev/null || true
        swapoff /dev/zram0 2>/dev/null || true
        zramctl --reset /dev/zram0 2>/dev/null || true
        rm -f "$ZRAM_CONF"
        echo "  ✓ ZRAM service stopped and configuration removed."
    fi

    # 4. Sysctl removal & live runtime restoration
    rm -f "$SYSCTL_CONF" "$BBR_CONF"
    if [[ -f "$BACKUP_DIR/99-vayu-performance.conf" ]]; then
        cp -a "$BACKUP_DIR/99-vayu-performance.conf" "$SYSCTL_CONF"
    fi
    if [[ -f "$BACKUP_DIR/99-vayu-bbr.conf" ]]; then
        cp -a "$BACKUP_DIR/99-vayu-bbr.conf" "$BBR_CONF"
    fi

    if [[ -f "$RUNTIME_BACKUP_DIR/sysctls.env" ]]; then
        echo "  -> Restoring kernel sysctl runtime parameters..."
        # shellcheck disable=SC1090
        source "$RUNTIME_BACKUP_DIR/sysctls.env"
        sysctl -w vm.swappiness="${ORIG_SWAPPINESS:-60}" >/dev/null 2>&1 || true
        sysctl -w vm.page-cluster="${ORIG_PAGE_CLUSTER:-3}" >/dev/null 2>&1 || true
        sysctl -w vm.vfs_cache_pressure="${ORIG_VFS_CACHE_PRESSURE:-100}" >/dev/null 2>&1 || true
        sysctl -w vm.watermark_scale_factor="${ORIG_WATERMARK_SCALE_FACTOR:-10}" >/dev/null 2>&1 || true
        sysctl -w vm.watermark_boost_factor="${ORIG_WATERMARK_BOOST_FACTOR:-15000}" >/dev/null 2>&1 || true
        sysctl -w vm.min_free_kbytes="${ORIG_MIN_FREE_KBYTES:-8192}" >/dev/null 2>&1 || true
        sysctl -w vm.dirty_ratio="${ORIG_DIRTY_RATIO:-20}" >/dev/null 2>&1 || true
        sysctl -w vm.dirty_background_ratio="${ORIG_DIRTY_BG_RATIO:-10}" >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc="${ORIG_DEFAULT_QDISC:-fq_codel}" >/dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control="${ORIG_TCP_CONGESTION:-cubic}" >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true
    echo "  ✓ Kernel sysctls restored to baseline."

    # 5. Restore runtime kernel subsystem states (THP, KSM, MGLRU)
    if [[ -f "$RUNTIME_BACKUP_DIR/thp_enabled" && -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        local orig_thp; orig_thp=$(< "$RUNTIME_BACKUP_DIR/thp_enabled")
        [[ -n "$orig_thp" ]] && echo "$orig_thp" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi
    if [[ -f "$RUNTIME_BACKUP_DIR/thp_defrag" && -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
        local orig_defrag; orig_defrag=$(< "$RUNTIME_BACKUP_DIR/thp_defrag")
        [[ -n "$orig_defrag" ]] && echo "$orig_defrag" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    fi

    if [[ -f "$RUNTIME_BACKUP_DIR/ksm_run" && -f /sys/kernel/mm/ksm/run ]]; then
        local orig_ksm; orig_ksm=$(< "$RUNTIME_BACKUP_DIR/ksm_run")
        echo "${orig_ksm:-0}" > /sys/kernel/mm/ksm/run 2>/dev/null || true
    fi
    if [[ -f "$RUNTIME_BACKUP_DIR/ksm_pages_to_scan" && -f /sys/kernel/mm/ksm/pages_to_scan ]]; then
        cat "$RUNTIME_BACKUP_DIR/ksm_pages_to_scan" > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
    fi
    if [[ -f "$RUNTIME_BACKUP_DIR/ksm_sleep_millisecs" && -f /sys/kernel/mm/ksm/sleep_millisecs ]]; then
        cat "$RUNTIME_BACKUP_DIR/ksm_sleep_millisecs" > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
    fi

    if [[ -f "$RUNTIME_BACKUP_DIR/mglru_enabled" && -f /sys/kernel/mm/lru_gen/enabled ]]; then
        cat "$RUNTIME_BACKUP_DIR/mglru_enabled" > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
    fi
    if [[ -f "$RUNTIME_BACKUP_DIR/mglru_min_ttl_ms" && -f /sys/kernel/mm/lru_gen/min_ttl_ms ]]; then
        cat "$RUNTIME_BACKUP_DIR/mglru_min_ttl_ms" > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null || true
    fi

    # 6. Journald revert
    rm -f "$JOURNALD_CONF"
    if [[ -f "$BACKUP_DIR/99-vayu-cap.conf" ]]; then
        cp -a "$BACKUP_DIR/99-vayu-cap.conf" "$JOURNALD_CONF"
    fi
    systemctl restart systemd-journald 2>/dev/null || true
    echo "  ✓ Revert complete. Restored distro defaults."
    exit 0
}

reclaim_memory() {
    require_root
    echo "==> [Module 03] Reclaiming disposable page cache and buffers..."
    sync
    if [[ -f /sys/fs/cgroup/memory.reclaim ]]; then
        echo 200M > /sys/fs/cgroup/memory.reclaim 2>/dev/null || true
    fi
    echo 3 > /proc/sys/vm/drop_caches
    echo "  ✓ Clean page cache flushed and disposable memory reclaimed."
}

apply_memory_tuning() {
    require_root
    detect_system
    snapshot_memory_state

    local ZRAM_PCT="${VAYU_ZRAM_PERCENT:-auto}"
    [[ "$ZRAM_PCT" == "auto" ]] && ZRAM_PCT="$REC_ZRAM_PERCENT"

    local SWAP_MB="${VAYU_SWAP_SIZE_MB:-auto}"
    [[ "$SWAP_MB" == "auto" ]] && SWAP_MB="$REC_SWAPFILE_MB"

    local ALGO="${VAYU_ZRAM_ALGO:-zstd}"
    local SWAPPINESS="${VAYU_SWAPPINESS:-160}"
    local VFS_PRESSURE="${VAYU_VFS_CACHE_PRESSURE:-150}"
    local ENABLE_KSM="${VAYU_ENABLE_KSM:-false}"
    local ENABLE_BBR="${VAYU_ENABLE_BBR:-false}"
    local ENABLE_JOURNALD="${VAYU_ENABLE_JOURNALD:-false}"
    local ENABLE_RECLAIM="${VAYU_ENABLE_RECLAIM:-false}"
    local SAFETY_MARGIN_MB="${VAYU_DISK_SAFETY_MARGIN_MB:-2048}"

    echo "==> [Module 03: Memory Engine] Applying Tiered Virtual Memory Tuning..."
    echo "  -> Target ZRAM Allocation: ${ZRAM_PCT}% of RAM (${ALGO})"
    echo "  -> Target Fallback Swap  : ${SWAP_MB} MB"

    # 1. MGLRU Activation
    if [[ -d /sys/kernel/mm/lru_gen ]]; then
        echo y > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
        echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null || true

        cat << 'EOF' > "$MGLRU_UNIT"
[Unit]
Description=Enable Multi-Gen LRU (MGLRU) at boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -d /sys/kernel/mm/lru_gen && echo y > /sys/kernel/mm/lru_gen/enabled && echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now vayu-mglru.service 2>/dev/null || true
        echo "  ✓ Multi-Gen LRU (MGLRU) activated (eliminates kswapd thrashing)."
    fi

    # 2. KSM Deduplication (Opt-in)
    if [[ "$ENABLE_KSM" == "true" ]]; then
        cat << EOF > "$KSM_UNIT"
[Unit]
Description=Enable KSM dynamic deduplication (managed by Vayu)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > /sys/kernel/mm/ksm/run && \\
  echo ${REC_KSM_PAGES} > /sys/kernel/mm/ksm/pages_to_scan && \\
  echo ${REC_KSM_SLEEP_MS} > /sys/kernel/mm/ksm/sleep_millisecs && \\
  echo 1 > /sys/kernel/mm/ksm/run'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now vayu-ksm.service 2>/dev/null || true
        echo "VAYU_ENABLED_KSM=1" >> "$STATE_FILE"
        echo "  ✓ KSM deduplication engine enabled (${REC_KSM_PAGES} pages / ${REC_KSM_SLEEP_MS}ms)."
    else
        echo "  ℹ KSM dynamic deduplication skipped (opt-in with --enable-ksm or VAYU_ENABLE_KSM=true)."
    fi

    # 3. Transparent Huge Pages (madvise to stop bloat)
    local THP_MODE="${VAYU_THP_MODE:-madvise}"
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "$THP_MODE" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

        cat << EOF > "$THP_UNIT"
[Unit]
Description=Set THP to ${THP_MODE} (managed by Vayu)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ${THP_MODE} > /sys/kernel/mm/transparent_hugepage/enabled && \\
  echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now vayu-thp.service 2>/dev/null || true
        echo "  ✓ THP locked to ${THP_MODE} (prevents 2MB memory bloat)."
    fi

    # 4. Tier 1: ZRAM Setup
    if ! dpkg -s zram-tools >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zram-tools
    fi

    touch "$ZRAM_CONF"
    sed -i '/^ALGO=/d;/^PERCENT=/d;/^SIZE=/d;/^PRIORITY=/d' "$ZRAM_CONF"
    printf 'ALGO=%s\nPERCENT=%s\nPRIORITY=100\n' "$ALGO" "$ZRAM_PCT" >> "$ZRAM_CONF"
    systemctl restart zramswap.service 2>/dev/null || true
    systemctl enable zramswap.service 2>/dev/null || true
    echo "  ✓ Tier 1 ZRAM active (priority 100, ${ALGO} compression)."

    # 5. Tier 2: Fallback Disk Swap (Guarded by disk-space safety margin)
    local existing_disk_swap
    existing_disk_swap=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | awk '$2 != "zram" {print $1}' | tr '\n' ' ' || true)

    if [[ -n "${existing_disk_swap// }" ]]; then
        echo "  ✓ Existing disk swap detected (${existing_disk_swap% }) — leaving intact."
    elif [[ -f /swapfile ]] && swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/swapfile'; then
        echo "  ✓ /swapfile is already active — leaving intact."
    else
        local min_swap_mb=512
        local free_disk_mb
        free_disk_mb=$(df --output=avail -m / 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
        [[ "$free_disk_mb" =~ ^[0-9]+$ ]] || free_disk_mb=0

        if (( free_disk_mb < SAFETY_MARGIN_MB + min_swap_mb )); then
            echo "  ⚠ Insufficient free disk space (${free_disk_mb}MB free, safety reserve: ${SAFETY_MARGIN_MB}MB)."
            echo "    Skipping fallback disk swap creation to protect the root filesystem."
        else
            # Ensure swap allocation leaves at least SAFETY_MARGIN_MB available
            if (( free_disk_mb - SWAP_MB < SAFETY_MARGIN_MB )); then
                local clamped_swap=$(( free_disk_mb - SAFETY_MARGIN_MB ))
                echo "  ⚠ Requested swap (${SWAP_MB}MB) exceeds safe disk budget (free: ${free_disk_mb}MB, reserve: ${SAFETY_MARGIN_MB}MB)."
                if (( clamped_swap >= min_swap_mb )); then
                    echo "  -> Clamping fallback swapfile to ${clamped_swap}MB to preserve safety reserve."
                    SWAP_MB="$clamped_swap"
                else
                    echo "  -> Safe swap capacity too small (< ${min_swap_mb}MB). Skipping swapfile creation."
                    SWAP_MB=0
                fi
            fi

            if (( SWAP_MB >= min_swap_mb )); then
                echo "  -> Allocating ${SWAP_MB} MB Tier 2 fallback swapfile..."
                local alloc_ok=0
                if fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null; then
                    alloc_ok=1
                elif dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_MB}" status=none 2>/dev/null; then
                    alloc_ok=1
                fi

                if (( ! alloc_ok )); then
                    echo "  ✗ Failed to allocate /swapfile (disk error or filesystem unsupported)." >&2
                    rm -f /swapfile
                else
                    chmod 600 /swapfile
                    if ! mkswap /swapfile >/dev/null 2>&1; then
                        echo "  ✗ mkswap failed on /swapfile. Removing file." >&2
                        rm -f /swapfile
                    elif ! swapon --priority 10 /swapfile 2>/dev/null; then
                        echo "  ✗ swapon failed for /swapfile. Removing file." >&2
                        rm -f /swapfile
                    else
                        if ! grep -q '^/swapfile' /etc/fstab; then
                            echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
                        fi
                        echo "VAYU_CREATED_SWAPFILE=1" >> "$STATE_FILE"
                        echo "  ✓ Tier 2 disk swap active (${SWAP_MB}MB, priority 10, safety net)."
                    fi
                fi
            fi
        fi
    fi

    # 6. Sysctl Consolidated Memory & VM Config
    mkdir -p "$(dirname "$SYSCTL_CONF")"
    cat << EOF > "$SYSCTL_CONF"
# Managed by Vayu Tiered Memory Engine
vm.swappiness = ${SWAPPINESS}
vm.page-cluster = 0
vm.vfs_cache_pressure = ${VFS_PRESSURE}
vm.watermark_scale_factor = 125
vm.watermark_boost_factor = 0
vm.min_free_kbytes = ${REC_MIN_FREE_KB}
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF
    sysctl --system >/dev/null
    echo "  ✓ Kernel memory sysctls applied (swappiness=${SWAPPINESS}, page-cluster=0, vfs_cache_pressure=${VFS_PRESSURE})."

    # 6b. Network BBR & FQ qdisc (Opt-in)
    if [[ "$ENABLE_BBR" == "true" ]]; then
        modprobe tcp_bbr 2>/dev/null || true
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
            cat << 'EOF' > "$BBR_CONF"
# Managed by Vayu Network Engine (Opt-in)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
            sysctl -p "$BBR_CONF" >/dev/null 2>&1 || true
            echo "VAYU_ENABLED_BBR=1" >> "$STATE_FILE"
            echo "  ✓ TCP BBR congestion control and FQ qdisc enabled."
        else
            echo "  ⚠ Kernel does not support TCP BBR congestion control. Skipped."
        fi
    else
        echo "  ℹ Network BBR tuning skipped (opt-in with --tune-network or VAYU_ENABLE_BBR=true)."
    fi

    # 7. Journald Caps (Opt-in)
    if [[ "$ENABLE_JOURNALD" == "true" ]]; then
        mkdir -p "$(dirname "$JOURNALD_CONF")"
        cat << 'EOF' > "$JOURNALD_CONF"
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=40M
MaxRetentionSec=1week
EOF
        systemctl restart systemd-journald 2>/dev/null || true
        echo "VAYU_ENABLED_JOURNALD=1" >> "$STATE_FILE"
        echo "  ✓ Journald caps applied (100M disk / 40M runtime)."
    else
        echo "  ℹ Journald retention caps skipped (opt-in with --tune-journald or VAYU_ENABLE_JOURNALD=true)."
    fi

    # 8. Flush disposable caches (Opt-in)
    if [[ "$ENABLE_RECLAIM" == "true" ]]; then
        reclaim_memory
    else
        echo "  ℹ Disposable cache flush skipped (run 'vayu --reclaim' for manual one-time cache eviction)."
    fi
}

MODE="apply"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --revert)
            MODE="revert" ;;
        --reclaim)
            MODE="reclaim" ;;
        --enable-ksm)
            export VAYU_ENABLE_KSM="true" ;;
        --tune-network|--enable-bbr)
            export VAYU_ENABLE_BBR="true" ;;
        --tune-journald)
            export VAYU_ENABLE_JOURNALD="true" ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
    shift
done

if [[ "$MODE" == "revert" ]]; then
    revert_memory
elif [[ "$MODE" == "reclaim" ]]; then
    reclaim_memory
else
    apply_memory_tuning
fi
