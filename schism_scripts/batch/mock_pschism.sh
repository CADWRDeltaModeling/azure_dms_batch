#!/bin/bash
################################################################################
# mock_pschism.sh
#
# Mock SCHISM process for testing watch_and_restart.sh without a real cluster.
#
# The script has 'pschism' in its filename so that pgrep -f 'pschism' (used
# by the watchdog's is_pschism_running) picks it up correctly.
#
# Behaviour
# ─────────
#   First run  (ihot != 2 in param.nml):
#     Write FREEZE_AFTER TIME STEP entries to outputs/mirror.out, create a
#     fake hotstart_it=*.nc, then busy-spin at 100% CPU with no further
#     mirror.out progress until killed by the watchdog.
#
#   Restart    (ihot = 2 in param.nml):
#     Resume from the last step recorded in mirror.out, write the remaining
#     steps to TOTAL_STEPS, then exit 0 (clean completion).
#
# Usage
# ─────
#   mock_pschism.sh <study_dir> <total_steps> <freeze_after_steps> <sleep_secs>
#
#   study_dir          – absolute path to the study directory      (default: pwd)
#   total_steps        – total time steps for a full run           (default: 50)
#   freeze_after_steps – steps written before freezing on run 1   (default: 8)
#   sleep_secs         – real-time seconds between each step write (default: 3)
#
# Notes
# ─────
#   DT is hard-coded to 90 s/step (real SCHISM default) so the sim_time values
#   in mirror.out are realistic and the watchdog's rndays check works correctly.
################################################################################

STUDY_DIR="${1:-$(pwd)}"
TOTAL_STEPS="${2:-50}"
FREEZE_AFTER="${3:-8}"
STEP_SLEEP="${4:-3}"
DT=90   # simulated seconds per time step

MIRROR_OUT="${STUDY_DIR}/outputs/mirror.out"
PARAM_NML="${STUDY_DIR}/param.nml"

mkdir -p "${STUDY_DIR}/outputs"

# ── Detect restart ────────────────────────────────────────────────────────────
ihot=1
if [[ -f "$PARAM_NML" ]] && grep -qi 'ihot[[:space:]]*=[[:space:]]*2' "$PARAM_NML"; then
    ihot=2
fi

# ── Find last completed step from mirror.out ──────────────────────────────────
current_step=0
if [[ -f "$MIRROR_OUT" ]]; then
    last_step=$(tail -100 "$MIRROR_OUT" \
                | grep "TIME STEP" | tail -1 \
                | awk '{print $3}' | tr -d ';')
    current_step="${last_step:-0}"
fi

echo "mock_pschism: ihot=$ihot  start_step=$current_step  total=$TOTAL_STEPS  freeze_after=$FREEZE_AFTER"

# ── Write advancing TIME STEP entries ─────────────────────────────────────────
step="$current_step"

while [[ "$step" -lt "$TOTAL_STEPS" ]]; do
    step=$(( step + 1 ))
    sim_time=$(( step * DT ))
    printf "  TIME STEP=%10d;  TIME=%20.6f\n" "$step" "${sim_time}.000000" \
        >> "$MIRROR_OUT"
    echo "mock_pschism: step=$step  sim_time=${sim_time}s"
    sleep "$STEP_SLEEP"

    # ── First run only: freeze after FREEZE_AFTER steps ───────────────────────
    if [[ "$ihot" != "2" ]] && [[ "$step" -ge "$FREEZE_AFTER" ]]; then
        # Create a fake combined hotstart so prepare_hotstart can find and link it
        fake_hotstart="${STUDY_DIR}/outputs/hotstart_it=${sim_time}.nc"
        touch "$fake_hotstart"
        echo "mock_pschism: created fake $fake_hotstart"
        echo "mock_pschism: FREEZING at step=$step — busy-spinning at 100% CPU until killed"
        # Busy-spin: keeps CPU high, no further mirror.out progress
        while true; do :; done
    fi
done

echo "mock_pschism: completed $TOTAL_STEPS steps — exiting cleanly (exit 0)"
exit 0
