#!/bin/bash
################################################################################
# schism_run_lib.sh
#
# Source this file to get run_with_watchdog.
#
# Usage in mpi_command:
#   source $SCHISM_SCRIPTS_HOME/batch/schism_run_lib.sh
#   run_with_watchdog "<mpirun command>" \
#       --study-dir "$SCHISM_STUDY_DIR" \
#       --poll-interval 300 \
#       --stuck-polls 2 \
#       --cpu-threshold 10 \
#       --max-restarts 5
#   exit $?
#
# The first positional argument is the full mpirun command string.
# All remaining arguments are passed through verbatim to watch_and_restart.sh.
# The function returns the final SCHISM exit code; use `exit $?` at call site.
################################################################################

# Guard against double-sourcing
[[ -n "${_SCHISM_RUN_LIB_LOADED:-}" ]] && return 0
readonly _SCHISM_RUN_LIB_LOADED=1

# ── run_with_watchdog ─────────────────────────────────────────────────────────
# Writes run_schism.sh from the given command, starts the watchdog in the
# background, runs the initial SCHISM launch, then waits for the appropriate
# exit condition.  Uses `return` (not `exit`) so it is safe to call from a
# sourced context.
run_with_watchdog() {
    local mpi_cmd="$1"
    shift  # remaining "$@" are forwarded to watch_and_restart.sh

    local run_script
    run_script="$(pwd)/run_schism.sh"
    printf '%s\n' "$mpi_cmd" > "$run_script"
    chmod +x "$run_script"
    echo "Wrote run script: $run_script"

    # Start watchdog in background; --run-script is injected here, everything
    # else (--study-dir, --poll-interval, etc.) comes from the caller via "$@".
    local watchdog_script="${SCHISM_SCRIPTS_HOME}/batch/watch_and_restart.sh"
    bash "$watchdog_script" --run-script "$run_script" "$@" &
    local watchdog_pid=$!
    echo "Watchdog started (pid $watchdog_pid)"

    # Initial SCHISM launch
    echo "Starting SCHISM Simulation-----------------------------------"
    bash "$run_script"
    local run_exit=$?

    # Determine final exit code.
    # Always wait for the watchdog regardless of run_exit: if run_schism.sh exits
    # with 0 while the watchdog is mid-restart (e.g. mpirun finished just as it was
    # being killed), killing the watchdog immediately would abort the restart.
    # The watchdog exits on its own once pschism is no longer running.
    local schism_exit
    if kill -0 "$watchdog_pid" 2>/dev/null; then
        echo "Watchdog still running (run_exit=$run_exit) — waiting for it to confirm completion or finish restart..."
        wait "$watchdog_pid"
        schism_exit=$?
    else
        echo "Watchdog already exited; using run_schism.sh exit code ($run_exit)."
        schism_exit=$run_exit
    fi

    echo "Final schism exit code: $schism_exit"
    return "$schism_exit"
}
