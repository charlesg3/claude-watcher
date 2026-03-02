#!/usr/bin/env bash
# scripts/lib/state.sh — atomic state file helpers for claude-status
#
# SOURCE this file; do not execute it directly.
# Requires config.sh to be sourced first (for get_config).
#
# State files live at $state_dir/claude-status-$session_id.json
# Writes are atomic: JSON is written to a .tmp file, then mv'd in place.
#
# Functions:
#   state_file_path SESSION_ID      — print the state file path
#   read_state_field SESSION_ID KEY — print a single field value
#   write_state SESSION_ID JSON     — atomically write full state JSON
#   patch_state SESSION_ID KEY VAL  — atomic single-field update

# ---------------------------------------------------------------------------
# state_file_path SESSION_ID
# ---------------------------------------------------------------------------
state_file_path() {
  local session_id="$1"
  local state_dir
  state_dir="$(get_config 'state_dir' '/tmp')"
  printf '%s/claude-status-%s.json' "$state_dir" "$session_id"
}

# ---------------------------------------------------------------------------
# _flatten_state
#
# Flattens the session state JSON into CLAUDE_STATE_* environment variables.
# Reads SESSION_ID from the environment. Call once in a parent script before
# invoking component functions; all subsequent read_state_field calls are free.
#
# State JSON is already flat (no nesting), so the mapping is 1:1:
#   branch  →  CLAUDE_STATE_branch=main
#   state   →  CLAUDE_STATE_state=working
#
# Null values are filtered out. Numeric values become strings.
# ---------------------------------------------------------------------------
_flatten_state() {
  local state_file
  # STATE_FILE env var overrides path derivation (used by tests and direct calls)
  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE}" ]]; then
    state_file="$STATE_FILE"
  else
    state_file="$(state_file_path "${SESSION_ID:?SESSION_ID not set}")"
  fi
  [[ -f "$state_file" ]] || return 0

  while IFS= read -r line; do
    local key="${line%%=*}"
    local value="${line#*=}"
    # export so child processes (component.sh, standalone calls) inherit them
    export "CLAUDE_STATE_${key}=${value}"
  done < <(jq -r '
    to_entries[]
    | select(.value != null)
    | "\(.key)=\(.value | tostring)"
  ' "$state_file")
}

# ---------------------------------------------------------------------------
# read_state_field KEY
#
# Prints the value for KEY from the session state, or empty string if absent.
# Reads SESSION_ID from the environment to locate the state file.
#
# Fast path: checks CLAUDE_STATE_* env vars populated by _flatten_state.
# Falls back to jq when env vars are absent (e.g. standalone component call).
# ---------------------------------------------------------------------------
read_state_field() {
  local key="$1"

  # Fast path: env var populated by _flatten_state (no jq, no file I/O).
  local env_key="CLAUDE_STATE_${key}"
  local cached="${!env_key:-}"
  if [[ -n "$cached" ]]; then
    printf '%s' "$cached"
    return
  fi

  # Fallback: read directly from the state file via jq.
  local state_file
  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE}" ]]; then
    state_file="$STATE_FILE"
  else
    state_file="$(state_file_path "${SESSION_ID:?SESSION_ID not set}")"
  fi
  [[ -f "$state_file" ]] || return 0
  jq -r ".${key} // empty" "$state_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# write_state SESSION_ID JSON
# Atomically write a full JSON object as the session state.
# ---------------------------------------------------------------------------
write_state() {
  local session_id="$1"
  local json="$2"
  local state_file
  state_file="$(state_file_path "$session_id")"
  local tmp="${state_file}.tmp"

  printf '%s\n' "$json" | jq '.' > "$tmp" 2>/dev/null \
    && mv "$tmp" "$state_file"
}

# ---------------------------------------------------------------------------
# patch_state SESSION_ID KEY VALUE_JSON
# Atomically merge a single key into the existing state.
# VALUE_JSON must be valid JSON (strings must be quoted).
# Creates the state file if it does not exist.
# ---------------------------------------------------------------------------
patch_state() {
  local session_id="$1"
  local key="$2"
  local value_json="$3"
  local state_file
  state_file="$(state_file_path "$session_id")"
  local tmp="${state_file}.tmp"

  local existing="{}"
  [[ -f "$state_file" ]] && existing="$(cat "$state_file")"

  printf '%s\n' "$existing" \
    | jq --argjson v "$value_json" ".\"${key}\" = \$v" \
    > "$tmp" 2>/dev/null \
    && mv "$tmp" "$state_file"
}
