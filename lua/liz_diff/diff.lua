local git = require('liz_diff.git')

local M = {}

local ref_buffers = {}

function M.cleanup_previous()
  for _, buf in ipairs(ref_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      local wins = vim.fn.win_findbuf(buf)
      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end
  ref_buffers = {}
end

-- Builds the reference buffer name: `liz-diff://<label>/<path>`, with an
-- optional ` (new file)` suffix when the path doesn't exist at the reference.
local function ref_buffer_name(label, path, is_new_file)
  local name = 'liz-diff://' .. label .. '/' .. path
  if is_new_file then
    name = name .. ' (new file)'
  end
  return name
end

-- Opens a vsplit forced to `direction` ('leftabove' or 'rightbelow'),
-- overriding the user's 'splitright' setting, and creates the read-only
-- reference-side scratch buffer inside it: filled with `content` (trailing
-- newline trimmed), named `name`, filetype `filetype`, and marked
-- buftype=nofile/bufhidden=wipe/noswapfile/nomodifiable. Marks it for
-- diffthis and tracks it in ref_buffers for the next cleanup_previous().
-- The new window is left focused; callers restore focus afterward.
local function open_ref_pane(direction, content, name, filetype)
  vim.cmd(direction .. ' vsplit')
  vim.cmd('enew')
  local ref_buf = vim.api.nvim_get_current_buf()

  local lines = vim.split(content, '\n')
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  vim.api.nvim_buf_set_lines(ref_buf, 0, -1, false, lines)

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = ref_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = ref_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = ref_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = ref_buf })

  vim.api.nvim_buf_set_name(ref_buf, name)
  vim.api.nvim_set_option_value('filetype', filetype, { buf = ref_buf })

  vim.cmd('diffthis')
  ref_buffers[#ref_buffers + 1] = ref_buf

  return ref_buf
end

function M.open(reference, file)
  if file.binary then
    vim.notify('liz-diff: binary file, cannot diff', vim.log.levels.INFO)
    return
  end

  M.cleanup_previous()

  local source_path
  if file.status == 'R' and file.old_path then
    source_path = file.old_path
  else
    source_path = file.filepath
  end

  local ref_content = ''
  if file.status ~= 'A' then
    local rev = reference == '' and ':' or (reference .. ':')
    local result = vim.fn.system({ 'git', 'show', rev .. source_path })
    if vim.v.shell_error == 0 then
      ref_content = result
    end
  end

  if file.status == 'D' then
    vim.cmd('enew')
    local del_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = del_buf })
    vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = del_buf })
    vim.api.nvim_buf_set_name(del_buf, '[deleted] ' .. file.filepath)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(file.filepath))
  end

  vim.cmd('diffthis')
  local right_win = vim.api.nvim_get_current_win()

  local ref_label = reference == '' and 'INDEX' or reference
  local ft = vim.filetype.match({ filename = file.filepath }) or ''

  -- Force the new window to the LEFT regardless of the user's 'splitright'.
  open_ref_pane('leftabove', ref_content, ref_buffer_name(ref_label, file.filepath), ft)

  vim.api.nvim_set_current_win(right_win)
end

-- M.open_current(reference): diffs the CURRENT buffer's file against `reference`.
-- Intentionally the OPPOSITE side order of M.open above: the live working
-- buffer stays on the LEFT, the reference/commit content goes on the RIGHT.
-- Do not "fix" this to match M.open — it is the deliberate, user-requested
-- layout for the zero-prompt current-file command.
function M.open_current(reference)
  local buf = 0
  local abs = vim.api.nvim_buf_get_name(buf)
  if abs == '' then
    vim.notify('liz-diff: no file in current buffer', vim.log.levels.INFO)
    return
  end

  if abs:match('^liz%-diff://') then
    vim.notify('liz-diff: cannot diff a liz-diff reference buffer', vim.log.levels.INFO)
    return
  end

  if vim.bo[buf].buftype ~= '' then
    vim.notify('liz-diff: no file in current buffer', vim.log.levels.INFO)
    return
  end

  local dir = vim.fn.fnamemodify(abs, ':h')

  -- `git -C dir rev-parse --show-prefix` scopes the repo lookup to the
  -- buffer's own directory (not Neovim's process cwd) and doubles as the
  -- repo guard: non-zero shell_error means `dir` isn't inside a work tree.
  -- It also sidesteps the Windows case-mismatch that broke a manual
  -- absolute-path prefix-strip (on-disk canonical case vs buffer name case).
  local prefix_lines = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', '--show-prefix' })
  if vim.v.shell_error ~= 0 then
    vim.notify('liz-diff: not a git repository', vim.log.levels.WARN)
    return
  end
  local prefix = prefix_lines[1] or ''
  local relpath = prefix .. vim.fn.fnamemodify(abs, ':t')

  M.cleanup_previous()

  local out = vim.fn.system({ 'git', '-C', dir, 'show', reference .. ':' .. relpath })
  local ok = vim.v.shell_error == 0
  local ref_content = ok and out or ''
  -- A new file exists on disk but not in `reference`; show a blank reference
  -- side (marked below) instead of surfacing git's "exists on disk" error.
  local is_new_file = (not ok) and git.is_new_file(dir, reference, relpath)

  vim.cmd('diffthis')
  local left_win = vim.api.nvim_get_current_win()

  local ft = vim.filetype.match({ filename = relpath }) or ''

  -- Force the new window to the RIGHT regardless of the user's 'splitright'.
  open_ref_pane('rightbelow', ref_content, ref_buffer_name(reference, relpath, is_new_file), ft)

  vim.api.nvim_set_current_win(left_win)
end

return M
