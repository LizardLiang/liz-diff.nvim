require('tests.helpers')

describe('liz-diff.diff', function()
  -- diff.lua is heavily Neovim-API dependent (nvim_open_win, diffthis, vsplit).
  -- These are contract tests — they define the expected behavior for integration testing.

  local diff

  before_each(function()
    package.loaded['liz_diff.diff'] = nil
    diff = require('liz_diff.diff')
  end)

  describe('ref_buffer_name()', function()
    it('builds liz-diff://<label>/<path> with no suffix by default', function()
      assert.are.equal('liz-diff://HEAD/a.lua', diff.ref_buffer_name('HEAD', 'a.lua'))
    end)

    it('appends " (new file)" when is_new_file is true', function()
      assert.are.equal('liz-diff://HEAD/new.lua (new file)', diff.ref_buffer_name('HEAD', 'new.lua', true))
    end)

    it('does not append the suffix when is_new_file is false', function()
      assert.are.equal('liz-diff://main/a.lua', diff.ref_buffer_name('main', 'a.lua', false))
    end)
  end)

  describe('ref_rev() / ref_label() — empty-reference baseline is HEAD', function()
    it('ref_rev("") targets HEAD (not the bare index)', function()
      assert.are.equal('HEAD:', diff.ref_rev(''))
    end)

    it('ref_rev(ref) targets the given reference', function()
      assert.are.equal('main:', diff.ref_rev('main'))
    end)

    it('ref_label("") is HEAD (not INDEX)', function()
      assert.are.equal('HEAD', diff.ref_label(''))
    end)

    it('ref_label(ref) is the given reference', function()
      assert.are.equal('main', diff.ref_label('main'))
    end)
  end)

  -- resolve_ref_content() backs M.open()'s "always attempt git show, never a
  -- silent unexplained blank pane" contract (tactical plan step 3 / spec-delta
  -- "Reference Pane Fallback In List Flow"). Mocked vim.fn.system + a
  -- monkey-patched git.is_new_file keep this a pure-logic unit test, no real
  -- Neovim splits required.
  describe('resolve_ref_content()', function()
    local git
    local orig_is_new_file

    before_each(function()
      git = require('liz_diff.git')
      orig_is_new_file = git.is_new_file
    end)

    after_each(function()
      git.is_new_file = orig_is_new_file
    end)

    it('returns the content on a successful git show', function()
      vim.fn.system = function() return 'file contents\n' end
      vim.v = { shell_error = 0 }
      local content, is_new, warning = diff.resolve_ref_content('/repo', 'HEAD:', 'HEAD', 'a.lua')
      assert.are.equal('file contents\n', content)
      assert.is_false(is_new)
      assert.is_nil(warning)
    end)

    it('returns is_new=true with no warning when the path is absent at the ref', function()
      vim.fn.system = function() return "fatal: path 'new.lua' does not exist in 'HEAD'\n" end
      vim.v = { shell_error = 128 }
      git.is_new_file = function() return true end
      local content, is_new, warning = diff.resolve_ref_content('/repo', 'HEAD:', 'HEAD', 'new.lua')
      assert.are.equal('', content)
      assert.is_true(is_new)
      assert.is_nil(warning)
    end)

    it('returns a warning naming the file for an unexpected (non-new-file) failure', function()
      vim.fn.system = function() return 'fatal: unable to read tree object\n' end
      vim.v = { shell_error = 128 }
      git.is_new_file = function() return false end
      local content, is_new, warning = diff.resolve_ref_content('/repo', 'HEAD:', 'HEAD', 'broken.lua')
      assert.are.equal('', content)
      assert.is_false(is_new)
      assert.is_not_nil(warning)
      assert.is_not_nil(warning:find('broken.lua', 1, true))
      assert.is_not_nil(warning:find('unable to read tree object', 1, true))
    end)
  end)

  pending('open() with Modified file opens vimdiff with working left, ref right')
  pending('open() with Added file opens vimdiff with empty (new file) ref pane on the right')
  pending('open() with Deleted file opens vimdiff with a [deleted] placeholder on the left')
  pending('open() with Renamed file uses old_path for reference content')
  pending('open() with binary file shows notify and returns without opening diff')
  pending('open() with empty reference uses HEAD as old side, and (new file) suffix for status A')
  pending('reference buffer has buftype=nofile and bufhidden=wipe')
  pending('reference buffer name follows liz-diff://<ref>/<path> convention')
  pending('reference buffer filetype matches source file extension')
  pending('cleanup_previous() wipes tracked reference buffers no longer in a window')

  pending('open_current() diffs working file on LEFT, HEAD content on RIGHT')
  pending('open_current() reflects the live (unsaved) buffer on the left')
  pending('open_current() with file absent at ref opens an empty right pane')
  pending('open_current() new-file reference buffer name carries the "(new file)" marker')
  pending('open_current() no-ops with notify when buffer has no file / not a repo')
  pending('open_current() reuses cleanup_previous() before opening')
end)
