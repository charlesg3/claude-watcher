-- lua/claude-status/sessions.lua
-- Buffer ↔ Claude session mapping.
--
-- Maintains a table of { bufnr -> session_id } for every terminal buffer that
-- is hosting a Claude session.  The mapping is established by walking the
-- process tree upward from claude_pid until we find a PID that matches one of
-- Neovim's open terminal buffers (each terminal exposes its shell PID via the
-- buffer-local variable `terminal_job_pid`).
--
-- Public functions:
--   sessions.register(session_id, claude_pid)  -- called by SessionStart hook
--   sessions.unregister(session_id)            -- called by SessionEnd hook
--   sessions.on_buf_delete(bufnr)              -- called by BufDelete autocmd
--   sessions.get_session(bufnr)  -> session_id or nil
--   sessions.get_bufnr(session_id) -> bufnr or nil

local M = {}

-- { bufnr -> session_id }
M._buf_sessions = {}

-- ---------------------------------------------------------------------------
-- Process-tree helpers
-- ---------------------------------------------------------------------------

-- get_ppid(pid) -> number or nil
-- Returns the parent PID of `pid`.  Reads /proc on Linux; falls back to `ps`
-- on macOS/BSD.
local function get_ppid(pid)
  local f = io.open("/proc/" .. tostring(pid) .. "/status")
  if f then
    local content = f:read("*a")
    f:close()
    local ppid = content:match("PPid:%s*(%d+)")
    return ppid and tonumber(ppid)
  end
  -- macOS / BSD
  local result = vim.fn.system("ps -p " .. tostring(pid) .. " -o ppid=")
  if vim.v.shell_error == 0 then
    local ppid = result:match("%s*(%d+)")
    return ppid and tonumber(ppid)
  end
  return nil
end

-- terminal_pid_map() -> { job_pid -> bufnr }
-- Builds a snapshot of every open terminal buffer and its shell PID.
local function terminal_pid_map()
  local map = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[bufnr].buftype == "terminal" then
      local job_pid = vim.b[bufnr].terminal_job_pid
      if job_pid then
        map[job_pid] = bufnr
      end
    end
  end
  return map
end

-- find_terminal_buf(start_pid) -> bufnr or nil
-- Walks the process tree upward from start_pid (up to 10 hops) and returns
-- the bufnr of the first terminal buffer whose job PID appears in the chain.
local function find_terminal_buf(start_pid)
  local pid_to_buf = terminal_pid_map()
  local pid = start_pid
  for _ = 1, 10 do
    if not pid or pid <= 1 then break end
    if pid_to_buf[pid] then return pid_to_buf[pid] end
    local ppid = get_ppid(pid)
    if not ppid or ppid == pid then break end
    pid = ppid
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- register(session_id, claude_pid)
-- Links a Claude session to the terminal buffer running its process.
-- Called by the SessionStart hook via nvim --server --remote-expr.
function M.register(session_id, claude_pid)
  claude_pid = tonumber(claude_pid)
  if not session_id or not claude_pid then return end
  local bufnr = find_terminal_buf(claude_pid)
  if bufnr then
    M._buf_sessions[bufnr] = session_id
  end
end

-- unregister(session_id)
-- Removes the mapping for this session.
-- Called by the SessionEnd hook via nvim --server --remote-expr.
function M.unregister(session_id)
  for bufnr, sid in pairs(M._buf_sessions) do
    if sid == session_id then
      M._buf_sessions[bufnr] = nil
    end
  end
end

-- on_buf_delete(bufnr)
-- Removes the mapping for a buffer that is being deleted.
-- Wire this up to a BufDelete autocmd in init.lua.
function M.on_buf_delete(bufnr)
  M._buf_sessions[bufnr] = nil
end

-- get_session(bufnr) -> session_id or nil
function M.get_session(bufnr)
  return M._buf_sessions[bufnr]
end

-- get_bufnr(session_id) -> bufnr or nil
function M.get_bufnr(session_id)
  for bufnr, sid in pairs(M._buf_sessions) do
    if sid == session_id then return bufnr end
  end
  return nil
end

return M
