# claude-status

claude-status keeps you informed while Claude works — without requiring you to watch
the terminal. When a long task finishes or something goes wrong, it tells you through
whatever channel you prefer: a desktop notification, a sound, or an alert in your editor.

It works without Neovim and without a status bar. You can use as much or as little of
it as you want.

## Features

- **Desktop notifications** — native OS alerts when a task completes or errors; works on
  macOS and Linux; each channel gracefully skips if its tool is not installed
- **Sound alerts** — plays a sound file or picks a random sound from a folder; different
  sounds per event; adjustable volume
- **Neovim integration** — in-editor alerts posted to the Neovim instance that owns the
  Claude session; detects the right buffer automatically; "claude mode" API for statuslines
- **Optional status bar** — shows session state, git context, cost, and context usage;
  component-based so you enable only what you want; works with tmux or shell prompts
- **Highly configurable** — every channel can be tuned independently; per-channel
  thresholds control when each fires (instantly or after a delay); user config is never
  overwritten by updates

## Requirements

| Dependency | Purpose | macOS | Linux |
|---|---|---|---|
| `bash` 4+ | All scripts | pre-installed | pre-installed |
| `jq` | JSON config parsing | `brew install jq` | `apt install jq` |
| `afplay` | Sound notifications | pre-installed | — |
| `mpg123` | Sound notifications | — | `apt install mpg123` |
| `libnotify` (`notify-send`) | OS notifications | — | `apt install libnotify-bin` |
| `nvim` | Vim notifications + plugin | optional | optional |

Run `install.sh` to check and install OS dependencies automatically.

## Installation

### Step 1 — Base installation (always required)

```sh
git clone https://github.com/charlesg3/claude-status ~/src/claude-status
cd ~/src/claude-status
bash install.sh
```

Add the hooks to `~/.claude/settings.json` (see [Configuring Claude Hooks](#configuring-claude-hooks) below).

Optionally edit `~/.config/claude-status/config.json` to override defaults.

### Step 2 (optional) — Status bar or Neovim plugin

After the base installation you can add a status bar, the Neovim plugin, or both.
See [Status Bar Setup](#status-bar-setup) and [Neovim Plugin Configuration](#neovim-plugin-configuration).
The Neovim plugin can be used instead of the status bar.

**vim-plug**

```vim
Plug 'charlesg3/claude-status', {'rtp': '.'}
```

**lazy.nvim**

```lua
{
  'charlesg3/claude-status',
  config = function()
    -- optional: override defaults before setup
    vim.g.claude_status_notify_vim = true
    require('claude-status').setup()
  end,
}
```

**packer.nvim**

```lua
use {
  'charlesg3/claude-status',
  config = function() require('claude-status').setup() end,
}
```

**pathogen (submodule style)**

```sh
cd ~/.config/nvim  # or your nvim config root
git submodule add https://github.com/charlesg3/claude-status bundle/claude-status
```

Then in your `init.vim`:

```vim
execute pathogen#infect()
```

The `plugin/claude-status.vim` file loads automatically via pathogen.

## Configuration

Configuration is loaded by merging two JSON files:

1. `config/config.json` in the repo — global defaults, version-controlled
2. `~/.config/claude-status/config.json` — user overrides, never overwritten by updates

Keys present in the user file take precedence. Nested objects are merged one level deep;
arrays and scalars are replaced wholesale.

### Top-level keys

| Key | Default | Description |
|---|---|---|
| `project_name` | `"claude-status"` | Internal identifier |
| `config_dir` | `"~/.config/claude-status"` | Where user config and assets live |
| `state_dir` | `"/tmp"` | Where session state files are written |
| `log.file` | `"~/.local/share/claude-status/claude-status.log"` | Log path |
| `log.max_lines` | `500` | Log is trimmed to this many lines on rotation |
| `notifications.terminal.enabled` | `true` | Enable/disable terminal bell |
| `notifications.terminal.notification_threshold` | `0` | Seconds to wait before firing; `0` = immediate |
| `notifications.terminal.skip_kitty_active` | `true` | Skip if the Kitty tab is currently active |
| `notifications.terminal.skip_nvim_active` | `false` | Skip if the Claude buffer is the focused Neovim window |
| `notifications.sound.enabled` | `true` | Enable/disable sound |
| `notifications.sound.volume` | `0.7` | Volume (0.0–1.0) |
| `notifications.sound.path` | `null` | Sound file or directory to pick a random file from |
| `notifications.sound.notification_threshold` | `60` | Seconds to wait before firing; `0` = immediate |
| `notifications.sound.skip_kitty_active` | `false` | Skip if the Kitty tab is currently active |
| `notifications.sound.skip_nvim_active` | `false` | Skip if the Claude buffer is the focused Neovim window |
| `notifications.os.enabled` | `true` | Enable/disable OS desktop notifications |
| `notifications.os.notification_threshold` | `30` | Seconds to wait before firing; `0` = immediate |
| `notifications.os.skip_kitty_active` | `true` | Skip if the Kitty tab is currently active |
| `notifications.os.skip_nvim_active` | `false` | Skip if the Claude buffer is the focused Neovim window |
| `notifications.nvim.enabled` | `true` | Enable/disable Neovim popup notifications |
| `notifications.nvim.notification_threshold` | `15` | Seconds to wait before firing; `0` = immediate |
| `notifications.nvim.skip_kitty_active` | `false` | Skip if the Kitty tab is currently active |
| `notifications.nvim.skip_nvim_active` | `false` | Skip if the Claude buffer is the focused Neovim window |
| `notifications.nvim.notification` | (vim.notify call) | Vimscript expression evaluated in Neovim; `%SESSION_ID%` is substituted |
| `statusline.enabled` | `true` | Master switch for the status bar; disable to use notifications only |
| `statusline.components.*` | (all enabled) | Toggle individual status bar components |
| `statusline.icons.*` | (see config/config.json) | Unicode icons used in the status bar |
| `statusline.colors.*` | (see config/config.json) | Hex colors for status bar segments |

### Example user override

```json
{
  "notifications": {
    "sound": { "enabled": false },
    "os":    { "notification_threshold": 60 },
    "nvim":  { "notification_threshold": 0 }
  }
}
```

This disables sound entirely, delays OS notifications to 60 s, and fires the Neovim
alert immediately — useful when you are in the editor and want instant feedback without
being spammed by OS popups for quick tasks.

## Notification Events

claude-status fires notifications on two occasions: when a prompt finishes (`Stop`) and
when Claude needs your permission (`Notification`/permission_prompt).

When either fires, each enabled channel is evaluated in turn. Channels with
`notification_threshold: 0` fire immediately (e.g. terminal bell). Channels with a
non-zero threshold are handled by a single background timer; they fire after that many
seconds unless the session receives a new prompt or the Kitty tab becomes active first.

Each channel has independent `skip_kitty_active` and `skip_nvim_active` flags that
suppress it when you are already watching the terminal. For example, the Neovim popup
channel skips when the Claude buffer is the focused window, but still fires when you
have switched to editing another file.

## Configuring Claude Hooks

Add the following to `~/.claude/settings.json`. All hook events point to the same
dispatcher script, which inspects `hook_event_name` and dispatches accordingly.

Adjust the path to match wherever you cloned the repo (the example uses `~/src/claude-status`).

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "~/src/claude-status/hooks/claude-hook.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "~/src/claude-status/hooks/claude-hook.sh" }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          { "type": "command", "command": "~/src/claude-status/hooks/claude-hook.sh" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "~/src/claude-status/hooks/claude-hook.sh" }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "~/src/claude-status/hooks/claude-hook.sh" }
        ]
      }
    ]
  }
}
```

### Hook chaining

The dispatcher accepts extra positional arguments — each one is an additional script to
run after the built-in handling. The same hook input JSON is forwarded to each script via
stdin.

```json
{ "type": "command", "command": "~/src/claude-status/hooks/claude-hook.sh /path/to/my-script.sh" }
```

Your script receives the raw Claude hook JSON on stdin and can do anything with it.
Exit codes from chained scripts are logged but do not affect Claude's hook processing.

## Status Bar Setup

`scripts/statusline.sh` reads the session state file and prints a one-line formatted
string suitable for tmux or a shell prompt right side.

The status bar reads from a per-session state file in `/tmp`. When running a single
Claude session, a global fallback file is supported so the status bar always shows the
most recent session. Multi-session support (showing the state for the session tied to the
current window) is a known open problem — see the tracking issues for current status.

Toggle components in `config/config.json` under `statusline.components` — set `"enabled": false`
for any segment you don't want.

## Neovim Plugin Configuration

Call `setup()` in your Neovim config to override defaults:

```lua
require('claude-status').setup({
  interval = 1000,  -- statusline refresh interval in ms
})
```

| Option | Default | Description |
|---|---|---|
| `interval` | `1000` | How often (ms) the statusline polls the session state file |

Notification behaviour (channel enabled, thresholds, skip flags) is controlled by
`config/config.json` / `~/.config/claude-status/config.json` — not by plugin options.

## Troubleshooting

**Hooks are not firing**
Check the log at `~/.local/share/claude-status/claude-status.log`. Ensure `jq` is installed
and that the hooks script is executable (`chmod +x hooks/claude-hook.sh`).

**No OS notifications on Linux**
Install `libnotify-bin` (`apt install libnotify-bin`) and ensure a notification daemon
(e.g. `dunst`, `mako`) is running.

**No sound on Linux**
Install `mpg123` (`apt install mpg123`) and verify it can play a file directly:
`mpg123 /path/to/sound.mp3`.

**Neovim notifications not appearing**
The plugin requires Neovim to be started with `--listen` or for `$NVIM` to be set.
Check that `g:claude_status_notify_vim` is `1` and that the server socket path is
discoverable. Run `:echo serverlist()` in Neovim to verify.

**Hook not firing**
Confirm the path in `~/.claude/settings.json` is correct and the script is executable.
Test manually: `echo '{"hook_event_name":"Stop","session_id":"test"}' | bash hooks/claude-hook.sh`.

**Status bar shows nothing**
Check `/tmp/claude-status-*.json` for state files. The hook dispatcher creates one on the
first hook event. Verify the hook is configured correctly in `~/.claude/settings.json`.

## License

MIT — see [LICENSE](LICENSE) for details.
