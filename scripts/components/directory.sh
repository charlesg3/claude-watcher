#!/usr/bin/env bash
# scripts/components/directory.sh — working directory component

comp_directory() {
  local dir
  dir="$(read_state_field directory)"
  [[ -n "$dir" ]] || return 0
  # ##*/ strips longest prefix up to last slash — basename without subprocess
  printf '[[dim]]%s %s[[/]]' "$(get_icon 'directory')" "${dir##*/}"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
