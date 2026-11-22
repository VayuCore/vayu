#!/usr/bin/env bash
# =============================================================================
# Vayu Module 06: Verification & Telemetry Dashboard
# =============================================================================
# Standalone usage: ./modules/06-verify.sh
# Purpose: Non-destructive health check of memory tiers, kernel tunables,
#          PSI memory pressure, and active agent processes.
# =============================================================================

set -Eeuo pipefail

# Colors
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_HDR=$'\033[1;36m'
    C_SEC=$'\033[1;34m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_DIM=$'\033[90m'
    C_BOLD=$'\033[1m'
    C_RST=$'\033[0m'
else
    C_HDR='' C_SEC='' C_OK='' C_WARN='' C_DIM='' C_BOLD='' C_RST=''
fi

echo "${C_HDR}=============================================================================${C_RST}"
echo "${C_BOLD}  VAYU SYSTEM HEALTH & MEMORY TELEMETRY REPORT${C_RST}"
echo "${C_HDR}=============================================================================${C_RST}"

echo "${C_SEC}[Host Overview]${C_RST}"
echo "  Hostname     : $(hostname) | Cores: $(nproc) | Kernel: $(uname -r)"
echo "  Uptime       : $(uptime -p 2>/dev/null || uptime)"
echo ""

echo "${C_SEC}[Physical Memory & Swap Allocation]${C_RST}"
free -h
mem_total_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))
mem_avail_mb=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))
mem_free_mb=$(( $(awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))
printf "  %-28s : %d MB\n" "MemTotal (Hardware)" "$mem_total_mb"
printf "  %-28s : %s%d MB%s (True usable headroom)\n" "MemAvailable (Real Usable)" "$C_OK" "$mem_avail_mb" "$C_RST"
printf "  %-28s : %d MB (Unallocated pages only)\n" "MemFree (Raw free)" "$mem_free_mb"
echo ""

if command -v swapon >/dev/null 2>&1; then
    echo "${C_SEC}[Active Swap Tiers (Higher Priority = Used First)]${C_RST}"
    swapon --show
    echo ""
fi

if command -v zramctl >/dev/null 2>&1; then
    echo "${C_SEC}[Tier 1: ZRAM In-Memory Compression Status]${C_RST}"
    zramctl
    echo ""
fi

echo "${C_SEC}[Active Kernel Subsystems & Tunables]${C_RST}"
if [[ -d /sys/kernel/mm/lru_gen ]]; then
    mglru_val=$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo "n/a")
    printf "  %-30s = %s%s%s\n" "Multi-Gen LRU (MGLRU)" "$C_OK" "$mglru_val" "$C_RST"
fi
printf "  %-30s = %s\n" "THP Mode" "$(grep -o '\[.*\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
ksm_val=$(cat /sys/kernel/mm/ksm/run 2>/dev/null || echo n/a)
if [[ "$ksm_val" == "0" ]]; then
    ksm_status="0 (Inactive / Disabled by default)"
elif [[ "$ksm_val" == "1" ]]; then
    ksm_status="1 (Active)"
else
    ksm_status="$ksm_val"
fi
printf "  %-30s = %s\n" "KSM Deduplication Status" "$ksm_status"
printf "  %-30s = %s%s%s\n" "vm.swappiness (Target: 160)" "$C_OK" "$(sysctl -n vm.swappiness 2>/dev/null || echo n/a)" "$C_RST"
printf "  %-30s = %s%s%s\n" "vm.page-cluster (Target: 0)" "$C_OK" "$(sysctl -n vm.page-cluster 2>/dev/null || echo n/a)" "$C_RST"
printf "  %-30s = %s\n" "vm.vfs_cache_pressure" "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo n/a)"
printf "  %-30s = %s\n" "vm.watermark_scale_factor" "$(sysctl -n vm.watermark_scale_factor 2>/dev/null || echo n/a)"
printf "  %-30s = %s\n" "TCP Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
oom_kills=$(awk '/oom_kill/{print $2}' /proc/vmstat 2>/dev/null || echo 0)
if (( oom_kills == 0 )); then
    printf "  %-30s = %s0 (Clean - No OOM events)%s\n" "Kernel OOM Kill Events" "$C_OK" "$C_RST"
else
    printf "  %-30s = %s%d (Warning: Processes killed)%s\n" "Kernel OOM Kill Events" "$C_WARN" "$oom_kills" "$C_RST"
fi
echo ""

if [[ -f /proc/pressure/memory ]]; then
    echo "${C_SEC}[Kernel Memory Pressure (PSI - Lower is Better)]${C_RST}"
    cat /proc/pressure/memory
    echo ""
fi

echo "${C_SEC}[Active Agent & Python Workloads]${C_RST}"
ps -eo pid,%cpu,%mem,rss,comm --sort=-%mem | grep -E "hermes|python3" | grep -v grep | head -6 || echo "  ${C_DIM}(None currently active)${C_RST}"
echo ""
echo "  ${C_DIM}Run 'vayu --bench' or './bench/benchmark.sh' to measure memory pressure & allocation throughput under load.${C_RST}"
echo "${C_HDR}=============================================================================${C_RST}"
