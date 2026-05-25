# vim-pr-fix

A Vim9 plugin for reviewing GitHub pull request comments inside Vim.

`vim-pr-fix` fetches the full event timeline of an open PR — commits,
reviews, issue comments, and inline diff threads — and opens a two-pane
layout: source file on the left, chronological PR History buffer on the
right.  The quickfix list is populated with all inline diff comments so you
can navigate them with `:cnext` / `:cprev` while the PR History buffer scrolls
to match.

## Features

- **Interactive PR selection** at startup with smart default (current branch), or pass a number / `.` directly
- **Two-pane layout**: source file on the left, PR History buffer on the right
- **PR History buffer** — full chronological timeline: commits, reviews, issue comments, and inline diff threads with replies
- **Live sync** — navigating the quickfix list highlights the matching entry in the PR History buffer, and pressing `<CR>` in the PR History buffer jumps to the source location
- **Apply suggestions** — auto-replace the exact commented lines with the suggestion block, or visually select them for manual edits
- **Browse in browser** — open any comment or the whole PR in the browser
- **Reload** — re-fetch PR data without restarting the session
- **Working-tree awareness** — line numbers are adjusted when local edits shift the commented lines

## Installation

With [vim-plug](https://github.com/junegunn/vim-plug):
```vim
Plug 'pabsan-0/vim-pr-fix'
```

## Requirements

- Vim 9 (Vim9script)
- `git` available in `$PATH`
- `gh` GitHub CLI (https://cli.github.com) authenticated

## Usage

Run `:PRFix` from any buffer inside a git repository:

```
:PRFix          " prompt to choose an open PR
:PRFix 42       " jump straight to PR #42
:PRFix .        " use the currently checked-out PR
```

The plugin will:

1. Verify you are inside a git repository
2. Check out the selected PR with `gh pr checkout`
3. Fetch all PR events in parallel via the GitHub API
4. Open the PR History buffer in a vertical split to the right

If any step fails, a scratch buffer opens with the error details.

## Layout

```
┌──────────────────────────────┬────────────────────────────────┐
│                              │  PR History buffer             │
│   source file                │  (chronological event timeline │
│   (left pane)                │   with commits, reviews,       │
│                              │   comments, diff threads)      │
└──────────────────────────────┴────────────────────────────────┘
```

The quickfix list is populated with all inline diff comments.  Navigating it
(`:cnext` / `:cprev` or `<C-n>` / `<C-p>` inside the PR History buffer)
scrolls the PR History buffer to keep the active entry in view.

## PR History Buffer Mappings

These mappings are active only inside the PR History buffer (`prhistory` filetype):

| Mapping | Action |
|---|---|
| `<CR>` | Jump to the source file location of the comment under the cursor |
| `<C-n>` | `:cnext` and focus the left (source) window |
| `<C-p>` | `:cprev` and focus the left (source) window |
| `o` | Open the comment under the cursor in the browser |
| `O` | Open the whole PR in the browser |
| `H` | Show the suggestion and original lines in a helper scratch buffer |
| `r` | Reload PR data from GitHub |

## Commands

All session commands are registered when `:PRFix` is run and removed by `:PRFixQuit`.

| Command | Action |
|---|---|
| `:PRFix [arg]` | Start a PR review session (no arg = prompt; number = direct; `.` = current branch) |
| `:PRFixHistoryToggle` | Show or hide the PR History buffer |
| `:PRFixApplySuggestion [n]` | Apply the suggestion from QF entry *n* (default: current) in-place |
| `:PRFixSelectLines [n]` | Visually select the lines referenced by QF entry *n* (default: current) |
| `:PRFixBrowse [n]` | Open the comment for QF entry *n* in the browser |
| `:PRFixQuit` | Close the PR History buffer, clear the quickfix list, and clean up the session |
