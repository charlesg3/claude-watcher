#!/usr/bin/env bash
# scripts/components/context.sh — context window usage bar
#
# Shows a 10-char fill bar and percentage.
# Color transitions: green < 50% → orange 50-79% → red ≥ 80%

comp_context() {
  local pct
  pct="$(read_state_field context_pct)"
  [[ -n "$pct" ]] || return 0

  local color="ready"
  [[ "$pct" -ge 50 ]] && color="warning"
  [[ "$pct" -ge 80 ]] && color="error"

  local filled=$(( pct / 10 )) empty i bar="" void=""
  empty=$(( 10 - filled ))
  for (( i=0; i<filled; i++ )); do bar+='█'; done
  for (( i=0; i<empty;  i++ )); do void+='░'; done

  printf '[[%s]]%s[[/]][[dim]]%s[[/]] %s%%' "$color" "$bar" "$void" "$pct"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
