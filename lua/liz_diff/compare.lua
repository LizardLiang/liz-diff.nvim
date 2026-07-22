-- Git-agnostic "stage two files, diff them" flow. Deliberately independent of
-- liz_diff.git / liz_diff.diff's git plumbing: the compare list is just two
-- file paths, and the vimdiff it opens works on any two files regardless of
-- whether either is tracked. No plenary at runtime — the float in this module
-- is built on nvim_open_win only (plenary is used by tests exclusively).
local M = {}

-- Module-level two-slot compare list: up to two normalized absolute paths.
-- Transient (not cached/persisted) — cleared by M.clear() or a fresh :edit.
local list = {}

-- Normalizes `path` to an absolute, separator-collapsed form so the same file
-- staged via a differently-separated path is recognized as one compare-list
-- entry. On Windows only, the result is ALSO case-folded (vim.fs.normalize
-- alone only uppercases the drive letter and leaves the rest as-typed) so a
-- differently-cased path to the same file on case-insensitive NTFS is
-- recognized too; Unix paths are left case-sensitive, matching the
-- filesystem. Pure and exported so the normalization rule is directly
-- unit-testable.
function M.normalize(path)
  local norm = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if vim.fn.has('win32') == 1 then
    norm = norm:lower()
  end
  return norm
end

-- Stages `path` into the compare list. Returns:
--   'duplicate' - the normalized path is already staged; list unchanged.
--   'added'     - a free slot existed; path appended; list mutated.
--   'full'      - two distinct files are already staged; list unchanged.
-- Pure/testable: only touches the module-level list, no notifications or
-- Neovim window/buffer calls (those live in M.add below).
function M.stage(path)
  local norm = M.normalize(path)
  for _, existing in ipairs(list) do
    if existing == norm then
      return 'duplicate'
    end
  end
  if #list >= 2 then
    return 'full'
  end
  list[#list + 1] = norm
  return 'added'
end

-- Replaces list[slot] (slot in {1, 2}) with `path`. Rejects ('duplicate')
-- when the normalized path equals the OTHER slot, leaving the list
-- untouched; otherwise overwrites the slot and returns 'replaced'.
function M.replace(slot, path)
  local norm = M.normalize(path)
  local other = slot == 1 and 2 or 1
  if list[other] == norm then
    return 'duplicate'
  end
  list[slot] = norm
  return 'replaced'
end

-- Returns a copy of the staged list so callers can't mutate compare state by
-- holding onto the returned table.
function M.get()
  return vim.deepcopy(list)
end

-- Empties the compare list. Pure (no notification) — the user-facing
-- :LizDiffClear command notifies after calling through.
function M.clear()
  list = {}
end

local SIDES = { 'LEFT', 'RIGHT' }

-- Centered pure-Lua float on a scratch (buftype=nofile, bufhidden=wipe)
-- buffer, sized to `lines` (pattern mirrors ui.lua's prompt/results floats,
-- lines 115-145 — no plenary dependency). `keymaps` is a list of
-- `{ key, fn }`; each fn is invoked with a `close` callback so it can act
-- (e.g. replace + notify) before dismissing the float. `q` and `<Esc>` always
-- close without invoking any extra fn.
local function open_float(lines, keymaps)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, #line + 2)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.8))
  local height = math.min(math.max(#lines, 1), math.floor(vim.o.lines * 0.8))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  for _, km in ipairs(keymaps or {}) do
    vim.keymap.set('n', km.key, function() km.fn(close) end, { buffer = buf })
  end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })

  return buf, win
end

-- M.add(): stages the CURRENT buffer's file. Reuses diff.current_buffer_path
-- for the exact same guard sequence diff.open_current uses (empty name ->
-- liz-diff:// reference buffer -> non-empty buftype), each a no-op INFO
-- notify, so the two call sites share one implementation instead of two
-- independently-drifting copies. Dispatches on M.stage's result: 'added'
-- notifies the new (n/2) count, 'duplicate' notifies it's already staged,
-- 'full' opens the replace picker instead of staging.
function M.add()
  local abs = require('liz_diff.diff').current_buffer_path('liz-diff: cannot stage a liz-diff reference buffer')
  if not abs then
    return
  end

  local result = M.stage(abs)
  if result == 'added' then
    local staged = M.get()
    vim.notify(string.format('liz-diff: staged %s (%d/2)', staged[#staged], #staged), vim.log.levels.INFO)
  elseif result == 'duplicate' then
    vim.notify('liz-diff: ' .. M.normalize(abs) .. ' is already staged', vim.log.levels.INFO)
  else -- 'full'
    M.prompt_replace(M.normalize(abs))
  end
end

-- M.prompt_replace(incoming): shown by M.add() when the list is already full.
-- Lists the two staged files with their LEFT/RIGHT slot plus the incoming
-- file; pressing 1/2 replaces that slot (M.replace already rejects a value
-- equal to the other slot as a duplicate) and notifies the outcome; q/<Esc>
-- cancels, leaving the pair untouched.
function M.prompt_replace(incoming)
  local staged = M.get()
  local lines = { 'liz-diff compare: list is full (2/2)', '' }
  for i, path in ipairs(staged) do
    lines[#lines + 1] = string.format('[%d] %-5s %s', i, SIDES[i], path)
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'incoming: ' .. incoming
  lines[#lines + 1] = ''
  lines[#lines + 1] = '[1] replace slot 1 (LEFT)   [2] replace slot 2 (RIGHT)   [q] cancel'

  local function replace_slot(slot)
    return function(close)
      local result = M.replace(slot, incoming)
      if result == 'duplicate' then
        vim.notify('liz-diff: ' .. incoming .. ' is already staged in the other slot', vim.log.levels.INFO)
      else
        vim.notify(
          string.format('liz-diff: replaced slot %d (%s) with %s', slot, SIDES[slot], incoming),
          vim.log.levels.INFO
        )
      end
      close()
    end
  end

  open_float(lines, {
    { key = '1', fn = replace_slot(1) },
    { key = '2', fn = replace_slot(2) },
  })
end

-- M.show_list(): read-only float listing the staged files with their slot and
-- LEFT/RIGHT assignment, or an empty-state message. Closes on q/<Esc>.
function M.show_list()
  local staged = M.get()
  local lines
  if #staged == 0 then
    lines = { 'liz-diff compare: no files staged', '', '[q] close' }
  else
    lines = { 'liz-diff compare list:', '' }
    for i, path in ipairs(staged) do
      lines[#lines + 1] = string.format('[%d] %-5s %s', i, SIDES[i], path)
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '[q] close'
  end
  open_float(lines, {})
end

-- M.compare(): opens the staged pair as real, editable file buffers in a
-- two-pane vimdiff — first-staged file LEFT, second-staged RIGHT, forced
-- regardless of 'splitright' (the plugin's one shared working-side-LEFT
-- layout rule). Guards on fewer than two staged files (INFO, reports the
-- count) and on a staged file missing from disk (WARN naming it, abort
-- before either pane opens). Tears down any prior liz-diff reference panes
-- via diff.cleanup_previous() first, matching :LizDiffFile.
function M.compare()
  local staged = M.get()
  if #staged < 2 then
    vim.notify(string.format('liz-diff: need two files to compare, %d staged', #staged), vim.log.levels.INFO)
    return
  end

  for _, path in ipairs(staged) do
    if not vim.uv.fs_stat(path) then
      vim.notify('liz-diff: staged file no longer exists: ' .. path, vim.log.levels.WARN)
      return
    end
  end

  require('liz_diff.diff').cleanup_previous()

  vim.cmd('edit ' .. vim.fn.fnameescape(staged[1]))
  vim.cmd('diffthis')
  local left_win = vim.api.nvim_get_current_win()

  -- Force the second pane to the RIGHT regardless of the user's 'splitright'.
  vim.cmd('rightbelow vsplit')
  vim.cmd('edit ' .. vim.fn.fnameescape(staged[2]))
  vim.cmd('diffthis')

  vim.api.nvim_set_current_win(left_win)
end

return M
