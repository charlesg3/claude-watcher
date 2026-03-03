#!/usr/bin/env bash
# scripts/lib/notification-timer.sh — background notification timer
#
# Spawned by notify_all for channels with notification_threshold > 0.
# Fires each delayed channel at its configured threshold, then exits.
# Cancelled cleanly via SIGTERM (see cancel_notification_timer in notify.sh).
#
# Usage (spawned by notify_all; do not call directly):
#   notification-timer.sh SESSION_ID TITLE MESSAGE
#
# Writes its PID to /tmp/claude-notification-timer-SESSION_ID.pid so that
# cancel_notification_timer() can terminate it via SIGTERM.

CLAUDE_STATUS_COMPONENT="notification-timer"

SESSION_ID="${1:?session_id required}"
TITLE="${2:-Claude}"
MESSAGE="${3:-Claude needs your attention}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export CLAUDE_SESSION_ID="$SESSION_ID"

source "$PROJECT_ROOT/scripts/common.sh"
source "$PROJECT_ROOT/scripts/lib/config.sh"
source "$PROJECT_ROOT/scripts/lib/notify.sh"
source "$PROJECT_ROOT/scripts/lib/sound.sh"

PID_FILE="/tmp/claude-notification-timer-${SESSION_ID}.pid"
SLEEP_PID=""

# ---------------------------------------------------------------------------
# Cleanup — always remove PID file on exit (normal or error).
# SIGTERM trap cancels any in-flight sleep and exits cleanly.
# ---------------------------------------------------------------------------
_cleanup() { rm -f "$PID_FILE"; }
_cancel() {
  [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null || true
  _cleanup
  exit 0
}
trap '_cancel' TERM
trap '_cleanup' EXIT

printf '%s\n' $$ > "$PID_FILE"

log_info "notification-timer started"

# ---------------------------------------------------------------------------
# Collect delayed channels sorted by threshold (ascending).
# Each entry: "threshold:channel"
# ---------------------------------------------------------------------------
declare -a pending=()

for channel in terminal sound os nvim; do
  local_enabled=$(get_config "notifications.${channel}.enabled" "false")
  local_threshold=$(get_config "notifications.${channel}.notification_threshold" "0")

  [[ "$local_enabled" == "true" ]]    || continue
  [[ "${local_threshold:-0}" -gt 0 ]] || continue

  pending+=("${local_threshold}:${channel}")
done

if [[ ${#pending[@]} -eq 0 ]]; then
  log_info "notification-timer: no delayed channels — exiting"
  exit 0
fi

# Sort by threshold (numeric ascending)
IFS=$'\n' sorted=($(printf '%s\n' "${pending[@]}" | sort -t: -k1 -n))
unset IFS

# ---------------------------------------------------------------------------
# Fire each channel at its configured threshold.
# Uses sleep + wait so SIGTERM can interrupt cleanly between firings.
# ---------------------------------------------------------------------------
elapsed=0
for entry in "${sorted[@]}"; do
  threshold="${entry%%:*}"
  channel="${entry#*:}"

  to_sleep=$(( threshold - elapsed ))
  if [[ $to_sleep -gt 0 ]]; then
    sleep "$to_sleep" &
    SLEEP_PID=$!
    wait $SLEEP_PID || true
    SLEEP_PID=""
  fi
  elapsed=$threshold

  # Re-check focus state at time of firing — user may have switched away
  local kitty_is_active=false nvim_is_active=false
  kitty_tab_active && kitty_is_active=true
  nvim_active "$SESSION_ID" && nvim_is_active=true

  local skip_kitty skip_nvim
  skip_kitty=$(get_config "notifications.${channel}.skip_kitty_active" "false")
  skip_nvim=$(get_config "notifications.${channel}.skip_nvim_active" "false")

  if [[ "$skip_kitty" == "true" && "$kitty_is_active" == "true" ]]; then
    log_info "notification-timer: kitty active at ${elapsed}s — skipping ${channel}"
    continue
  fi
  if [[ "$skip_nvim" == "true" && "$nvim_is_active" == "true" ]]; then
    log_info "notification-timer: nvim active at ${elapsed}s — skipping ${channel}"
    continue
  fi

  log_info "notification-timer: firing ${channel} at ${elapsed}s"
  case "$channel" in
    terminal) ring_bell ;;
    sound)    play_sound ;;
    os)       notify_os "$TITLE" "$MESSAGE" ;;
    nvim)
      local expr
      expr=$(get_config "notifications.nvim.notification" "")
      if [[ -n "$expr" ]]; then
        expr="${expr//%SESSION_ID%/$SESSION_ID}"
        notify_vim "$expr"
      fi
      ;;
  esac
done

log_info "notification-timer: done"
