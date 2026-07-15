local M = {}

function M.is_git_repo()
  vim.fn.system({ 'git', 'rev-parse', '--is-inside-work-tree' })
  return vim.v.shell_error == 0
end

-- Resolves the repository root for Neovim's current process cwd (list-form
-- vim.fn.system, same locale-independent exit-code convention as
-- M.is_git_repo / M.is_new_file — never parses git's translatable text).
-- Returns the trimmed absolute path, or nil when the cwd isn't inside a work
-- tree. Callers scope every subsequent git call and file `:edit` to this root
-- so selections are correct regardless of cwd drift after the initial fetch.
function M.repo_root()
  local out = vim.fn.system({ 'git', 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return vim.trim(out)
end

function M.parse_name_status(lines)
  local results = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      local parts = vim.split(line, '\t')
      local status_field = parts[1]
      if status_field:sub(1, 1) == 'R' then
        results[#results + 1] = {
          status = 'R',
          filepath = parts[3],
          old_path = parts[2],
        }
      else
        results[#results + 1] = {
          status = status_field,
          filepath = parts[2],
        }
      end
    end
  end
  return results
end

function M.parse_numstat(lines)
  local results = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      local parts = vim.split(line, '\t')
      local ins = parts[1]
      local del = parts[2]
      local is_binary = ins == '-' and del == '-'
      local filepath = parts[3]
      local arrow = filepath:find(' => ')
      if arrow then
        local brace = filepath:find('{')
        if brace then
          local prefix = filepath:sub(1, brace - 1)
          local suffix = filepath:match('}(.*)$') or ''
          local new_part = filepath:match('=> ([^}]+)')
          filepath = prefix .. new_part .. suffix
        else
          filepath = filepath:sub(arrow + 4)
        end
      end
      results[#results + 1] = {
        filepath = filepath,
        insertions = is_binary and 0 or tonumber(ins),
        deletions = is_binary and 0 or tonumber(del),
        binary = is_binary,
      }
    end
  end
  return results
end

function M.merge_results(name_status, numstat)
  local stat_map = {}
  for _, entry in ipairs(numstat) do
    stat_map[entry.filepath] = entry
  end

  local seen = {}
  local results = {}

  for _, ns in ipairs(name_status) do
    local stat = stat_map[ns.filepath]
    seen[ns.filepath] = true
    results[#results + 1] = {
      status = ns.status,
      filepath = ns.filepath,
      old_path = ns.old_path,
      insertions = stat and stat.insertions or 0,
      deletions = stat and stat.deletions or 0,
      binary = stat and stat.binary or false,
    }
  end

  for _, stat in ipairs(numstat) do
    if not seen[stat.filepath] then
      results[#results + 1] = {
        status = 'M',
        filepath = stat.filepath,
        insertions = stat.insertions,
        deletions = stat.deletions,
        binary = stat.binary,
      }
    end
  end

  return results
end

-- True when `path` is absent from `reference`'s tree while the reference itself
-- resolves — i.e. a genuinely new file. Locale-independent: keys off `git
-- ls-tree` exit code + empty stdout, never git's (translatable) error text. A
-- missing path at a valid ref prints nothing with exit 0; an unresolvable ref
-- exits non-zero.
function M.is_new_file(dir, reference, path)
  local out = vim.fn.system({ 'git', '-C', dir, 'ls-tree', '-r', reference, '--', path })
  return vim.v.shell_error == 0 and vim.trim(out) == ''
end

local function run_git(args, on_done)
  local stdout_chunks = {}
  local stderr_chunks = {}
  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout_chunks = data
    end,
    on_stderr = function(_, data)
      stderr_chunks = data
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          local err = table.concat(stderr_chunks, '\n')
          on_done(err, nil)
        else
          on_done(nil, stdout_chunks)
        end
      end)
    end,
  })
  return job_id
end

-- True when HEAD resolves to a commit. Locale-independent: exit-code only,
-- same convention as M.is_new_file — never parse git's (translatable) error
-- text. False on a brand-new repo with no commits yet ("unborn HEAD").
local function head_resolves()
  vim.fn.system({ 'git', 'rev-parse', '--verify', '--quiet', 'HEAD' })
  return vim.v.shell_error == 0
end

-- Neovim's job transport rewrites embedded NUL bytes to NL when delivering
-- stdout to Lua callbacks (see :h channel-lines), so `git ls-files -z`
-- output arrives as newline-joined text rather than genuinely NUL-separated
-- chunks. Concatenating every buffered chunk and re-splitting on '\n'
-- recovers the individual paths regardless of how Neovim chunked delivery,
-- and -z sidesteps git's C-quoting of non-ASCII/space paths at the source.
local function split_nul_lines(lines)
  local text = table.concat(lines, '\n')
  local paths = {}
  for path in text:gmatch('[^\n]+') do
    paths[#paths + 1] = path
  end
  return paths
end

-- Async job listing untracked (never-added) files, respecting .gitignore.
-- Scoped to `root` via `-C` (not Neovim's process cwd) so every path comes
-- back root-relative, matching `git diff --name-status`/`--numstat`'s
-- inherent root-relative convention. Without this, `git ls-files` (which is
-- cwd-relative by default, unlike `git diff`) would emit cwd-relative paths
-- when Neovim is launched inside a repo subdirectory, and would also only
-- cover that subtree instead of the whole repo. callback(err, paths).
-- Returns the job id for M.diff's cancellation list.
function M.list_untracked(root, callback)
  return run_git({ 'git', '-C', root, 'ls-files', '--others', '--exclude-standard', '-z' }, function(err, lines)
    if err then
      callback(err, nil)
      return
    end
    callback(nil, split_nul_lines(lines or {}))
  end)
end

-- Lines in `content`: a trailing fragment without a terminating newline still
-- counts as one line (mirrors `git numstat`'s treatment, within ±1 on files
-- missing a final newline).
local function count_lines(content)
  if content == '' then
    return 0
  end
  local n = 0
  for _ in content:gmatch('\n') do
    n = n + 1
  end
  if content:sub(-1) ~= '\n' then
    n = n + 1
  end
  return n
end

-- Builds diff-list entries for untracked `paths` (root-relative, as returned
-- by M.list_untracked) via pure Lua file reads (no per-file git process —
-- identical behavior on Windows). Each path is joined onto `root` before
-- `io.open` since Lua's io library resolves relative paths against
-- Neovim's process cwd, not the repo root the paths are relative to — with
-- nvim's cwd in a subdirectory, opening the bare relative path would miss
-- the file. Binary is detected by a NUL byte in the first 8KB; otherwise
-- lines are counted for `insertions` (deletions always 0, since there's
-- nothing to compare against). A path that can no longer be opened yields a
-- zero-count entry rather than erroring the whole list. Entries keep the
-- root-relative `path` (not the absolute one) so they match the tracked
-- entries' filepath convention.
function M.untracked_stats(root, paths)
  local entries = {}
  for _, path in ipairs(paths) do
    local binary = false
    local insertions = 0
    local f = io.open(root .. '/' .. path, 'rb')
    if f then
      -- Check only the first 8KB for a NUL byte before deciding whether to
      -- read the rest — avoids pulling large binary files fully into memory
      -- (and stalling the UI thread) just to discard them.
      local head = f:read(8192) or ''
      binary = head:find('\0', 1, true) ~= nil
      if binary then
        f:close()
      else
        local rest = f:read('*a') or ''
        f:close()
        insertions = count_lines(head .. rest)
      end
    end
    entries[#entries + 1] = {
      status = 'A',
      filepath = path,
      insertions = insertions,
      deletions = 0,
      binary = binary,
    }
  end
  return entries
end

-- Appends `untracked_entries` after `files`, skipping any filepath already
-- present (e.g. a staged-new file also reported as untracked would be a
-- contradiction in practice, but this keeps the merge defensive).
function M.append_untracked(files, untracked_entries)
  local seen = {}
  for _, f in ipairs(files) do
    seen[f.filepath] = true
  end
  local results = {}
  for _, f in ipairs(files) do
    results[#results + 1] = f
  end
  for _, u in ipairs(untracked_entries) do
    if not seen[u.filepath] then
      results[#results + 1] = u
      seen[u.filepath] = true
    end
  end
  return results
end

-- `root` scopes the untracked-file listing/read (M.list_untracked /
-- M.untracked_stats) to the repo root resolved at fetch time — see those
-- functions' docs. The `git diff --name-status`/`--numstat` commands below
-- are left unscoped: git diff's paths are always root-relative regardless of
-- the invoking process's cwd, so no `-C root` is needed there.
function M.diff(reference, root, callback)
  local cmd1 = { 'git', 'diff', '--name-status' }
  local cmd2 = { 'git', 'diff', '--numstat' }

  if reference ~= '' then
    cmd1[#cmd1 + 1] = reference
    cmd2[#cmd2 + 1] = reference
  elseif head_resolves() then
    -- Empty prompt now means "all uncommitted changes": worktree + index vs
    -- HEAD, instead of the old bare index diff. Skipped entirely on an
    -- unborn HEAD (no commits yet) — falls back to the original bare
    -- `git diff` commands built above.
    cmd1[#cmd1 + 1] = 'HEAD'
    cmd2[#cmd2 + 1] = 'HEAD'
  end

  -- Untracked files are included for the empty prompt and single-ref
  -- prompts, but never for commit ranges (`a..b`, `a...b`, incl. the PR
  -- flow's `base...head`) — those compare commits, not the worktree.
  local include_untracked = not reference:find('%.%.')

  local expected_jobs = include_untracked and 3 or 2
  local done_count = 0
  local name_status_lines, numstat_lines, untracked_paths
  local had_error = false

  local function fail(err)
    if not had_error then
      had_error = true
      callback(err, nil)
    end
  end

  local function check_done()
    done_count = done_count + 1
    if done_count < expected_jobs or had_error then
      return
    end
    local ns = M.parse_name_status(name_status_lines)
    local stat = M.parse_numstat(numstat_lines)
    local files = M.merge_results(ns, stat)
    if include_untracked then
      files = M.append_untracked(files, M.untracked_stats(root, untracked_paths or {}))
    end
    callback(nil, files)
  end

  local jobs = {}

  jobs[#jobs + 1] = run_git(cmd1, function(err, lines)
    if err then
      fail(err)
      return
    end
    name_status_lines = lines
    check_done()
  end)

  jobs[#jobs + 1] = run_git(cmd2, function(err, lines)
    if err then
      fail(err)
      return
    end
    numstat_lines = lines
    check_done()
  end)

  if include_untracked then
    jobs[#jobs + 1] = M.list_untracked(root, function(err, paths)
      if err then
        fail(err)
        return
      end
      untracked_paths = paths
      check_done()
    end)
  end

  return jobs
end

return M
