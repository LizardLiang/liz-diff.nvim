local git = require('liz_diff.git')

local M = {}

local ref_buffers = {}

function M.cleanup_previous()
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
local function fill_scratch(content, name, filetype)
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

-- Opens a vsplit forced to `direction` ('leftabove' or 'rightbelow'),
-- overriding the user's 'splitright' setting, then fills the new window with a
-- read-only reference scratch buffer via fill_scratch. The new window is left
-- focused; callers restore focus afterward.
local function open_ref_pane(direction, content, name, filetype)
  vim.cmd(direction .. ' vsplit')
  return fill_scratch(content, name, filetype)
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
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. file.filepath))
  end

  vim.cmd('diffthis')
  local left_win = vim.api.nvim_get_current_win()

  local ft = vim.filetype.match({ filename = file.filepath }) or ''

  -- Force the new window to the RIGHT regardless of the user's 'splitright'.
  open_ref_pane('rightbelow', ref_content, M.ref_buffer_name(ref_label, file.filepath, is_new_file), ft)

  vim.api.nvim_set_current_win(left_win)
end

-- M.open_current(reference): diffs the CURRENT buffer's file against `reference`.
-- The live working buffer stays on the LEFT, the reference/commit content goes
-- on the RIGHT — this is the ONE shared layout rule across every liz-diff
-- view (M.open's list flow and M.open_pr's head/base flow both match it).
-- This function remains otherwise the reference implementation: git calls and
-- the repo-root lookup below stay scoped to the buffer's own directory via
-- `-C dir`, independent of Neovim's process cwd.
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
  open_ref_pane('rightbelow', ref_content, M.ref_buffer_name(reference, relpath, is_new_file), ft)

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
  fill_scratch(base_content, M.ref_buffer_name(label .. ' base', base_path), ft)

  -- Force the head pane to the LEFT regardless of the user's 'splitright'.
  -- open_ref_pane leaves the new (head) window focused, which is the desired
  -- final focus for the PR flow — no explicit restore needed.
  open_ref_pane('leftabove', head_content, M.ref_buffer_name(label .. ' head', head_path), ft)
end

return M
