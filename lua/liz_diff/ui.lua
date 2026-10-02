local M = {}

local config = require('liz_diff.config')

local state = {
  prompt_buf = nil,
  prompt_win = nil,
  results_buf = nil,
  results_win = nil,
  filter_buf = nil,
  filter_win = nil,
  files = {},
  picker_id = 0,
  closing = false,
  refresh_filter_placeholder = function() end,
}

local PROMPT_PLACEHOLDER = 'Enter git ref, or #<PR> / !<MR>... '
local FILTER_PLACEHOLDER = 'Filter by name or .ext... '

function M.format_line(file)
  if file.binary then
    return string.format('%-2s %-50s [binary]', file.status, file.filepath)
  end
  return string.format('%-2s %-50s +%-4d -%d', file.status, file.filepath, file.insertions, file.deletions)
end

-- Pure matcher behind the filter float. Whitespace-separated terms, matched
-- case-insensitively against the full filepath: a term starting with `.` or
-- `*.` is an extension term (path ends with it, several are OR'ed); any other
-- term is a literal substring (several are AND'ed). A file must satisfy both
-- groups. Order is preserved; an empty query returns every file.
function M.filter_files(files, query)
  local exts, names = {}, {}
  for term in (query or ''):lower():gmatch('%S+') do
    local ext = term:match('^%*?(%..+)$')
    if ext then
      exts[#exts + 1] = ext
    else
      names[#names + 1] = term
    end
  end

  local result = {}
  for _, file in ipairs(files) do
    local path = file.filepath:lower()
    local ok = #exts == 0
    for _, ext in ipairs(exts) do
      if path:sub(-#ext) == ext then
        ok = true
        break
      end
    end
    if ok then
      for _, name in ipairs(names) do
        if not path:find(name, 1, true) then
          ok = false
          break
        end
      end
    end
    if ok then
      result[#result + 1] = file
    end
  end
  return result
end

function M.no_match_message(query)
  return string.format('No files match "%s"', vim.trim(query))
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

-- Overlays `text` as a dim hint on line 1 of `buf` while the line is empty.
-- Returns the refresh function to call after the buffer text changes.
local function attach_placeholder(buf, text)
  local ns = vim.api.nvim_create_namespace('liz_diff_placeholder')
  return function()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or '') == '' then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
        virt_text = { { text, 'Comment' } },
        virt_text_pos = 'overlay',
        hl_mode = 'combine',
      })
    end
  end
end

function M.is_open()
  return win_valid(state.prompt_win) and win_valid(state.results_win) and win_valid(state.filter_win)
end

function M.focus()
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd('startinsert')
  end
end

function M.close()
  state.closing = true
  for _, win in ipairs({ state.prompt_win, state.results_win, state.filter_win }) do
    if win_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.prompt_buf, state.results_buf, state.filter_buf }) do
    if buf_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.filter_buf = nil
  state.filter_win = nil
  state.prompt_buf = nil
  state.prompt_win = nil
  state.results_buf = nil
  state.results_win = nil
  state.files = {}
  state.closing = false
end

function M.set_prompt_text(text)
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { text })
  end
end

function M.is_filter_focused()
  return win_valid(state.filter_win) and vim.api.nvim_get_current_win() == state.filter_win
end

function M.get_filter_text()
  if buf_valid(state.filter_buf) then
    return vim.api.nvim_buf_get_lines(state.filter_buf, 0, 1, false)[1] or ''
  end
  return ''
end

function M.set_filter_text(text)
  if buf_valid(state.filter_buf) then
    vim.api.nvim_buf_set_lines(state.filter_buf, 0, -1, false, { text })
    state.refresh_filter_placeholder()
  end
end

function M.get_cursor_index()
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    return vim.api.nvim_win_get_cursor(state.results_win)[1]
  end
  return 1
end

function M.set_results(lines, cursor_index, keep_focus)
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
    if not keep_focus then
      vim.cmd('stopinsert')
      vim.api.nvim_set_current_win(state.results_win)
    end
  end
end

-- Files behind the result rows, indexed by row. This is the one list <CR>
-- selects from; message rows carry none.
function M.set_files(files)
  state.files = files
end

function M.get_files()
  return state.files
end

-- Shows non-selectable message rows.
function M.set_message(lines, keep_focus)
  state.files = {}
  M.set_results(lines, 1, keep_focus)
end

function M.set_error(message)
  local lines = vim.split(message, '\n', { trimempty = true })
  if #lines == 0 then
    lines = { 'Unknown error' }
  end
  for i, line in ipairs(lines) do
    lines[i] = 'Error: ' .. line
  end
  M.set_message(lines)
end

-- Pure message builder, extracted from set_empty() so the wording can be
-- unit-tested without a live results buffer/window.
function M.empty_message(reference)
  return reference == '' and 'No uncommitted changes found' or ('No changes found for ' .. reference)
end

function M.set_empty(reference)
  M.set_message({ M.empty_message(reference) })
end

function M.open(on_submit, on_select, on_refresh, on_filter)
  M.close()
  state.picker_id = state.picker_id + 1
  local picker_id = state.picker_id
  local cfg = config.get()
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local float_width = math.floor(editor_width * cfg.width)
  local float_height = math.floor(editor_height * cfg.height)
  local row = math.floor((editor_height - float_height) / 2)
  local col = math.floor((editor_width - float_width) / 2)

  local prompt_height = 1
  local filter_height = 1
  local results_height = math.max(float_height - prompt_height - filter_height - 3, 1)

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

  state.filter_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = state.filter_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = state.filter_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = state.filter_buf })

  state.filter_win = vim.api.nvim_open_win(state.filter_buf, false, {
    relative = 'editor',
    width = float_width,
    height = filter_height,
    row = row + prompt_height + 1,
    col = col,
    style = 'minimal',
    border = { '├', '─', '┤', '│', '┤', '─', '├', '│' },
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
    row = row + prompt_height + filter_height + 2,
    col = col,
    style = 'minimal',
    border = { '├', '─', '┤', '│', '╯', '─', '╰', '│' },
  })
  vim.api.nvim_set_option_value('cursorline', true, { win = state.results_win })

  local refresh_prompt_placeholder = attach_placeholder(state.prompt_buf, PROMPT_PLACEHOLDER)
  state.refresh_filter_placeholder = attach_placeholder(state.filter_buf, FILTER_PLACEHOLDER)
  refresh_prompt_placeholder()
  state.refresh_filter_placeholder()

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = state.prompt_buf,
    callback = refresh_prompt_placeholder,
  })

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = state.filter_buf,
    callback = function()
      state.refresh_filter_placeholder()
      if on_filter then
        on_filter(M.get_filter_text())
      end
    end,
  })

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
    if state.files[idx] then
      on_select(state.files[idx])
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

  if cfg.keymap.filter then
    vim.keymap.set('n', cfg.keymap.filter, function()
      vim.api.nvim_set_current_win(state.filter_win)
      vim.cmd('startinsert!')
    end, { buffer = state.results_buf })
  end

  local function focus_results()
    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(state.results_win)
  end

  vim.keymap.set('i', '<CR>', focus_results, { buffer = state.filter_buf })
  vim.keymap.set('i', '<Esc>', focus_results, { buffer = state.filter_buf })
  vim.keymap.set('n', '<CR>', focus_results, { buffer = state.filter_buf })

  for _, key in ipairs(cfg.keymap.close) do
    vim.keymap.set('n', key, function() M.close() end, { buffer = state.filter_buf })
  end

  -- Closing any one of the three floats closes the picker.
  for _, win in ipairs({ state.prompt_win, state.filter_win, state.results_win }) do
    vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(win),
      once = true,
      callback = function()
        if state.closing then
          return
        end
        vim.schedule(function()
          if state.picker_id == picker_id then
            M.close()
          end
        end)
      end,
    })
  end

  vim.cmd('startinsert')
end

return M
