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

  vim.cmd('vsplit')
  vim.cmd('enew')
  local ref_buf = vim.api.nvim_get_current_buf()

  local ref_lines = vim.split(ref_content, '\n')
  if ref_lines[#ref_lines] == '' then
    ref_lines[#ref_lines] = nil
  end
  vim.api.nvim_buf_set_lines(ref_buf, 0, -1, false, ref_lines)

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = ref_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = ref_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = ref_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = ref_buf })

  local ref_label = reference == '' and 'INDEX' or reference
  vim.api.nvim_buf_set_name(ref_buf, 'liz-diff://' .. ref_label .. '/' .. file.filepath)

  local ft = vim.filetype.match({ filename = file.filepath }) or ''
  vim.api.nvim_set_option_value('filetype', ft, { buf = ref_buf })

  vim.cmd('diffthis')

  ref_buffers[#ref_buffers + 1] = ref_buf

  vim.api.nvim_set_current_win(right_win)
end

return M
