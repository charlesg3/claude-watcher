#!/usr/bin/env bash
# scripts/components/git_status.sh — git staged/modified file counts

comp_git_status() {
  local staged modified out=""
  staged="$(read_state_field git_staged)"
  modified="$(read_state_field git_modified)"
  [[ "${staged:-0}"   -gt 0 ]] && out+="$(get_icon 'staged')${staged}"
  [[ "${modified:-0}" -gt 0 ]] && out+="${out:+ }$(get_icon 'modified')${modified}"
  [[ -n "$out" ]] && printf '[[warning]]%s[[/]]' "$out"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
