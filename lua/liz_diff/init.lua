local config = require('liz_diff.config')
local cache = require('liz_diff.cache')
local git = require('liz_diff.git')
local ui = require('liz_diff.ui')
local diff = require('liz_diff.diff')
local pr = require('liz_diff.pr')

local M = {}

M._VERSION = "0.11.0"

local state = {
  current_keyword = nil,
  -- Keyword whose fetch has not reached a result, error or empty outcome yet.
  fetching = nil,
  -- Active :LizDiffNext / :LizDiffPrev session, captured when a file is
  -- selected: { keyword, mode, pr, range, root, files, filter, index }. `mode`
  -- is M.resolve_open_mode's routing, fixed at selection. Later picker use
  -- never changes it.
  nav = nil,
  active_jobs = {},
}

-- Picker model, shared by every open so a fetch that finishes after the picker
-- was closed and reopened still updates the live one. `all_files` is the
-- unfiltered list for the current keyword and `applied_filter` the filter text
-- last applied to it. `pr`, `range` and `root` are the PR meta, the resolved
-- commit-range meta (both nil for a raw ref) and the repo root the list was
-- fetched with. The filtered rows on screen live in ui
-- (ui.get_files).
local model = {
  all_files = nil,
  applied_filter = '',
  pr = nil,
  range = nil,
  root = nil,
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

-- Decides which diff view backs the next open_file_at() call. Pure (PR/range
-- session state + the raw keyword in, a mode string out) so the routing rule
-- is unit-testable without a live float or real git calls; open_file_at is
-- the only caller. `current_pr`/`current_range` are resolved once per
-- keyword in run_diff (below) and passed in rather than read from module
-- state directly, so the decision itself has no hidden dependencies.
-- 'range-unresolved' means the keyword IS a commit range (git.parse_range
-- matches) but run_diff's git.resolve_range call for it failed — routed to a
-- notify-only no-op in open_file_at rather than falling through to M.open(),
-- which is exactly the `<range>:<path>` git show bug this routing exists to
-- prevent (M.open only ever expects a single ref).
function M.resolve_open_mode(current_pr, current_range, keyword)
  if current_pr then
    return 'pr'
  end
  if current_range then
    return 'range'
  end
  if git.parse_range(keyword) then
    return 'range-unresolved'
  end
  return 'ref'
end

-- Splits a cached/fetched session meta object into its (pr, range) slots.
-- `.kind` — stamped once, where the object is built: run_diff's PR branch
-- tags 'pr', its range branch tags 'range' — decides which slot a non-nil
-- meta belongs in; a nil meta (plain single-ref keyword, no PR/range) or an
-- unrecognized `.kind` yields (nil, nil). Pure and exported so M.open()'s
-- cache-restore routing is unit-testable without a live float: a caller that
-- reverts to assigning `cached.meta` straight into current_pr (bypassing this
-- split) puts a RANGE meta into the PR slot, which M.resolve_open_mode then
-- misreads as an active PR session (Hermes M1).
function M.split_meta(meta)
  if meta and meta.kind == 'pr' then
    return meta, nil
  end
  if meta and meta.kind == 'range' then
    return nil, meta
  end
  return nil, nil
end

-- Opens the diff for the file at `index` in the active nav session, wrapping the
-- index into range first. Records the new position, syncs the session's cached
-- cursor so a reopen lands on this file (only while the cached filter is the
-- one the list was built with, since the cursor indexes the filtered rows),
-- dispatches on the session's mode to diff.open_pr / diff.open_commits /
-- diff.open, and echoes `path (i/n)`. Reads only the session, never the
-- picker's state.
local function open_file_at(index)
  local nav = state.nav
  if not nav or #nav.files == 0 then
    return
  end
  local n = #nav.files
  index = M.wrap_index(index, n)
  nav.index = index
  local file = nav.files[index]
  local cached = cache.get(nav.keyword)
  if cached and cached.filter == nav.filter then
    cache.set_cursor(nav.keyword, index)
  end
  if nav.mode == 'pr' then
    diff.open_pr(nav.pr, file, nav.root)
  elseif nav.mode == 'range' then
    diff.open_commits(nav.range, file, nav.root)
  elseif nav.mode == 'range-unresolved' then
    vim.notify('liz-diff: could not resolve range ' .. tostring(nav.keyword), vim.log.levels.WARN)
    return
  else
    diff.open(nav.keyword, file, nav.root)
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

  local function show_files(files, cursor_index, keep_focus)
    local query = ui.get_filter_text()
    model.applied_filter = query
    local shown = ui.filter_files(files, query)
    if #shown == 0 then
      ui.set_message({ ui.no_match_message(query) }, keep_focus)
    else
      ui.set_files(shown)
      ui.set_results(format_files(shown), cursor_index, keep_focus)
    end
  end

  local function show_loading()
    model.all_files = nil
    ui.set_message({ 'Loading...' }, true)
  end

  local function run_diff(keyword, cursor_index)
    show_loading()
    for _, job_id in ipairs(state.active_jobs) do
      pcall(vim.fn.jobstop, job_id)
    end
    state.active_jobs = {}
    state.current_keyword = keyword
    state.fetching = keyword

    -- Repo root resolved once per fetch (not once globally): scopes every git
    -- call and `:edit` for selections made from this list to the root that
    -- was current when the list was fetched, regardless of later cwd drift.
    local root = git.repo_root()
    if not root then
      state.fetching = nil
      ui.set_error('liz-diff: could not resolve repository root')
      return
    end

    -- Captured PR/range meta for this fetch: nil for a raw ref, the resolved
    -- info for a PR keyword or a commit-range keyword. Cached alongside the
    -- files (tagged with `.kind`) so a reopen can diff without re-resolving.
    local pr_info = nil

    local function on_result(err, files)
      if keyword ~= state.current_keyword then
        if not err and files and #files > 0 then
          cache.set(keyword, files, pr_info, root)
        end
        return
      end
      state.active_jobs = {}
      state.fetching = nil
      if err then
        model.all_files = nil
        ui.set_error(err)
      elseif #files == 0 then
        model.all_files = nil
        cache.delete(keyword)
        ui.set_empty(keyword)
      else
        cache.set(keyword, files, pr_info, root)
        model.pr, model.range = M.split_meta(pr_info)
        model.root = root
        if ui.is_open() then
          cache.set_filter(keyword, ui.get_filter_text())
        end
        model.all_files = files
        show_files(files, cursor_index, ui.is_filter_focused())
      end
    end

    local pr_number = pr.parse_keyword(keyword)
    if not pr_number then
      -- Commit-range keyword (`a..b` / `a...b`): resolve base/head ONCE here
      -- (not per file, per open_file_at's routing) so every file opened from
      -- this list reuses the same pair. Resolution is local/synchronous (at
      -- worst one `git merge-base` call) — no forge CLI or network involved,
      -- unlike the PR flow below. A resolution failure leaves the range meta
      -- nil (open_file_at then routes to a notify-only no-op instead of
      -- M.open() for this keyword — see M.resolve_open_mode's
      -- 'range-unresolved' branch), but the WARN notification for it is
      -- deferred to on_result below: an unresolvable merge-base (e.g.
      -- unrelated histories) usually also fails `git diff` itself, and firing
      -- both the resolve_range warning AND ui.set_error's own message for the
      -- same underlying cause would double up (Hermes SUGGESTION 2) — so the
      -- resolve_range warning only fires when the file LIST otherwise
      -- succeeded (meaning it's the only explanation the user gets for why
      -- opening a file from this list won't work).
      local range_error = nil
      local range = git.parse_range(keyword)
      if range then
        local resolved, rerr = git.resolve_range(range, root)
        if resolved then
          resolved.kind = 'range'
          resolved.label = keyword
          pr_info = resolved
        else
          range_error = rerr
        end
      end

      state.active_jobs = git.diff(keyword, root, function(err, files)
        if not err and range_error then
          vim.notify(range_error, vim.log.levels.WARN)
        end
        on_result(err, files)
      end)
      return
    end

    -- PR/MR flow: detect provider from origin, resolve base/head via the forge
    -- CLI, ensure the commits are local (auto-fetch), then feed the three-dot
    -- range into the existing git.diff pipeline.
    local provider = pr.detect_provider(pr.origin_url())
    if not provider then
      state.fetching = nil
      ui.set_error('liz-diff: could not detect GitHub/GitLab from the origin remote')
      return
    end

    state.active_jobs = pr.resolve(pr_number, provider, function(rerr, info)
      if keyword ~= state.current_keyword then
        return
      end
      if rerr then
        state.fetching = nil
        ui.set_error(rerr)
        return
      end
      pr.ensure_commits(info, function(eerr)
        if keyword ~= state.current_keyword then
          return
        end
        if eerr then
          state.fetching = nil
          ui.set_error(eerr)
          return
        end
        info.kind = 'pr'
        pr_info = info
        local range = info.base_oid .. '...' .. info.head_oid
        local jobs = git.diff(range, root, on_result)
        for _, j in ipairs(jobs) do
          state.active_jobs[#state.active_jobs + 1] = j
        end
      end)
    end)
  end

  local function on_submit(keyword)
    ui.set_filter_text('')
    model.applied_filter = ''
    cache.set_filter(keyword, '')
    run_diff(keyword, 1)
  end

  local function on_filter(text)
    if text == model.applied_filter then
      return
    end
    cache.set_filter(state.current_keyword, text)
    if not model.all_files then
      return
    end
    show_files(model.all_files, 1, true)
  end

  local function on_refresh()
    if state.current_keyword == nil then
      return
    end
    local idx = ui.get_cursor_index()
    run_diff(state.current_keyword, idx)
  end

  local function on_select()
    -- Capture the filtered list as an active nav session so :LizDiffNext / ]f
    -- can move to sibling files without reopening the picker. The file's row
    -- index drives navigation from here on.
    local idx = ui.get_cursor_index()
    state.nav = {
      keyword = state.current_keyword,
      mode = M.resolve_open_mode(model.pr, model.range, state.current_keyword),
      pr = model.pr,
      range = model.range,
      root = model.root,
      files = ui.get_files(),
      filter = model.applied_filter,
      index = idx,
    }
    ui.close()
    open_file_at(idx)
  end

  model.all_files = nil
  model.applied_filter = ''
  ui.open(on_submit, on_select, on_refresh, on_filter)

  if state.current_keyword then
    local cached = cache.get(state.current_keyword)
    ui.set_prompt_text(state.current_keyword)
    if cached then
      ui.set_filter_text(cached.filter)
      model.all_files = cached.files
      -- PR or range context (both nil for a raw ref) and root recorded when
      -- this list was fetched, so a selection from it scopes to the same
      -- PR/range and repo even if Neovim's cwd has since changed. Routed
      -- through M.split_meta: assigning `cached.meta` straight into model.pr
      -- would put a cached RANGE meta into the PR slot.
      model.pr, model.range = M.split_meta(cached.meta)
      model.root = cached.root
      show_files(cached.files, cached.cursor_index)
    elseif state.fetching == state.current_keyword then
      show_loading()
    end
  end
end

-- Navigate to the next/previous file in the active list, wrapping at the ends.
-- No-ops with an INFO notify when no list has been selected from (e.g. after
-- only :LizDiffFile, which has no list).
local function step(delta)
  local nav = state.nav
  if not nav or #nav.files == 0 then
    vim.notify('liz-diff: no active file list', vim.log.levels.INFO)
    return
  end
  open_file_at((nav.index or 1) + delta)
end

function M.next()
  step(1)
end

function M.prev()
  step(-1)
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
