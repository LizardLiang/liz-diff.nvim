local config = require('liz_diff.config')
local cache = require('liz_diff.cache')
local git = require('liz_diff.git')
local ui = require('liz_diff.ui')
local diff = require('liz_diff.diff')
local pr = require('liz_diff.pr')

local M = {}

M._VERSION = "0.4.0"

local state = {
  current_keyword = nil,
  current_pr = nil,
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

    -- Captured PR meta for this fetch: nil for a raw ref, the resolved info for
    -- a PR keyword. Cached alongside the files so a reopen can diff without
    -- re-resolving.
    local pr_info = nil

    local function on_result(err, files)
      if keyword ~= state.current_keyword then
        if not err and files and #files > 0 then
          cache.set(keyword, files, pr_info)
        end
        return
      end
      state.active_jobs = {}
      if err then
        ui.set_error(err)
      elseif #files == 0 then
        ui.set_empty(keyword)
      else
        cache.set(keyword, files, pr_info)
        ui.set_results(format_files(files), cursor_index)
        ui._set_files_ref(files)
      end
    end

    local pr_number = pr.parse_keyword(keyword)
    if not pr_number then
      state.current_pr = nil
      state.active_jobs = git.diff(keyword, on_result)
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
        local jobs = git.diff(range, on_result)
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
    cache.set_cursor(state.current_keyword, ui.get_cursor_index())
    ui.close()
    if state.current_pr then
      diff.open_pr(state.current_pr, file)
    else
      diff.open(state.current_keyword, file)
    end
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
    end
  end
end

function M.open_current(ref)
  -- No git.is_git_repo() guard here: that check runs against Neovim's
  -- process cwd, not the buffer's file, and would wrongly refuse a valid
  -- file when nvim was launched from outside any repo. diff.open_current
  -- owns the repo check instead, scoped to the buffer's own directory.
  diff.open_current(ref or 'HEAD')
end

return M
