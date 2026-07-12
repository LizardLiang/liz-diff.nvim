require('tests.helpers')

describe('liz-diff.pr', function()
  local pr

  before_each(function()
    package.loaded['liz_diff.pr'] = nil
    pr = require('liz_diff.pr')
  end)

  describe('parse_keyword()', function()
    it('parses a #-prefixed PR number', function()
      assert.are.equal(123, pr.parse_keyword('#123'))
    end)

    it('parses a !-prefixed MR number', function()
      assert.are.equal(45, pr.parse_keyword('!45'))
    end)

    it('returns nil for a bare number (no prefix)', function()
      assert.is_nil(pr.parse_keyword('123'))
    end)

    it('returns nil for a plain ref', function()
      assert.is_nil(pr.parse_keyword('main'))
    end)

    it('returns nil for a lone prefix', function()
      assert.is_nil(pr.parse_keyword('#'))
    end)

    it('returns nil for a doubled prefix', function()
      assert.is_nil(pr.parse_keyword('##1'))
    end)

    it('returns nil for a prefix followed by non-digits', function()
      assert.is_nil(pr.parse_keyword('#12a'))
    end)

    it('returns nil for trailing text after digits', function()
      assert.is_nil(pr.parse_keyword('#12 foo'))
    end)

    it('returns nil for non-string input', function()
      assert.is_nil(pr.parse_keyword(nil))
    end)
  end)

  describe('detect_provider()', function()
    it('detects GitHub from an HTTPS URL', function()
      assert.are.equal('github', pr.detect_provider('https://github.com/owner/repo.git'))
    end)

    it('detects GitHub from an SSH URL', function()
      assert.are.equal('github', pr.detect_provider('git@github.com:owner/repo.git'))
    end)

    it('detects GitLab from an HTTPS URL', function()
      assert.are.equal('gitlab', pr.detect_provider('https://gitlab.com/owner/repo.git'))
    end)

    it('detects GitLab from an SSH URL', function()
      assert.are.equal('gitlab', pr.detect_provider('git@gitlab.com:owner/repo.git'))
    end)

    it('detects a self-hosted GitLab host containing gitlab', function()
      assert.are.equal('gitlab', pr.detect_provider('https://gitlab.example.com/g/r.git'))
    end)

    it('returns nil for an unknown host', function()
      assert.is_nil(pr.detect_provider('https://bitbucket.org/owner/repo.git'))
    end)

    it('returns nil for non-string input', function()
      assert.is_nil(pr.detect_provider(nil))
    end)
  end)

  describe('parse_gh_view()', function()
    it('extracts base/head oids and refs', function()
      local json = '{"baseRefName":"main","headRefName":"feat","baseRefOid":"aaa111","headRefOid":"bbb222"}'
      local info = pr.parse_gh_view(json)
      assert.are.equal('aaa111', info.base_oid)
      assert.are.equal('bbb222', info.head_oid)
      assert.are.equal('main', info.base_ref)
      assert.are.equal('feat', info.head_ref)
    end)

    it('returns nil when oids are missing', function()
      assert.is_nil(pr.parse_gh_view('{"baseRefName":"main","headRefName":"feat"}'))
    end)

    it('returns nil for invalid JSON', function()
      assert.is_nil(pr.parse_gh_view('not json'))
    end)
  end)

  describe('parse_glab_view()', function()
    it('extracts base/head shas from diff_refs', function()
      local json = '{"target_branch":"main","source_branch":"feat",'
        .. '"diff_refs":{"base_sha":"aaa111","head_sha":"bbb222","start_sha":"aaa111"}}'
      local info = pr.parse_glab_view(json)
      assert.are.equal('aaa111', info.base_oid)
      assert.are.equal('bbb222', info.head_oid)
      assert.are.equal('main', info.base_ref)
      assert.are.equal('feat', info.head_ref)
    end)

    it('falls back to branch names when diff_refs is absent', function()
      local info = pr.parse_glab_view('{"target_branch":"main","source_branch":"feat"}')
      assert.is_nil(info.base_oid)
      assert.is_nil(info.head_oid)
      assert.are.equal('main', info.base_ref)
      assert.are.equal('feat', info.head_ref)
    end)

    it('returns nil when neither oids nor branch names are present', function()
      assert.is_nil(pr.parse_glab_view('{"iid":5}'))
    end)

    it('returns nil for invalid JSON', function()
      assert.is_nil(pr.parse_glab_view('not json'))
    end)
  end)
end)
