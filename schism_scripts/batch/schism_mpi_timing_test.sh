#!/bin/bash
# schism_mpi_timing_test.sh — HPC-X/OpenMPI tuning timing benchmark for SCHISM on HBv4
#
# Usage: schism_mpi_timing_test.sh [study_dir] [rnday] [num_cores] [num_scribes] [max_mins]
#
#   study_dir   : path to SCHISM study directory (default: .)
#   rnday       : absolute simulation end-day for param.nml (default: 10; leave blank
#                 to keep existing value — useful for hotstart benchmarks)
#   num_cores   : total MPI ranks (default: nproc * #hosts-in-hostfile)
#   num_scribes : SCHISM scribe count (default: 10)
#   max_mins    : kill any variant that runs longer than this many minutes (default: no limit)
#
# Runs SCHISM under multiple HPC-X/OpenMPI option sets and reports simulation
# throughput as sim_days_per_minute (measured from first flux.out change, excluding init time).
# Simulation progress is monitored via outputs/flux.out, sampled every BENCH_POLL_INTERVAL s (default: 30).
# Designed for HPC-X/OpenMPI on Azure HBv4 (Standard_HB176rs_v4, 4 NUMA x 44 cores).
#
# Shared helpers (patch_rnday, restore_outputs, etc.) live in schism_bench_lib.sh.
#
# WARNING: This script clears outputs/ between each run. Do NOT run this against
#          a study directory with outputs you wish to keep.
#
# SCHISM_EXE env var overrides the default executable name.

set -uo pipefail

STUDY_DIR="${1:-.}"
STUDY_DIR="$(realpath "$STUDY_DIR")"
BENCH_RNDAY="${2:-10}"
NUM_SCRIBES="${4:-10}"
export BENCH_TIMEOUT_MINS="${5:-}"   # empty = no timeout; N = kill variant after N minutes
SCHISM_EXE="${SCHISM_EXE:-pschism_PREC_EVAP_GOTM_TVD-VL}"
RESULTS_FILE="${STUDY_DIR}/mpi_timing_results.txt"

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

echo "=== SCHISM MPI Timing Benchmark ==="
echo "Study dir   : $STUDY_DIR"
echo "Hosts       : $NUM_HOSTS  ($(cat "$HOSTFILE" | tr '\n' ',' | sed 's/,$//') )"
echo "Cores/node  : $CORES_PER_NODE"
echo "Total cores : $NUM_CORES"
echo "Scribes     : $NUM_SCRIBES"
echo "rnday       : $BENCH_RNDAY"
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
# Shared helpers (patch_rnday, setup_sflux, restore_outputs, read_sim_days,
# bench_init_backups, bench_restore_final, print_timing_summary)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")" 
source "${SCRIPT_DIR}/schism_bench_lib.sh"

# ---------------------------------------------------------------------------
# Backups (param.nml and outputs/) — created once, re-used for each variant
# ---------------------------------------------------------------------------
bench_init_backups

# ---------------------------------------------------------------------------
# Results file header
# ---------------------------------------------------------------------------
echo "label|sim_days_per_min|wall_secs|mpirun_exit|last_sim_day|first_sim_day|mpi_extra_opts" > "$RESULTS_FILE"

# ---------------------------------------------------------------------------
# Core benchmark function
# ---------------------------------------------------------------------------
run_schism_bench() {
    local label="$1"
    local extra_opts="$2"
    # Disable errexit for the entire variant run so a crash or setup failure
    # does not abort the outer benchmark loop — all variants always run.
    set +e

    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo "BENCH [$label]"
    echo "  extra opts : ${extra_opts:-(none)}"

    # Restore param.nml and set rnday
    cp "$PARAM_BACKUP" param.nml
    patch_rnday

    # Restore outputs to the pre-benchmark snapshot
    restore_outputs

    # Build full command (eval used so extra_opts with spaces expands correctly)
    local mpirun_cmd
    mpirun_cmd="mpirun --bind-to core --np ${NUM_CORES} --hostfile ${HOSTFILE} -x PATH -x LD_LIBRARY_PATH ${extra_opts} ${SCHISM_EXE} ${NUM_SCRIBES}"
    echo "  cmd        : $mpirun_cmd"
    echo ""

    run_sim_and_measure_speed "$mpirun_cmd"

    printf "  RESULT: speed=%s d/min  wall=%ds  exit=%d  sim_days=%s\n" \
        "$BENCH_SIM_SPEED" "$BENCH_WALL_SECS" "$BENCH_EXIT_CODE" "$BENCH_LAST_SIM_DAY"

    # Append to results CSV
    echo "${label}|${BENCH_SIM_SPEED}|${BENCH_WALL_SECS}|${BENCH_EXIT_CODE}|${BENCH_LAST_SIM_DAY}|${BENCH_FIRST_SIM_DAY}|${extra_opts}" >> "$RESULTS_FILE"

    # Re-enable errexit so the preamble / summary code retains error protection
    set -e
}

# ---------------------------------------------------------------------------
# One-time sflux setup
# ---------------------------------------------------------------------------
# setup_sflux

# ---------------------------------------------------------------------------
# UCX IB device auto-detection
# Needed for HCOLL_MAIN_IB and UCX_NET_DEVICES in Round 2 variants.
# Prefer dc_mlx5 device (NDR400); fall back to first listed IB device.
# ---------------------------------------------------------------------------
UCX_IB_DEV=""
if command -v ucx_info &>/dev/null; then
    # Extract device for dc_mlx5 transport first (ideal for NDR400 / ConnectX-7)
    # Use $NF (last field) — handles both "Device: mlx5_ib0:1" and "# Device: mlx5_ib0:1" formats
    UCX_IB_DEV=$(ucx_info -d 2>/dev/null \
        | awk '/Transport: dc_mlx5/{found=1} found && /Device:/{print $NF; found=0; exit}')
    if [ -z "$UCX_IB_DEV" ]; then
        # Fall back to first mlx5 device of any transport
        UCX_IB_DEV=$(ucx_info -d 2>/dev/null \
            | awk '/Transport: .*mlx5/{found=1} found && /Device:/{print $NF; found=0; exit}')
    fi
fi
if [ -z "$UCX_IB_DEV" ]; then
    # Last resort: ask ibstat
    UCX_IB_DEV=$(ibstat 2>/dev/null | awk '/CA /{dev=$2} /Port 1/{print dev":1"; exit}' | tr -d "'")
fi
if [ -z "$UCX_IB_DEV" ]; then
    UCX_IB_DEV="mlx5_ib0:1"
    echo "WARNING: Could not auto-detect UCX IB device; defaulting to $UCX_IB_DEV"
fi
echo "UCX IB device : $UCX_IB_DEV"

# ============================================================================
# MPI variant matrix
# All variants share the fixed base:
#   mpirun --bind-to core --np <N> --hostfile <F> -x PATH -x LD_LIBRARY_PATH
# Tuned for HBv4: 4 NUMA domains x 44 cores each, NDR400 InfiniBand (ConnectX-7)
#
# ROUND 1 results (2026-03-22):
#   WINNER: map_ppr44_numa (4109s), numa_hcoll (4121s) — effectively equal
#   FAILED: all UCX_TLS=rc_x,sm variants (SIGABRT/MPI abort, exit 134/16/205)
#   Hypothesis: mlx5_ib0:1 is the WRONG device name on these HBv4 nodes.
#   UCX without HCOLL + rc_x ran but was SLOWEST successful (4557s).
#   HCOLL alone without NUMA placement hurt vs baseline (4358 vs 4258s).
#
# ROUND 2 — findings from UCX device discovery (2026-03-23):
#   - mlx5_ib0:1 IS the correct device name (not the bug).
#   - rc_x (rc_mlx5) caused SIGABRT because at 352 ranks x 2 nodes RC requires
#     ~61K QP pairs, exhausting ConnectX-7 resources.
#   - dc_mlx5 (UCX TLS: dc_x) IS present and IS the correct transport for NDR400.
#     DC = Dynamic Connected: one QP per HCA port regardless of rank count —
#     specifically designed for large-scale NDR InfiniBand.
#   - ud_mlx5 (UCX TLS: ud_x) is connectionless, good fallback.
#   HCOLL crash root cause (2026-03-23):
#   - numa_hcoll without UCX_TLS crashes: HCOLL's internal UCX also defaults to
#     rc_mlx5 → same QP exhaustion → "Destination is unreachable" → SIGBUS.
#   - Fix: always pair HCOLL with UCX_NET_DEVICES (at minimum) so UCX auto-selects
#     dc_mlx5, or set UCX_TLS=dc_x,sm explicitly (numa_hcoll_dcx).
# ============================================================================

# 1. Confirmed round-1 winner — NUMA topology placement, no UCX override
run_schism_bench "map_ppr44_numa" "--map-by ppr:44:numa"

# 2. NUMA + HCOLL + UCX auto-select — HCOLL with correct IB device, UCX picks dc_mlx5
#    (numa_hcoll without UCX_NET_DEVICES crashes: HCOLL's UCX defaults to rc_mlx5 → QP exhaustion)
run_schism_bench "numa_hcoll_ucx_auto" \
    "--map-by ppr:44:numa -mca coll_hcoll_enable 1 -x HCOLL_MAIN_IB=${UCX_IB_DEV} -x UCX_NET_DEVICES=${UCX_IB_DEV}"

# 3. NUMA + DC transport (UCX dc_x) — the CORRECT transport for NDR400 / ConnectX-7
#    dc_mlx5 uses one QP per HCA port, scales to any number of ranks
run_schism_bench "numa_dcx_sm" \
    "--map-by ppr:44:numa -x UCX_TLS=dc_x,sm -x UCX_NET_DEVICES=${UCX_IB_DEV}"

# 4. NUMA + HCOLL + DC transport — should be the optimal full combo for NDR HBv4
run_schism_bench "numa_hcoll_dcx" \
    "--map-by ppr:44:numa -mca coll_hcoll_enable 1 -x HCOLL_MAIN_IB=${UCX_IB_DEV} -x UCX_TLS=dc_x,sm -x UCX_NET_DEVICES=${UCX_IB_DEV}"

# 5. NUMA + UD transport (ud_mlx5 hardware path, connectionless)
#    Lower latency per message than DC for small messages, no QP scaling issues
run_schism_bench "numa_udx_sm" \
    "--map-by ppr:44:numa -x UCX_TLS=ud_x,sm -x UCX_NET_DEVICES=${UCX_IB_DEV}"

# 6. NUMA + HCOLL + UD
run_schism_bench "numa_hcoll_udx" \
    "--map-by ppr:44:numa -mca coll_hcoll_enable 1 -x HCOLL_MAIN_IB=${UCX_IB_DEV} -x UCX_TLS=ud_x,sm -x UCX_NET_DEVICES=${UCX_IB_DEV}"

# 7. NUMA + UCX auto (no TLS override) — let UCX pick dc_mlx5 automatically
#    UCX on NDR400 should prefer dc_mlx5 when left to auto-select
run_schism_bench "numa_ucx_auto" \
    "--map-by ppr:44:numa -x UCX_NET_DEVICES=${UCX_IB_DEV}"

# 8. Baseline — sanity reference
run_schism_bench "baseline" ""
# ============================================================================
# Summary and restore
# ============================================================================
print_timing_summary 32
bench_restore_final
echo "Done. The highest sim_days/min with exit=0 is your best config."
echo "  Uncomment the winning opts in mpi_tuning_opts in your launch YAML."
