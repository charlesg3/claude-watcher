#!/usr/bin/env bash
# scripts/components/branch.sh — git branch component

comp_branch() {
  local branch
  branch="$(read_state_field branch)"
  [[ -n "$branch" ]] || return 0
  printf '[[branch]]%s %s[[/]]' "$(get_icon 'branch')" "$branch"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
