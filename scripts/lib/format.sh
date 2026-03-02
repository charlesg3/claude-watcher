#!/usr/bin/env bash
# scripts/lib/format.sh — token-to-escape-sequence converters
#
# Components output a generic intermediate format using [[token]] markers.
# These functions convert those tokens to the target format in one pass.
#
# Token format:
#   [[name]]    — start a colored span; name matches a statusline.colors key
#   [[/]]       — end the current span (reset to default style)
#   [[spacer]]  — flexible gap between left and right sections
#
# Special tokens ([[/]] and [[spacer]]) are handled explicitly.
# All other tokens are resolved generically:
#   ANSI  — looks up statusline.colors.<name> from env/config → truecolor escape
#   Vim   — converts to %#ClaudeStatus<Name># highlight group
#
# SOURCE this file; do not execute it directly.

# ---------------------------------------------------------------------------
# format_ansi STRING
#
# Converts [[tokens]] to ANSI truecolor escape sequences for terminal output.
#
# Color hex values are read from CLAUDE_CONFIG_statusline_colors_* env vars
# (populated by _flatten_config), falling back to get_config if absent.
# [[spacer]] is stripped — render-statusline.sh handles terminal spacing.
# ---------------------------------------------------------------------------
format_ansi() {
  local s="$1"
  # $'...' syntax interprets \033 as the actual ESC character
  local reset=$'\033[0m'

  # Handle the two special-case tokens first
  s="${s//\[\[\/\]\]/$reset}"
  s="${s//\[\[spacer\]\]/}"

  # Resolve remaining [[name]] tokens generically.
  # Each iteration handles one unique token name; bash substitution replaces
  # all occurrences of that token in a single pass.
  while [[ "$s" =~ \[\[([a-z_]+)\]\] ]]; do
    local token="${BASH_REMATCH[1]}"

    # Read hex color: env var (fast path, no jq) or get_config fallback
    local varname="CLAUDE_CONFIG_statusline_colors_${token}"
    local hex="${!varname:-}"
    [[ -z "$hex" ]] && hex="$(get_config "statusline.colors.${token}" '')"

    # Build ANSI truecolor escape, or empty string if color not configured
    local esc=""
    if [[ -n "$hex" ]]; then
      hex="${hex#\#}"
      esc="$(printf '\033[38;2;%d;%d;%dm' \
        "$((16#${hex:0:2}))" "$((16#${hex:2:2}))" "$((16#${hex:4:2}))")"
    fi

    s="${s//\[\[$token\]\]/$esc}"
  done

  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# format_vim STRING
#
# Converts [[tokens]] to Neovim statusline/winbar %#GroupName# syntax.
#
# [[name]] becomes %#ClaudeStatus<Name># where <Name> is the token with its
# first letter capitalised. Highlight groups are defined by the Lua plugin.
#
# [[spacer]] becomes %=, Neovim's built-in separator that pushes content
# to the right edge — no width calculation needed.
# ---------------------------------------------------------------------------
format_vim() {
  local s="$1"

  # Handle the two special-case tokens first
  s="${s//\[\[\/\]\]/%#Normal#}"
  s="${s//\[\[spacer\]\]/%=}"

  # Convert remaining [[name]] tokens to %#ClaudeStatus<Name># generically.
  # ${token^} capitalises the first character (bash 4+).
  while [[ "$s" =~ \[\[([a-z_]+)\]\] ]]; do
    local token="${BASH_REMATCH[1]}"
    local group="ClaudeStatus${token^}"
    s="${s//\[\[$token\]\]/%#${group}#}"
  done

  printf '%s' "$s"
}
