#!/usr/bin/env bash
# scripts/component.sh — standalone component dispatcher
#
# Renders a single named component for a session. Useful for debugging,
# testing individual components, or calling from Neovim via vim.fn.system.
#
# Usage:
#   component.sh SESSION_ID COMPONENT_NAME [FORMAT]
#
#   SESSION_ID      — Claude session ID; locates /tmp/claude-status-$id.json
#   COMPONENT_NAME  — name matching a file in scripts/components/
#   FORMAT          — "ansi" (default) or "vim"
#
# From Neovim Lua (with pre-built env for zero jq):
#   vim.system({component_sh, sid, "branch", "vim"}, { env = flat_env })

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SESSION_ID="${1:?Usage: component.sh SESSION_ID COMPONENT_NAME [FORMAT]}"
COMPONENT="${2:?Usage: component.sh SESSION_ID COMPONENT_NAME [FORMAT]}"
FORMAT="${3:-ansi}"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/format.sh"

COMP_FILE="$SCRIPT_DIR/components/${COMPONENT}.sh"
if [[ ! -f "$COMP_FILE" ]]; then
  printf 'component.sh: unknown component "%s"\n' "$COMPONENT" >&2
  exit 1
fi

# Source the component file — defines comp_COMPONENT() without executing it.
# component-standalone.sh (sourced at the end of the component file) will
# detect it is not being run directly and skip its bootstrap block.
source "$COMP_FILE"

output="$(comp_"${COMPONENT}" 2>/dev/null || true)"

if [[ "$FORMAT" == "vim" ]]; then
  format_vim "$output"
else
  format_ansi "$output"
fi
printf '\n'
