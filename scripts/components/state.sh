#!/usr/bin/env bash
# scripts/components/state.sh — Claude session state component

comp_state() {
  local state
  state="$(read_state_field state)"
  case "$state" in
    working) printf '[[working]]%s working[[/]]' "$(get_icon 'working')" ;;
    ready)   printf '[[ready]]%s ready[[/]]'     "$(get_icon 'ready')"   ;;
    *)       printf '[[dim]]%s[[/]]' "${state:-?}" ;;
  esac
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
