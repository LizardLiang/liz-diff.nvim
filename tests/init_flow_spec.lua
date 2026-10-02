-- Headless tests for the picker wiring in init.lua. git.diff and the git repo
-- checks are stubbed, so each test drives the real ui floats and decides when
-- a fetch finishes.

local function f(path)
  return { filepath = path, status = 'M', insertions = 1, deletions = 0 }
end


describe('liz-diff picker wiring', function()
  local liz, ui, cache, config
  local fetches, opened
  local pr_module, pr_originals

  local function row_of(win)
    local r = vim.api.nvim_win_get_config(win).row
    return type(r) == 'table' and r[false] or r
  end

  -- Prompt, filter and results floats, ordered top to bottom.
  local function picker()
    local floats = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= '' then
        floats[#floats + 1] = win
      end
    end
    table.sort(floats, function(a, b) return row_of(a) < row_of(b) end)
    return {
      prompt_win = floats[1],
      filter_win = floats[2],
      results_win = floats[3],
      prompt = floats[1] and vim.api.nvim_win_get_buf(floats[1]),
      filter = floats[2] and vim.api.nvim_win_get_buf(floats[2]),
      results = floats[3] and vim.api.nvim_win_get_buf(floats[3]),
    }
  end

  local function press(buf, mode, lhs)
    local map = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, mode, false, true)
    end)
    assert(map.callback, 'no mapping for ' .. lhs)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    map.callback()
  end

  local function lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local function submit(p, ref)
    vim.api.nvim_buf_set_lines(p.prompt, 0, -1, false, { ref })
    press(p.prompt, 'n', '<CR>')
  end

  local function type_filter(p, text)
    vim.api.nvim_buf_set_lines(p.filter, 0, -1, false, { text })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = p.filter })
  end

  local function select_row(p, row)
    vim.api.nvim_win_set_cursor(p.results_win, { row, 0 })
    press(p.results, 'n', '<CR>')
  end

  local function finish(index, err, files)
    fetches[index].callback(err, files)
  end

  before_each(function()
    for _, name in ipairs({ 'liz_diff', 'liz_diff.ui', 'liz_diff.cache', 'liz_diff.config' }) do
      package.loaded[name] = nil
    end
    local git = require('liz_diff.git')
    git.is_git_repo = function() return true end
    git.repo_root = function() return 'C:/repo' end
    fetches = {}
    git.diff = function(ref, root, callback)
      fetches[#fetches + 1] = { ref = ref, callback = callback }
      return {}
    end
    opened = {}
    require('liz_diff.diff').open = function(ref, file, root)
      opened[#opened + 1] = { ref = ref, path = file.filepath, root = root }
    end
    require('liz_diff.diff').open_pr = function(info, file, root)
      opened[#opened + 1] = { pr = info, path = file.filepath, root = root }
    end
    pr_module = require('liz_diff.pr')
    pr_originals = {}
    for _, name in ipairs({ 'detect_provider', 'origin_url', 'resolve', 'ensure_commits' }) do
      pr_originals[name] = pr_module[name]
    end
    config = require('liz_diff.config')
    liz = require('liz_diff')
    ui = require('liz_diff.ui')
    cache = require('liz_diff.cache')
  end)

  after_each(function()
    ui.close()
    vim.cmd('stopinsert')
    for name, fn in pairs(pr_originals) do
      pr_module[name] = fn
    end
  end)

  -- Makes every PR keyword resolve at once, handing out `infos` in order.
  local function stub_pr(infos)
    pr_module.detect_provider = function() return 'github' end
    pr_module.origin_url = function() return 'git@example.com:o/r.git' end
    pr_module.resolve = function(_, _, callback)
      callback(nil, table.remove(infos, 1))
      return {}
    end
    pr_module.ensure_commits = function(_, callback) callback(nil) end
  end

  local files3 = function()
    return { f('a.lua'), f('b.md'), f('c.lua') }
  end

  it('opens the file behind the filtered row and walks only the filtered files', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    type_filter(p, '.lua')
    assert.are.equal(2, #lines(p.results))

    select_row(p, 2)

    assert.are.same({ 'c.lua' }, { opened[1].path })
    liz.next()
    assert.are.equal('a.lua', opened[2].path)
    liz.prev()
    assert.are.equal('c.lua', opened[3].path)
  end)

  it('applies a filter typed before the results arrive', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    type_filter(p, '.md')
    finish(1, nil, files3())

    assert.are.equal(1, #lines(p.results))
    assert.is_truthy(lines(p.results)[1]:find('b.md', 1, true))
    select_row(p, 1)
    assert.are.equal('b.md', opened[1].path)
    liz.next()
    assert.are.equal('b.md', opened[2].path)
  end)

  it('keeps and reapplies the filter on refresh', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    type_filter(p, '.lua')

    press(p.results, 'n', 'R')
    assert.are.equal(2, #fetches)
    finish(2, nil, { f('x.lua'), f('y.md'), f('z.lua'), f('w.lua') })

    assert.are.equal('.lua', lines(p.filter)[1])
    assert.are.equal(3, #lines(p.results))
    select_row(p, 3)
    assert.are.equal('w.lua', opened[1].path)
  end)

  it('clears the filter when a new reference is submitted', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    type_filter(p, '.lua')

    submit(p, 'dev')
    assert.are.equal('', lines(p.filter)[1])
    finish(2, nil, files3())
    assert.are.equal(3, #lines(p.results))
  end)

  it('leaves no selectable rows after an error', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    submit(p, 'broken')
    finish(2, 'boom')

    assert.are.same({ 'Error: boom' }, lines(p.results))
    select_row(p, 1)
    assert.are.equal(0, #opened)
  end)

  it('leaves no selectable rows after an empty result', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    submit(p, 'dev')
    finish(2, nil, {})

    select_row(p, 1)
    assert.are.equal(0, #opened)
  end)

  it('applies a result that finishes after the picker was closed and reopened', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    press(p.results, 'n', 'q')
    assert.is_false(ui.is_open())

    liz.open()
    p = picker()
    finish(1, nil, files3())
    assert.are.equal(3, #lines(p.results))

    type_filter(p, '.md')
    assert.are.equal(1, #lines(p.results))
    select_row(p, 1)
    assert.are.equal('b.md', opened[1].path)
    liz.next()
    assert.are.equal('b.md', opened[2].path)
  end)

  it('selects from the visible rows after a cached reopen', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    press(p.results, 'n', 'q')

    liz.open()
    p = picker()
    type_filter(p, '.lua')
    select_row(p, 2)
    assert.are.equal('c.lua', opened[1].path)
    liz.next()
    assert.are.equal('a.lua', opened[2].path)
  end)

  it('selects nothing while a refresh is in flight', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, { f('a.lua'), f('b.md'), f('c.lua'), f('d.lua') })
    type_filter(p, '.lua')

    press(p.results, 'n', 'R')
    select_row(p, 1)
    assert.are.equal(0, #opened)
    liz.next()
    assert.are.equal(0, #opened)
  end)

  it('selects nothing after the repository root cannot be resolved', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    local git = require('liz_diff.git')
    git.repo_root = function() return nil end
    submit(p, 'dev')

    select_row(p, 1)
    assert.are.equal(0, #opened)
  end)

  it('records the cursor only for the filter the nav list was built with', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    select_row(p, 2)
    assert.are.equal(2, cache.get('main').cursor_index)

    liz.open()
    p = picker()
    type_filter(p, '.md')
    assert.are.equal(1, cache.get('main').cursor_index)
    press(p.results, 'n', 'q')

    liz.next()
    assert.are.equal(1, cache.get('main').cursor_index)
  end)

  it('restores the cursor of a selection made under the cached filter', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    type_filter(p, '.lua')
    select_row(p, 2)

    liz.open()
    p = picker()
    assert.are.equal('.lua', lines(p.filter)[1])
    assert.are.equal(2, vim.api.nvim_win_get_cursor(p.results_win)[1])
  end)

  it('binds / to the filter line and moves focus there', function()
    liz.open()
    local p = picker()
    press(p.results, 'n', '/')
    assert.are.equal(p.filter_win, vim.api.nvim_get_current_win())
  end)

  it('does not bind the filter key when keymap.filter is false', function()
    config.merge({ keymap = { filter = false } })
    liz.open()
    local p = picker()
    local map = vim.api.nvim_buf_call(p.results, function()
      return vim.fn.maparg('/', 'n', false, true)
    end)
    assert.are.equal(0, vim.tbl_count(map))
  end)

  describe('navigating after the picker was reused', function()
    it('keeps walking the list it was selected from after another ref is submitted', function()
      liz.open()
      local p = picker()
      submit(p, 'main')
      finish(1, nil, files3())
      select_row(p, 1)
      assert.are.equal('main', opened[1].ref)

      require('liz_diff.git').repo_root = function() return 'C:/other' end
      liz.open()
      p = picker()
      submit(p, 'dev')
      finish(2, nil, files3())
      press(p.results, 'n', 'q')

      liz.next()
      assert.are.same({ ref = 'main', path = 'b.md', root = 'C:/repo' }, opened[2])
      assert.are.equal(1, cache.get('dev').cursor_index)
      assert.are.equal(2, cache.get('main').cursor_index)
    end)

    it('does not open a PR diff for a list selected from a raw ref', function()
      stub_pr({ { number = 12, base_oid = 'b', head_oid = 'h' } })
      liz.open()
      local p = picker()
      submit(p, 'main')
      finish(1, nil, files3())
      select_row(p, 1)

      liz.open()
      p = picker()
      submit(p, '#12')
      press(p.results, 'n', 'q')

      liz.next()
      assert.is_nil(opened[2].pr)
      assert.are.equal('main', opened[2].ref)
      assert.are.equal('b.md', opened[2].path)
    end)

    it('opens the PR of the list it was selected from', function()
      local info = { number = 12, base_oid = 'b', head_oid = 'h' }
      stub_pr({ info })
      liz.open()
      local p = picker()
      submit(p, '#12')
      finish(1, nil, files3())
      select_row(p, 1)

      liz.open()
      p = picker()
      submit(p, 'dev')
      press(p.results, 'n', 'q')

      liz.next()
      assert.are.equal(info, opened[2].pr)
      assert.are.equal('b.md', opened[2].path)
    end)
  end)

  it('diffs a list that arrives after a cached reopen with the PR it was fetched for', function()
    local first = { number = 12, base_oid = 'b1', head_oid = 'h1' }
    local second = { number = 12, base_oid = 'b2', head_oid = 'h2' }
    stub_pr({ first, second })
    liz.open()
    local p = picker()
    submit(p, '#12')
    finish(1, nil, files3())
    press(p.results, 'n', 'q')

    liz.open()
    p = picker()
    press(p.results, 'n', 'R')
    press(p.results, 'n', 'q')

    liz.open()
    p = picker()
    finish(2, nil, files3())
    select_row(p, 1)
    assert.are.equal(second, opened[1].pr)
  end)

  it('shows the prompt text and Loading when reopened during the first fetch', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    press(p.results, 'n', 'q')

    liz.open()
    p = picker()
    assert.are.equal('main', lines(p.prompt)[1])
    assert.are.same({ 'Loading...' }, lines(p.results))
    select_row(p, 1)
    assert.are.equal(0, #opened)

    finish(1, nil, files3())
    assert.are.equal(3, #lines(p.results))
  end)

  it('stops showing Loading on reopen once the fetch failed', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, 'boom')
    press(p.results, 'n', 'q')

    liz.open()
    p = picker()
    assert.are_not.same({ 'Loading...' }, lines(p.results))
  end)

  it('offers no stale list on reopen after a refresh came back empty', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    press(p.results, 'n', 'R')
    finish(2, nil, {})
    press(p.results, 'n', 'q')
    assert.is_nil(cache.get('main'))

    liz.open()
    p = picker()
    select_row(p, 1)
    assert.are.equal(0, #opened)
  end)

  it('keeps the last good list when a refresh fails', function()
    liz.open()
    local p = picker()
    submit(p, 'main')
    finish(1, nil, files3())
    press(p.results, 'n', 'R')
    finish(2, 'boom')
    press(p.results, 'n', 'q')

    liz.open()
    p = picker()
    select_row(p, 1)
    assert.are.equal('a.lua', opened[1].path)
  end)

  it('still closes a picker float after a close attempt that threw', function()
    liz.open()
    local real_close = vim.api.nvim_win_close
    vim.api.nvim_win_close = function() error('E11: Invalid in command-line window') end
    local ok = pcall(ui.close)
    vim.api.nvim_win_close = real_close
    assert.is_true(ok)

    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= '' then
        real_close(win, true)
      end
    end
    liz.open()
    vim.api.nvim_win_close(picker().filter_win, true)
    vim.wait(200, function() return not ui.is_open() end)
    assert.is_false(ui.is_open())
  end)

  describe('closing a float', function()
    for _, which in ipairs({ 'filter_win', 'prompt_win', 'results_win' }) do
      it('closes the whole picker when only the ' .. which .. ' closes', function()
        liz.open()
        local p = picker()
        vim.api.nvim_win_close(p[which], true)
        vim.wait(200, function() return #vim.api.nvim_list_wins() == 1 end)
        assert.is_false(ui.is_open())
        assert.are.equal(1, #vim.api.nvim_list_wins())
      end)
    end

    it('lets the picker open again afterwards', function()
      liz.open()
      vim.api.nvim_win_close(picker().filter_win, true)
      vim.wait(200, function() return #vim.api.nvim_list_wins() == 1 end)
      liz.open()
      assert.is_true(ui.is_open())
      assert.are.equal(4, #vim.api.nvim_list_wins())
    end)
  end)
end)
