local M = {}

local config = require('liz_diff.config')

local state = {
  prompt_buf = nil,
  prompt_win = nil,
  results_buf = nil,
  results_win = nil,
}

function M.format_line(file)
  if file.binary then
    return string.format('%-2s %-50s [binary]', file.status, file.filepath)
  end
  return string.format('%-2s %-50s +%-4d -%d', file.status, file.filepath, file.insertions, file.deletions)
end

function M.is_open()
  return state.prompt_win ~= nil
    and vim.api.nvim_win_is_valid(state.prompt_win)
    and state.results_win ~= nil
    and vim.api.nvim_win_is_valid(state.results_win)
end

function M.focus()
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd('startinsert')
  end
end

function M.close()
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_win_close(state.prompt_win, true)
  end
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.api.nvim_win_close(state.results_win, true)
  end
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    vim.api.nvim_buf_delete(state.prompt_buf, { force = true })
  end
  if state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf) then
    vim.api.nvim_buf_delete(state.results_buf, { force = true })
  end
  state.prompt_buf = nil
  state.prompt_win = nil
  state.results_buf = nil
  state.results_win = nil
end

function M.set_prompt_text(text)
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { text })
  end
end

function M.get_cursor_index()
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    return vim.api.nvim_win_get_cursor(state.results_win)[1]
  end
  return 1
end

function M.set_results(lines, cursor_index)
  if not state.results_buf or not vim.api.nvim_buf_is_valid(state.results_buf) then
    return
  end
  vim.api.nvim_set_option_value('modifiable', true, { buf = state.results_buf })
  vim.api.nvim_buf_set_lines(state.results_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = state.results_buf })
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    local idx = math.min(cursor_index or 1, #lines)
    idx = math.max(idx, 1)
    vim.api.nvim_win_set_cursor(state.results_win, { idx, 0 })
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(state.results_win)
  end
end

function M.set_error(message)
  local lines = vim.split(message, '\n', { trimempty = true })
  if #lines == 0 then
    lines = { 'Unknown error' }
  end
  for i, line in ipairs(lines) do
    lines[i] = 'Error: ' .. line
  end
  M.set_results(lines, 1)
end

function M.set_empty(reference)
  local msg = reference == '' and 'No unstaged changes found' or ('No changes found for ' .. reference)
  M.set_results({ msg }, 1)
end

function M.open(on_submit, on_select, on_refresh)
  local cfg = config.get()
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local float_width = math.floor(editor_width * cfg.width)
  local float_height = math.floor(editor_height * cfg.height)
  local row = math.floor((editor_height - float_height) / 2)
  local col = math.floor((editor_width - float_width) / 2)

  local prompt_height = 1
  local results_height = float_height - prompt_height - 2

  state.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = state.prompt_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = state.prompt_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = state.prompt_buf })

  state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, true, {
    relative = 'editor',
    width = float_width,
    height = prompt_height,
    row = row,
    col = col,
    style = 'minimal',
    border = { '╭', '─', '╮', '│', '┤', '─', '├', '│' },
  })

  state.results_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = state.results_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = state.results_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = state.results_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = state.results_buf })
  vim.api.nvim_set_option_value('filetype', 'lizdiff', { buf = state.results_buf })

  state.results_win = vim.api.nvim_open_win(state.results_buf, false, {
    relative = 'editor',
    width = float_width,
    height = results_height,
    row = row + prompt_height + 1,
    col = col,
    style = 'minimal',
    border = { '├', '─', '┤', '│', '╯', '─', '╰', '│' },
  })
  vim.api.nvim_set_option_value('cursorline', true, { win = state.results_win })

  local placeholder_ns = vim.api.nvim_create_namespace('liz_diff_placeholder')
  vim.api.nvim_buf_set_extmark(state.prompt_buf, placeholder_ns, 0, 0, {
    virt_text = { { 'Enter git ref, or #<PR> / !<MR>... ', 'Comment' } },
    virt_text_pos = 'overlay',
    hl_mode = 'combine',
  })

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = state.prompt_buf,
    callback = function()
      local text = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ''
      if text ~= '' then
        vim.api.nvim_buf_clear_namespace(state.prompt_buf, placeholder_ns, 0, -1)
      else
        vim.api.nvim_buf_set_extmark(state.prompt_buf, placeholder_ns, 0, 0, {
          virt_text = { { 'Enter git ref, or #<PR> / !<MR>... ', 'Comment' } },
          virt_text_pos = 'overlay',
          hl_mode = 'combine',
        })
      end
    end,
  })

  local files_ref = {}

  local function submit()
    local text = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ''
    text = vim.trim(text)
    on_submit(text)
  end

  vim.keymap.set('i', '<CR>', submit, { buffer = state.prompt_buf })
  vim.keymap.set('n', '<CR>', submit, { buffer = state.prompt_buf })

  for _, key in ipairs(cfg.keymap.close) do
    vim.keymap.set('n', key, function() M.close() end, { buffer = state.prompt_buf })
  end

  local function select_file()
    local idx = vim.api.nvim_win_get_cursor(state.results_win)[1]
    if files_ref[idx] then
      on_select(files_ref[idx])
    end
  end

  vim.keymap.set('n', cfg.keymap.open_diff, select_file, { buffer = state.results_buf })

  if on_refresh then
    vim.keymap.set('n', cfg.keymap.refresh, function() on_refresh() end, { buffer = state.results_buf })
  end

  for _, key in ipairs(cfg.keymap.close) do
    vim.keymap.set('n', key, function() M.close() end, { buffer = state.results_buf })
  end

  vim.keymap.set('n', 'i', function()
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd('startinsert')
  end, { buffer = state.results_buf })

  vim.keymap.set('n', '/', function()
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd('startinsert')
  end, { buffer = state.results_buf })

  M._set_files_ref = function(files)
    files_ref = files
  end

  vim.cmd('startinsert')
end

return M
