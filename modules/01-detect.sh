#!/usr/bin/env bash
# =============================================================================
# Vayu Module 01: Hardware & Kernel Capability Detector
# =============================================================================
# Standalone usage: ./modules/01-detect.sh
# Purpose: Probes system hardware, cloud hypervisor, and kernel subsystems,
#          then computes dynamic, hardware-tailored recommendations.
# =============================================================================

set -Eeuo pipefail

# Output variables
DETECT_RAM_MB=0
DETECT_CPU_CORES=1
DETECT_DISK_FREE_MB=0
DETECT_CLOUD_HYPERVISOR="Unknown"
DETECT_KERNEL_VERSION=""
DETECT_HAS_MGLRU=0
DETECT_HAS_CGROUP_RECLAIM=0
DETECT_HAS_ZRAM_MODULE=0

# Recommended auto-calculated parameters
REC_ZRAM_PERCENT=100
REC_SWAPFILE_MB=2048
REC_MIN_FREE_KB=8192
REC_KSM_PAGES=600
REC_KSM_SLEEP_MS=30

detect_system() {
    # 1. RAM Detection
    DETECT_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)

    # 2. CPU Cores
    DETECT_CPU_CORES=$(nproc 2>/dev/null || echo 1)

    # 3. Root Disk Free
    DETECT_DISK_FREE_MB=$(df --output=avail -m / 2>/dev/null | tail -1 | tr -d ' ' || echo 10240)

    # 4. Kernel Version
    DETECT_KERNEL_VERSION=$(uname -r)

    # 5. Cloud Hypervisor Detection
    if grep -qsi "oracle" /sys/class/dmi/id/chassis_asset_tag 2>/dev/null || [[ -d /etc/oracle-cloud-agent ]]; then
        DETECT_CLOUD_HYPERVISOR="Oracle Cloud Infrastructure (OCI)"
    elif grep -qsi "amazon" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        DETECT_CLOUD_HYPERVISOR="Amazon Web Services (AWS)"
    elif grep -qsi "google" /sys/class/dmi/id/product_name 2>/dev/null; then
        DETECT_CLOUD_HYPERVISOR="Google Cloud Platform (GCP)"
    elif grep -qsi "microsoft" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        DETECT_CLOUD_HYPERVISOR="Microsoft Azure"
    elif grep -qsi "digitalocean" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        DETECT_CLOUD_HYPERVISOR="DigitalOcean"
    elif grep -qsi "hetzner" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        DETECT_CLOUD_HYPERVISOR="Hetzner Cloud"
    elif [[ -f /sys/hypervisor/type ]]; then
        DETECT_CLOUD_HYPERVISOR="Virtual Machine ($(cat /sys/hypervisor/type))"
    else
        DETECT_CLOUD_HYPERVISOR="KVM / Generic Linux / Bare Metal"
    fi

    # 6. Kernel Subsystems Probing
    [[ -d /sys/kernel/mm/lru_gen ]] && DETECT_HAS_MGLRU=1
    [[ -f /sys/fs/cgroup/memory.reclaim ]] && DETECT_HAS_CGROUP_RECLAIM=1
    modinfo zram >/dev/null 2>&1 && DETECT_HAS_ZRAM_MODULE=1

    # 7. Dynamic Math Calculation
    # ZRAM: 100% on small VMs gives optimal compression without stealing silicon RAM
    if (( DETECT_RAM_MB <= 1100 )); then
        REC_ZRAM_PERCENT=100
    elif (( DETECT_RAM_MB <= 2200 )); then
        REC_ZRAM_PERCENT=125
    else
        REC_ZRAM_PERCENT=150
    fi

    # Swapfile: 2x RAM, but never exceed 20% of free disk
    local max_swap_allowed=$(( DETECT_DISK_FREE_MB * 20 / 100 ))
    local target_swap=$(( DETECT_RAM_MB * 2 ))
    (( target_swap < 2048 )) && target_swap=2048
    (( target_swap > 4096 )) && target_swap=4096

    if (( target_swap > max_swap_allowed )); then
        REC_SWAPFILE_MB=$max_swap_allowed
    else
        REC_SWAPFILE_MB=$target_swap
    fi

    # Minimum free kbytes: ~1% of RAM (clamped 4096 - 32768)
    local calc_min=$(( (DETECT_RAM_MB * 1024) / 100 ))
    (( calc_min < 4096 ))  && calc_min=4096
    (( calc_min > 32768 )) && calc_min=32768
    REC_MIN_FREE_KB=$calc_min

    # KSM CPU Tuning based on cores
    if (( DETECT_CPU_CORES == 1 )); then
        REC_KSM_PAGES=400
        REC_KSM_SLEEP_MS=40
    else
        REC_KSM_PAGES=1000
        REC_KSM_SLEEP_MS=20
    fi
}

print_summary() {
    local zram_virtual_mb=$(( DETECT_RAM_MB * REC_ZRAM_PERCENT / 100 ))
    local virtual_ceiling=$(( DETECT_RAM_MB + zram_virtual_mb + REC_SWAPFILE_MB ))
    cat <<EOF
=============================================================================
  Vayu System & Capability Analysis
=============================================================================
[Host Architecture]
  Cloud / Hypervisor   : ${DETECT_CLOUD_HYPERVISOR}
  Kernel Version       : ${DETECT_KERNEL_VERSION}
  Physical RAM         : ${DETECT_RAM_MB} MB
  CPU Cores            : ${DETECT_CPU_CORES}
  Root Free Disk       : ${DETECT_DISK_FREE_MB} MB

[Kernel Subsystems Detected]
  Multi-Gen LRU (MGLRU): $( (( DETECT_HAS_MGLRU )) && echo "✓ Supported (Linux 6.1+)" || echo "✗ Not supported" )
  cgroups v2 Reclaim   : $( (( DETECT_HAS_CGROUP_RECLAIM )) && echo "✓ Supported" || echo "✗ Not supported" )
  ZRAM Kernel Module   : $( (( DETECT_HAS_ZRAM_MODULE )) && echo "✓ Available" || echo "⚠ Missing (needs linux-modules-extra)" )
  Kernel Samepage (KSM): $( [[ -f /sys/kernel/mm/ksm/run ]] && echo "✓ Supported (opt-in with --enable-ksm)" || echo "✗ Not supported" )

[Computed Dynamic Policy]
  Recommended ZRAM Size: ${REC_ZRAM_PERCENT}% of RAM (${zram_virtual_mb} MB virtual device)
  Fallback Disk Swap   : ${REC_SWAPFILE_MB} MB (Tier 2 safety net)
  Virtual Swap Ceiling : ~${virtual_ceiling} MB (Physical RAM + ZRAM virtual + Disk swap)
  Note: Physical RAM is ${DETECT_RAM_MB} MB. ZRAM compresses cold pages in-RAM; disk swap is last resort.
=============================================================================
EOF
}

detect_system

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    print_summary
fi
