#!/bin/bash
################################################################################
# test_watchdog_local.sh
#
# Local (no Azure Batch) integration test for watch_and_restart + mock_pschism.
#
# What it tests:
#   1. Mock pschism writes N steps then busy-spins (100% CPU, no progress).
#   2. Watchdog detects stuck after 2 × 15 s polls.
#   3. Watchdog kills mock, finds fake hotstart, sets ihot=2 in param.nml.
#   4. Watchdog relaunches mock; restarted mock finishes and exits 0.
#   5. Watchdog exits 0; run_with_watchdog returns 0.
#
# Expected runtime: ~1 minute
#
# Usage:
#   bash tests/test_watchdog_local.sh
################################################################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SCHISM_SCRIPTS_HOME="${REPO_ROOT}/schism_scripts"

echo "=============================================="
echo "  Watchdog local integration test"
echo "  REPO_ROOT           = $REPO_ROOT"
echo "  SCHISM_SCRIPTS_HOME = $SCHISM_SCRIPTS_HOME"
echo "=============================================="
echo ""

# ── Create a temp study directory ─────────────────────────────────────────────
TEST_DIR=$(mktemp -d /tmp/watchdog_test_XXXXXX)
export SCHISM_STUDY_DIR="$TEST_DIR"
echo "Study dir: $TEST_DIR"
echo "Watchdog log will be written to: $TEST_DIR/watchdog.log"
echo ""

# Scope the watchdog's pgrep/pkill patterns to this test's unique temp dir
# (present in the mock's argv) so it can never match/kill a real production
# pschism or mpirun process on a shared machine. There is no real mpirun in
# this test, so both patterns point at the mock invocation.
export WATCHDOG_PSCHISM_PATTERN="mock_pschism.sh ${TEST_DIR}"
export WATCHDOG_MPIRUN_PATTERN="mock_pschism.sh ${TEST_DIR}"

cleanup() {
    echo ""
    echo "--- Cleaning up $TEST_DIR ---"
    # Kill any leftover mock or watchdog processes from this test
    pkill -KILL -f "mock_pschism.sh ${TEST_DIR}" 2>/dev/null || true
    pkill -KILL -f "watch_and_restart.sh.*${TEST_DIR}" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/outputs"

# Minimal param.nml — rnday large so rndays-check won't fire during the freeze
# (mock reaches only 20 steps × 90 s DT = 1800 s = 0.02 days)
cat > "$TEST_DIR/param.nml" << 'EOF'
rnday = 365
ihot  = 1
EOF

cd "$TEST_DIR"

# ── Source the lib and run ─────────────────────────────────────────────────────
source "${SCHISM_SCRIPTS_HOME}/batch/schism_run_lib.sh"

# Mock args: <study_dir> <total_steps> <freeze_after_steps> <sleep_secs_per_step>
#   total_steps=20, freeze_after=4, sleep=2s
#   → writes for 4 × 2 s = 8 s, then freezes
#   → watchdog detects stuck after 2 × 15 s = 30 s
#   → restart runs steps 5–20 = 16 steps × 2 s = 32 s
#   → total ≈ 8 + 30 + 5 (kill overhead) + 32 ≈ 75 s
run_with_watchdog \
    "bash ${SCHISM_SCRIPTS_HOME}/batch/mock_pschism.sh \"${SCHISM_STUDY_DIR}\" 20 4 2" \
    --study-dir  "$SCHISM_STUDY_DIR" \
    --poll-interval 15 \
    --stuck-polls   2  \
    --max-restarts  3

FINAL_EXIT=$?

echo ""
echo "=============================================="
if [[ "$FINAL_EXIT" -eq 0 ]]; then
    echo "  PASS — run_with_watchdog exited 0"
else
    echo "  FAIL — run_with_watchdog exited $FINAL_EXIT"
fi
echo "=============================================="
echo ""
echo "--- param.nml (should show ihot = 2 after restart) ---"
cat "$TEST_DIR/param.nml"
echo ""
echo "--- Last 20 lines of mirror.out ---"
tail -20 "$TEST_DIR/outputs/mirror.out" 2>/dev/null || echo "(mirror.out not found)"
echo ""
echo "--- watchdog.log ---"
cat "$TEST_DIR/watchdog.log" 2>/dev/null || echo "(watchdog.log not found)"

exit "$FINAL_EXIT"
