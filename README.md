# liz-diff.nvim

> **Browse git diffs in Neovim from a centered floating window.** Diff any branch, commit, tag, or your unstaged working tree, then jump straight into side-by-side **vimdiff** splits — with zero dependencies.

![Neovim](https://img.shields.io/badge/Neovim-0.9+-57A143?logo=neovim&logoColor=white)
![Made with Lua](https://img.shields.io/badge/made%20with-Lua-2C2D72?logo=lua&logoColor=white)
![GitHub stars](https://img.shields.io/github/stars/LizardLiang/liz-diff?style=social)

`liz-diff.nvim` is a lightweight **Neovim git diff plugin** written in pure Lua. Pop open a floating window, type any git reference, and browse the changed files — then open each one in a native side-by-side diff. No external diff tool, no heavy UI, no plugin dependencies.

![liz-diff.nvim demo — browse git diffs in a Neovim floating window](https://raw.githubusercontent.com/LizardLiang/liz-diff/master/assets/demo.gif)

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [How it works](#how-it-works)

## Features

- **Centered floating window** with an input prompt and a navigable changed-files list
- **Any git reference** — branch, commit hash, tag, range (`main..HEAD`), or empty for unstaged working-tree changes
- **Side-by-side vimdiff** per file status: added files show an empty left pane, deleted files show an empty right pane, renamed files are treated as modified, and binary files notify instead of crashing
- **In-memory cache per keyword** — re-querying the same reference is instant
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

| Key           | Action                        |
| ------------- | ----------------------------- |
| `<CR>`        | Open selected file in vimdiff |
| `j` / `k`     | Navigate the file list        |
| `<Esc>` / `q` | Close the float               |

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
  },
})
```

## How it works

1. `:LizDiff` opens a centered float with an input prompt.
2. Typing a reference and pressing `<CR>` runs `git diff --numstat <ref>` asynchronously.
3. Results render as `<status> <path> +<insertions> -<deletions>`.
4. Pressing `<CR>` on a file closes the float and opens a vertical vimdiff split (reference version vs working tree).
5. Results are cached in memory for the session, so the same keyword never re-runs git.

---

<sub>**Keywords:** neovim git diff plugin · nvim vimdiff · side-by-side diff · floating window git browser · diff branch/commit/tag · Lua. Maintainer note: set GitHub repo **Topics** (`neovim`, `neovim-plugin`, `nvim`, `lua`, `git`, `diff`, `vimdiff`, `git-diff`) in repo settings for the biggest discoverability boost.</sub>
