#!/usr/bin/env bash
# scripts/lib/notify.sh — OS desktop notification helpers
#
# SOURCE this file; do not execute it directly.
# Requires config.sh to be sourced first.
#
# Functions:
#   kitty_tab_active                        — returns 0 if running in Kitty with the active tab
#   notify_os TITLE MESSAGE                 — send a native desktop notification
#   cancel_notification_timer SESSION_ID    — kill any pending notification timer for a session
#   notify_all SESSION_ID TITLE MSG         — fire all enabled channels per their thresholds

_NOTIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${_NOTIFY_LIB_DIR}/state.sh"

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
# nvim_active SESSION_ID
# Returns 0 (true) if the nvim_active field in the session state file is true.
# Returns 1 if the state file is absent, unreadable, or the field is not true.
# ---------------------------------------------------------------------------
nvim_active() {
  local session_id="$1"
  local state_file
  state_file="$(state_file_path "$session_id")"
  [[ -f "$state_file" ]] || return 1
  local active
  active=$(jq -r '.nvim_active // empty' "$state_file" 2>/dev/null)
  [[ "$active" == "true" ]]
}

# ---------------------------------------------------------------------------
# notify_os TITLE MESSAGE
# Sends a desktop notification using the best available tool.
# ---------------------------------------------------------------------------
notify_os() {
  local title="$1"
  local message="$2"

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
# cancel_notification_timer SESSION_ID
# Sends SIGTERM to any running notification timer for SESSION_ID and removes
# the PID file.  Safe to call even if no timer is running (no-op).
# ---------------------------------------------------------------------------
cancel_notification_timer() {
  local session_id="$1"
  local pid_file="/tmp/claude-notification-timer-${session_id}.pid"
  [[ -f "$pid_file" ]] || return 0

  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)

  if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]]; then
    kill -TERM "$pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"
}

# ---------------------------------------------------------------------------
# _fire_channel CHANNEL SESSION_ID TITLE MESSAGE
# Fire a single notification channel immediately.
# ---------------------------------------------------------------------------
_fire_channel() {
  local channel="$1" session_id="$2" title="$3" message="$4"
  case "$channel" in
    terminal) ring_bell ;;
    sound)    play_sound ;;
    os)       notify_os "$title" "$message" ;;
    nvim)
      local expr
      expr=$(get_config "notifications.nvim.notification" "")
      [[ -n "$expr" ]] || return 0
      expr="${expr//%SESSION_ID%/$session_id}"
      notify_vim "$expr"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# notify_all SESSION_ID TITLE MESSAGE
# Fire all enabled notification channels according to their configured
# notification_threshold values.
#
# Channels with notification_threshold=0 fire immediately (in the calling
# process).  Channels with notification_threshold>0 are handled by a single
# background notification-timer.sh process (one PID, cancellable via
# cancel_notification_timer).
#
# Each channel is skipped independently based on its skip_kitty_active and
# skip_nvim_active config flags.  Delayed channels are always scheduled so
# the timer can re-check focus state at fire time.
# ---------------------------------------------------------------------------
notify_all() {
  local session_id="$1"
  local title="${2:-Claude}"
  local message="${3:-Claude needs your attention}"

  local kitty_is_active=false nvim_is_active=false
  kitty_tab_active && kitty_is_active=true
  nvim_active "$session_id" && nvim_is_active=true

  local has_delayed=false

  for channel in terminal sound os nvim; do
    local enabled threshold skip_kitty skip_nvim
    enabled=$(get_config "notifications.${channel}.enabled" "false")
    threshold=$(get_config "notifications.${channel}.notification_threshold" "0")
    skip_kitty=$(get_config "notifications.${channel}.skip_kitty_active" "false")
    skip_nvim=$(get_config "notifications.${channel}.skip_nvim_active" "false")

    [[ "$enabled" == "true" ]] || continue

    if [[ "${threshold:-0}" -eq 0 ]]; then
      [[ "$skip_kitty" == "true" && "$kitty_is_active" == "true" ]] && continue
      [[ "$skip_nvim"  == "true" && "$nvim_is_active"  == "true" ]] && continue
      _fire_channel "$channel" "$session_id" "$title" "$message"
    else
      has_delayed=true
    fi
  done

  if [[ "$has_delayed" == "true" ]]; then
    cancel_notification_timer "$session_id"
    local timer="${_NOTIFY_LIB_DIR}/notification-timer.sh"
    if [[ -x "$timer" ]]; then
      "$timer" "$session_id" "$title" "$message" \
        </dev/null >/dev/null 2>/dev/null &
      disown 2>/dev/null || true
    fi
  fi
}
