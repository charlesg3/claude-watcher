#!/usr/bin/env bash
# hooks/claude-hook.sh — single entry-point dispatcher for all Claude hook events
#
# Claude calls this script via stdin for every configured hook event.
# The script reads the JSON payload and dispatches to the appropriate handler.
#
# Usage (in ~/.claude/settings.json):
#   { "type": "command", "command": "/path/to/hooks/claude-hook.sh" }
#
# Handled hook events:
#   SessionStart      — initialize state file for this session
#   UserPromptSubmit  — mark session as working, record prompt start time
#   Notification      — surface idle/permission prompts to the user
#   Stop              — mark session as ready, fire long-running notification
#   SessionEnd        — clean up state file

set -euo pipefail

CLAUDE_STATUS_COMPONENT="hooks"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$HOOK_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/common.sh"
source "$PROJECT_ROOT/scripts/lib/config.sh"
source "$PROJECT_ROOT/scripts/lib/state.sh"
source "$PROJECT_ROOT/scripts/lib/notify.sh"
source "$PROJECT_ROOT/scripts/lib/sound.sh"

# ---------------------------------------------------------------------------
# Read stdin
# ---------------------------------------------------------------------------
HOOK_INPUT="$(cat)"

# ---------------------------------------------------------------------------
# Parse top-level fields present in every hook event
# ---------------------------------------------------------------------------
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id       // empty')"
EVENT="$(printf '%s'      "$HOOK_INPUT" | jq -r '.hook_event_name   // empty')"
CWD="$(printf '%s'        "$HOOK_INPUT" | jq -r '.cwd               // empty')"

if [[ -z "$SESSION_ID" || -z "$EVENT" ]]; then
  log_warn "missing session_id or hook_event_name in hook payload"
  exit 0
fi

[[ -z "$CWD" ]] && CWD="$PWD"   # fallback if cwd absent

export CLAUDE_SESSION_ID="$SESSION_ID"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_notify_vim_session_start() {
  local session_id="$1" claude_pid="${2:-0}"
  notify_vim "ClaudeStatusRegister('${session_id}', ${claude_pid})"
}

_notify_vim_session_end() {
  notify_vim "ClaudeStatusUnregister('${1}')"
}

# _find_claude_pid — walk up the process tree past shell wrappers to find the
# Claude process PID.  Claude runs hooks as a subprocess, potentially via an
# intermediate shell (bash/sh/env), so we skip up to 3 hops of shell processes.
_find_claude_pid() {
  local pid="$PPID"
  local hops=0
  while [[ "$hops" -lt 3 && -n "$pid" && "$pid" -gt 1 ]]; do
    local cmd
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ') || break
    case "$cmd" in
      bash|sh|zsh|dash|env) ;;
      *) break ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    hops=$(( hops + 1 ))
  done
  printf '%s' "$pid"
}

# _git_info DIR — sets GIT_BRANCH, GIT_STAGED, GIT_MODIFIED for the given dir
_git_info() {
  local dir="${1:-$CWD}"
  GIT_BRANCH=""
  GIT_STAGED=0
  GIT_MODIFIED=0

  if command -v git &>/dev/null \
      && git -C "$dir" rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    GIT_STAGED=$(git -C "$dir" diff --cached --numstat 2>/dev/null \
      | wc -l | tr -d ' ')
    GIT_MODIFIED=$(git -C "$dir" diff --numstat 2>/dev/null \
      | wc -l | tr -d ' ')
  fi
}

# _should_notify_channel CHANNEL — returns 0 if the channel is enabled
_should_notify_channel() {
  local channel="$1"
  [[ "$(get_config "notifications.${channel}.enabled" "true")" == "true" ]]
}

# _fire_long_running_notifications DURATION
# Fires OS + sound notifications for each channel whose threshold was exceeded.
_fire_long_running_notifications() {
  local duration="$1"
  local dir_label title message
  dir_label=$(basename "$CWD")
  title="Claude: done"
  message="Finished in ${duration}s in ${dir_label}"

  local fired=false
  for channel in os sound; do
    _should_notify_channel "$channel" || continue
    [[ "$(get_config "notifications.${channel}.on_long_running" "true")" == "true" ]] || continue
    local threshold
    threshold=$(get_threshold "$channel")
    if [[ "$threshold" -eq 0 ]] || [[ "$duration" -ge "$threshold" ]]; then
      case "$channel" in
        os)    notify_os "$title" "$message" ;;
        sound) play_sound "long_running" ;;
      esac
      fired=true
    fi
  done

  [[ "$fired" == "true" ]] && log_info "long_running notification fired (${duration}s)" || true
}

# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

handle_session_start() {
  local source model
  source=$(printf '%s' "$HOOK_INPUT" | jq -r '.source // empty')
  model=$(printf '%s'  "$HOOK_INPUT" | jq -r '.model  // empty')

  local now claude_pid
  now=$(date +%s)
  claude_pid=$(_find_claude_pid)

  _git_info "$CWD"

  local new_state
  new_state=$(jq -n \
    --arg session_id    "$SESSION_ID" \
    --arg directory     "$CWD" \
    --arg branch        "$GIT_BRANCH" \
    --argjson git_staged  "$GIT_STAGED" \
    --argjson git_modified "$GIT_MODIFIED" \
    --arg source        "$source" \
    --arg model         "$model" \
    --argjson epoch     "$now" \
    --argjson claude_pid "${claude_pid:-0}" \
    '{
      session_id:          $session_id,
      state:               "ready",
      directory:           $directory,
      branch:              $branch,
      git_staged:          $git_staged,
      git_modified:        $git_modified,
      source:              $source,
      model:               $model,
      session_start_epoch: $epoch,
      claude_pid:          $claude_pid
    }')

  write_state "$SESSION_ID" "$new_state"
  _notify_vim_session_start "$SESSION_ID" "$claude_pid"
  log_info "SessionStart source=$source dir=$CWD pid=$claude_pid"
}

handle_user_prompt_submit() {
  local now
  now=$(date +%s)

  _git_info "$CWD"

  local state_file
  state_file="$(state_file_path "$SESSION_ID")"

  # Build on existing state so fields set at SessionStart are preserved
  local base="{}"
  [[ -f "$state_file" ]] && base="$(cat "$state_file")"

  local updated
  updated=$(printf '%s' "$base" \
    | jq \
      --arg  directory    "$CWD" \
      --arg  branch       "$GIT_BRANCH" \
      --argjson staged    "$GIT_STAGED" \
      --argjson modified  "$GIT_MODIFIED" \
      --argjson epoch     "$now" \
      '.state               = "working"
      | .directory          = $directory
      | .branch             = $branch
      | .git_staged         = $staged
      | .git_modified       = $modified
      | .prompt_start_epoch = $epoch')

  write_state "$SESSION_ID" "$updated"
  log_info "UserPromptSubmit state→working"
}

handle_notification() {
  local notification_type message title
  notification_type=$(printf '%s' "$HOOK_INPUT" | jq -r '.notification_type // empty')
  message=$(printf '%s'           "$HOOK_INPUT" | jq -r '.message           // empty')
  title=$(printf '%s'             "$HOOK_INPUT" | jq -r '.title             // empty')

  # permission_prompt: Claude is blocked waiting for user — reflect in state
  if [[ "$notification_type" == "permission_prompt" ]]; then
    local state_file
    state_file="$(state_file_path "$SESSION_ID")"
    if [[ -f "$state_file" ]]; then
      local updated
      updated=$(jq '.state = "waiting"' "$state_file")
      write_state "$SESSION_ID" "$updated"
    fi
  fi

  # Surface attention-needed notifications via OS alert
  case "$notification_type" in
    idle_prompt|permission_prompt)
      if _should_notify_channel "os"; then
        notify_os "${title:-Claude}" "${message:-Claude needs your attention}"
      fi
      ;;
  esac

  log_info "Notification type=${notification_type}"
}

handle_stop() {
  _git_info "$CWD"

  local state_file
  state_file="$(state_file_path "$SESSION_ID")"

  local now duration=0
  now=$(date +%s)

  if [[ -f "$state_file" ]]; then
    local prompt_start
    prompt_start=$(read_state_field "prompt_start_epoch")
    [[ -n "$prompt_start" ]] && duration=$(( now - prompt_start ))

    local updated
    updated=$(jq \
      --arg  branch          "$GIT_BRANCH" \
      --argjson git_staged    "$GIT_STAGED" \
      --argjson git_modified   "$GIT_MODIFIED" \
      --argjson duration      "$duration" \
      '.state             = "ready"
      | .branch           = $branch
      | .git_staged       = $git_staged
      | .git_modified     = $git_modified
      | .duration_seconds = $duration' \
      "$state_file")
    write_state "$SESSION_ID" "$updated"
  else
    # No state file — session had no prompts; create a minimal ready state
    local new_state
    new_state=$(jq -n \
      --arg  session_id "$SESSION_ID" \
      --arg  directory  "$CWD" \
      --arg  branch     "$GIT_BRANCH" \
      --argjson git_staged  "$GIT_STAGED" \
      --argjson git_modified "$GIT_MODIFIED" \
      '{
        session_id:       $session_id,
        state:            "ready",
        directory:        $directory,
        branch:           $branch,
        git_staged:       $git_staged,
        git_modified:     $git_modified,
        duration_seconds: 0
      }')
    write_state "$SESSION_ID" "$new_state"
  fi

  _fire_long_running_notifications "$duration"
  log_info "Stop duration=${duration}s state→ready"
}

handle_session_end() {
  _notify_vim_session_end "$SESSION_ID"
  local state_file
  state_file="$(state_file_path "$SESSION_ID")"
  rm -f "$state_file"
  log_info "SessionEnd state file removed"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$EVENT" in
  SessionStart)      handle_session_start      ;;
  UserPromptSubmit)  handle_user_prompt_submit  ;;
  Notification)      handle_notification        ;;
  Stop)              handle_stop                ;;
  SessionEnd)        handle_session_end         ;;
  *)
    log_info "ignoring event: $EVENT"
    ;;
esac

exit 0
