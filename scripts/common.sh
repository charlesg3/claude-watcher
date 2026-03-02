#!/usr/bin/env bash
# scripts/common.sh — shared helpers for all claude-status scripts
#
# SOURCE this file; do not execute it directly.
#
# COMPONENT IDENTITY
#   Each script that sources this file should declare its name at the top:
#     CLAUDE_STATUS_COMPONENT="hooks"
#   This appears in every log line written by log_info/log_warn/log_error.
#
# FUNCTION GROUPS
#   Script output (install, run-tests, pre-commit):
#     ok, warn, err, skip, header, pass_banner, fail_banner, spin, clear_spin
#
#   Structured log (watcher, hooks, lib scripts → shared log file):
#     log_info, log_warn, log_error
#
# OVERRIDING COLORS
#   All color variables use ${VAR:-default} so they can be overridden by the
#   environment before sourcing this file. Scripts normally run in subshells
#   so there is no collision risk between callers.
#
# USAGE
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"   # from scripts/
#   source "$PROJECT_ROOT/scripts/common.sh"               # from anywhere

# ---------------------------------------------------------------------------
# Panda Syntax palette (inline — no external dependency)
# Mirrors dotfiles/shell/colors.sh semantic values.
# ---------------------------------------------------------------------------
PANDA_HOT_PINK="${PANDA_HOT_PINK:-#FF2C6D}"   # error / bright magenta-red
PANDA_GREEN="${PANDA_GREEN:-#55B96D}"          # success
PANDA_BLUE="${PANDA_BLUE:-#6FC1FF}"            # info / functions
PANDA_ORANGE="${PANDA_ORANGE:-#FFB86C}"        # warning / constants
PANDA_LAVENDER="${PANDA_LAVENDER:-#B1B9F5}"    # headers / UI accents
PANDA_COMMENT="${PANDA_COMMENT:-#676B79}"      # dim / secondary text

# ---------------------------------------------------------------------------
# ANSI codes — derived from palette, each overridable independently
# ---------------------------------------------------------------------------
_ansi_fg() {
  local hex="${1#\#}"
  printf '\033[38;2;%d;%d;%dm' \
    "$((16#${hex:0:2}))" "$((16#${hex:2:2}))" "$((16#${hex:4:2}))"
}

ANSI_RESET="${ANSI_RESET:-\033[0m}"
ANSI_BOLD="${ANSI_BOLD:-\033[1m}"
ANSI_DIM="${ANSI_DIM:-\033[2m}"
ANSI_OK="${ANSI_OK:-$(_ansi_fg "$PANDA_GREEN")}"
ANSI_WARN="${ANSI_WARN:-$(_ansi_fg "$PANDA_ORANGE")}"
ANSI_ERR="${ANSI_ERR:-$(_ansi_fg "$PANDA_HOT_PINK")}"
ANSI_HEADER="${ANSI_HEADER:-$(_ansi_fg "$PANDA_LAVENDER")}"
ANSI_SPIN="${ANSI_SPIN:-$(_ansi_fg "$PANDA_BLUE")}"

# ---------------------------------------------------------------------------
# Script output helpers
# (install.sh, run-tests.sh, pre-commit.sh)
# ---------------------------------------------------------------------------
ok()          { echo -e "  ${ANSI_OK}✓${ANSI_RESET} $*"; }
warn()        { echo -e "  ${ANSI_WARN}~${ANSI_RESET} $*"; }
err()         { echo -e "  ${ANSI_ERR}✗${ANSI_RESET} $*" >&2; }
skip()        { echo -e "  ${ANSI_DIM}-${ANSI_RESET} $* ${ANSI_DIM}(skipped)${ANSI_RESET}"; }
header()      { echo -e "\n${ANSI_BOLD}${ANSI_HEADER}${*}${ANSI_RESET}"; }
pass_banner() { echo -e "\n${ANSI_OK}${*}${ANSI_RESET}\n"; }
fail_banner() { echo -e "\n${ANSI_ERR}${*}${ANSI_RESET}\n" >&2; }
spin()        { echo -ne "  ${ANSI_SPIN}↻${ANSI_RESET}  ${1}..."; }
clear_spin()  { echo -ne "\r\033[2K"; }

# ---------------------------------------------------------------------------
# Structured log helpers
# (hooks/claude-hook.sh, scripts/lib/*.sh)
#
# Log format:
#   2026-01-15T12:34:56Z [session:abc123] [hooks] INFO  message
#
# CLAUDE_STATUS_COMPONENT — set by each sourcing script (default: "unknown")
# CLAUDE_SESSION_ID       — set by hooks from Claude's env, or passed explicitly
# CLAUDE_STATUS_LOG       — override the log file path
# CLAUDE_STATUS_LOG_MAX_LINES — trim threshold (default: 500)
# ---------------------------------------------------------------------------
CLAUDE_STATUS_LOG="${CLAUDE_STATUS_LOG:-$HOME/.local/share/claude-status/claude-status.log}"
CLAUDE_STATUS_COMPONENT="${CLAUDE_STATUS_COMPONENT:-unknown}"
CLAUDE_STATUS_LOG_MAX_LINES="${CLAUDE_STATUS_LOG_MAX_LINES:-500}"

_log_line() {
  local level="$1"; shift
  local session="${CLAUDE_SESSION_ID:-none}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
  local line
  printf -v line "%s [session:%s] [%s] %-5s %s" \
    "$ts" "$session" "$CLAUDE_STATUS_COMPONENT" "$level" "$*"
  echo "$line" >> "$CLAUDE_STATUS_LOG"
}

_rotate_log() {
  [[ -f "$CLAUDE_STATUS_LOG" ]] || return 0
  local lines
  lines="$(wc -l < "$CLAUDE_STATUS_LOG")"
  if (( lines > CLAUDE_STATUS_LOG_MAX_LINES )); then
    local tmp="${CLAUDE_STATUS_LOG}.tmp"
    tail -n "$CLAUDE_STATUS_LOG_MAX_LINES" "$CLAUDE_STATUS_LOG" > "$tmp" \
      && mv "$tmp" "$CLAUDE_STATUS_LOG"
  fi
}

# ---------------------------------------------------------------------------
# Neovim RPC helper
# ---------------------------------------------------------------------------

# notify_vim EXPR
# Evaluates a Vimscript expression in the parent Neovim instance, if any.
# $NVIM is set by Neovim for every process running inside one of its terminal
# buffers, so this is silently a no-op when running outside Neovim.
# Runs asynchronously so it never blocks the calling script.
notify_vim() {
  [[ -n "${NVIM:-}" ]] || return 0
  nvim --server "$NVIM" --remote-expr "$1" &>/dev/null &
}

log_info() {
  mkdir -p "$(dirname "$CLAUDE_STATUS_LOG")"
  _log_line "INFO" "$@"
  _rotate_log
}

log_warn() {
  mkdir -p "$(dirname "$CLAUDE_STATUS_LOG")"
  _log_line "WARN" "$@"
  _rotate_log
}

log_error() {
  mkdir -p "$(dirname "$CLAUDE_STATUS_LOG")"
  _log_line "ERROR" "$@"
  _rotate_log
}
