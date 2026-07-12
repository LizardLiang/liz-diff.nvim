# liz-diff.nvim

> **Browse git diffs in Neovim from a centered floating window.** Diff any branch, commit, tag, or your unstaged working tree, then jump straight into side-by-side **vimdiff** splits — with zero dependencies.

![Neovim](https://img.shields.io/badge/Neovim-0.9+-57A143?logo=neovim&logoColor=white)
![Made with Lua](https://img.shields.io/badge/made%20with-Lua-2C2D72?logo=lua&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![GitHub stars](https://img.shields.io/github/stars/LizardLiang/liz-diff.nvim?style=social)

`liz-diff.nvim` is a lightweight **Neovim git diff plugin** written in pure Lua. Pop open a floating window, type any git reference, and browse the changed files — then open each one in a native side-by-side diff. No external diff tool, no heavy UI, no plugin dependencies.

![liz-diff.nvim demo — browse git diffs in a Neovim floating window](https://raw.githubusercontent.com/LizardLiang/liz-diff.nvim/master/assets/demo.gif)

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [License](#license)

## Features

- **Centered floating window** with an input prompt and a navigable changed-files list
- **Any git reference** — branch, commit hash, tag, range (`main..HEAD`), or empty for unstaged working-tree changes
- **Pull / merge request review** — prefix the prompt with `#` or `!` (e.g. `#123`) to browse a GitHub PR or GitLab MR's `base...head` diff, read-only base-left / head-right (needs the `gh` / `glab` CLI; core stays zero-dependency)
- **Side-by-side vimdiff** per file status: added files show an empty left pane, deleted files show an empty right pane, renamed files are treated as modified, and — in the `:LizDiff` list flow — binary files notify instead of crashing
- **In-memory cache per keyword** — reopening the panel restores the last reference's results instantly
- **Explicit refresh** — `<CR>` always re-fetches on submit, and `R` refreshes the results list in place without leaving the float
- **Cursor position remembered** per keyword across re-opens
- **Zero dependencies** beyond Neovim 0.9+ and git

## Requirements

- Neovim >= 0.9.0
- git

## Installation

**[lazy.nvim](https://github.com/folke/lazy.nvim)**

```lua
{
  'LizardLiang/liz-diff.nvim',
  cmd = 'LizDiff',
  opts = {},
}
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim)**

```lua
use {
  'LizardLiang/liz-diff.nvim',
  config = function()
    require('liz_diff').setup()
  end,
}
```

## Usage

```
:LizDiff
```

Opens the floating window. Type a git reference in the prompt and press `<CR>` to load the changed files. Leave the prompt empty to see unstaged working-tree changes.

### Keymaps (inside the float)

| Key           | Action                                       |
| ------------- | --------------------------------------------- |
| `<CR>`        | Open selected file in vimdiff                 |
| `R`           | Refresh the file list for the current ref     |
| `j` / `k`     | Navigate the file list                        |
| `<Esc>` / `q` | Close the float                               |

Pressing `<CR>` in the prompt always re-runs `git diff` for the typed reference, even if it was already fetched this session — this keeps unstaged working-tree diffs current. Pressing `R` while the results list is focused re-runs `git diff` for the currently displayed reference without leaving the results window, preserving the cursor position. `R` is a no-op until a reference has been submitted at least once.

### `:LizDiffFile` — current file vs a reference

```
:LizDiffFile [ref]
```

Skips the floating window entirely: diffs the file in the **current buffer**
against a git reference (default `HEAD`) with zero prompts. Also available as
`require('liz_diff').open_current(ref)`.

**Side order is the deliberate opposite of `:LizDiff`**: the working (current
buffer, including unsaved edits) file is on the **LEFT**, the reference/commit
version is on the **RIGHT**, and focus returns to the left window. `:LizDiff`'s
list flow is unchanged (commit left / working right).

```
:LizDiffFile          " current file vs HEAD
:LizDiffFile main     " current file vs the main branch
```

Bind it to `<leader>gd` in your own config:

```lua
vim.keymap.set('n', '<leader>gd', function()
  require('liz_diff').open_current()
end, { desc = 'liz-diff: current file vs HEAD' })
```

If the file doesn't exist at the given reference (new/untracked file), the
right pane opens empty instead of erroring, and its buffer name carries a
` (new file)` marker so it's clear the blank pane means "absent at that ref"
rather than a real empty file. An unresolvable reference also produces an
empty right pane, but without the marker or any error.

### Reviewing a pull / merge request

Inside the `:LizDiff` prompt, prefix the keyword with **`#`** (or **`!`**) followed
by a number to target a pull request / merge request instead of a raw git ref:

```
#123     " GitHub PR 123 (or GitLab MR 123)
!45      " same — either prefix works for either forge
```

The plugin lists the PR's changed files (its `base...head` diff) in the usual
float; pressing `<CR>` on a file opens a **read-only** side-by-side diff with the
PR **base on the LEFT** and **head on the RIGHT**. Both panes come straight from
git — a PR head is a branch you're reviewing, not your working tree, so nothing on
disk is edited.

**Requirements for this feature (optional, only for PR/MR keywords):**

- GitHub → the [`gh`](https://cli.github.com/) CLI, authenticated.
- GitLab → the [`glab`](https://gitlab.com/gitlab-org/cli) CLI, authenticated.

The forge is auto-detected from your `origin` remote's host. Missing commits
(common when reviewing someone else's PR) are fetched on demand — you'll see a
brief `fetching #123…` notification. If the required CLI isn't installed, the
provider can't be detected, or the number can't be resolved, you get a clear
message rather than a crash.

> **Note:** host detection keys off the strings `github` / `gitlab` in the remote
> URL, so GitHub Enterprise / self-hosted GitLab instances on custom domains
> aren't auto-detected yet. Everything else (raw `:LizDiff` refs) is unaffected
> and still needs no external tools.

## Configuration

Call `setup()` with any overrides (all fields optional):

```lua
require('liz_diff').setup({
  width  = 0.8,       -- float width as fraction of editor width
  height = 0.6,       -- float height as fraction of editor height
  border = 'rounded', -- 'rounded' | 'single' | 'double' | 'none'
  keymap = {
    close     = { '<Esc>', 'q' },
    open_diff = '<CR>',
    refresh   = 'R',
  },
})
```

## How it works

1. `:LizDiff` opens a centered float with an input prompt.
2. Typing a reference and pressing `<CR>` runs `git diff --numstat <ref>` asynchronously — every submit fetches fresh, even for a previously-seen reference.
3. Results render as `<status> <path> +<insertions> -<deletions>`.
4. Pressing `<CR>` on a file closes the float and opens a vertical vimdiff split (reference version vs working tree).
5. Pressing `R` with the results list focused re-runs `git diff` for the currently displayed reference in place, preserving the cursor position (clamped to the new list length).
6. Each successful fetch is cached in memory so closing and reopening the panel restores the last reference's results and cursor position without a git call.

## License

MIT — see [LICENSE](LICENSE).

---

<sub>**Keywords:** neovim git diff plugin · nvim vimdiff · side-by-side diff · floating window git browser · diff branch/commit/tag · Lua. Maintainer note: set GitHub repo **Topics** (`neovim`, `neovim-plugin`, `nvim`, `lua`, `git`, `diff`, `vimdiff`, `git-diff`) in repo settings for the biggest discoverability boost.</sub>
