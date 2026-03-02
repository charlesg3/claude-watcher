#!/usr/bin/env bash
# scripts/components/cost.sh — session cost component

comp_cost() {
  local cost
  cost="$(read_state_field cost_usd)"
  [[ -n "$cost" ]] || return 0
  printf '[[warning]]%s$%.2f[[/]]' "$(get_icon 'cost')" "$cost"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
