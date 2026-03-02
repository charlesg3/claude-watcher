#!/usr/bin/env bash
# scripts/components/duration.sh — session duration component
#
# Computes elapsed time from session_start_epoch to now.

comp_duration() {
  local start
  start="$(read_state_field session_start_epoch)"
  [[ -n "$start" ]] || return 0

  local d=$(( ${MOCK_NOW:-$(date +%s)} - start ))
  local formatted
  if   (( d < 60   )); then formatted="${d}s"
  elif (( d < 3600 )); then formatted="$(printf '%dm %ds' $(( d/60 ))   $(( d%60 )))"
  else                       formatted="$(printf '%dh %dm' $(( d/3600 )) $(( (d%3600)/60 )))"
  fi

  printf '[[dim]]%s %s[[/]]' "$(get_icon 'duration')" "$formatted"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
