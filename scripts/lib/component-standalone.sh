#!/usr/bin/env bash
# scripts/lib/component-standalone.sh — generic standalone execution bootstrap
#
# SOURCE this file at the bottom of every component script (one line).
# It enables a component to be executed directly for debugging or called
# individually from Neovim, without duplicating bootstrap logic in each file.
#
# Usage — add this as the last line of every component file:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
#
# How it works:
#   When render-statusline.sh sources a component file:
#     BASH_SOURCE[1] = component file (e.g. branch.sh)
#     $0             = render-statusline.sh
#     → condition false, nothing runs; comp_* function is simply defined
#
#   When a component file is executed directly:
#     BASH_SOURCE[1] = component file (e.g. branch.sh)
#     $0             = component file (e.g. branch.sh)
#     → condition true; libs sourced, function invoked with $1 as SESSION_ID
#
# The component function name is derived from the filename automatically,
# so this block is identical across all component files with no edits needed.

if [[ "${BASH_SOURCE[1]}" == "$0" ]]; then
  _COMP_DIR="$(cd "$(dirname "$0")" && pwd)"
  source "$_COMP_DIR/../lib/config.sh"
  source "$_COMP_DIR/../lib/state.sh"
  export SESSION_ID="${1:?Usage: $(basename "$0") SESSION_ID}"
  "comp_$(basename "$0" .sh)"
fi
