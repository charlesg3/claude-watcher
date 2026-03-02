#!/usr/bin/env bash
# scripts/statusline.sh — session state resolver and render dispatcher
#
# Handles two responsibilities:
#   1. Resolve STATE_FILE — from explicit env var (test/tmux) or from the
#      live session JSON that Claude pipes on stdin (statusLine.command mode).
#   2. Patch context_pct / cost_usd back into STATE_FILE so other renderers
#      (e.g. the Neovim plugin's timer) always have the latest values.
#
# After resolving and patching state, delegates rendering to render-statusline.sh
# unless running inside Neovim (future: winbar handles display there).
#
# Environment:
#   STATE_FILE       — path to the session state JSON (skips stdin detection)
#   CONFIG_OVERRIDE  — alternate user config path (for tests)
#   COLUMNS          — terminal width passed through to the renderer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/config.sh"

# ---------------------------------------------------------------------------
# Debug log
# ---------------------------------------------------------------------------
_LOG=/tmp/claude-statusline.log
_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$_LOG"; }

# ---------------------------------------------------------------------------
# Bail if statusline is disabled
# ---------------------------------------------------------------------------
if [[ "$(get_config 'statusline.enabled' 'true')" != "true" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve STATE_FILE: explicit env var (test/tmux) or statusLine stdin mode
#
# When Claude calls us as statusLine.command it pipes live session JSON on
# stdin and does NOT set STATE_FILE.  Detect that, derive the state file path
# from the session_id, and patch context_pct / cost_usd back so other
# renderers (e.g. the Neovim plugin's timer) can read them from STATE_FILE.
# ---------------------------------------------------------------------------
STDIN_CONTEXT_PCT=""
STDIN_COST_USD=""

if [[ -z "${STATE_FILE:-}" ]] && ! [ -t 0 ]; then
  _STDIN_JSON="$(cat)"
  _SESSION_ID="$(printf '%s' "$_STDIN_JSON" | jq -r '.session_id // empty')"
  _log "stdin mode: session_id=${_SESSION_ID:-<empty>}"

  if [[ -n "$_SESSION_ID" ]]; then
    STATE_FILE="$(get_config 'state_dir' '/tmp')/claude-status-${_SESSION_ID}.json"
    _log "resolved STATE_FILE=$STATE_FILE exists=$([ -f "$STATE_FILE" ] && echo yes || echo no)"

    # Extract live values from the session payload
    STDIN_CONTEXT_PCT="$(printf '%s' "$_STDIN_JSON" \
      | jq -r 'if .context_window.remaining_percentage != null
               then (100 - .context_window.remaining_percentage | floor | tostring)
               else empty end' 2>/dev/null)"
    STDIN_COST_USD="$(printf '%s' "$_STDIN_JSON" \
      | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)"

    # Patch STATE_FILE so other renderers can read cost/context (only source
    # for these fields — hooks never receive them)
    if [[ -f "$STATE_FILE" ]] && [[ -n "${STDIN_CONTEXT_PCT}${STDIN_COST_USD}" ]]; then
      _patch_tmp="$(mktemp)"
      jq \
        --arg ctx  "$STDIN_CONTEXT_PCT" \
        --arg cost "$STDIN_COST_USD" \
        '(if $ctx  != "" then .context_pct = ($ctx  | tonumber) else . end) |
         (if $cost != "" then .cost_usd    = ($cost | tonumber) else . end)' \
        "$STATE_FILE" > "$_patch_tmp" \
        && mv "$_patch_tmp" "$STATE_FILE" \
        || rm -f "$_patch_tmp"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Require a usable STATE_FILE (hooks may not have run yet, or session ended)
# ---------------------------------------------------------------------------
if [[ -z "${STATE_FILE:-}" || ! -f "$STATE_FILE" ]]; then
  _log "exit: no state file (STATE_FILE=${STATE_FILE:-<unset>})"
  exit 0
fi
_log "rendering from STATE_FILE=$STATE_FILE"

# ---------------------------------------------------------------------------
# Extract SESSION_ID from the resolved state file.
# ---------------------------------------------------------------------------
SESSION_ID="$(jq -r '.session_id // empty' "$STATE_FILE")"
if [[ -z "$SESSION_ID" ]]; then
  _log "exit: no session_id in $STATE_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Delegate rendering.
# In the future, skip this when running inside Neovim ($NVIM is set) and let
# the winbar handle display instead.
# ---------------------------------------------------------------------------
export SESSION_ID
export STATE_FILE
exec "$SCRIPT_DIR/render-statusline.sh"
