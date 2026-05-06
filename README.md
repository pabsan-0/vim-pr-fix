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
- **Apply suggestions** — insert ` ```suggestion ` blocks as real text, visually selected for easy placement
- **Mark as fixed** — flag quickfix entries with `[x]` and strikethrough styling
- **Ghost text** — `<-- change requested` annotation at column 80 on each commented line
- **Error buffer** — any startup failure dumps full CLI output into a scratch buffer

## Requirements

- Vim 9 (Vim9script)
- [`gh` GitHub CLI](https://cli.github.com) — authenticated
- `git` available in `$PATH`
- [vim-gitgutter](https://github.com/airblade/vim-gitgutter) recommended (shows which lines have been modified)

Ghost text additionally requires Vim >= 9.0.0067. The plugin loads and works
fully without it; only the inline annotations are suppressed.

## Installation

With [vim-plug](https://github.com/junegunn/vim-plug):
```vim
Plug 'pabsan-0/vim-pr-fix'
```

Or manually, clone into `~/.vim/pack/plugins/start/vim-pr-fix`.

## Usage

Run `:PRfix` from any buffer inside a git repository. The plugin will:

1. Verify you are inside a git repository
2. Fetch open pull requests with `gh pr list`
3. Prompt you to choose one — the PR whose branch matches your current HEAD is pre-selected (`*`)
4. Check out the selected PR with `gh pr checkout`
5. Fetch all inline review comments via the GitHub API
6. Open a new tab with the three-pane review layout

If any step fails, a scratch buffer opens with the error details.

## Mappings

All mappings are buffer-local and active only in the quickfix window opened by `:PRfix`.

| Mapping | Action |
|---|---|
| `<leader>x` | Mark the current entry as fixed (`[x]` prefix + strikethrough) |
| `<leader>s` | Insert the ` ```suggestion ` block below the target line, visually selected |

## Commands

| Command | Action |
|---|---|
| `:PRfix` | Start a PR review session |

## Ghost text

When you navigate to a source file that has review comments, prfix.vim adds
a virtual-text marker at column 80:

```
some code here                                              <-- change requested
```

This requires **Vim >= 9.0.0067**. On older builds a one-time warning is
printed and the plugin continues to work without annotations. Use
vim-gitgutter to see which lines you have actually changed.

## Help

```vim
:help prfix
```
