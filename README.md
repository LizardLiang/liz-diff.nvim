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
- **Any git reference** — branch, commit hash, tag, range (`main..HEAD`), or empty for all uncommitted changes (staged + unstaged + untracked)
- **Pull / merge request review** — prefix the prompt with `#` or `!` (e.g. `#123`) to browse a GitHub PR or GitLab MR's `base...head` diff, read-only head-left / base-right (needs the `gh` / `glab` CLI; core stays zero-dependency)
- **Side-by-side vimdiff** per file status: added files show the working file on the left and an empty, `(new file)`-marked reference pane on the right, deleted files show a `[deleted]` placeholder on the left and the reference content on the right, renamed files are treated as modified, and — in the `:LizDiff` list flow — binary files notify instead of crashing
- **Next / previous file navigation** — after opening a file from the list, jump straight to the next or previous changed file with `]f` / `[f` (or `:LizDiffNext` / `:LizDiffPrev`) without reopening the picker; wraps around at both ends
- **Compare two arbitrary files** — stage any two files with `:LizDiffAdd`, then `:LizDiffCompare` opens them side-by-side (first-staged left, second right) as real editable buffers; fully git-independent, with `:LizDiffList` / `:LizDiffClear` to manage the pair
- **Show both diff panes' paths** — `:LizDiffPaths` blinks each pane's absolute path above it for ~2s (on-disk files show the full path, reference panes show `<ref>:<path>`), useful when the pane titles alone aren't enough
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

Opens the floating window. Type a git reference in the prompt and press `<CR>` to load the changed files. Leave the prompt empty to see all uncommitted changes (staged + unstaged + untracked).

### Keymaps (inside the float)

| Key           | Action                                       |
| ------------- | --------------------------------------------- |
| `<CR>`        | Open selected file in vimdiff                 |
| `R`           | Refresh the file list for the current ref     |
| `j` / `k`     | Navigate the file list                        |
| `<Esc>` / `q` | Close the float                               |

Pressing `<CR>` in the prompt always re-runs `git diff` for the typed reference, even if it was already fetched this session — this keeps unstaged working-tree diffs current. Pressing `R` while the results list is focused re-runs `git diff` for the currently displayed reference without leaving the results window, preserving the cursor position. `R` is a no-op until a reference has been submitted at least once.

### Navigating between files in the diff view

Once you've opened a file from the `:LizDiff` list, you can move to the next or
previous file in that same list **without** reopening the picker:

| Key / command                     | Action                          |
| --------------------------------- | ------------------------------- |
| `]f` &nbsp;·&nbsp; `:LizDiffNext` | Diff the next file in the list  |
| `[f` &nbsp;·&nbsp; `:LizDiffPrev` | Diff the previous file          |

The `]f` / `[f` keymaps are set buffer-locally on the diff panes (both sides),
so they work from whichever pane is focused. Navigation **wraps around** — next
on the last file jumps to the first, previous on the first jumps to the last —
and works for both raw-ref and PR/MR lists. The commands (and the underlying
`require('liz_diff').next()` / `require('liz_diff').prev()`) work from anywhere;
they notify `liz-diff: no active file list` if no `:LizDiff` list has been
opened from yet.

The keys are configurable via `keymap.next_file` / `keymap.prev_file` (set
either to `false` to disable that mapping and rely on the commands only).

### `:LizDiffFile` — current file vs a reference

```
:LizDiffFile [ref]
```

Skips the floating window entirely: diffs the file in the **current buffer**
against a git reference (default `HEAD`) with zero prompts. Also available as
`require('liz_diff').open_current(ref)`.

**Side order**: the working (current buffer, including unsaved edits) file is
on the **LEFT**, the reference/commit version is on the **RIGHT**, and focus
returns to the left window. This is the one shared layout rule across every
liz-diff view — the `:LizDiff` list flow matches it too (working/new side
LEFT, reference RIGHT).

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

The `:LizDiff` list flow follows the same rule and goes one step further: it
always attempts to read the reference version regardless of the file's listed
status (a stale/cached status is never trusted to skip the read). If that read
fails for a reason other than "the file doesn't exist at the reference", a
`WARN`-level notification names the file so a blank reference pane is never
silent or unexplained.

### Reviewing a pull / merge request

Inside the `:LizDiff` prompt, prefix the keyword with **`#`** (or **`!`**) followed
by a number to target a pull request / merge request instead of a raw git ref:

```
#123     " GitHub PR 123 (or GitLab MR 123)
!45      " same — either prefix works for either forge
```

The plugin lists the PR's changed files (its `base...head` diff) in the usual
float; pressing `<CR>` on a file opens a **read-only** side-by-side diff with the
PR **head on the LEFT** and **base on the RIGHT** — matching the working-left /
reference-right rule used everywhere else. Both panes come straight from
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

### Compare two arbitrary files

Stage any two files — from different directories, unrelated git histories, or
no git repository at all — and open them side-by-side, completely independent
of `:LizDiff` / `:LizDiffFile`'s git plumbing:

| Command           | Action                                                          |
| ----------------- | ---------------------------------------------------------------- |
| `:LizDiffAdd`     | Stage the **current buffer's** file into the compare list (max 2) |
| `:LizDiffCompare` | Open the two staged files side-by-side in vimdiff                |
| `:LizDiffList`    | Show the staged files (slot + side) in a float                   |
| `:LizDiffClear`   | Empty the compare list                                           |

**First staged file is LEFT, second staged file is RIGHT** — forced regardless
of your `'splitright'` setting, matching the plugin's one shared layout rule.
Both panes are real, editable file buffers opened via `:edit`, so each buffer's
name is simply the file's own path — no custom naming needed.

Staging a third file while the list already holds a pair opens a float letting
you pick which slot (`1` = LEFT, `2` = RIGHT) the new file replaces, or `q` /
`<Esc>` to cancel and leave the pair untouched.

`<Plug>(LizDiffAdd)` and `<Plug>(LizDiffCompare)` are also available if you'd
rather bind your own keys (no default key is bound):

```lua
vim.keymap.set('n', '<leader>ca', '<Plug>(LizDiffAdd)', { desc = 'liz-diff: stage current file' })
vim.keymap.set('n', '<leader>cc', '<Plug>(LizDiffCompare)', { desc = 'liz-diff: compare staged files' })
```

### `:LizDiffPaths` — show both diff panes' paths

```
:LizDiffPaths
```

Blinks the path of **both** panes of the currently active diff as virtual
text pinned above each pane for about 2 seconds, then auto-clears. Nothing is
ever written into real buffer content.

- An on-disk pane (a real file buffer) shows its full absolute path.
- A `liz-diff://` reference/scratch pane (commit, PR blob, or deleted-file
  placeholder) shows `<ref>:<repo-absolute path>`, e.g. `HEAD:/repo/a.lua`.
- Running it again re-renders and restarts the 2s timer; opening a new diff
  clears any lingering overlay from the previous one.
- With no diff window open in the current tab, it notifies
  `liz-diff: no active diff` and does nothing else.

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
    next_file = ']f',   -- next file in the diff view (false to disable)
    prev_file = '[f',   -- previous file in the diff view (false to disable)
  },
})
```

## How it works

1. `:LizDiff` opens a centered float with an input prompt.
2. Typing a reference and pressing `<CR>` runs `git diff --numstat <ref>` asynchronously — every submit fetches fresh, even for a previously-seen reference.
3. Results render as `<status> <path> +<insertions> -<deletions>`.
4. Pressing `<CR>` on a file closes the float and opens a vertical vimdiff split (working tree on the left, reference version on the right). The file list stays active, so `]f` / `[f` (or `:LizDiffNext` / `:LizDiffPrev`) cycle to sibling files without reopening the picker.
5. Pressing `R` with the results list focused re-runs `git diff` for the currently displayed reference in place, preserving the cursor position (clamped to the new list length).
6. Each successful fetch is cached in memory so closing and reopening the panel restores the last reference's results and cursor position without a git call.

## License

MIT — see [LICENSE](LICENSE).

---

<sub>**Keywords:** neovim git diff plugin · nvim vimdiff · side-by-side diff · floating window git browser · diff branch/commit/tag · Lua. Maintainer note: set GitHub repo **Topics** (`neovim`, `neovim-plugin`, `nvim`, `lua`, `git`, `diff`, `vimdiff`, `git-diff`) in repo settings for the biggest discoverability boost.</sub>
