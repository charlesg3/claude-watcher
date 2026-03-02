#!/usr/bin/env bash
# scripts/lib/focus-watcher.sh — background focus-polling escalation timer
#
# Spawned in background by notify_escalating. Polls kitty_tab_active every
# POLL_INTERVAL seconds. If the user returns before TIMEOUT_SECS, exits
# cleanly with no notification. If TIMEOUT_SECS elapses without focus,
# fires OS notification + sound.
#
# Usage (spawned by notify_escalating; do not call directly):
#   focus-watcher.sh SESSION_ID TIMEOUT_SECS TITLE MESSAGE
#
# KITTY_WINDOW_ID and KITTY_LISTEN_ON must be set in the environment
# (inherited from the spawning hook process).
#
# Writes its PID to /tmp/claude-focus-watcher-SESSION_ID.pid immediately
# so cancel_focus_watcher() can terminate it via SIGTERM.

CLAUDE_STATUS_COMPONENT="focus-watcher"

SESSION_ID="${1:?session_id required}"
TIMEOUT_SECS="${2:-30}"
TITLE="${3:-Claude}"
MESSAGE="${4:-Claude needs your attention}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export CLAUDE_SESSION_ID="$SESSION_ID"

source "$PROJECT_ROOT/scripts/common.sh"
source "$PROJECT_ROOT/scripts/lib/config.sh"
source "$PROJECT_ROOT/scripts/lib/notify.sh"
source "$PROJECT_ROOT/scripts/lib/sound.sh"

PID_FILE="/tmp/claude-focus-watcher-${SESSION_ID}.pid"
POLL_INTERVAL=3

# ---------------------------------------------------------------------------
# Cleanup — always remove PID file on exit (normal, SIGTERM, or error).
# SIGTERM trap exits cleanly so the watcher disappears without firing.
# ---------------------------------------------------------------------------
_cleanup() { rm -f "$PID_FILE"; }
trap '_cleanup; exit 0' TERM
trap '_cleanup' EXIT

printf '%s\n' $$ > "$PID_FILE"

log_info "focus-watcher started (timeout=${TIMEOUT_SECS}s)"

# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------
elapsed=0
while [[ "$elapsed" -lt "$TIMEOUT_SECS" ]]; do
  sleep "$POLL_INTERVAL" || true    # sleep may be interrupted by SIGTERM
  elapsed=$(( elapsed + POLL_INTERVAL ))
  if kitty_tab_active; then
    log_info "focus-watcher: user returned after ${elapsed}s — cancelled"
    exit 0
  fi
done

# ---------------------------------------------------------------------------
# Timeout reached — fire escalated notifications
# ---------------------------------------------------------------------------
log_info "focus-watcher: timeout ${TIMEOUT_SECS}s reached — escalating"

# Final focus check in case the user returned during the last sleep
kitty_tab_active && { log_info "focus-watcher: focused at last check — skipping"; exit 0; } || true

if [[ "$(get_config 'notifications.os.enabled' 'true')" == "true" ]]; then
  notify_os "$TITLE" "$MESSAGE"
fi

if [[ "$(get_config 'notifications.sound.enabled' 'true')" == "true" ]]; then
  play_sound "long_running"
fi
