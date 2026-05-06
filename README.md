# vim-pr-fix

A Vim9 plugin for reviewing GitHub pull request comments inside Vim.

`vim-pr-fix` fetches inline review comments from an open PR, populates the
quickfix list, and opens a three-pane layout — source file on top, comment
list bottom-left, full comment preview bottom-right — so you can work
through every review note without leaving your editor.

## Features

- **Interactive PR selection** at startup with smart default (current branch)
- **Three-pane layout** in a new tab: source, quickfix list, comment preview
- **Live comment preview** — moves as you navigate the quickfix list or use `:cnext` / `:cprev`
- **Apply suggestions** — insert ` ```suggestion ` blocks in-place, visually selected for easy placement
- **Mark as fixed** — flag quickfix entries with `[x]` and strikethrough styling
- **Ghost text** — `<-- change requested` annotation at column 80 on each commented line
- **Error buffer** — any startup failure dumps full CLI output into a scratch buffer

## Requirements

- Vim 9 (Vim9script)
- [`gh` GitHub CLI](https://cli.github.com) — authenticated
- `git` available in `$PATH`
- [vim-gitgutter](https://github.com/airblade/vim-gitgutter) recommended (shows which lines have been modified)

## Installation

With [vim-plug](https://github.com/junegunn/vim-plug):
```vim
Plug 'pabsan-0/vim-pr-fix'
```

Or manually, clone into `~/.vim/pack/plugins/start/vim-pr-fix`.

## Usage

Run `:PRFix` from any buffer inside a git repository. The plugin will:

1. Verify you are inside a git repository
2. Fetch open pull requests with `gh pr list`
3. Prompt you to choose one — the PR whose branch matches your current HEAD is pre-selected (`*`)
4. Check out the selected PR with `gh pr checkout`
5. Fetch all inline review comments via the GitHub API
6. Open a new tab with the three-pane review layout

If any step fails, a scratch buffer opens with the error details.

## Mappings

These mappings are active globally during a PRFix session and work from any
window — the source file, the quickfix list, or anywhere else.

| Mapping | Action |
|---|---|
| `<leader>pf` | Mark the current QF entry as fixed (`[x]` prefix + strikethrough) |
| `<leader>ps` | Insert the ` ```suggestion ` block in-place, visually selected |

When applying a suggestion, the inserted lines are visually selected so you
can move (`gvd` / `gvp`) or delete (`gvd`) them. The displaced original lines
receive a ` ***` ghost-text marker that clears the next time the buffer is
entered.

## Commands

| Command | Action |
|---|---|
| `:PRFix` | Start a PR review session |

## Ghost text

When you navigate to a source file that has review comments, prfix.vim adds
a virtual-text marker at column 80:

```
some code here                                              <-- change requested
```

Use vim-gitgutter to see which lines you have actually changed.

## Help

```vim
:help prfix
```
