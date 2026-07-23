local git = require('liz_diff.git')

local M = {}

-- Namespace + duration for the :LizDiffPaths blink overlay (extmark
-- virt_lines pinned above each diff pane, cleared after PATHS_BLINK_MS).
local PATHS_NS = vim.api.nvim_create_namespace('liz_diff_paths')
local PATHS_BLINK_MS = 2000

-- Bumped on every M.show_paths() call; the deferred auto-clear captures its
-- own generation and no-ops if a later invocation has superseded it. Without
-- this guard, two show_paths() calls within PATHS_BLINK_MS race: the first
-- call's stale deferred clear fires and wipes the second call's fresh
-- overlay early instead of letting it run its own full PATHS_BLINK_MS (PO-5).
local paths_generation = 0

local ref_buffers = {}

-- Buffers carrying the buffer-local ]f / [f nav keymaps. Tracked separately
-- from ref_buffers because the raw-ref LEFT pane is the user's real working
-- file buffer (not wiped on cleanup) — its keymaps must be deleted explicitly
-- so no lingering plugin mapping survives the diff session.
local nav_mapped_buffers = {}

local function nav_keys()
  local cfg = require('liz_diff.config').get().keymap
  local keys = {}
  if type(cfg.next_file) == 'string' and cfg.next_file ~= '' then
    keys[#keys + 1] = { key = cfg.next_file, fn = function() require('liz_diff').next() end }
  end
  if type(cfg.prev_file) == 'string' and cfg.prev_file ~= '' then
    keys[#keys + 1] = { key = cfg.prev_file, fn = function() require('liz_diff').prev() end }
  end
  return keys
end

-- Also clears the :LizDiffPaths blink overlay (PATHS_NS) from every
-- nav-mapped buffer — notably the non-wiped LEFT working buffer — so no
-- stale path overlay survives into the next diff session (PO-7).
local function clear_nav_keymaps()
  local keys = nav_keys()
  for _, buf in ipairs(nav_mapped_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, k in ipairs(keys) do
        pcall(vim.keymap.del, 'n', k.key, { buffer = buf })
      end
      vim.api.nvim_buf_clear_namespace(buf, PATHS_NS, 0, -1)
    end
  end
  nav_mapped_buffers = {}
end

-- Sets the configured next/previous-file keymaps on each valid buffer so the
-- user can cycle files from whichever diff pane is focused. Callbacks require
-- 'liz_diff' lazily (require is cached) to avoid an init<->diff load cycle.
local function set_nav_keymaps(bufs)
  local keys = nav_keys()
  for _, buf in ipairs(bufs) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for _, k in ipairs(keys) do
        vim.keymap.set('n', k.key, k.fn, { buffer = buf })
      end
      nav_mapped_buffers[#nav_mapped_buffers + 1] = buf
    end
  end
end

function M.cleanup_previous()
  clear_nav_keymaps()
  for _, buf in ipairs(ref_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      local wins = vim.fn.win_findbuf(buf)
      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
          -- pcall guards the last-window case (E444): when a PR diff's two
          -- panes are the only windows, the second close fails; the forced
          -- buffer delete below then repurposes that window instead.
          pcall(vim.api.nvim_win_close, win, true)
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
-- Exported (pure, no Neovim window/buffer calls) so pane naming is directly
-- unit-testable without standing up real splits.
function M.ref_buffer_name(label, path, is_new_file)
  local name = 'liz-diff://' .. label .. '/' .. path
  if is_new_file then
    name = name .. ' (new file)'
  end
  return name
end

-- M.open's reference rev/label for a given prompt reference: empty prompt
-- now means "against HEAD" (all uncommitted changes), matching git.lua's
-- M.diff baseline change. Exported for the same reason as ref_buffer_name.
function M.ref_rev(reference)
  return reference == '' and 'HEAD:' or (reference .. ':')
end

function M.ref_label(reference)
  return reference == '' and 'HEAD' or reference
end

-- Fills the CURRENT window with a fresh read-only reference scratch buffer:
-- `content` (trailing newline trimmed), named `name`, filetype `filetype`,
-- marked buftype=nofile/bufhidden=wipe/noswapfile/nomodifiable, marked for
-- diffthis, and tracked in ref_buffers for the next cleanup_previous().
-- `display_path`, when given, is stashed as vim.b[buf].liz_diff_path — the
-- <ref>:<repo-absolute path> string M.pane_path()/:LizDiffPaths reads for
-- this virtual pane, computed here while root/relpath/ref are in scope.
local function fill_scratch(content, name, filetype, display_path)
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

  if display_path then
    vim.b[ref_buf].liz_diff_path = display_path
  end

  vim.cmd('diffthis')
  ref_buffers[#ref_buffers + 1] = ref_buf

  return ref_buf
end

-- Opens a vsplit forced to `direction` ('leftabove' or 'rightbelow'),
-- overriding the user's 'splitright' setting, then fills the new window with a
-- read-only reference scratch buffer via fill_scratch. The new window is left
-- focused; callers restore focus afterward.
local function open_ref_pane(direction, content, name, filetype, display_path)
  vim.cmd(direction .. ' vsplit')
  return fill_scratch(content, name, filetype, display_path)
end

-- Resolves the reference-pane content for a M.open() selection. Always
-- attempts `git -C root show ref_rev..source_path` regardless of the file's
-- listed status (that status may be stale — e.g. restored from cache). On
-- success returns the content. On failure, distinguishes a genuinely new file
-- (absent from ref_label's tree, via git.is_new_file's locale-independent
-- exit-code check) from an unexpected failure: the latter carries a non-nil
-- `warning` message (naming the file, including git's trimmed output) so the
-- caller can notify instead of silently blanking the pane. Kept separate from
-- window/buffer setup so this contract is unit-testable with a mocked
-- vim.fn.system, without standing up real Neovim splits.
function M.resolve_ref_content(root, ref_rev, ref_label, source_path)
  local out = vim.fn.system({ 'git', '-C', root, 'show', ref_rev .. source_path })
  if vim.v.shell_error == 0 then
    return out, false, nil
  end

  local is_new = git.is_new_file(root, ref_label, source_path)
  if is_new then
    return '', true, nil
  end

  local warning = 'liz-diff: could not read ' .. source_path .. ' at ' .. ref_label .. ': ' .. vim.trim(out)
  return '', false, warning
end

function M.open(reference, file, root)
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

  local ref_label = M.ref_label(reference)
  local ref_content, is_new_file, warning = M.resolve_ref_content(root, M.ref_rev(reference), ref_label, source_path)
  if warning then
    vim.notify(warning, vim.log.levels.WARN)
  end

  if file.status == 'D' then
    vim.cmd('enew')
    local del_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = del_buf })
    vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = del_buf })
    vim.api.nvim_buf_set_name(del_buf, '[deleted] ' .. file.filepath)
    vim.b[del_buf].liz_diff_path = root .. '/' .. file.filepath
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. file.filepath))
  end

  vim.cmd('diffthis')
  local left_win = vim.api.nvim_get_current_win()
  local left_buf = vim.api.nvim_win_get_buf(left_win)

  local ft = vim.filetype.match({ filename = file.filepath }) or ''

  -- Force the new window to the RIGHT regardless of the user's 'splitright'.
  local right_display = ref_label .. ':' .. root .. '/' .. source_path
  local right_buf =
    open_ref_pane('rightbelow', ref_content, M.ref_buffer_name(ref_label, file.filepath, is_new_file), ft, right_display)

  set_nav_keymaps({ left_buf, right_buf })

  vim.api.nvim_set_current_win(left_win)
end

-- Resolves the CURRENT buffer's file path for a same-buffer action (diffing
-- it, staging it into the compare list). Shared by M.open_current here and
-- liz_diff.compare's M.add, so the "is this a real file buffer" guard has one
-- implementation instead of two independently-drifting copies. Rejects (INFO
-- notify, returns nil) an empty name, a `liz-diff://` reference buffer (using
-- the caller-supplied `ref_buffer_message` so each call site keeps its own
-- wording), or a non-empty `buftype`; returns the absolute path on success.
function M.current_buffer_path(ref_buffer_message)
  local buf = 0
  local abs = vim.api.nvim_buf_get_name(buf)
  if abs == '' then
    vim.notify('liz-diff: no file in current buffer', vim.log.levels.INFO)
    return nil
  end

  if abs:match('^liz%-diff://') then
    vim.notify(ref_buffer_message, vim.log.levels.INFO)
    return nil
  end

  if vim.bo[buf].buftype ~= '' then
    vim.notify('liz-diff: no file in current buffer', vim.log.levels.INFO)
    return nil
  end

  return abs
end

-- M.open_current(reference): diffs the CURRENT buffer's file against `reference`.
-- The live working buffer stays on the LEFT, the reference/commit content goes
-- on the RIGHT — this is the ONE shared layout rule across every liz-diff
-- view (M.open's list flow and M.open_pr's head/base flow both match it).
-- This function remains otherwise the reference implementation: git calls and
-- the repo-root lookup below stay scoped to the buffer's own directory via
-- `-C dir`, independent of Neovim's process cwd.
function M.open_current(reference)
  local abs = M.current_buffer_path('liz-diff: cannot diff a liz-diff reference buffer')
  if not abs then
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
  local right_display = reference .. ':' .. abs
  open_ref_pane('rightbelow', ref_content, M.ref_buffer_name(reference, relpath, is_new_file), ft, right_display)

  vim.api.nvim_set_current_win(left_win)
end

-- M.open_pr(pr, file, root): diffs a PR/MR file with BOTH sides read-only from
-- git — head (newer) on the LEFT, base (merge-base) on the RIGHT, matching the
-- one layout rule shared by every liz-diff view. Unlike M.open, neither pane
-- is the live working file: a PR head is a branch under review, not your tree.
-- `pr` carries { base_oid, head_oid, merge_base, n } as produced by pr.lua.
function M.open_pr(pr, file, root)
  if file.binary then
    vim.notify('liz-diff: binary file, cannot diff', vim.log.levels.INFO)
    return
  end

  M.cleanup_previous()

  local head_path = file.filepath
  local base_path = (file.status == 'R' and file.old_path) or file.filepath
  local base_rev = pr.merge_base or pr.base_oid

  -- RIGHT (base) is empty for an added file; LEFT (head) is empty for a deleted
  -- file. A failed `git show` (e.g. side absent) yields a blank pane, not an error.
  local base_content = ''
  if file.status ~= 'A' then
    local out = vim.fn.system({ 'git', '-C', root, 'show', base_rev .. ':' .. base_path })
    if vim.v.shell_error == 0 then
      base_content = out
    end
  end

  local head_content = ''
  if file.status ~= 'D' then
    local out = vim.fn.system({ 'git', '-C', root, 'show', pr.head_oid .. ':' .. head_path })
    if vim.v.shell_error == 0 then
      head_content = out
    end
  end

  local ft = vim.filetype.match({ filename = file.filepath }) or ''
  local label = 'PR#' .. tostring(pr.n)

  -- RIGHT pane = base, in the current window.
  local base_display = base_rev .. ':' .. root .. '/' .. base_path
  local base_buf = fill_scratch(base_content, M.ref_buffer_name(label .. ' base', base_path), ft, base_display)

  -- Force the head pane to the LEFT regardless of the user's 'splitright'.
  -- open_ref_pane leaves the new (head) window focused, which is the desired
  -- final focus for the PR flow — no explicit restore needed.
  local head_display = pr.head_oid .. ':' .. root .. '/' .. head_path
  local head_buf = open_ref_pane('leftabove', head_content, M.ref_buffer_name(label .. ' head', head_path), ft, head_display)

  set_nav_keymaps({ base_buf, head_buf })
end

-- Resolves the display path for a single diff pane buffer: a stashed
-- vim.b[buf].liz_diff_path (virtual/reference/deleted panes) wins; otherwise
-- a real on-disk buffer (buftype == '', non-empty name) shows its full
-- absolute path; otherwise the raw buffer name is returned as a defensive
-- fallback. Pure aside from the buffer reads, so the on-disk-vs-virtual rule
-- is unit-testable without standing up real diff windows (mirrors the
-- ref_buffer_name / resolve_ref_content pattern).
function M.pane_path(buf)
  local stashed = vim.b[buf].liz_diff_path
  if stashed then
    return stashed
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= '' and vim.bo[buf].buftype == '' then
    return vim.fn.fnamemodify(name, ':p')
  end

  return name
end

-- :LizDiffPaths — blinks every diff pane's path (see M.pane_path) as an
-- extmark virt_lines line above the pane, for PATHS_BLINK_MS. Idempotent:
-- clears PATHS_NS on the target buffers first so a repeat invocation doesn't
-- stack overlays, then re-renders and re-schedules the auto-clear. A fresh
-- invocation supersedes any prior invocation's pending auto-clear (via
-- paths_generation) so the newest overlay always gets its own full
-- PATHS_BLINK_MS lifetime instead of being cut short by a stale timer
-- (PO-5). INFO no-op when no window in the current tabpage has 'diff' set.
function M.show_paths()
  local bufs = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_option_value('diff', { win = win }) then
      local buf = vim.api.nvim_win_get_buf(win)
      bufs[#bufs + 1] = buf
    end
  end

  if #bufs == 0 then
    vim.notify('liz-diff: no active diff', vim.log.levels.INFO)
    return
  end

  paths_generation = paths_generation + 1
  local generation = paths_generation

  for _, buf in ipairs(bufs) do
    vim.api.nvim_buf_clear_namespace(buf, PATHS_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, PATHS_NS, 0, 0, {
      virt_lines = { { { M.pane_path(buf), 'Comment' } } },
      virt_lines_above = true,
    })
  end

  vim.defer_fn(function()
    if generation ~= paths_generation then
      -- Superseded by a later show_paths() call; that call owns the clear.
      return
    end
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, PATHS_NS, 0, -1)
      end
    end
  end, PATHS_BLINK_MS)
end

return M
