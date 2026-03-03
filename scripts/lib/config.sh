#!/usr/bin/env bash
# scripts/lib/config.sh — config loading and merging for claude-status
#
# SOURCE this file; do not execute it directly.
#
# Merges two JSON files (highest precedence last):
#   1. <project>/config/config.json   — shipped defaults
#   2. ~/.config/claude-status/config.json  — user overrides
#
# The merge uses jq's * operator (recursive object merge); user values win at
# every key. Arrays and scalars are replaced wholesale.
#
# Functions:
#   get_config KEY [DEFAULT]   — print value for a dotted jq path, or DEFAULT
#
# Environment:
#   CONFIG_OVERRIDE   — path to an alternate user config (used by tests)

# ---------------------------------------------------------------------------
# Locate repo root from this file's own path
# ---------------------------------------------------------------------------
_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_PROJECT_DIR="$(cd "$_CONFIG_LIB_DIR/../.." && pwd)"
_CONFIG_PROJECT_FILE="$_CONFIG_PROJECT_DIR/config/config.json"

# ---------------------------------------------------------------------------
# _build_config — merge repo + user config; print merged JSON to stdout.
# Called once and cached in _CLAUDE_MERGED_CONFIG.
# ---------------------------------------------------------------------------
_CLAUDE_MERGED_CONFIG=""

_build_config() {
  if [[ -n "$_CLAUDE_MERGED_CONFIG" ]]; then
    printf '%s' "$_CLAUDE_MERGED_CONFIG"
    return
  fi

  if [[ ! -f "$_CONFIG_PROJECT_FILE" ]]; then
    _CLAUDE_MERGED_CONFIG="{}"
    printf '{}'
    return
  fi

  local user_config="${CONFIG_OVERRIDE:-${HOME}/.config/claude-status/config.json}"
  local merged

  if [[ -f "$user_config" ]]; then
    merged=$(jq -s '.[0] * .[1]' "$_CONFIG_PROJECT_FILE" "$user_config" 2>/dev/null) \
      || merged="{}"
  else
    merged=$(jq '.' "$_CONFIG_PROJECT_FILE" 2>/dev/null) || merged="{}"
  fi

  _CLAUDE_MERGED_CONFIG="$merged"
  printf '%s' "$merged"
}

# ---------------------------------------------------------------------------
# _flatten_config
#
# Flattens the merged config JSON into CLAUDE_CONFIG_* environment variables.
# Call this once in a parent script before invoking any component functions.
# All subsequently called functions (get_config, get_icon) will read from
# these env vars directly, skipping jq entirely.
#
# Flattening uses jq leaf_paths to walk every non-object leaf in the tree.
# Path segments are joined with underscores to form valid env var names:
#   statusline.icons.branch  →  CLAUDE_CONFIG_statusline_icons_branch=🌿
#
# Arrays (e.g. statusline.layout) are expanded to indexed keys:
#   statusline.layout[0]  →  CLAUDE_CONFIG_statusline_layout_0=state
# These are not used by get_config (array access falls back to jq), but they
# do not interfere with anything.
#
# Null values are filtered out; booleans become the strings "true"/"false".
# ---------------------------------------------------------------------------
_flatten_config() {
  local json
  json="$(_build_config)"

  while IFS= read -r line; do
    local key="${line%%=*}"
    local value="${line#*=}"
    # export so child processes (component.sh, standalone calls) inherit them
    export "CLAUDE_CONFIG_${key}=${value}"
  done < <(printf '%s' "$json" | jq -r '
    [paths(scalars) as $p | {
      key: ($p | map(tostring) | join("_")),
      value: getpath($p)
    }]
    | .[]
    | select(.value != null)
    | "\(.key)=\(.value | tostring)"
  ')
}

# ---------------------------------------------------------------------------
# get_config KEY [DEFAULT]
#
# Prints the value at the given jq key path.
# If the key is absent or null, prints DEFAULT (empty string if not given).
#
# Fast path: checks CLAUDE_CONFIG_* env vars populated by _flatten_config.
# Dots in KEY are converted to underscores to match the flattened var names.
# Falls back to jq when the env var is absent (e.g. first call before
# _flatten_config, or for array-valued keys which are not cached as strings).
#
# Examples:
#   get_config 'log.file'
#   get_config 'notifications.os.notification_threshold' '30'
# ---------------------------------------------------------------------------
get_config() {
  local key="$1"
  local default="${2:-}"

  # Fast path: env var populated by _flatten_config (no jq, no file I/O).
  # Dots converted to underscores to match flattened key names.
  local env_key="CLAUDE_CONFIG_${key//./_}"
  local cached="${!env_key:-}"
  if [[ -n "$cached" ]]; then
    printf '%s' "$cached"
    return
  fi

  # Fallback: extract from merged JSON via jq.
  # Use `if null then empty else tostring end` instead of `// empty` so that
  # JSON false is returned as the string "false" rather than being swallowed.
  # jq's // operator treats both null AND false as absent, which is wrong for
  # boolean config keys like statusline.enabled.
  local val
  val=$(_build_config \
    | jq -r "if .${key} == null then empty else (.${key} | tostring) end" \
    2>/dev/null)
  [[ "$val" == "null" ]] && val=""
  if [[ -z "$val" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# ---------------------------------------------------------------------------
# get_icon NAME [DEFAULT]
#
# Shorthand for get_config on the statusline.icons subtree.
#
# Examples:
#   get_icon 'branch' '🌿'
#   get_icon 'working' '↻'
# ---------------------------------------------------------------------------
get_icon() {
  get_config "statusline.icons.${1}" "${2:-}"
}

