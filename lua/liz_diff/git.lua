local M = {}

function M.is_git_repo()
  vim.fn.system({ 'git', 'rev-parse', '--is-inside-work-tree' })
  return vim.v.shell_error == 0
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

function M.diff(reference, callback)
  local cmd1 = { 'git', 'diff', '--name-status' }
  local cmd2 = { 'git', 'diff', '--numstat' }
  if reference ~= '' then
    cmd1[#cmd1 + 1] = reference
    cmd2[#cmd2 + 1] = reference
  end

  local done_count = 0
  local name_status_lines, numstat_lines
  local had_error = false

  local function check_done()
    done_count = done_count + 1
    if done_count < 2 then
      return
    end
    if had_error then
      return
    end
    local ns = M.parse_name_status(name_status_lines)
    local stat = M.parse_numstat(numstat_lines)
    local files = M.merge_results(ns, stat)
    callback(nil, files)
  end

  local job1 = run_git(cmd1, function(err, lines)
    if err then
      if not had_error then
        had_error = true
        callback(err, nil)
      end
      return
    end
    name_status_lines = lines
    check_done()
  end)

  local job2 = run_git(cmd2, function(err, lines)
    if err then
      if not had_error then
        had_error = true
        callback(err, nil)
      end
      return
    end
    numstat_lines = lines
    check_done()
  end)

  return { job1, job2 }
end

return M
