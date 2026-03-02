#!/usr/bin/env bash
# scripts/lib/notify.sh — OS desktop notification helpers
#
# SOURCE this file; do not execute it directly.
# Requires config.sh to be sourced first.
#
# Functions:
#   kitty_tab_active                        — returns 0 if running in Kitty with the active tab
#   notify_os TITLE MESSAGE                 — send a native desktop notification
#   cancel_focus_watcher SESSION_ID         — kill any pending focus watcher for a session
#   notify_escalating SESSION_ID TITLE MSG  — bell now; OS+sound after focus timeout

_NOTIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# kitty_tab_active
# Returns 0 (true) if the current process is running inside Kitty terminal
# and the tab containing this window is currently the active (visible) tab.
# Requires allow_remote_control yes in kitty.conf (sets $KITTY_LISTEN_ON).
# Returns 1 if not in Kitty, remote control is unavailable, or tab is inactive.
# ---------------------------------------------------------------------------
kitty_tab_active() {
  [[ -n "${KITTY_WINDOW_ID:-}" ]] || return 1
  [[ -n "${KITTY_LISTEN_ON:-}" ]] || return 1

  kitty @ --to "$KITTY_LISTEN_ON" ls 2>/dev/null \
    | jq --argjson id "$KITTY_WINDOW_ID" '
        [.[].tabs[] | select(any(.windows[]; .id == $id)) | .is_active] | any
      ' 2>/dev/null \
    | grep -q true
}

# ---------------------------------------------------------------------------
# notify_os TITLE MESSAGE
# Sends a desktop notification using the best available tool.
# Silently skips if no notification tool is installed, or if the current
# Kitty tab is active (user is already watching the terminal).
# ---------------------------------------------------------------------------
notify_os() {
  local title="$1"
  local message="$2"

  kitty_tab_active && return 0

  if [[ "$(uname)" == "Darwin" ]]; then
    if command -v osascript &>/dev/null; then
      osascript -e \
        "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" \
        &>/dev/null || true
    fi
  else
    if command -v notify-send &>/dev/null; then
      notify-send "$title" "$message" &>/dev/null || true
    fi
  fi
}

# ---------------------------------------------------------------------------
# cancel_focus_watcher SESSION_ID
# Sends SIGTERM to any running focus watcher for SESSION_ID and removes the
# PID file.  Safe to call even if no watcher is running (no-op).
# ---------------------------------------------------------------------------
cancel_focus_watcher() {
  local session_id="$1"
  local pid_file="/tmp/claude-focus-watcher-${session_id}.pid"
  [[ -f "$pid_file" ]] || return 0

  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)

  if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
    # Sanity-check: only kill if the process looks like our watcher
    local comm
    comm=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ' || true)
    if [[ "$comm" == *"focus-watcher"* ]] || [[ "$comm" == "bash" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  fi

  rm -f "$pid_file"
}

# ---------------------------------------------------------------------------
# notify_escalating SESSION_ID TITLE MESSAGE
# Rings the bell immediately (caller's responsibility) then starts a
# background focus-watcher that fires OS+sound after focus_timeout_seconds
# if the user has not returned to the Kitty tab.
#
# Falls back to an immediate notify_os + play_sound when:
#   - focus_timeout_seconds is 0
#   - Kitty remote control is not available
#   - focus-watcher.sh is not executable
# ---------------------------------------------------------------------------
notify_escalating() {
  local session_id="$1"
  local title="${2:-Claude}"
  local message="${3:-Claude needs your attention}"

  local timeout
  timeout=$(get_config 'long_running.focus_timeout_seconds' '30')

  # timeout=0: immediate notification, bypass watcher
  if [[ "$timeout" -eq 0 ]]; then
    notify_os "$title" "$message"
    play_sound "long_running"
    return 0
  fi

  # Non-Kitty or remote control unavailable: immediate fallback
  if [[ -z "${KITTY_LISTEN_ON:-}" ]]; then
    notify_os "$title" "$message"
    play_sound "long_running"
    return 0
  fi

  # Already focused — bell is enough, no escalation needed
  kitty_tab_active && return 0

  # Cancel any previous watcher before spawning a new one
  cancel_focus_watcher "$session_id"

  local watcher="${_NOTIFY_LIB_DIR}/focus-watcher.sh"
  if [[ ! -x "$watcher" ]]; then
    # Watcher missing: immediate fallback
    notify_os "$title" "$message"
    play_sound "long_running"
    return 0
  fi

  # Spawn background watcher; detach so hook exits immediately
  "$watcher" "$session_id" "$timeout" "$title" "$message" \
    </dev/null >/dev/null 2>/dev/null &
  disown 2>/dev/null || true
}
