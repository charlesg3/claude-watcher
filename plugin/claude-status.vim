" plugin/claude-status.vim — claude-status Neovim plugin entry point.
"
" Loads the Lua plugin and exposes Vimscript functions that hooks can call via:
"   nvim --server $NVIM --remote-expr "ClaudeStatusRegister(session_id, pid)"
"   nvim --server $NVIM --remote-expr "ClaudeStatusUnregister(session_id)"

if exists('g:loaded_claude_status') | finish | endif
let g:loaded_claude_status = 1

lua require('claude-status')

" ---------------------------------------------------------------------------
" Hook entry points (remote-expr targets)
" ---------------------------------------------------------------------------

function! ClaudeStatusRegister(session_id, claude_pid) abort
  return luaeval("require('claude-status').register(_A[1], _A[2])",
        \ [a:session_id, a:claude_pid])
endfunction

function! ClaudeStatusUnregister(session_id) abort
  return luaeval("require('claude-status').unregister(_A)", a:session_id)
endfunction

" ClaudeStatusIsClaudeWin([winnr]) -> session_id string (truthy) or v:null (falsy)
function! ClaudeStatusIsClaudeWin(...) abort
  return luaeval("require('claude-status').get_session_for_win(_A)",
        \ get(a:, 1, 0))
endfunction
