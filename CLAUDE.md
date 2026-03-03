# claude-status

AI coding guide for the claude-status project.

## Project Overview

claude-status is a Claude Code hook dispatcher, status bar formatter, and Neovim plugin.
It connects Claude's hook events to OS notifications,
sounds, and the Neovim RPC server so the user always knows what Claude is doing, even
when they've switched away from its window.

## Repository Structure

| Path | Purpose |
|---|---|
| `hooks/claude-hook.sh` | Single dispatcher for all Claude hook events; chainable |
| `scripts/statusline.sh` | Claude `statusLine.command` entry point; resolves STATE_FILE from stdin, patches context_pct/cost_usd, delegates to render-statusline.sh |
| `scripts/render-statusline.sh` | Full statusline renderer; sources all component scripts in one process |
| `scripts/components/` | One script per statusline component (`state.sh`, `branch.sh`, `cost.sh`, etc.) |
| `scripts/lib/config.sh` | Loads and merges global + user config.json |
| `scripts/lib/notify.sh` | `notify_all`, `kitty_tab_active`, `nvim_active` helpers |
| `scripts/lib/notification-timer.sh` | Background timer process for deferred notification channels |
| `scripts/lib/format.sh` | `[[token]]` → ANSI / Vim highlight group converters |
| `config.json` | Global defaults (version-controlled) |
| `lua/claude-status/init.lua` | Neovim plugin — session/buffer mapping, statusline, nvim_active tracking |
| `lua/claude-status/sessions.lua` | Terminal buffer ↔ Claude session PID mapping |
| `plugin/claude-status.vim` | Neovim plugin entry point; exposes `ClaudeStatusRegister/Unregister` |
| `install.sh` | OS dependency detection and setup |
| `tests/test-statusline.sh` | Unit tests for status bar output |
| `tests/mock-event.sh` | Fire synthetic hook events for manual testing |
| `tests/test-vim.lua` | Headless Neovim tests for the Lua plugin |
| `CHANGELOG.md` | Keepachangelog format; updated on every PR merge |
| `CLAUDE.md` | This file |

## Development Setup

This plugin lives at `nvim/bundle/claude-status/` inside the dotfiles nvim submodule.
During active development it is NOT treated as a git submodule — it is a plain git repo
checked out directly. `update.sh` skips it. Once development churn settles, it will be
added as a proper submodule.

```sh
cd ~/.config/nvim/bundle/claude-status   # or wherever you checked it out
bash install.sh                           # install OS deps
```

## Branch & PR Naming

- Feature branches:  `feat/issue#-short-kebab-desc`  (e.g. `feat/3-hook-dispatcher`)
- Bug branches:      `bug/issue#-short-kebab-desc`   (e.g. `bug/7-state-file-race`)
- Chore branches:    `chore/issue#-short-kebab-desc` (e.g. `chore/9-lint-scripts`)
- Every branch must have an issue number — create one with `/add-issue` if needed.
- PRs must reference the issue they close: **"Closes #N"** in the PR body.

## Versioning

This project uses **continuous patch/minor releases** — every merged PR produces a new
version tag.

- By default, merging a PR bumps the **patch** version (e.g. `0.1.0` → `0.1.1`).
- If the PR is labelled **`minor`**, the **minor** version is bumped and patch resets to
  zero (e.g. `0.1.3` → `0.2.0`).
- Major version bumps are manual.
- Update `CHANGELOG.md` before merging: add an entry under `[Unreleased]` with the
  correct version heading and date. Use the `/changelog` skill to draft it.

## Commit Style

Format: `[{feat|bug|chore}/KEBAB-DESCRIPTION] short imperative summary`

```
[feat/hook-dispatcher] add single entry-point hook dispatcher

Overview of what is changing and why, with context for the reader.

Changes:
- hooks/claude-hook.sh: new dispatcher reads hook_event_name from stdin
- scripts/common.sh: source shared helpers

Caveats:
- depends on watcher (#2) for full lifecycle management

closes #1
```

- No "Co-Authored-By: Claude" lines
- First line ≤ 72 characters; imperative mood, present tense
- Body: overview paragraph + bulleted change list + caveats if relevant
- Always include `refs #N` or `closes #N` — warn if missing
- One logical change per commit

## README Guidelines

Features in `README.md` should describe what the user **experiences**, not how the
system works internally. Avoid mentioning implementation details (polling intervals,
process management, config merge strategy, script names, etc.) in the Features section.
When adding or changing a feature, update the relevant README section to reflect the
user-visible change — but keep descriptions high-level and benefit-focused.

## Notification Philosophy

Notifications should be **rare, high-signal, and non-intrusive**. The goal is to
surface moments when Claude needs your attention — not to narrate every tool call.

There is exactly one notification trigger: **`notification`** — fired when a prompt
completes (`Stop`) or Claude needs permission (`Notification`/`permission_prompt`).

When a notification fires, each channel is evaluated in order (`terminal`, `sound`, `os`,
`vim`). A channel is skipped if `enabled` is false. Otherwise:

- `notification_threshold: 0` — fires immediately in the hook process (e.g. terminal bell,
  Neovim alert).
- `notification_threshold: N` — deferred to a single background timer process that sleeps
  N seconds, then fires the channel (after re-checking whether the Kitty tab is active).

Only one background timer PID runs per session at a time. Cancellation (on
`UserPromptSubmit`, `PreToolUse`, `SessionEnd`) sends SIGTERM to that process, which
interrupts the sleep via `wait` and exits cleanly.

Do not add notifications for routine events (every tool use, every file read, status
updates, etc.). If a new notification channel or trigger is proposed, ask: "would this
become noise within a day of normal use?" If yes, it should not be a default-on event.

## Dependencies

When adding a new OS-level dependency:
1. Add a check block (and an install branch) for it in `install.sh`'s `check_deps()`.
2. Add a row to the requirements table in `README.md`.

Neovim plugin dependencies (airline, lualine, nvim-notify, etc.) are **not managed by
`install.sh`** and must never be added to it. Users install these via their own plugin
manager. Document optional integrations in the section below.

## Optional Neovim Integrations

| Plugin | Integration | Status |
|---|---|---|
| `nvim-notify` | `vim.notify()` calls are routed through nvim-notify automatically if installed | Working |
| `vim-airline` | Airline is disabled on Claude terminal windows; our statusline replaces it | Working |
| `lualine.nvim` | Provide a lualine component for claude state + last-status dot | Planned |

## Architecture

- **Hook dispatcher pattern** — a single entry-point script reads `hook_event_name` from
  stdin JSON and calls the appropriate handler. Handles: `SessionStart`,
  `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`. All other events are ignored.
- **State files in /tmp** — each Claude session writes a JSON state file at
  `/tmp/claude-status-SESSION_ID.json`. The statusline reads this file.
  Writing is atomic (write to `.tmp`, then `mv`).
- **Config merge strategy** — `scripts/lib/config.sh` reads `config.json` (repo
  defaults), then deep-merges `~/.config/claude-status/config.json` (user overrides)
  using `jq *`. User values win at every key.
- **Nvim remote-expr bridge** — hooks call `nvim --server $NVIM --remote-expr` to
  invoke `ClaudeStatusRegister/Unregister` in the running Neovim instance.
- **Statusline refresh timer** — the Lua plugin uses `vim.uv.new_timer()` to
  periodically call `render-statusline.sh vim` and update the cached statusline string.
- **`nvim_active` tracking** — the Lua plugin writes `nvim_active: true/false` to the
  session state file whenever window focus changes. The notification timer reads this to
  skip the nvim channel when the user is already looking at the Claude buffer.
- **Config precedence** — settings resolution order (highest wins): 1)
  `~/.config/claude-status/config.json` (user overrides); 2) `config.json` in repo
  (shipped defaults).

### Data flow and field sources

| Field | Source |
|---|---|
| `state` | hooks: `SessionStart` (ready), `UserPromptSubmit` (working), `Stop` (ready) |
| `directory` | hooks: cwd from each event payload |
| `branch` | hooks: `git rev-parse --abbrev-ref HEAD` |
| `git_staged` | hooks: `git diff --cached --numstat \| wc -l` |
| `git_modified` | hooks: `git diff --numstat \| wc -l` |
| `claude_pid` | `SessionStart` hook: PID of the Claude process (walks up past shell wrappers) |
| `duration_seconds` | `Stop` hook: `now - prompt_start_epoch` |
| `context_pct` | `statusLine` stdin: `100 - context_window.remaining_percentage` |
| `cost_usd` | `statusLine` stdin: `cost.total_cost_usd` |

`context_pct` and `cost_usd` are **not present in any hook payload**. They arrive
exclusively via `statusLine.command` stdin. `scripts/statusline.sh` patches them
back into STATE_FILE after each render so other renderers (e.g. the winbar timer)
can read the latest values.

### statusLine data flow

Claude calls `statusLine.command` on every render, piping live session JSON on stdin:

```json
{
  "session_id": "abc123",
  "context_window": { "remaining_percentage": 30.0 },
  "cost": { "total_cost_usd": 0.123 }
}
```

`scripts/statusline.sh` detects stdin input (no `STATE_FILE` env var, stdin is a
pipe), auto-locates STATE_FILE as `/tmp/claude-status-SESSION_ID.json`, computes
`context_pct = floor(100 - remaining_percentage)`, patches both fields into
STATE_FILE atomically, then renders the status line as normal.

When `STATE_FILE` is set explicitly (test / tmux mode), stdin is ignored entirely.

### Hook wiring (required events)

Configure these five hook events to point at `hooks/claude-hook.sh`:

| Event | Handler action |
|---|---|
| `SessionStart` | write_state: session_id, directory, branch, git info, model, claude_pid |
| `UserPromptSubmit` | patch_state: state=working, prompt_start_epoch, git refresh |
| `Notification` | fire ready notifications (permission_prompt / idle_prompt); update state to "waiting" |
| `Stop` | patch_state: state=ready, duration_seconds; fire ready notifications |
| `SessionEnd` | cancel notification timer; remove state file (see #44) |

`PreToolUse`, `PostToolUse`, and `SubagentStop` are not needed — the dispatcher
ignores them, so wiring them just adds unnecessary overhead.

## Config System

| File | Role |
|---|---|
| `config.json` (repo) | Shipped defaults; do not edit for personal preferences |
| `~/.config/claude-status/config.json` | User overrides; never overwritten by install/update |

The merge is performed with `jq`. Nested objects are merged one level deep; scalars and
arrays are replaced by the user value.

### Null-punning convention

`get_config` always returns an **empty string** when a key is absent or JSON-null.
Never check `[[ "$val" != "null" ]]` in calling code — just check `[[ -n "$val" ]]`.
The function strips the literal string `"null"` defensively so callers never see it.

JSON `false` is returned as the string `"false"` so that boolean config keys work
correctly. jq's `// empty` operator treats `false` the same as `null` (swallows it),
so `get_config` uses `if .key == null then empty else tostring end` internally instead.

## State Files

Each running Claude session produces `/tmp/claude-status-SESSION_ID.json`:

```json
{
  "session_id": "abc123",
  "state": "working",
  "directory": "/home/user/project",
  "branch": "feat/3-watcher-health",
  "git_staged": 2,
  "git_modified": 1,
  "context_pct": 58,
  "cost_usd": 0.042,
  "prompt_start_epoch": 1700000000,
  "duration_seconds": 12,
  "claude_pid": 12345,
  "nvim_active": true
}
```

Fields are updated by hook events. The statusline script reads this file and formats it
for display.

## Testing

```sh
# Status bar unit tests
bash tests/test-statusline.sh

# List available mock events
bash tests/mock-event.sh --list

# Fire a specific mock event
bash tests/mock-event.sh Stop

# Headless Neovim plugin tests
nvim --headless -l tests/test-vim.lua
```

Tests are in the `tests/` directory. Mock events are JSON payloads that replicate what
Claude would send via stdin to the hook dispatcher. Headless Neovim tests load the
plugin and exercise the Lua API without a GUI.

## What to omit from public artifacts

Do **not** mention `CLAUDE.md` in commits, CHANGELOG.md entries, PR descriptions, or GitHub issues. It is an internal AI guide, not a user-visible file. Treat it like an internal implementation note.

## Skills

| Skill | Command | Purpose |
|---|---|---|
| add-issue | `/add-issue` | Create a new GitHub issue with labels |
| issues | `/issues` | List open issues grouped by component |
| commit | `/commit` | Stage and commit with proper message format |
| pr | `/pr` | Create a PR with correct naming, labels, and issue reference |
| changelog | `/changelog` | Update CHANGELOG.md from commits and issues |
| test | `/test` | Run the test suite and report results |

## Adding New Features

1. Create a GitHub issue with `/add-issue` — note the issue number N
2. Create a branch: `git checkout -b feat/N-short-desc`
3. Implement the feature, writing tests alongside the code
4. Run `bash tests/test-statusline.sh` and `nvim --headless -l tests/test-vim.lua`
5. Update `CHANGELOG.md` with `/changelog`
6. Commit with `/commit` — include `closes #N` in the message
7. Open a PR with `/pr` — body must contain "Closes #N"; add label `minor` if appropriate
8. Merge the PR; the version bumps automatically per the versioning rules above
