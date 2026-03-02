# Status Line Components

Each file in this directory defines one status line component. Components are
format-agnostic: they output a generic `[[token]]text[[/]]` string that is
converted to ANSI or Vim highlight syntax by the formatter.

## Adding a component

1. Create `scripts/components/myname.sh` with a `comp_myname()` function
2. Add `"myname"` to `statusline.layout` in `config.json` or your user config

No other files need to change.

## Component structure

```bash
#!/usr/bin/env bash
# scripts/components/myname.sh — one-line description

comp_myname() {
  local value
  value="$(read_state_field some_key)"
  [[ -n "$value" ]] || return 0
  printf '[[colorname]]%s[[/]]' "$value"
}

source "$(dirname "${BASH_SOURCE[0]}")/../lib/component-standalone.sh"
```

The `source` line at the bottom enables standalone execution (`bash
scripts/components/myname.sh SESSION_ID`) without duplicating any bootstrap
logic. See `lib/component-standalone.sh` for how it works.

## Token format

| Token          | Meaning                                      |
|----------------|----------------------------------------------|
| `[[name]]`     | Start colored span; name = `statusline.colors` key |
| `[[/]]`        | End span (reset)                             |
| `[[spacer]]`   | Flexible gap between left and right sections |

Color names (`working`, `ready`, `error`, `warning`, `branch`, `dim`) map to
hex values in `config.json` → `statusline.colors`. Add a new color there and
use it as a token immediately — no changes to the formatter needed.

## Environment

Components read all data from environment variables. Two sets are pre-populated
by `render-statusline.sh` before any component function is called:

**`CLAUDE_CONFIG_*`** — flattened config (from `_flatten_config` in `lib/config.sh`):
```
CLAUDE_CONFIG_statusline_icons_branch=🌿
CLAUDE_CONFIG_statusline_colors_branch=B1B9F5
```
`get_config` and `get_icon` check these first, falling back to jq if absent.

**`CLAUDE_STATE_*`** — flattened session state (from `_flatten_state` in `lib/state.sh`):
```
CLAUDE_STATE_branch=main
CLAUDE_STATE_state=working
```
`read_state_field` checks these first, falling back to reading the state file
via jq if absent.

Both sets are `export`ed, so they are also inherited by child processes such
as `scripts/component.sh` when called from Neovim.

**`SESSION_ID`** — the current Claude session ID. Set by `render-statusline.sh`
and `statusline.sh`. Used by `read_state_field` and `state_file_path` as the
fallback when `CLAUDE_STATE_*` vars are absent.

## Lib files

| File | Purpose |
|------|---------|
| `lib/config.sh` | `get_config`, `get_icon`, `_flatten_config` |
| `lib/state.sh`  | `read_state_field`, `state_file_path`, `_flatten_state` |
| `lib/format.sh` | `format_ansi`, `format_vim` — token converters |
| `lib/component-standalone.sh` | Generic standalone execution bootstrap |

## Rendering pipeline

```
statusline.sh          — resolves STATE_FILE from stdin, patches context/cost,
                         exports SESSION_ID, execs render-statusline.sh
  └─ render-statusline.sh  — _flatten_config + _flatten_state (2 jq calls total),
                             sources all components/*.sh, drives layout,
                             calls format_ansi or format_vim
       └─ components/*.sh  — pure functions; read env vars, output [[tokens]]
```

For Neovim, `vim.system` calls `render-statusline.sh SESSION_ID vim` with a
pre-built env table (config + state already decoded in Lua), so the two jq
calls are also eliminated on that path.
