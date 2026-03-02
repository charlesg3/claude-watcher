-- lua/claude-status/init.lua
-- claude-status Neovim plugin — entry point and public API.
--
-- Architecture:
--   sessions.lua  — terminal buffer ↔ Claude session mapping  (loaded now)
--   state.lua     — state file reading / caching              (TODO)
--   render.lua    — winbar / statusline component system      (TODO)
--
-- External callers (hooks via nvim --server --remote-expr) use the Vimscript
-- wrappers defined in plugin/claude-status.vim, which delegate here.
--
-- Setup:
--   require('claude-status').setup(opts)   -- call from your init.lua (optional)
--
-- Query from statusline / winbar:
--   require('claude-status').winbar()      -- returns formatted winbar string
--   require('claude-status').get_session_for_win([winnr])  -- session_id or nil

local M = {}

local sessions = require("claude-status.sessions")

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

-- Default config; overridden by setup() or vim.g.claude_status_* variables.
-- Extended as state.lua / render.lua are added.
M._config = {}

-- setup(opts)
-- Call once from your Neovim config to customise behaviour.
-- opts are merged into M._config; keys will be documented as the plugin grows.
function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", M._config, opts or {})
end

-- ---------------------------------------------------------------------------
-- Session / buffer API (delegates to sessions.lua)
-- ---------------------------------------------------------------------------

-- register(session_id, claude_pid)
-- Called by the SessionStart hook. Links the session to its terminal buffer.
function M.register(session_id, claude_pid)
  sessions.register(session_id, claude_pid)
  return "" -- remote-expr requires a return value
end

-- unregister(session_id)
-- Called by the SessionEnd hook. Removes the session mapping.
function M.unregister(session_id)
  sessions.unregister(session_id)
  return ""
end

-- get_session_for_win([winnr]) -> session_id or nil
-- Returns the Claude session_id for the buffer visible in the given window.
-- winnr defaults to the current window.
function M.get_session_for_win(winnr)
  local win = (winnr and winnr ~= 0)
    and vim.fn.win_getid(winnr)
    or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  return sessions.get_session(bufnr)
end

-- ---------------------------------------------------------------------------
-- Statusline / winbar
-- Stubs that will delegate to render.lua once that module is implemented.
-- ---------------------------------------------------------------------------

-- winbar() -> string
-- Returns the formatted winbar string for the current window.
-- Intended for use in: set winbar=%{%v:lua.require('claude-status').winbar()%}
function M.winbar()
  -- TODO: delegate to render.lua; read state via state.lua
  return ""
end

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

vim.api.nvim_create_autocmd("BufDelete", {
  callback = function(ev)
    sessions.on_buf_delete(ev.buf)
  end,
})

return M
