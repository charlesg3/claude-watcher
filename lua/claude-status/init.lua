-- lua/claude-status/init.lua
-- claude-status Neovim plugin — entry point and public API.
--
-- Architecture:
--   sessions.lua  — terminal buffer ↔ Claude session mapping  (loaded now)
--   state.lua     — state file reading / caching              (TODO)
--
-- External callers (hooks via nvim --server --remote-expr) use the Vimscript
-- wrappers defined in plugin/claude-status.vim, which delegate here.
--
-- Setup (optional, call from your init.lua):
--   require('claude-status').setup({ interval = 1000 })
--
-- Requires Neovim 0.10+ (vim.system).

local M = {}

local sessions = require("claude-status.sessions")

-- ---------------------------------------------------------------------------
-- Plugin root — derived from this file's path.
-- init.lua lives at lua/claude-status/init.lua; root is three levels up.
-- ---------------------------------------------------------------------------
local _plugin_root = vim.fn.fnamemodify(
  debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local _render_script = _plugin_root .. "/scripts/render-statusline.sh"

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

M._config = {
  interval = 1000, -- statusline refresh interval in ms
}

function M.setup(opts)
  M._config = vim.tbl_deep_extend("force", M._config, opts or {})
end

-- ---------------------------------------------------------------------------
-- Config helpers
-- ---------------------------------------------------------------------------

local function _read_json(path)
  if vim.fn.filereadable(path) == 0 then return nil end
  local ok, decoded = pcall(
    vim.fn.json_decode,
    table.concat(vim.fn.readfile(path), "\n")
  )
  return ok and decoded or nil
end

local function _merged_config()
  local cfg = _read_json(_plugin_root .. "/config.json") or {}
  local user = _read_json(vim.fn.expand("~/.config/claude-status/config.json"))
  if user then cfg = vim.tbl_deep_extend("force", cfg, user) end
  return cfg
end

-- State file directory — read once at load time from the merged config.
local _state_dir = _merged_config().state_dir or "/tmp"

-- ---------------------------------------------------------------------------
-- Highlight groups
--
-- Names are derived generically from statusline.colors keys in config.json:
--   working → ClaudeStatusWorking
--   dim     → ClaudeStatusDim
--   etc.
--
-- Colors come from the merged config (repo defaults + user overrides) so
-- there are no magic numbers here — edit config.json to change them.
-- Re-applied after ColorScheme events so they survive theme switches.
-- ---------------------------------------------------------------------------

-- _load_colors() -> { token -> "#rrggbb" }
local function _load_colors()
  return (_merged_config().statusline or {}).colors or {}
end

local function _setup_highlights()
  -- Use Normal's background on all groups so the statusline has a uniform
  -- background — without this, grouped spans use StatusLine's bg while
  -- %#Normal# resets use Normal's bg, causing visible banding.
  local normal_bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg

  for token, hex in pairs(_load_colors()) do
    if hex and hex ~= "" then
      -- Capitalise first letter: "working" → "ClaudeStatusWorking"
      local group = "ClaudeStatus" .. token:sub(1, 1):upper() .. token:sub(2)
      vim.api.nvim_set_hl(0, group, { fg = hex, bg = normal_bg })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Render cache and refresh timer
--
-- _render_cache: { session_id -> rendered_string }
-- One shared timer drives periodic refreshes for all active sessions.
-- The timer starts on the first register() and stops when no sessions remain.
-- ---------------------------------------------------------------------------

local _render_cache = {}
local _timer = nil

-- ---------------------------------------------------------------------------
-- nvim_active tracking
--
-- Writes nvim_active=true/false to the session state file when a Claude
-- terminal buffer becomes visible in (or disappears from) all windows.
-- Only writes when the value in the file differs from the desired value.
--
-- A session is active if its buffer is the one shown in the current window.
-- ---------------------------------------------------------------------------

-- _patch_nvim_active(session_id, active)
-- Reads the state file, compares nvim_active, and writes back atomically
-- only if the value has changed.
local function _patch_nvim_active(session_id, active)
  local state_file = _state_dir .. "/claude-status-" .. session_id .. ".json"
  local f = io.open(state_file, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()

  local ok, state = pcall(vim.fn.json_decode, content)
  if not ok or type(state) ~= "table" then return end
  if state.nvim_active == active then return end

  state.nvim_active = active
  local tmp = state_file .. ".tmp"
  local out = io.open(tmp, "w")
  if not out then return end
  out:write(vim.fn.json_encode(state) .. "\n")
  out:close()
  os.rename(tmp, state_file)
end

-- _update_nvim_active()
-- For every registered session, sets nvim_active=true only if the current
-- window is showing that session's buffer.
local function _update_nvim_active()
  local cur_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  for bufnr, session_id in pairs(sessions._buf_sessions) do
    _patch_nvim_active(session_id, bufnr == cur_buf)
  end
end

-- _refresh_session(session_id)
-- Runs render-statusline.sh asynchronously for one session, updates the cache,
-- and triggers a statusline redraw on completion.
local function _refresh_session(session_id)
  vim.system(
    { _render_script, "vim" },
    { env = { SESSION_ID = session_id } },
    function(result)
      if result.code == 0 then
        -- strip trailing newline the shell script appends
        local s = (result.stdout or ""):gsub("\n$", "")
        _render_cache[session_id] = s
        vim.schedule(function()
          vim.cmd("redrawstatus!")
        end)
      end
    end
  )
end

local function _start_timer()
  if _timer then return end
  local uv = vim.uv or vim.loop
  _timer = uv.new_timer()
  _timer:start(
    M._config.interval,
    M._config.interval,
    vim.schedule_wrap(function()
      local seen = {}
      for _, session_id in pairs(sessions._buf_sessions) do
        if not seen[session_id] then
          seen[session_id] = true
          _refresh_session(session_id)
        end
      end
    end)
  )
end

local function _stop_timer()
  if not _timer then return end
  _timer:stop()
  _timer:close()
  _timer = nil
end

-- ---------------------------------------------------------------------------
-- Window statusline management
--
-- For Claude terminal windows: disable airline and install our statusline.
-- For all other windows: restore airline and the default statusline.
-- ---------------------------------------------------------------------------

local _statusline_expr = "%{%v:lua.require('claude-status').statusline()%}"

local function _update_win(win)
  win = win or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local session_id = sessions.get_session(bufnr)
  if session_id then
    vim.api.nvim_win_set_var(win, "airline_disabled", 1)
    vim.wo[win].statusline = _statusline_expr
    -- airline#update_statusline() bails early when the active window has
    -- airline_disabled=1 (set above), so other windows never receive their
    -- inactive statuslines (w:airline_active stays 1, mode indicator stays live).
    -- Drive the inactive update manually: collect all other windows and call
    -- airline#update_statusline_inactive() from a non-disabled proxy window so
    -- airline's own stl_disabled(winnr()) guard passes.
    local range, proxy = {}, nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= win then
        local nr = vim.fn.win_id2win(w)
        if nr > 0 then
          table.insert(range, nr)
          if not proxy then
            -- Use airline's own stl_disabled check so we skip any window
            -- airline won't render (w:airline_disabled, b:airline_disable_statusline, etc.)
            local ok, stl_dis = pcall(vim.fn["airline#util#stl_disabled"], nr)
            if ok and stl_dis == 0 then proxy = w end
          end
        end
      end
    end
    if proxy then
      vim.api.nvim_win_call(proxy, function()
        pcall(vim.fn["airline#update_statusline_inactive"], range)
      end)
    end
  else
    -- Only restore airline if this window previously had airline_disabled set
    -- (i.e. it was a Claude or managed window). Calling setlocal statusline< on
    -- every regular window on every WinEnter would wipe airline's statuslines.
    local had_disabled = pcall(vim.api.nvim_win_del_var, win, "airline_disabled")
    if had_disabled then
      vim.api.nvim_win_call(win, function()
        vim.cmd("setlocal statusline<")
      end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Session / buffer API (delegates to sessions.lua)
-- ---------------------------------------------------------------------------

-- register(session_id, claude_pid)
-- Called by the SessionStart hook. Links the session to its terminal buffer,
-- installs the custom statusline, starts the refresh timer, and renders once.
function M.register(session_id, claude_pid)
  sessions.register(session_id, claude_pid)
  local bufnr = sessions.get_bufnr(session_id)
  if bufnr then
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      _update_win(win)
    end
  end
  _start_timer()
  _refresh_session(session_id)
  _update_nvim_active()
  return "" -- remote-expr requires a return value
end

-- unregister(session_id)
-- Called by the SessionEnd hook. Restores airline and clears cached content.
function M.unregister(session_id)
  local bufnr = sessions.get_bufnr(session_id) -- capture before unregistering
  sessions.unregister(session_id)
  _render_cache[session_id] = nil
  if not next(sessions._buf_sessions) then
    _stop_timer()
  end
  -- Schedule the window reset so it runs after the remote-expr call returns.
  -- Airline needs a proper event-loop cycle to notice the change.
  vim.schedule(function()
    if bufnr then
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        _update_win(win)
      end
    end
    pcall(vim.cmd, "AirlineRefresh")
    vim.cmd("redrawstatus!")
  end)
  return ""
end

-- get_session_for_win([winnr]) -> session_id or nil
-- Returns the Claude session_id for the buffer visible in the given window.
-- winnr defaults to the current window (0).
function M.get_session_for_win(winnr)
  local win = (winnr and winnr ~= 0)
    and vim.fn.win_getid(winnr)
    or vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  return sessions.get_session(bufnr)
end

-- ---------------------------------------------------------------------------
-- Statusline
-- ---------------------------------------------------------------------------

-- statusline() -> string
-- Returns the formatted statusline string for the current window's session.
-- Called from the local statusline expression set by _update_win().
--
-- The mode indicator is evaluated at draw time (not cached) so it updates
-- immediately on mode changes. 't' = terminal mode (typing) → I, else → N.
function M.statusline()
  local bufnr = vim.api.nvim_win_get_buf(0)
  local session_id = sessions.get_session(bufnr)
  if not session_id then return "" end

  local mode     = vim.fn.mode()
  local mode_hl  = (mode == "t") and "ClaudeStatusWorking" or "ClaudeStatusDim"
  local mode_chr = (mode == "t") and "I" or "N"
  local indicator = "%#" .. mode_hl .. "# " .. mode_chr .. "%#Normal#"

  return indicator .. (_render_cache[session_id] or "")
end

-- bell()
-- Called via ClaudeStatusBell() remote-expr from the ring_bell() hook helper.
-- Writes BEL directly to /dev/tty from Neovim's process context, where
-- /dev/tty is Kitty's pty (not the terminal-buffer pty Claude uses).
-- Respects visualbell and belloff so user preferences are honoured.
function M.bell()
  if vim.o.visualbell then return "" end
  for _, v in ipairs(vim.split(vim.o.belloff or "", ",", { trimempty = true })) do
    if v == "all" then return "" end
  end
  local f = io.open("/dev/tty", "w")
  if f then
    f:write("\a")
    f:flush()
    f:close()
  end
  return ""
end

-- winbar() kept as an alias so existing callers don't break.
M.winbar = M.statusline

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

-- Re-install our statusline when switching into a Claude window.
vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
  callback = function() _update_win() end,
})

vim.api.nvim_create_autocmd("BufDelete", {
  callback = function(ev)
    local session_id = sessions.get_session(ev.buf)
    sessions.on_buf_delete(ev.buf)
    if session_id then
      _render_cache[session_id] = nil
    end
    if not next(sessions._buf_sessions) then
      _stop_timer()
    end
  end,
})

-- Update nvim_active in the state file when the focused window changes.
-- WinEnter fires when the user moves focus; BufWinEnter/BufWinLeave cover
-- splits and :hide; WinClosed covers :q.
-- vim.schedule defers until after the window list has settled.
vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "BufWinLeave", "WinClosed" }, {
  callback = function() vim.schedule(_update_nvim_active) end,
})

-- Re-apply highlights after any colour scheme change (themes reset them).
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = _setup_highlights,
})

_setup_highlights()

return M
