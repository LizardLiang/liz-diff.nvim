local M = {}

-- CLI executable per detected provider.
local CLI = { github = 'gh', gitlab = 'glab' }

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-testable without git or network)
-- ---------------------------------------------------------------------------

-- Extract a PR/MR number from a prompt keyword. `#123` / `!45` -> number.
-- The prefix char is cosmetic (either works for either forge); anything else,
-- or a prefix followed by non-digits, returns nil (caller treats it as a ref).
function M.parse_keyword(keyword)
  if type(keyword) ~= 'string' then
    return nil
  end
  local digits = keyword:match('^[#!](%d+)$')
  if digits then
    return tonumber(digits)
  end
  return nil
end

-- Detect the forge provider from a remote URL host. Substring match handles
-- both SSH (git@host:owner/repo) and HTTPS (https://host/owner/repo) forms.
-- Returns 'github' | 'gitlab' | nil.
function M.detect_provider(url)
  if type(url) ~= 'string' then
    return nil
  end
  local lower = url:lower()
  if lower:find('github', 1, true) then
    return 'github'
  end
  if lower:find('gitlab', 1, true) then
    return 'gitlab'
  end
  return nil
end

-- Parse `gh pr view <n> --json baseRefName,headRefName,baseRefOid,headRefOid`.
-- Returns { base_oid, head_oid, base_ref, head_ref } or nil.
function M.parse_gh_view(json_str)
  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  if not data.baseRefOid or not data.headRefOid then
    return nil
  end
  return {
    base_oid = data.baseRefOid,
    head_oid = data.headRefOid,
    base_ref = data.baseRefName,
    head_ref = data.headRefName,
  }
end

-- Parse `glab mr view <n> --output json`. Prefers the base/head SHAs under
-- `diff_refs`; falls back to just the branch names (oids resolved later from
-- git in ensure_commits). Returns a partial table or nil.
function M.parse_glab_view(json_str)
  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= 'table' then
    return nil
  end
  local refs = data.diff_refs
  if type(refs) == 'table' and refs.base_sha and refs.head_sha then
    return {
      base_oid = refs.base_sha,
      head_oid = refs.head_sha,
      base_ref = data.target_branch,
      head_ref = data.source_branch,
    }
  end
  if data.target_branch and data.source_branch then
    return {
      base_ref = data.target_branch,
      head_ref = data.source_branch,
    }
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- git/CLI plumbing
-- ---------------------------------------------------------------------------

-- The `origin` remote URL, or nil when there is no origin.
function M.origin_url()
  local out = vim.fn.systemlist({ 'git', 'remote', 'get-url', 'origin' })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out[1]
end

-- Async command runner mirroring git.lua's run_git: buffered stdout/stderr,
-- callback scheduled on the main loop, joined into single strings.
local function run_cmd(args, on_done)
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
          on_done(table.concat(stderr_chunks, '\n'), nil)
        else
          on_done(nil, table.concat(stdout_chunks, '\n'))
        end
      end)
    end,
  })
  if job_id <= 0 then
    vim.schedule(function()
      on_done('liz-diff: failed to start ' .. tostring(args[1]), nil)
    end)
    return nil
  end
  return job_id
end

-- Resolve a PR/MR to base/head refs via the forge CLI. Calls
-- callback(err, info) where info carries whatever the CLI provided
-- (oids and/or branch names) plus provider/remote/n. Missing oids are
-- filled in later by ensure_commits. Returns the job id list for cancellation.
function M.resolve(number, provider, callback)
  local cli = CLI[provider]
  if not cli then
    callback('liz-diff: unsupported provider', nil)
    return {}
  end
  if vim.fn.executable(cli) == 0 then
    local what = provider == 'github' and 'GitHub PRs' or 'GitLab MRs'
    callback(string.format('liz-diff: %s not found — install %s to view %s', cli, cli, what), nil)
    return {}
  end

  local args, parser
  if provider == 'github' then
    args = { 'gh', 'pr', 'view', tostring(number), '--json', 'baseRefName,headRefName,baseRefOid,headRefOid' }
    parser = M.parse_gh_view
  else
    args = { 'glab', 'mr', 'view', tostring(number), '--output', 'json' }
    parser = M.parse_glab_view
  end

  local job = run_cmd(args, function(err, out)
    if err and err ~= '' then
      callback(err, nil)
      return
    end
    local info = parser(out or '')
    if not info then
      callback('liz-diff: could not resolve #' .. number .. ' (unexpected ' .. cli .. ' output)', nil)
      return
    end
    info.provider = provider
    info.remote = 'origin'
    info.n = number
    callback(nil, info)
  end)

  if not job then
    return {}
  end
  return { job }
end

-- ---------------------------------------------------------------------------
-- ensure_commits: guarantee base/head/merge-base are available locally,
-- fetching on demand (with a one-time notify). Fills any oids the CLI didn't
-- provide. Sync git calls (fast except fetch) — consistent with diff.lua's
-- existing use of vim.fn.system.
-- ---------------------------------------------------------------------------

local function commit_present(oid)
  if not oid then
    return false
  end
  vim.fn.system({ 'git', 'cat-file', '-e', oid .. '^{commit}' })
  return vim.v.shell_error == 0
end

local function rev_parse(ref)
  local out = vim.fn.system({ 'git', 'rev-parse', '--verify', '--quiet', ref })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local trimmed = vim.trim(out)
  return trimmed ~= '' and trimmed or nil
end

local function fetch(remote, spec)
  vim.fn.system({ 'git', 'fetch', remote, spec })
  return vim.v.shell_error == 0
end

function M.ensure_commits(info, callback)
  local remote = info.remote or 'origin'
  local head_spec = info.provider == 'github'
    and ('pull/' .. info.n .. '/head')
    or ('merge-requests/' .. info.n .. '/head')

  local notified = false
  local function notify_once()
    if not notified then
      notified = true
      vim.notify('liz-diff: fetching #' .. info.n .. '…', vim.log.levels.INFO)
    end
  end

  -- Head commit: fetch the PR/MR head ref when missing; resolve its oid from
  -- FETCH_HEAD if the CLI didn't hand us one (glab fallback path).
  if not commit_present(info.head_oid) then
    notify_once()
    if not fetch(remote, head_spec) then
      callback('liz-diff: failed to fetch head for #' .. info.n)
      return
    end
    if not info.head_oid then
      info.head_oid = rev_parse('FETCH_HEAD')
    end
  end
  if not info.head_oid then
    callback('liz-diff: could not resolve head commit for #' .. info.n)
    return
  end

  -- Base commit: prefer the CLI oid; else resolve the base branch, fetching it
  -- from the remote if it isn't present locally.
  if not commit_present(info.base_oid) then
    if not info.base_oid and info.base_ref then
      info.base_oid = rev_parse(remote .. '/' .. info.base_ref) or rev_parse(info.base_ref)
    end
    if not commit_present(info.base_oid) and info.base_ref then
      notify_once()
      if fetch(remote, info.base_ref) then
        info.base_oid = info.base_oid or rev_parse('FETCH_HEAD')
      end
    end
  end
  if not commit_present(info.base_oid) then
    callback('liz-diff: could not resolve base commit for #' .. info.n)
    return
  end

  -- Merge-base keeps the per-file diff consistent with the three-dot file list
  -- (git diff base...head is merge-base(base,head)..head).
  local mb = vim.fn.system({ 'git', 'merge-base', info.base_oid, info.head_oid })
  info.merge_base = (vim.v.shell_error == 0 and vim.trim(mb) ~= '') and vim.trim(mb) or info.base_oid

  callback(nil)
end

return M
