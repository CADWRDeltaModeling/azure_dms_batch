#!/bin/bash
# schism_mpi_timing_test_mvapich2.sh — MVAPICH2 MPI tuning timing benchmark for SCHISM
#                                       on Azure HBv3 (Standard_HB120rs_v3) and
#                                       HBv2 (Standard_HB120rs_v2)
#
# Usage: schism_mpi_timing_test_mvapich2.sh [study_dir] [rnday] [num_cores] [num_scribes] [max_mins]
#
#   study_dir   : path to SCHISM study directory (default: .)
#   rnday       : simulation end-day in param.nml (absolute, not relative); leave at
#                 its current value if running a hotstart benchmark (default: keep as-is)
#   num_cores   : total MPI ranks (default: nproc * #hosts-in-hostfile)
#   num_scribes : SCHISM scribe count (default: 10)
#   max_mins    : kill any variant that runs longer than this many minutes (default: no limit)
#
# Runs SCHISM under multiple MVAPICH2 env var combinations and reports simulation
# throughput as sim_days_per_minute (measured from first flux.out change, excluding init time).
# Simulation progress is monitored via outputs/flux.out, sampled every BENCH_POLL_INTERVAL s (default: 30).
#
# Designed for MVAPICH2 2.3.7-1 on Azure HBv3 and HBv2:
#   HBv3  Standard_HB120rs_v3 — AMD EPYC Milan-X, 120 cores, 8 NUMA × 15, HDR200 IB
#   HBv2  Standard_HB120rs_v2 — AMD EPYC Rome,    120 cores, 8 NUMA × 15, HDR   IB
#
# Key MVAPICH2 2.3.7 tuning knobs tested:
#   MV2_CPU_BINDING_POLICY  bunch|scatter — NUMA-aware process-to-core placement
#   MV2_CPU_BINDING_LEVEL   numanode|core — granularity of binding
#   MV2_ENABLE_AFFINITY     1             — enable hardware affinity
#   MV2_ENABLE_SHARP        1             — SHARP in-network collective  (HDR; may be off)
#   MV2_HOMOGENEOUS_CLUSTER 1             — identical nodes → faster comm setup
#   MV2_NDREG_ENTRIES_MAX   131072        — memory registration cache size (ODP performance)
#   MV2_NDREG_ENTRIES       32768         — initial NDREG entry count
#   MV2_IBA_HCA             mlx5_ib0:1   — explicit HCA device pin
#
# Assumptions:
#   - 'hostfile' is present in study_dir (one host per line; produced by Batch coord cmd)
#   - pschism_PREC_EVAP_GOTM_TVD-VL is on PATH (from setup_paths.sh / module load mvapich2)
#   - param.nml is in study_dir
#
# WARNING: This script clears outputs/ between each run. Do NOT run against a directory
#          with outputs you wish to keep.
#
# SCHISM_EXE env var overrides the default executable name.

set -uo pipefail

STUDY_DIR="${1:-.}"
STUDY_DIR="$(realpath "$STUDY_DIR")"
BENCH_RNDAY="${2:-}"         # empty = do not patch rnday (use value already in param.nml)
NUM_SCRIBES="${4:-10}"
export BENCH_TIMEOUT_MINS="${5:-}"   # empty = no timeout; N = kill variant after N minutes
SCHISM_EXE="${SCHISM_EXE:-pschism_PREC_EVAP_GOTM_TVD-VL}"
RESULTS_FILE="${STUDY_DIR}/mpi_timing_results_mvapich2.txt"

cd "$STUDY_DIR"

# ---------------------------------------------------------------------------
# Detect hostfile
# ---------------------------------------------------------------------------
HOSTFILE="${STUDY_DIR}/hostfile"
if [ ! -f "$HOSTFILE" ]; then
    echo "ERROR: hostfile not found at $HOSTFILE"
    echo "  Create a hostfile with one host IP (or hostname) per line."
    echo "  In Azure Batch this is produced by the coordination command template."
    exit 1
fi

NUM_HOSTS=$(wc -l < "$HOSTFILE")
CORES_PER_NODE=$(nproc)
NUM_CORES="${3:-$(( NUM_HOSTS * CORES_PER_NODE ))}"

echo "=== SCHISM MVAPICH2 Timing Benchmark ==="
echo "Study dir   : $STUDY_DIR"
echo "Hosts       : $NUM_HOSTS  ($(tr '\n' ',' < "$HOSTFILE" | sed 's/,$//') )"
echo "Cores/node  : $CORES_PER_NODE"
echo "Total cores : $NUM_CORES"
echo "Scribes     : $NUM_SCRIBES"
echo "rnday       : ${BENCH_RNDAY:-<unchanged from param.nml>}"
echo "timeout     : ${BENCH_TIMEOUT_MINS:-none} min"
echo "Executable  : $(command -v "$SCHISM_EXE" 2>/dev/null || echo 'NOT FOUND ON PATH — set SCHISM_EXE')"
echo ""

# ---------------------------------------------------------------------------
# Verify executable
# ---------------------------------------------------------------------------
if ! command -v "$SCHISM_EXE" &>/dev/null; then
    echo "ERROR: $SCHISM_EXE not found on PATH."
    echo "  Run: source \$AZ_BATCH_APP_PACKAGE_schism_with_deps_*/schism/setup_paths.sh"
    echo "  Or set: export SCHISM_EXE=/full/path/to/pschism_..."
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect IBA HCA device (used for MV2_IBA_HCA variant)
# MVAPICH2 uses ibverbs directly, not UCX — so ibstat is the right tool.
# ---------------------------------------------------------------------------
IBA_HCA=""
if command -v ibstat &>/dev/null; then
    # ibstat output: "CA 'mlx5_0'" or similar; port 1 is active
    IBA_HCA=$(ibstat 2>/dev/null \
        | awk "/^CA '/{ca=\$2; gsub(\"'\",\"\",ca)} /Port 1/{print ca\":1\"; exit}")
fi
if [ -z "$IBA_HCA" ]; then
    # Fall back to first mlx5 device via ibv_devices
    IBA_HCA=$(ibv_devices 2>/dev/null | awk 'NR==2{print $1":1"}')
fi
if [ -z "$IBA_HCA" ]; then
    IBA_HCA="mlx5_ib0:1"
    echo "WARNING: Could not auto-detect IBA HCA; defaulting to $IBA_HCA"
fi
echo "IBA HCA device : $IBA_HCA"
echo ""

# ---------------------------------------------------------------------------
# Shared helpers (patch_rnday, setup_sflux, restore_outputs, read_sim_days,
# bench_init_backups, bench_restore_final, print_timing_summary)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")" 
source "${SCRIPT_DIR}/schism_bench_lib.sh"

# ---------------------------------------------------------------------------
# Unset any MV2_* env vars inherited from the Batch application command template
# (e.g. MV2_HOMOGENEOUS_CLUSTER, MV2_NDREG_ENTRIES_MAX, MV2_ENABLE_AFFINITY, etc.)
# so each variant starts from a clean baseline and controls its own settings.
# ---------------------------------------------------------------------------
unset MV2_HOMOGENEOUS_CLUSTER
unset MV2_NDREG_ENTRIES_MAX
unset MV2_NDREG_ENTRIES
unset MV2_ENABLE_AFFINITY
unset MV2_CPU_BINDING_POLICY
unset MV2_CPU_BINDING_LEVEL

# ---------------------------------------------------------------------------
# Backups (param.nml and outputs/) — created once, re-used for each variant
# ---------------------------------------------------------------------------
bench_init_backups

# ---------------------------------------------------------------------------
# Results file header
# ---------------------------------------------------------------------------
echo "label|sim_days_per_min|wall_secs|mpirun_exit|last_sim_day|first_sim_day|extra_env_vars" > "$RESULTS_FILE"

# ---------------------------------------------------------------------------
# Core benchmark function
# MVAPICH2 pattern: extra tuning is passed as env vars prefixed to mpirun.
#   run_schism_bench LABEL "MV2_VAR1=val MV2_VAR2=val ..."
# These are applied via 'env' so they don't pollute the shell for the next run.
# ---------------------------------------------------------------------------
run_schism_bench() {
    local label="$1"
    local extra_env="$2"
    # Disable errexit for the entire variant run so a crash or setup failure
    # does not abort the outer benchmark loop — all variants always run.
    set +e

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "BENCH [$label]"
    echo "  extra env  : ${extra_env:-(none)}"

    # Restore param.nml and optionally patch rnday
    cp "$PARAM_BACKUP" param.nml
    patch_rnday

    # Restore outputs to the pre-benchmark snapshot
    restore_outputs

    # MVAPICH2 mpirun: uses -np and -f (short forms), env vars passed via env(1).
    # --bind-to core is supported in MVAPICH2 2.3.x.
    local mpirun_cmd
    if [ -n "$extra_env" ]; then
        mpirun_cmd="env ${extra_env} mpirun --bind-to core -np ${NUM_CORES} -f ${HOSTFILE} ${SCHISM_EXE} ${NUM_SCRIBES}"
    else
        mpirun_cmd="mpirun --bind-to core -np ${NUM_CORES} -f ${HOSTFILE} ${SCHISM_EXE} ${NUM_SCRIBES}"
    fi
    echo "  cmd        : $mpirun_cmd"
    echo ""

    run_sim_and_measure_speed "$mpirun_cmd"

    printf "  RESULT: speed=%s d/min  wall=%ds  exit=%d  sim_days=%s\n" \
        "$BENCH_SIM_SPEED" "$BENCH_WALL_SECS" "$BENCH_EXIT_CODE" "$BENCH_LAST_SIM_DAY"

    # Append to results CSV
    echo "${label}|${BENCH_SIM_SPEED}|${BENCH_WALL_SECS}|${BENCH_EXIT_CODE}|${BENCH_LAST_SIM_DAY}|${BENCH_FIRST_SIM_DAY}|${extra_env}" >> "$RESULTS_FILE"

    # Re-enable errexit so the preamble / summary code retains error protection
    set -e
}

# ============================================================================
# MVAPICH2 2.3.7 variant matrix
# All variants share the fixed base:
#   mpirun --bind-to core -np <N> -f <hostfile>
#
# Hardware context:
#   HBv3: Standard_HB120rs_v3, 2 × AMD EPYC Milan-X (Zen3), 120 cores,
#         8 NUMA domains × 15 cores, 448 GiB, HDR200 InfiniBand (ConnectX-6)
#   HBv2: Standard_HB120rs_v2, 2 × AMD EPYC Rome (Zen2),    120 cores,
#         8 NUMA domains × 15 cores, 456 GiB, HDR   InfiniBand (ConnectX-6)
#
# Key MVAPICH2 2.3.7 env var dimensions:
#
#  1. NUMA placement (MV2_CPU_BINDING_POLICY):
#       bunch   — fill all 15 cores of one NUMA domain before moving to next
#                 (equivalent to "--map-by ppr:15:numa" in OpenMPI)
#       scatter — distribute ranks across all NUMA domains round-robin
#                 better for memory-bandwidth-bound codes
#
#  2. SHARP (MV2_ENABLE_SHARP=1):
#       In-network collective acceleration (SwitchIB/Quantum InfiniBand switch)
#       Falls back silently if not enabled in the cluster's SHARP daemon.
#       Usually beneficial for Allreduce-heavy workloads on HDR.
#
#  3. Memory registration cache (MV2_NDREG_ENTRIES_MAX / MV2_NDREG_ENTRIES):
#       Controls how many pinned-memory registrations MVAPICH2 caches.
#       Larger values reduce pin/unpin overhead for large-buffer MPI calls.
#       Recommended values from Azure MVAPICH2 sample configs: 65536/34688.
#
#  4. Homogeneous cluster (MV2_HOMOGENEOUS_CLUSTER=1):
#       Tells MVAPICH2 all nodes are identical → skips heterogeneity detection
#       and enables faster collective algorithm selection. Always safe on Azure
#       Batch (nodes come from the same VM image).
#
#  5. Explicit HCA pin (MV2_IBA_HCA):
#       Force a specific InfiniBand adapter, avoiding wasted probing.
# ============================================================================

# 1. Baseline — default MVAPICH2, no extra env vars
run_schism_bench "baseline" ""

# 2. Homogeneous cluster only — cheapest optimization, always safe
run_schism_bench "homogeneous" \
    "MV2_HOMOGENEOUS_CLUSTER=1"

# 3. NUMA bunch placement — fill 15 cores per NUMA domain before moving on
#    Binds at core level to avoid conflict with mpirun --bind-to core;
#    MV2_CPU_BINDING_POLICY=bunch fills cores sequentially within each NUMA domain.
#    NOTE: MV2_CPU_BINDING_LEVEL=numanode conflicts with --bind-to core and causes hangs.
run_schism_bench "numa_bunch" \
    "MV2_ENABLE_AFFINITY=1 MV2_CPU_BINDING_POLICY=bunch MV2_CPU_BINDING_LEVEL=core"

# 4. NUMA scatter placement — spread ranks evenly across all 8 NUMA domains
#    Better for memory-bandwidth-bound kernels; worse for cache-reuse patterns
run_schism_bench "numa_scatter" \
    "MV2_ENABLE_AFFINITY=1 MV2_CPU_BINDING_POLICY=scatter"

# 5. NDREG memory registration cache tuning (values from production application_command_template.sh)
#    Reduces contention on pinned-memory pool for large MPI_Allreduce buffers.
#    Use 131072/32768 — the 65536/34688 values were found to crash with exit=255 on HBv3.
run_schism_bench "ndreg_cache" \
    "MV2_NDREG_ENTRIES_MAX=131072 MV2_NDREG_ENTRIES=32768"

# 6. SHARP collectives + homogeneous cluster
#    SHARP accelerates MPI_Allreduce in the switch fabric (lossless HDR required)
#    Falls back silently if SHARP daemon is not running
run_schism_bench "sharp_homogeneous" \
    "MV2_ENABLE_SHARP=1 MV2_HOMOGENEOUS_CLUSTER=1"

# 7. NUMA bunch + homogeneous + NDREG — full placement + cache tuning
run_schism_bench "numa_bunch_ndreg" \
    "MV2_ENABLE_AFFINITY=1 MV2_CPU_BINDING_POLICY=bunch MV2_CPU_BINDING_LEVEL=core MV2_HOMOGENEOUS_CLUSTER=1 MV2_NDREG_ENTRIES_MAX=131072 MV2_NDREG_ENTRIES=32768"

# 8. Full combo — NUMA bunch + SHARP + homogeneous + NDREG + explicit HCA
#    Expected to be the best for HDR HBv3 with SHARP available
run_schism_bench "full_combo" \
    "MV2_ENABLE_AFFINITY=1 MV2_CPU_BINDING_POLICY=bunch MV2_CPU_BINDING_LEVEL=core MV2_ENABLE_SHARP=1 MV2_HOMOGENEOUS_CLUSTER=1 MV2_NDREG_ENTRIES_MAX=131072 MV2_NDREG_ENTRIES=32768 MV2_IBA_HCA=${IBA_HCA}"

# ============================================================================
# Summary and restore
# ============================================================================
print_timing_summary 28
bench_restore_final
echo "Done. Highest sim_days/min with exit=0 is your best config."
echo "To apply the winner, set the winning env vars before mpirun in your batch YAML's mpi_command."
