#!/bin/bash
################################################################################
# watch_and_restart.sh
#
# Monitors a running SCHISM simulation and automatically restarts it if stuck.
#
# "Stuck" is defined as: pschism* processes are running, total CPU usage is
# below --cpu-threshold %, AND the simulation TIME (from mirror.out) has not
# advanced across --stuck-polls consecutive polls (each --poll-interval seconds).
#
# On detecting stuck:
#   1. Kill mpirun (and any remaining pschism processes).
#   2. Find the latest combined hotstart_it=*.nc already in the study dir or
#      outputs/ and link it as hotstart.nc.  If none is found, fall back to
#      combine_hotstart_from_mirror.sh.
#   3. Set ihot = 2 in param.nml.
#   4. Relaunch SCHISM via --run-script (bash, inheriting current environment).
#
# Exit conditions:
#   0  – pschism processes gone (clean exit or crash handled elsewhere).
#   2  – max restarts exhausted.
#   3  – hotstart / param.nml preparation failed.
#
# Usage:
#   watch_and_restart.sh --study-dir DIR --run-script FILE [OPTIONS]
#
# Required:
#   --study-dir  DIR   Absolute path to the SCHISM study directory.
#   --run-script FILE  Script that contains the mpirun launch command.
#
# Optional:
#   --poll-interval N   Seconds between polls              (default: 300)
#   --stuck-polls   N   Consecutive no-progress polls to
#                       declare stuck                      (default: 2)
#   --cpu-threshold N   CPU % below which run is idle      (default: 10)
#   --max-restarts  N   Max restart attempts before abort  (default: 5)
#   --log-file      F   Log file path
#                       (default: <study-dir>/watchdog.log)
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse shared rndays parser (defines get_rndays_from_param_nml)
# shellcheck source=get_rndays_from_param_nml.sh
source "${SCRIPT_DIR}/get_rndays_from_param_nml.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
STUDY_DIR=""
RUN_SCRIPT=""
POLL_INTERVAL=300
STUCK_POLLS=2
CPU_THRESHOLD=10
MAX_RESTARTS=5
LOG_FILE=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --study-dir)     STUDY_DIR="$(realpath "$2")";  shift 2 ;;
        --run-script)    RUN_SCRIPT="$(realpath "$2")"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2";            shift 2 ;;
        --stuck-polls)   STUCK_POLLS="$2";              shift 2 ;;
        --cpu-threshold) CPU_THRESHOLD="$2";            shift 2 ;;
        --max-restarts)  MAX_RESTARTS="$2";             shift 2 ;;
        --log-file)      LOG_FILE="$2";                 shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$STUDY_DIR" || -z "$RUN_SCRIPT" ]]; then
    echo "ERROR: --study-dir and --run-script are required." >&2
    exit 1
fi
if [[ ! -d "$STUDY_DIR" ]]; then
    echo "ERROR: study dir does not exist: $STUDY_DIR" >&2; exit 1
fi
if [[ ! -f "$RUN_SCRIPT" ]]; then
    echo "ERROR: run script not found: $RUN_SCRIPT" >&2; exit 1
fi

LOG_FILE="${LOG_FILE:-${STUDY_DIR}/watchdog.log}"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# ── get_sim_time ──────────────────────────────────────────────────────────────
# Reads the last TIME= value from mirror.out (same parse as telegraf inputs.exec).
# Prints the float seconds value, or "NO_OUTPUT" if unavailable.
get_sim_time() {
    local mirror_out="${STUDY_DIR}/outputs/mirror.out"
    [[ -f "$mirror_out" ]] || { echo "NO_OUTPUT"; return; }

    local val
    val=$(tail -50 "$mirror_out" \
          | grep "TIME STEP" | tail -1 \
          | grep -oE 'TIME=[[:space:]]*[0-9]+\.?[0-9]*' \
          | grep -oE '[0-9]+\.?[0-9]*$')

    [[ -n "$val" ]] && echo "$val" || echo "NO_OUTPUT"
}

# ── get_cpu_usage ─────────────────────────────────────────────────────────────
# Returns total CPU usage as an integer percentage (0-100), sampled over 1 s.
get_cpu_usage() {
    local s1 s2
    s1=$(grep '^cpu ' /proc/stat)
    sleep 1
    s2=$(grep '^cpu ' /proc/stat)

    awk '
    NR==1 { for (i=2;i<=NF;i++) total1+=$i; idle1=$5 }
    NR==2 { for (i=2;i<=NF;i++) total2+=$i; idle2=$5 }
    END {
        dt = total2 - total1
        di = idle2  - idle1
        if (dt == 0) { print 0 }
        else { printf "%d\n", int(100 * (1 - di/dt) + 0.5) }
    }' <<< "$(printf '%s\n%s\n' "$s1" "$s2")"
}

# ── is_pschism_running ────────────────────────────────────────────────────────
# Returns 0 (true) if any pschism* process exists.
is_pschism_running() {
    pgrep -f 'pschism' > /dev/null 2>&1
}

# ── kill_mpirun ───────────────────────────────────────────────────────────────
kill_mpirun() {
    log "Sending SIGTERM to mpirun..."
    pkill -TERM -f 'mpirun' 2>/dev/null || true
    sleep 10
    if pgrep -f 'mpirun' > /dev/null 2>&1; then
        log "mpirun still alive — sending SIGKILL..."
        pkill -KILL -f 'mpirun' 2>/dev/null || true
        sleep 3
    fi
    if pgrep -f 'pschism' > /dev/null 2>&1; then
        log "Killing remaining pschism processes..."
        pkill -KILL -f 'pschism' 2>/dev/null || true
        sleep 3
    fi
    log "MPI processes killed."
}

# ── prepare_hotstart ──────────────────────────────────────────────────────────
# Finds the latest combined hotstart_it=*.nc already on disk (study dir root
# or outputs/).  Links it as hotstart.nc.  Falls back to combining via
# combine_hotstart_from_mirror.sh if no combined file is found.
prepare_hotstart() {
    pushd "$STUDY_DIR" > /dev/null

    # Prefer a file already in the study root; also check outputs/.
    local latest
    latest=$(ls -t hotstart_it=*.nc outputs/hotstart_it=*.nc 2>/dev/null | head -1)

    if [[ -n "$latest" ]]; then
        log "Found combined hotstart: $latest"
        ln -sf "$latest" hotstart.nc
        log "Linked hotstart.nc -> $latest"
    else
        log "No combined hotstart_it=*.nc found; falling back to combine_hotstart_from_mirror.sh..."
        if bash "$SCRIPT_DIR/combine_hotstart_from_mirror.sh" -1; then
            # combine_hotstart_from_mirror.sh creates the link itself
            log "Hotstart combined and linked."
        else
            log "ERROR: hotstart preparation failed." >&2
            popd > /dev/null
            return 1
        fi
    fi

    popd > /dev/null
}

# ── update_param_nml ──────────────────────────────────────────────────────────
update_param_nml() {
    local param="${STUDY_DIR}/param.nml"
    if [[ ! -f "$param" ]]; then
        log "ERROR: param.nml not found: $param" >&2
        return 1
    fi
    sed -i 's/ihot[[:space:]]*=[[:space:]]*1/ihot = 2/g' "$param"
    log "param.nml: set ihot = 2"
}

# ── relaunch ──────────────────────────────────────────────────────────────────
relaunch() {
    log "Relaunching SCHISM: bash $RUN_SCRIPT &"
    bash "$RUN_SCRIPT" &
    log "Relaunch started (pid $!). Resuming monitoring after next poll interval."
}

# ── Main monitoring loop ──────────────────────────────────────────────────────
log "=========================================="
log "Watchdog started."
log "  study_dir     = $STUDY_DIR"
log "  run_script    = $RUN_SCRIPT"
log "  poll_interval = ${POLL_INTERVAL}s"
log "  stuck_polls   = $STUCK_POLLS  (stuck after $((STUCK_POLLS * POLL_INTERVAL))s no-progress)"
log "  max_restarts  = $MAX_RESTARTS"
log "=========================================="

prev_sim_time=""
no_progress_count=0
no_output_count=0
restart_count=0

while true; do
    sleep "$POLL_INTERVAL"

    # ── Exit if SCHISM is no longer running ───────────────────────────────────
    if ! is_pschism_running; then
        log "No pschism processes found — SCHISM has exited. Watchdog exiting."
        exit 0
    fi

    # ── Sample simulation time ────────────────────────────────────────────────
    cur_sim_time=$(get_sim_time)
    log "Poll: sim_time=$cur_sim_time  prev=${prev_sim_time:-<unset>}  no_progress=$no_progress_count"

    if [[ "$cur_sim_time" == "NO_OUTPUT" ]]; then
        no_output_count=$(( no_output_count + 1 ))
        log "mirror.out not yet available (${no_output_count}/${MAX_RESTARTS}); skipping this poll."
        if [[ "$no_output_count" -ge "$MAX_RESTARTS" ]]; then
            log "ERROR: mirror.out produced no output for ${MAX_RESTARTS} consecutive polls. SCHISM may have failed to start. Giving up." >&2
            exit 2
        fi
        continue
    fi

    # Valid output received — reset the no-output counter
    no_output_count=0

    # Establish baseline on first valid reading
    if [[ -z "$prev_sim_time" ]]; then
        prev_sim_time="$cur_sim_time"
        log "Baseline sim_time set: $prev_sim_time"
        continue
    fi

    # ── Check for forward progress ────────────────────────────────────────────
    if awk -v cur="$cur_sim_time" -v prev="$prev_sim_time" \
           'BEGIN { exit !(cur + 0 > prev + 0) }'; then
        log "Progress: $prev_sim_time -> $cur_sim_time"
        prev_sim_time="$cur_sim_time"
        no_progress_count=0
        continue
    fi

    # No progress this poll — accumulate count; sample CPU for logging only
    no_progress_count=$(( no_progress_count + 1 ))
    cpu=$(get_cpu_usage)
    log "No progress (${no_progress_count}/${STUCK_POLLS}), CPU=${cpu}% (informational)"

    # ── Stuck decision: sim time alone is the criterion ───────────────────────
    if [[ "$no_progress_count" -ge "$STUCK_POLLS" ]]; then

        # Before restarting, check whether the simulation has simply reached rndays.
        # At end-of-run SCHISM may be writing final output (100% CPU, no sim_time
        # advance) which looks identical to a stuck run.  If sim_days >= rndays,
        # skip the restart and let mpirun exit naturally.
        rndays=$(get_rndays_from_param_nml "${STUDY_DIR}/param.nml")
        if [[ "$rndays" =~ ^[0-9]+$ ]]; then
            sim_days=$(awk -v t="$cur_sim_time" 'BEGIN{print int(t/86400)}')
            if [[ "$sim_days" -ge "$rndays" ]]; then
                log "Sim time (${sim_days}d) >= rndays (${rndays}d): end-of-run writes, not stuck. Skipping restart."
                continue
            fi
        fi

        log "STUCK: no progress for ${no_progress_count} polls (CPU=${cpu}% at time of detection)"

        if [[ "$restart_count" -ge "$MAX_RESTARTS" ]]; then
            log "ERROR: max restarts ($MAX_RESTARTS) exhausted. Giving up." >&2
            exit 2
        fi

        restart_count=$(( restart_count + 1 ))
        log "--- Restart $restart_count / $MAX_RESTARTS ---"

        kill_mpirun
        prepare_hotstart || exit 3
        update_param_nml || exit 3
        relaunch

        # Reset state for new run
        prev_sim_time=""
        no_progress_count=0
    fi
done
