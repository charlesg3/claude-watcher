#!/usr/bin/env bash
# scripts/render-statusline.sh — full status line renderer
#
# Sources all component scripts as function libraries (one bash process, no
# per-component subprocesses) and renders a complete formatted status line.
#
# Usage:
#   render-statusline.sh [FORMAT]
#
#   FORMAT  — "ansi" (default, for terminal/tmux) or "vim" (for Neovim winbar)
#
# Environment (required):
#   SESSION_ID  — Claude session ID; state is read from the corresponding
#                 /tmp/claude-status-$SESSION_ID.json file
#
# Adding a new component requires no changes here:
#   1. Create scripts/components/newname.sh defining comp_newname()
#   2. Add "newname" to statusline.layout in config.json or user config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${SESSION_ID:?render-statusline.sh requires SESSION_ID in environment}"
FORMAT="${1:-ansi}"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/format.sh"

# ---------------------------------------------------------------------------
# Pre-flatten config and state into CLAUDE_CONFIG_* / CLAUDE_STATE_* env vars.
#
# This is the core performance optimisation: rather than spawning a jq process
# for every get_config / read_state_field call inside each component function,
# we flatten both JSON blobs into env vars in one jq pass each. Component
# functions then read env vars directly — no jq, no file I/O per call.
#
# _flatten_config must run before _flatten_state because state_file_path
# calls get_config('state_dir'), which benefits from the config fast path.
# ---------------------------------------------------------------------------
_flatten_config
_flatten_state

# ---------------------------------------------------------------------------
# Source all component scripts.
#
# Each file in scripts/components/ defines a comp_<name>() function and ends
# with `source component-standalone.sh`, which is a no-op when not run
# directly. Globbing the directory means new components are picked up
# automatically — no changes to this file needed.
# ---------------------------------------------------------------------------
for _comp_file in "$SCRIPT_DIR/components/"*.sh; do
  source "$_comp_file"
done

# ---------------------------------------------------------------------------
# Build layout from config.
#
# statusline.layout is a JSON array of component names with an optional
# "spacer" entry that splits left-aligned from right-aligned content.
# Falls back to a sensible default if the key is absent.
# ---------------------------------------------------------------------------
LEFT_PARTS=()
RIGHT_PARTS=()
IN_RIGHT=false

_layout_json="$(get_config 'statusline.layout' '')"
if [[ -n "$_layout_json" ]]; then
  mapfile -t _layout_items < <(printf '%s' "$_layout_json" | jq -r '.[]' 2>/dev/null)
else
  _layout_items=(state directory branch git_status spacer context cost duration)
fi

for _item in "${_layout_items[@]}"; do
  if [[ "$_item" == "spacer" ]]; then
    IN_RIGHT=true; continue
  fi
  $IN_RIGHT && RIGHT_PARTS+=("$_item") || LEFT_PARTS+=("$_item")
done

# ---------------------------------------------------------------------------
# Render each section.
#
# Calls comp_<name>() for each layout item, joining non-empty outputs with
# two spaces. Component names with hyphens are converted to underscores to
# match the function naming convention (e.g. git-status → comp_git_status).
# ---------------------------------------------------------------------------
_render_section() {
  local out=""
  for _name in "$@"; do
    local _fn="comp_${_name//-/_}"
    if declare -f "$_fn" > /dev/null 2>&1; then
      local _seg
      _seg="$("$_fn" 2>/dev/null || true)"
      [[ -n "$_seg" ]] && out+="${out:+  }${_seg}"
    fi
  done
  printf '%s' "$out"
}

LEFT_RAW="$( _render_section "${LEFT_PARTS[@]+"${LEFT_PARTS[@]}"}")"
RIGHT_RAW="$(_render_section "${RIGHT_PARTS[@]+"${RIGHT_PARTS[@]}"}")"

# ---------------------------------------------------------------------------
# Format tokens and assemble final output.
#
# vim:  tokens → %#GroupName#; [[spacer]] → %=; Neovim handles alignment.
# ansi: tokens → ANSI escapes; spacer gap computed from terminal width.
# ---------------------------------------------------------------------------
if [[ "$FORMAT" == "vim" ]]; then
  output="$LEFT_RAW"
  [[ -n "$RIGHT_RAW" ]] && output+="[[spacer]]$RIGHT_RAW"
  format_vim "$output"
  printf '\n'
else
  LEFT="$(format_ansi "$LEFT_RAW")"
  RIGHT="$(format_ansi "$RIGHT_RAW")"

  if [[ -z "$RIGHT" ]]; then
    printf '%s\n' "$LEFT"
  else
    # Strip ANSI escapes to measure visible width for padding calculation.
    # Wide (emoji) characters occupy 2 terminal columns; count them separately.
    _visible_len() {
      local plain
      plain="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')"
      local chars wide
      chars=$(printf '%s' "$plain" | wc -m | tr -d ' ')
      wide=$(printf '%s' "$plain" | LC_ALL=C awk '{
        for (i = 1; i <= length($0); i++) {
          b = substr($0, i, 1)
          if (b >= "\360" && b <= "\364") w++
        }
      } END { print w+0 }')
      echo $(( chars + wide ))
    }

    TERM_WIDTH="${COLUMNS:-$(stty size </dev/tty 2>/dev/null | awk '{print $2}')}"
    TERM_WIDTH="${TERM_WIDTH:-120}"
    LEFT_LEN="$(_visible_len "$LEFT")"
    RIGHT_LEN="$(_visible_len "$RIGHT")"
    # 2-space gap + 3-char right margin (Claude clips the rightmost chars)
    SPACER_LEN=$(( TERM_WIDTH - LEFT_LEN - RIGHT_LEN - 5 ))
    [[ $SPACER_LEN -lt 1 ]] && SPACER_LEN=1
    PADDING="$(printf '%*s' "$SPACER_LEN" '')"
    printf '%s%s%s\n' "$LEFT" "$PADDING" "$RIGHT"
  fi
fi
