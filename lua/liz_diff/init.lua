local config = require('liz_diff.config')
local cache = require('liz_diff.cache')
local git = require('liz_diff.git')
local ui = require('liz_diff.ui')
local diff = require('liz_diff.diff')
local pr = require('liz_diff.pr')

local M = {}

M._VERSION = "0.9.0"

local state = {
  current_keyword = nil,
  current_pr = nil,
  current_root = nil,
  current_files = nil,
  current_index = nil,
  active_jobs = {},
}

function M.setup(opts)
  config.merge(opts)
end

local function format_files(files)
  local lines = {}
  for _, file in ipairs(files) do
    lines[#lines + 1] = ui.format_line(file)
  end
  return lines
end

-- Normalizes a 1-based index into the range 1..n with wrap-around at both ends
-- (index n+1 -> 1, index 0 -> n), handling arbitrary over/underflow. Returns
-- nil for an empty list. Pure and exported so the wrap math is unit-testable
-- without a live diff view.
function M.wrap_index(index, n)
  if not n or n == 0 then
    return nil
  end
  return ((index - 1) % n + n) % n + 1
end

-- Opens the diff for the file at `index` in the active nav session, wrapping the
-- index into range first. Records the new position, syncs the picker's cached
-- cursor so a reopen lands on this file, dispatches through the same
-- diff.open_pr / diff.open path on_select uses, and echoes `path (i/n)`.
local function open_file_at(index)
  local files = state.current_files
  if not files or #files == 0 then
    return
  end
  local n = #files
  index = M.wrap_index(index, n)
  state.current_index = index
  local file = files[index]
  cache.set_cursor(state.current_keyword, index)
  if state.current_pr then
    diff.open_pr(state.current_pr, file, state.current_root)
  else
    diff.open(state.current_keyword, file, state.current_root)
  end
  vim.api.nvim_echo({ { string.format('liz-diff: %s (%d/%d)', file.filepath, index, n) } }, false, {})
end

function M.open()
  if not git.is_git_repo() then
    vim.notify('liz-diff: not a git repository', vim.log.levels.WARN)
    return
  end

  if ui.is_open() then
    ui.focus()
    return
  end

  local function run_diff(keyword, cursor_index)
    for _, job_id in ipairs(state.active_jobs) do
      pcall(vim.fn.jobstop, job_id)
    end
    state.active_jobs = {}
    state.current_keyword = keyword

    -- Repo root resolved once per fetch (not once globally): scopes every git
    -- call and `:edit` for selections made from this list to the root that
    -- was current when the list was fetched, regardless of later cwd drift.
    local root = git.repo_root()
    state.current_root = root
    if not root then
      state.current_pr = nil
      ui._set_files_ref({})
      ui.set_error('liz-diff: could not resolve repository root')
      return
    end

    -- Captured PR meta for this fetch: nil for a raw ref, the resolved info for
    -- a PR keyword. Cached alongside the files so a reopen can diff without
    -- re-resolving.
    local pr_info = nil

    local function on_result(err, files)
      if keyword ~= state.current_keyword then
        if not err and files and #files > 0 then
          cache.set(keyword, files, pr_info, root)
        end
        return
      end
      state.active_jobs = {}
      if err then
        ui.set_error(err)
      elseif #files == 0 then
        ui.set_empty(keyword)
      else
        cache.set(keyword, files, pr_info, root)
        ui.set_results(format_files(files), cursor_index)
        ui._set_files_ref(files)
      end
    end

    local pr_number = pr.parse_keyword(keyword)
    if not pr_number then
      state.current_pr = nil
      state.active_jobs = git.diff(keyword, root, on_result)
      return
    end

    -- PR/MR flow: detect provider from origin, resolve base/head via the forge
    -- CLI, ensure the commits are local (auto-fetch), then feed the three-dot
    -- range into the existing git.diff pipeline.
    state.current_pr = nil
    local provider = pr.detect_provider(pr.origin_url())
    if not provider then
      ui.set_error('liz-diff: could not detect GitHub/GitLab from the origin remote')
      return
    end

    state.active_jobs = pr.resolve(pr_number, provider, function(rerr, info)
      if keyword ~= state.current_keyword then
        return
      end
      if rerr then
        ui.set_error(rerr)
        return
      end
      pr.ensure_commits(info, function(eerr)
        if keyword ~= state.current_keyword then
          return
        end
        if eerr then
          ui.set_error(eerr)
          return
        end
        pr_info = info
        state.current_pr = info
        local range = info.base_oid .. '...' .. info.head_oid
        local jobs = git.diff(range, root, on_result)
        for _, j in ipairs(jobs) do
          state.active_jobs[#state.active_jobs + 1] = j
        end
      end)
    end)
  end

  local function on_submit(keyword)
    run_diff(keyword, 1)
  end

  local function on_refresh()
    if state.current_keyword == nil then
      return
    end
    local idx = ui.get_cursor_index()
    run_diff(state.current_keyword, idx)
  end

  local function on_select(file)
    -- Capture the full list as an active nav session so :LizDiffNext / ]f can
    -- move to sibling files without reopening the picker. The file's row index
    -- (not the file arg) drives navigation from here on.
    local idx = ui.get_cursor_index()
    local cached = cache.get(state.current_keyword)
    state.current_files = cached and cached.files or { file }
    ui.close()
    open_file_at(idx)
  end

  ui.open(on_submit, on_select, on_refresh)

  if state.current_keyword then
    local cached = cache.get(state.current_keyword)
    if cached then
      ui.set_prompt_text(state.current_keyword)
      ui.set_results(format_files(cached.files), cached.cursor_index)
      ui._set_files_ref(cached.files)
      -- Restore PR context (nil for a raw ref) so a select from the restored
      -- list diffs base-vs-head without re-resolving.
      state.current_pr = cached.meta
      -- Restore the root recorded when this list was fetched, so a selection
      -- from the restored (cached) list scopes to the same repo even if
      -- Neovim's cwd has since changed.
      state.current_root = cached.root
    end
  end
end

-- Navigate to the next/previous file in the active list, wrapping at the ends.
-- No-ops with an INFO notify when no list has been selected from (e.g. after
-- only :LizDiffFile, which has no list).
function M.next()
  if not state.current_files or #state.current_files == 0 then
    vim.notify('liz-diff: no active file list', vim.log.levels.INFO)
    return
  end
  open_file_at((state.current_index or 1) + 1)
end

function M.prev()
  if not state.current_files or #state.current_files == 0 then
    vim.notify('liz-diff: no active file list', vim.log.levels.INFO)
    return
  end
  open_file_at((state.current_index or 1) - 1)
end

function M.open_current(ref)
  -- No git.is_git_repo() guard here: that check runs against Neovim's
  -- process cwd, not the buffer's file, and would wrongly refuse a valid
  -- file when nvim was launched from outside any repo. diff.open_current
  -- owns the repo check instead, scoped to the buffer's own directory.
  diff.open_current(ref or 'HEAD')
end

-- Blinks the path of every pane in the active diff for ~2s. Equivalent to
-- :LizDiffPaths.
function M.paths()
  diff.show_paths()
end

-- Thin delegators to liz_diff.compare (the git-agnostic "stage two files,
-- diff them" flow) — mirrors M.next/M.prev/M.open_current above. No compare
-- state lives in init.lua; liz_diff.compare owns the two-slot list.
function M.add()
  require('liz_diff.compare').add()
end

function M.compare()
  require('liz_diff.compare').compare()
end

function M.list()
  require('liz_diff.compare').show_list()
end

function M.clear()
  require('liz_diff.compare').clear()
end

return M
