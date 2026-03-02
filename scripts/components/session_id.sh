#!/usr/bin/env bash
# scripts/components/session_id.sh — short session ID component

comp_session_id() {
  local sid
  sid="$(read_state_field session_id)"
  [[ -n "$sid" ]] || return 0
  printf '[[dim]][%s][[/]]' "${sid:0:8}"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
