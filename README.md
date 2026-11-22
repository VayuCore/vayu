<p align="center">
  <a href="https://github.com/VayuCore/vayu">
    <img src="assets/logo.svg" alt="Vayu" width="72" height="72">
  </a>
</p>

<h1 align="center">Vayu (वायु)</h1>

<p align="center">
  <strong>Opinionated Linux Memory Guardrail & Bootstrap Toolkit</strong><br>
  Prevent OOM crashes & kswapd thrashing on memory-constrained VPS instances (1–8 GB RAM).
</p>

<p align="center">
  <a href="https://github.com/VayuCore/vayu"><img src="https://img.shields.io/badge/Source-GitHub-181717?style=flat-square&logo=github" alt="Source"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License MIT"></a>
  <a href="https://ubuntu.com"><img src="https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-orange?style=flat-square" alt="Ubuntu / Debian"></a>
  <img src="https://img.shields.io/badge/Target-1%E2%80%938%20GB%20RAM-brightgreen?style=flat-square" alt="Target RAM">
</p>

---

### The Reality of 1–8 GB VPS Servers

Resource-constrained cloud instances (1–8 GB RAM, 1–2 vCPUs on AWS, Oracle Cloud, Hetzner, DigitalOcean, or GCP) frequently lock up or crash under spiky workloads:

1. **`kswapd` CPU Lockups:** When memory runs low, the legacy kernel page scanner attempts aggressive synchronous reclaim against slow cloud block storage, pegging CPU at 100% and freezing SSH.
2. **OOM Killer Invocations:** Background worker processes, Python runtimes, and agent workloads get unceremoniously killed when resident heap spikes.
3. **Heap Fragmentation:** Multi-threaded runtimes spawning multiple glibc memory arenas fragment physical memory, leaving tens or hundreds of megabytes unclaimable.

**Vayu is not a magical RAM creator.** It does not overcome the laws of physics or replace hardware scaling for heavy production databases. Instead, Vayu configures production-tested Linux kernel subsystems, tiered memory compression, allocator bounds, and clean rollback guardrails so that small servers absorb transient memory spikes gracefully without crashing or thrashing.

---

## 🏛️ The Four-Pillar Architecture

| Pillar | Mechanism | Technical Purpose |
| :--- | :--- | :--- |
| **1. Tier 1: In-RAM Compression** | ZRAM (`zstd` / `lz4`) at Priority 100 | Compresses idle/cold anonymous memory inside RAM at typical **2.5:1 to 4:1 ratios** with microsecond latency; acts as the primary swap tier before any disk I/O. |
| **2. Tier 2: Guarded Fallback Swap** | Disk/NVMe swapfile at Priority 10 | Emergency safety net only touched on genuine saturation; protected by a mandatory free-disk headroom check (`VAYU_DISK_SAFETY_MARGIN_MB=2048`). |
| **3. Kernel Reclaim & VM Tuning** | MGLRU (`CONFIG_LRU_GEN`), `vm.page-cluster=0`, `vm.swappiness=160`, `vm.vfs_cache_pressure=150` | Multi-Gen LRU replaces legacy dual-list scanning to prevent `kswapd` thrashing; single-page paging eliminates wasted decompression readahead; keeps filesystem metadata hot. |
| **4. Process & Allocator Bounds** | `MALLOC_ARENA_MAX=2`, concurrency limits | Bounds glibc multi-threaded heap creation (which defaults to $8 \times \text{cores}$ on 64-bit systems), saving 80–120 MB of fragmented virtual memory padding. |

---

## ⚡ Quickstart

### 1. Run Full Safe Pipeline (Default)

```bash
git clone https://github.com/VayuCore/vayu.git
cd vayu
chmod +x vayu setup.sh modules/*.sh bench/*.sh
sudo ./vayu
```

### 2. Optional: Install CLI Globally

```bash
sudo ./vayu --install-cli

# Now accessible system-wide:
vayu --verify
vayu --bench
sudo vayu --revert
```

---

## 🔍 Understanding Memory Metrics: `MemFree` vs. `MemAvailable`

> [!IMPORTANT]
> **Do not confuse `MemFree` with usable capacity.**
> * **`MemFree`** only counts completely unallocated pages. A jump in `MemFree` following cache eviction (`drop_caches`) is **not** a raw usable RAM gain—it simply discards the kernel page cache and forces slow disk I/O when processes read files again.
> * **`MemAvailable`** is the kernel's estimate of memory available for starting new applications without swapping. Vayu does not drop caches during normal apply; it optimizes *effective capacity* and *swap hierarchy* so `MemAvailable` remains functional under memory pressure.

---

## 📊 Live Verification & Benchmarks

### 1. Operational Telemetry (`vayu --verify`)

Captured on a live **Oracle Cloud Infrastructure (OCI) `VM.Standard.E2.1.Micro`** (AMD EPYC, 2 vCPUs, 951 MiB RAM, Linux 7.0):

```text
$ vayu --verify

=============================================================================
  VAYU SYSTEM HEALTH & MEMORY TELEMETRY REPORT
=============================================================================
[Host Overview]
  Hostname     : agni11 | Cores: 2 | Kernel: 7.0.0-1016-oracle
  Uptime       : up 5 days, 19 hours

[Physical Memory & Swap Allocation]
               total        used        free      shared  buff/cache   available
Mem:           951Mi       725Mi        88Mi       4.0Mi       311Mi       225Mi
Swap:          2.9Gi       285Mi       2.7Gi
  MemTotal (Hardware)          : 951 MB
  MemAvailable (Real Usable)   : 225 MB (True usable headroom)
  MemFree (Raw free)           : 88 MB (Unallocated pages only)

[Active Swap Tiers (Higher Priority = Used First)]
NAME       TYPE        SIZE   USED PRIO
/dev/zram0 partition 951.2M 247.7M  100   <-- Tier 1: In-RAM compressed block device
/swapfile  file          2G  37.8M   10   <-- Tier 2: NVMe/Disk fallback overflow

[Tier 1: ZRAM In-Memory Compression Status]
NAME       ALGORITHM DISKSIZE   DATA COMPR TOTAL STREAMS MOUNTPOINT
/dev/zram0 zstd        951.2M 245.7M 70.5M 73.4M         [SWAP]
  --> Effective Compression Ratio: 3.48:1 (245 MB cold pages held in 70 MB physical RAM)

[Active Kernel Subsystems & Tunables]
  Multi-Gen LRU (MGLRU)          = 0x0007 (Active - 4 Generations)
  THP Mode                       = [madvise] (Eliminates 2MB page fragmentation)
  KSM Deduplication Status       = 0 (Inactive / Disabled by default to save CPU)
  vm.swappiness (Target: 160)    = 160
  vm.page-cluster (Target: 0)    = 0
  vm.vfs_cache_pressure          = 150
  Kernel OOM Kill Events         = 0 (Clean - No OOM events)

[Kernel Memory Pressure (PSI - Lower is Better)]
some avg10=0.00 avg60=0.01 avg300=0.08 total=1449369868
full avg10=0.00 avg60=0.01 avg300=0.08 total=1075261087
=============================================================================
```

### 2. Reproducible Load Benchmark (`vayu --bench`)

Vayu includes a reproducible benchmark tool under `bench/benchmark.sh` that captures operational signals under synthetic load without fake cache-drop metrics:

```text
$ vayu --bench

=============================================================================
  VAYU REPRODUCIBLE MEMORY BENCHMARK
=============================================================================
  Target Workload Allocation  : 128 MB
  Available Physical RAM      : 245 MB
  Data Pattern                : Semi-compressible repeated block (~3:1 ratio)
  Execution Mode              : Safe allocation + page-fault dirtying + fork latency

  -> Capturing pre-workload system baseline...
  -> Executing memory allocation & subprocess latency test...

[Benchmark Performance & Responsiveness]
  Allocated & Faulted Memory : 128 MB
  Allocation Latency         : 23.82 ms (5373.6 MB/s)
  Fork/Exec Latency (load)   : 3.69 ms per subprocess

[Memory Pressure & Kernel Health Deltas]
  PSI Some Stall Delta       : 0 ms (some tasks delayed waiting for memory)
  PSI Full Stall Delta       : 0 ms (Zero deadlock - All CPU cores made forward progress)
  OOM Kill Events (delta)    : 0 (PASSED - Guardrails prevented OOM)

[Swap & ZRAM Compression Efficiency]
  ZRAM In-Memory Compression : 3.48:1
  Swap Pages In / Out        : +0 in / +0 out
  Disk Swap Spillover        : 0 MB

=============================================================================
  ✓ VERDICT: PASSED. System absorbed 128MB allocation without OOM or thrashing.
=============================================================================
```

You can also output machine-readable JSON for CI/CD automation:
```bash
vayu --bench --json
vayu --bench --check --json
```

---

## 🛠️ The Technical Deep Dive

### 1. Tiered Virtual Memory & Realistic Compression
* **Tier 1: ZRAM (Priority 100):** Allocates a compressed block device in RAM using `zstd` (or `lz4`).
  * *Compressibility Reality:* Text, JSON, dictionaries, logs, and application heap typically achieve **2.5:1 to 4:1** compression ratios. Highly redundant data can reach **5:1–7:1**, but already-compressed or encrypted data (JPEGs, media, TLS buffers, compressed tarballs) will achieve **~1:1**.
  * *CPU Cost:* Compressing and decompressing pages consumes CPU cycles. On modern x86/ARM cores, `zstd` decompress runs at >1 GB/s per core (~2–4 microseconds per 4 KB page), which is orders of magnitude faster than NVMe or cloud disk seek latency.
* **Tier 2: Fallback Disk Swap (Priority 10):** Configured with priority 10 so the kernel exhausts fast ZRAM first.
  * *Disk Safety Headroom:* Before creating `/swapfile`, Vayu verifies free root disk space against `VAYU_DISK_SAFETY_MARGIN_MB` (default `2048 MB`). If disk space is tight, it clamps the swapfile or skips creation to prevent disk-full crashes.

### 2. Multi-Gen LRU (`MGLRU`)
Legacy Linux kernels maintain two lists (active and inactive) for anonymous and file pages. Under high memory pressure on small VMs, `kswapd` spins at 100% CPU scanning pages. Linux 6.1+ Multi-Gen LRU (`/sys/kernel/mm/lru_gen`) introduces generational generation-based tracking, eliminating the `kswapd` thrashing livelock.

### 3. Transparent Huge Pages (`THP=madvise`)
Standard hugepages allocate 2 MB blocks. On small 1–2 GB VPS instances, allocating 2 MB for a process that only needs 64 KB creates severe internal memory fragmentation. Vayu locks THP to `madvise` and defrag to `defer+madvise`, preventing automatic 2 MB page bloat while allowing specialized applications that explicitly request huge pages to use them.

### 4. Glibc Memory Arena Throttling (`MALLOC_ARENA_MAX=2`)
On 64-bit glibc systems, the allocator creates up to $8 \times \text{CPU cores}$ memory arenas ($16$ arenas on 2 cores, $32$ on 4 cores, $64$ on 8 cores). In multi-threaded runtimes (Python, Node.js, C/C++ services), each thread gets its own arena with separate heap allocation pools, leading to 80–150 MB of resident memory fragmentation.
* *Configuration:* Setting `MALLOC_ARENA_MAX=2` bounds the allocator to 2 arenas.
* *Trade-off:* Multi-threaded programs with dozens of threads doing heavy, simultaneous `malloc()` / `free()` operations in tight loops may experience minor arena mutex contention. For 1–8 GB VPS servers running developer tools, agents, or microservices, this trade-off is overwhelmingly positive, saving substantial RAM.

### 5. Zero Page-Cluster Paging (`vm.page-cluster = 0`)
The Linux kernel default `vm.page-cluster = 3` reads $2^3 = 8$ contiguous pages (32 KB) on every swap-in. On rotating or cloud disk, this amortizes head movement. On in-memory ZRAM, there are no disk seeks; readahead simply forces the CPU to decompress 28 KB of unrequested data. Setting `vm.page-cluster = 0` restricts swap-in to single 4 KB pages, eliminating wasted CPU cycles.

---

## 🎛️ Default vs. Opt-In Actions

To keep default runs safe, predictable, and non-invasive, aggressive side effects and auxiliary networking changes are strictly opt-in:

| Action / Flag | Default | Description |
| :--- | :--- | :--- |
| `sudo vayu` *(no args)* | **Safe Core** | Applies ZRAM, guarded swap, MGLRU, THP madvise, memory sysctls, and glibc bounds. |
| `--reclaim` | Opt-in | Runs a one-time clean page cache flush (`drop_caches=3`) and cgroup memory reclaim. |
| `--enable-ksm` | Disabled | Enables Kernel Samepage Merging (`ksmd`). Disabled by default because page scanning consumes 10–30% CPU on 1–2 vCPU VPS instances for near-zero deduplication on non-container hosts. |
| `--tune-network` | Disabled | Enables TCP BBR congestion control and Fair Queueing (`fq`) qdisc (stored in `/etc/sysctl.d/99-vayu-bbr.conf`). |
| `--tune-journald` | Disabled | Applies disk (100 MB) and runtime (40 MB) size caps to systemd journald. |
| `--bench [OPTS]` | On Demand | Executes the reproducible load benchmark or telemetry check. |
| `--revert` | Safe Rollback | Completely restores all configs and runtime settings back to pre-Vayu baseline. |

---

## 🛡️ State Backup & True Rollback (`--revert`)

Vayu takes a full snapshot before applying changes and supports clean, genuine rollback:

1. **State Snapshot:** Before touching configs, Vayu snapshots `/etc/fstab`, `/etc/environment`, relevant sysctls, ZRAM configuration, journald configuration, and runtime kernel subsystem states (THP, KSM, MGLRU) into `/var/lib/vayu/backup/`.
2. **Idempotent Baseline Protection:** If `/var/lib/vayu/backup/` exists, subsequent runs never overwrite the original pre-Vayu baseline.
3. **Swapfile Rollback:** Deactivates and deletes `/swapfile` **only** if Vayu created it (tracked via `state.env`). Pre-existing user swapfiles and partitions are left intact.
4. **Environment Rollback:** Surgically removes only `MALLOC_ARENA_MAX=2` and `PYTHONDONTWRITEBYTECODE=1` without clobbering unrelated user environment variables added after installation.
5. **Immediate Runtime Restoration:** Re-applies baseline sysctls directly via `sysctl -w` so kernel memory returns to default immediately without requiring a reboot.
6. **State Directory Cleanup:** Rollback cleanly removes `/var/lib/vayu/` after all revert steps succeed.

```bash
sudo vayu --revert
```

---

## ⚙️ Configuration File (`vayu.conf`)

Customize policy in `config/vayu.conf` or `/etc/vayu/vayu.conf`:

```bash
# ZRAM allocation percentage relative to RAM ("auto" scales 100-150%)
VAYU_ZRAM_PERCENT="auto"

# ZRAM compression algorithm (zstd, lz4)
VAYU_ZRAM_ALGO="zstd"

# Fallback disk swapfile size in MB ("auto" bounds to max 20% free disk)
VAYU_SWAP_SIZE_MB="auto"

# Minimum free disk headroom (MB) required to remain after swap allocation
VAYU_DISK_SAFETY_MARGIN_MB="2048"

# Swappiness (160 prioritizes compressed ZRAM over dropping file caches)
VAYU_SWAPPINESS="160"

# VFS Cache Pressure (150 reclaims stale directory/inode caches)
VAYU_VFS_CACHE_PRESSURE="150"

# Transparent Huge Pages mode (madvise | never)
VAYU_THP_MODE="madvise"

# Opt-in subsystems (set to "true" to enable in standard runs)
VAYU_ENABLE_KSM="false"
VAYU_ENABLE_BBR="false"
VAYU_ENABLE_JOURNALD="false"
VAYU_ENABLE_RECLAIM="false"
```

---

## ⚖️ When to Use / When Not to Use

| ✅ **Use Vayu When...** | ❌ **Don't Use Vayu When...** |
| :--- | :--- |
| Running 1–8 GB VPS instances (AWS, OCI, Hetzner, DO, GCP) | Running on instances with $\ge 16$ GB RAM and no memory pressure |
| Hosting CLI agents, automation, microservices, CI runners | Running large local LLMs (Ollama 7B/8B+) needing raw RAM bandwidth |
| Experiencing OOM kills, `kswapd` CPU thrashing, or fork failures | High-throughput databases where active hot set exceeds physical RAM |
| Needing verifiable, reversible, distro-native tuning (no custom kernels) | Requiring microsecond hard real-time latency guarantees |

---

## 📄 License

[MIT License](LICENSE) — Free for personal and commercial use.
