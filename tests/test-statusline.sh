#!/usr/bin/env bash
# Visual + functional tests for scripts/statusline.sh.
#
# For each subdirectory under tests/data/, runs the statusline script with
# the scenario's state.json (and optional config.json override) and prints
# the rendered output.  Used both for CI assertion and for pasting into PR
# descriptions when status bar changes are involved.
#
# Usage:
#   bash tests/test-statusline.sh            # run all scenarios
#   bash tests/test-statusline.sh working    # run one named scenario
#
# Environment overrides:
#   STATUSLINE_WIDTH  Terminal width for rendering (default: 120)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
STATUSLINE="$REPO_DIR/scripts/statusline.sh"

source "$REPO_DIR/scripts/common.sh"

# Override terminal width for reproducible output.
# The statusline script reads COLUMNS (falls back to tput cols).
export COLUMNS="${STATUSLINE_WIDTH:-120}"

# Fix "now" so duration (now - session_start_epoch) is deterministic across runs.
export MOCK_NOW=1772340000

# ── Guard ─────────────────────────────────────────────────────────────────────
if [[ ! -f "$STATUSLINE" ]]; then
    err "scripts/statusline.sh not yet implemented"
    exit 1
fi

pass=0; fail=0; skip=0

run_scenario() {
    local scenario_dir="$1"
    local scenario
    scenario="$(basename "$scenario_dir")"
    local state_file="$scenario_dir/state.json"
    local config_file="$scenario_dir/config.json"
    local stdin_file="$scenario_dir/stdin.json"

    if [[ ! -f "$state_file" ]]; then
        skip "$scenario"
        skip=$(( skip + 1 )); return
    fi

    local output exit_code=0

    if [[ -f "$stdin_file" ]]; then
        # stdin-mode scenario: simulate Claude's statusLine call (no STATE_FILE).
        # Place the state file where statusline.sh will look for it based on session_id.
        local session_id state_dir expected_state
        session_id="$(jq -r '.session_id // "test-session"' "$stdin_file")"
        state_dir="$(jq -r '.state_dir // "/tmp"' "$REPO_DIR/config/config.json" 2>/dev/null || echo /tmp)"
        expected_state="${state_dir}/claude-status-${session_id}.json"
        cp "$state_file" "$expected_state"

        local env_args=("COLUMNS=${STATUSLINE_WIDTH:-120}" "NVIM=")
        [[ -f "$config_file" ]] && env_args+=("CONFIG_OVERRIDE=$config_file")

        output=$(env "${env_args[@]}" bash "$STATUSLINE" < "$stdin_file" 2>&1) || exit_code=$?
        rm -f "$expected_state"
    else
        local env_args=("COLUMNS=${STATUSLINE_WIDTH:-120}" "STATE_FILE=$state_file" "NVIM=")
        [[ -f "$config_file" ]] && env_args+=("CONFIG_OVERRIDE=$config_file")

        output=$(env "${env_args[@]}" bash "$STATUSLINE" 2>&1) || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        ok "$scenario"
        pass=$(( pass + 1 ))
    else
        err "$scenario (exit $exit_code)"
        fail=$(( fail + 1 ))
    fi

    if [[ -n "$output" ]]; then
        printf "    %s\n" "$output"
    else
        printf "    (no output)\n"
    fi
}

# ── Run scenarios ─────────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
    for name in "$@"; do
        scenario_dir="$DATA_DIR/$name"
        if [[ ! -d "$scenario_dir" ]]; then
            err "no scenario named '$name' in tests/data/"
            exit 1
        fi
        run_scenario "$scenario_dir"
    done
else
    for scenario_dir in "$DATA_DIR"/*/; do
        [[ -d "$scenario_dir" ]] || continue
        run_scenario "$scenario_dir"
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $fail -eq 0 ]]; then
    pass_banner "All tests passed  ($pass passed, $skip skipped)"
else
    fail_banner "$fail failed  ($pass passed, $skip skipped)"
fi

[[ $fail -eq 0 ]]
