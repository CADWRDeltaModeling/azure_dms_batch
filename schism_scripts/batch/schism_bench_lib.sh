#!/bin/bash
# schism_bench_lib.sh — shared helper functions for SCHISM MPI timing benchmarks
#
# Source this file from the benchmark scripts; do NOT execute it directly.
#   source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/schism_bench_lib.sh"
#
# Required variables (must be set by the caller before sourcing):
#   STUDY_DIR      — absolute path to SCHISM study directory
#   BENCH_RNDAY    — absolute rnday value to patch into param.nml, or "" to leave unchanged
#   RESULTS_FILE   — path to the pipe-delimited results CSV
#
# Variables set by bench_init_backups() (available after calling it):
#   PARAM_BACKUP   — path to param.nml backup
#   OUTPUTS_BACKUP — path to outputs/ snapshot directory

# Guard against double-sourcing
[[ -n "${_SCHISM_BENCH_LIB_LOADED:-}" ]] && return 0
readonly _SCHISM_BENCH_LIB_LOADED=1

# ---------------------------------------------------------------------------
# patch_rnday — patch rnday in param.nml if BENCH_RNDAY is non-empty.
#
# NOTE: rnday is absolute (days from t=0 in SCHISM calendar), not a duration.
# For hotstart runs the value already in param.nml is usually correct — pass
# BENCH_RNDAY="" to leave it unchanged.
# ---------------------------------------------------------------------------
patch_rnday() {
    if [ -n "${BENCH_RNDAY:-}" ]; then
        sed -i "s/^\([[:space:]]*rnday[[:space:]]*=\)[[:space:]]*[0-9.]*/\1 ${BENCH_RNDAY}/" param.nml
        local actual
        actual=$(grep -i "rnday" param.nml | head -1 || echo "(not found)")
        echo "  param.nml -> $actual"
    else
        local actual
        actual=$(grep -i "rnday" param.nml | head -1 || echo "(not found)")
        echo "  param.nml (unchanged) -> $actual"
    fi
}

# ---------------------------------------------------------------------------
# setup_sflux — set up sflux symbolic links in the sflux/ subdirectory.
# Call once before the timing loop if sflux links need to be recreated.
# (Commented out by default in the benchmark scripts — uncomment if needed.)
# ---------------------------------------------------------------------------
setup_sflux() {
    if [ -d sflux ]; then
        echo "Setting up sflux links..."
        pushd sflux > /dev/null
        rm -f ./*.nc
        if [ -f make_links_full.py ]; then
            python3 make_links_full.py
        elif [ -f make_links.py ]; then
            python make_links.py
        else
            echo "  WARNING: no make_links*.py found in sflux/, skipping"
        fi
        popd > /dev/null
        echo "  sflux links done"
    else
        echo "  WARNING: no sflux/ directory — assuming forcing files are handled elsewhere"
    fi
}

# ---------------------------------------------------------------------------
# restore_outputs — restore outputs/ from the bench backup snapshot.
# Called before each benchmark variant to guarantee a clean, identical start.
# Pre-existing files in the backup (hotstart inputs, etc.) are preserved.
# ---------------------------------------------------------------------------
restore_outputs() {
    find outputs -mindepth 1 -depth -delete 2>/dev/null || true
    rm -rf outputs 2>/dev/null || true
    mkdir -p outputs
    if [ -d "${OUTPUTS_BACKUP}" ]; then
        cp -a "${OUTPUTS_BACKUP}"/* outputs/ 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# read_sim_days — print last simulation day from outputs/flux.out (column 1).
# Prints "NO_OUTPUT" if the file is missing or empty.
# ---------------------------------------------------------------------------
read_sim_days() {
    if [ -f outputs/flux.out ] && [ -s outputs/flux.out ]; then
        tail -1 outputs/flux.out | awk '{printf "%.4f", $1}'
    else
        echo "NO_OUTPUT"
    fi
}

# ---------------------------------------------------------------------------
# run_sim_and_measure_speed — launch an mpirun command in the background,
# poll outputs/flux.out every BENCH_POLL_INTERVAL seconds (default: 30),
# and measure simulation throughput as sim_days_per_minute.
#
# The clock starts from the FIRST detected change in flux.out, filtering out
# initialization time (mesh load, domain decomposition, I/O setup, etc.).
#
# Usage:
#   run_sim_and_measure_speed "full mpirun command string"
#
# Globals set on return (readable by the calling function):
#   BENCH_EXIT_CODE     — mpirun exit status
#   BENCH_WALL_SECS     — total elapsed seconds from launch to exit
#   BENCH_SIM_SPEED     — simulated days per minute after first flux.out change,
#                         or "N/A" if flux.out never changed
#   BENCH_LAST_SIM_DAY  — last simulation day in flux.out on job exit
#   BENCH_FIRST_SIM_DAY — simulation day when first flux.out change detected
#
# Optional env override:
#   BENCH_POLL_INTERVAL — sampling interval in seconds (default: 30)
# ---------------------------------------------------------------------------
run_sim_and_measure_speed() {
    local cmd="$1"
    local poll_interval="${BENCH_POLL_INTERVAL:-30}"

    # Reset output globals
    BENCH_EXIT_CODE="-1"
    BENCH_WALL_SECS="0"
    BENCH_SIM_SPEED="N/A"
    BENCH_LAST_SIM_DAY="NO_OUTPUT"
    BENCH_FIRST_SIM_DAY="NO_OUTPUT"

    # flux.out from the backup may contain a stale sim_day (e.g. == rnday from a
    # previous completed run, or a higher restart day than the new run starts at).
    # Two-phase baseline detection avoids locking in that stale value:
    #   Phase 1 — candidate: record the first reading seen after launch.
    #   Phase 2 — wait for the reading to differ from the candidate; that
    #             confirmed change locks in prev_sim_day and starts the clock.
    # This tolerates any stale backup content regardless of direction of change.
    local candidate_baseline="" prev_sim_day="" first_change_ts="" first_sim_day=""
    local max_secs="" timed_out=0 stuck=0
    # After the first change is registered, kill the run if sim_day fails to
    # advance for this many consecutive polls.  Override with BENCH_STUCK_POLLS.
    local stuck_limit="${BENCH_STUCK_POLLS:-3}"
    local stuck_count=0
    if [ -n "${BENCH_TIMEOUT_MINS:-}" ]; then
        max_secs=$(( BENCH_TIMEOUT_MINS * 60 ))
    fi
    echo "  [flux.out] Polling every ${poll_interval}s (2-phase baseline: wait for first change)${max_secs:+, timeout=${BENCH_TIMEOUT_MINS}min}, stuck-kill after ${stuck_limit} no-progress polls"

    local start_ts
    start_ts=$(date +%s)

    # Launch mpirun in background; stdout/stderr inherited (log appears normally)
    eval "$cmd" &
    local mpirun_pid=$!

    # Sampling loop: read flux.out every poll_interval seconds until job exits
    local cur_sim_day=""
    while kill -0 "$mpirun_pid" 2>/dev/null; do
        sleep "$poll_interval"
        # Enforce per-variant timeout if BENCH_TIMEOUT_MINS is set
        if [ -n "$max_secs" ] && [ $(( $(date +%s) - start_ts )) -ge "$max_secs" ]; then
            echo "  [flux.out] TIMEOUT: ${BENCH_TIMEOUT_MINS}min elapsed — killing mpirun (pid $mpirun_pid)"
            kill "$mpirun_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$mpirun_pid" 2>/dev/null || true
            timed_out=1
            break
        fi
        cur_sim_day=$(read_sim_days)
        if [ "$cur_sim_day" = "NO_OUTPUT" ]; then
            : # flux.out not yet created; keep waiting
        elif [ -z "$candidate_baseline" ]; then
            # Phase 1: first reading after launch — may be stale backup content.
            candidate_baseline="$cur_sim_day"
            echo "  [flux.out] Candidate  at $(date '+%H:%M:%S'): sim_day=${candidate_baseline} (watching for change)"
        elif [ -z "$prev_sim_day" ]; then
            # Phase 1: waiting for value to differ from the initial candidate.
            if [ "$cur_sim_day" != "$candidate_baseline" ]; then
                # Confirmed live activity — lock in baseline and start speed clock.
                prev_sim_day="$cur_sim_day"
                first_change_ts=$(date +%s)
                first_sim_day="$cur_sim_day"
                echo "  [flux.out] Baseline confirmed at $(date '+%H:%M:%S'): sim_day=${first_sim_day} (changed from ${candidate_baseline})"
            else
                echo "  [flux.out] Waiting   at $(date '+%H:%M:%S'): sim_day=${cur_sim_day} (unchanged from candidate)"
            fi
        elif awk -v cur="$cur_sim_day" -v prev="$prev_sim_day" 'BEGIN{exit !(cur+0 > prev+0)}'; then
            # Phase 2: sim_day has increased — reset stuck counter and record progress.
            stuck_count=0
            echo "  [flux.out] Progress  at $(date '+%H:%M:%S'): sim_day=${cur_sim_day}"
            prev_sim_day="$cur_sim_day"
        else
            # Phase 2: no increase since last poll — count as stuck.
            stuck_count=$(( stuck_count + 1 ))
            echo "  [flux.out] No progress at $(date '+%H:%M:%S'): sim_day=${cur_sim_day} (stuck poll ${stuck_count}/${stuck_limit})"
            if [ "$stuck_count" -ge "$stuck_limit" ]; then
                echo "  [flux.out] STUCK: no progress for ${stuck_limit} consecutive polls — killing mpirun (pid $mpirun_pid)"
                kill "$mpirun_pid" 2>/dev/null || true
                sleep 2
                kill -9 "$mpirun_pid" 2>/dev/null || true
                stuck=1
                break
            fi
        fi
    done

    # Collect exit status and compute speed
    wait "$mpirun_pid"
    BENCH_EXIT_CODE=$?
    if [ "$timed_out" -eq 1 ]; then
        BENCH_EXIT_CODE=124  # match 'timeout' command convention
    elif [ "$stuck" -eq 1 ]; then
        BENCH_EXIT_CODE=125  # custom: killed because sim_day stopped advancing
    fi
    local end_ts
    end_ts=$(date +%s)
    BENCH_WALL_SECS=$(( end_ts - start_ts ))
    BENCH_LAST_SIM_DAY=$(read_sim_days)
    BENCH_FIRST_SIM_DAY="${first_sim_day:-NO_OUTPUT}"

    # sim_days_per_minute: delta sim_days / elapsed_minutes since first change
    if [ -n "$first_change_ts" ] && [ "$BENCH_LAST_SIM_DAY" != "NO_OUTPUT" ]; then
        local elapsed_since_first
        elapsed_since_first=$(( end_ts - first_change_ts ))
        BENCH_SIM_SPEED=$(awk \
            -v last="$BENCH_LAST_SIM_DAY" \
            -v first="$first_sim_day" \
            -v elapsed="$elapsed_since_first" \
            'BEGIN{
                delta = last + 0 - (first + 0)
                if (elapsed > 0 && delta > 0)
                    printf "%.4f", delta / (elapsed / 60.0)
                else
                    print "N/A"
            }')
    fi
    echo "  [flux.out] Speed: ${BENCH_SIM_SPEED} d/min  (sim_day ${BENCH_FIRST_SIM_DAY} -> ${BENCH_LAST_SIM_DAY}  over ${BENCH_WALL_SECS}s wall)"
}

# ---------------------------------------------------------------------------
# bench_init_backups — create one-time backups of param.nml and outputs/.
# Sets PARAM_BACKUP and OUTPUTS_BACKUP in the caller's environment.
# Safe to call repeatedly — backups are only created the first time.
# ---------------------------------------------------------------------------
bench_init_backups() {
    PARAM_BACKUP="${STUDY_DIR}/param.nml.bench_backup"
    if [ ! -f "$PARAM_BACKUP" ]; then
        cp param.nml "$PARAM_BACKUP"
        echo "Backed up param.nml -> $(basename "$PARAM_BACKUP")"
    fi

    OUTPUTS_BACKUP="${STUDY_DIR}/outputs.bench_backup"
    if [ ! -d "$OUTPUTS_BACKUP" ]; then
        if [ -d outputs ]; then
            cp -a outputs/ "$OUTPUTS_BACKUP"
            echo "Backed up outputs/ -> $(basename "$OUTPUTS_BACKUP") ($(du -sh "$OUTPUTS_BACKUP" | cut -f1))"
        else
            mkdir -p "$OUTPUTS_BACKUP"
            echo "No existing outputs/ directory; created empty backup"
        fi
    fi
}

# ---------------------------------------------------------------------------
# bench_restore_final — restore param.nml and outputs/ to their pre-benchmark
# state at the end of the run. Leaves the backup directories in place so the
# benchmark can be safely re-run without collecting backups again.
# ---------------------------------------------------------------------------
bench_restore_final() {
    echo ""
    echo "Restoring original param.nml"
    cp "$PARAM_BACKUP" param.nml
    echo "Restoring original outputs/"
    find outputs -mindepth 1 -depth -delete 2>/dev/null || true
    rm -rf outputs 2>/dev/null || true
    mkdir -p outputs
    cp -a "$OUTPUTS_BACKUP"/. outputs/ 2>/dev/null || true
    echo "Backup dirs left in place for re-runs: $(basename "$PARAM_BACKUP"), $(basename "$OUTPUTS_BACKUP")"
    echo "  Remove when finished: rm -rf $PARAM_BACKUP $OUTPUTS_BACKUP"
}

# ---------------------------------------------------------------------------
# print_timing_summary — print a sorted throughput table from RESULTS_FILE.
# Sorted by sim_days_per_min descending (highest = fastest simulation).
# Usage: print_timing_summary [label_width]
#   label_width : column width for the LABEL column (default: 32)
# ---------------------------------------------------------------------------
print_timing_summary() {
    local label_width="${1:-32}"
    local sep
    sep=$(printf '%*s' "$label_width" '' | tr ' ' '-')

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "TIMING SUMMARY  (full CSV: $RESULTS_FILE)"
    echo "════════════════════════════════════════════════════════════════"
    printf "%-${label_width}s  %15s  %9s  %6s  %12s\n" \
        "LABEL" "SPEED(d/min)" "WALL(s)" "EXIT" "SIM_DAYS"
    printf "%-${label_width}s  %15s  %9s  %6s  %12s\n" \
        "$sep" "---------------" "---------" "------" "------------"
    # Sort by sim_days_per_min (field 2) descending: highest speed first.
    # "N/A" entries are treated as 0 by -rn and appear last (correct for failed runs).
    tail -n +2 "$RESULTS_FILE" | sort -t'|' -k2 -rn | \
    while IFS='|' read -r label speed secs code last_day first_day rest; do
        local flag=""
        [ "$code" != "0" ] && flag=" [FAILED]"
        printf "%-${label_width}s  %15s  %8ss  %6s  %12s%s\n" \
            "$label" "$speed" "$secs" "$code" "$last_day" "$flag"
    done
}
