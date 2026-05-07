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
<!-- - **Ghost text** — `<-- change requested` annotation at column 80 on each commented line -->


## Installation

With [vim-plug](https://github.com/junegunn/vim-plug):
```vim
Plug 'pabsan-0/vim-pr-fix'
```

## Usage

Run `:PRFix` from any buffer inside a git repository. The plugin will:

1. Verify you are inside a git repository
2. Fetch open pull requests with `gh pr list`
3. Prompt you to choose one PR to check for comments
4. Check out the selected PR with `gh pr checkout`
5. Fetch all inline review comments via the GitHub API
6. Open a new tab with a three-pane review layout

If any step fails, a scratch buffer opens with the error details.

## Mappings

| Mapping | Action |
|---|---|
| `<leader>pf` | Mark the current QF entry as fixed (`[x]` prefix + strikethrough) |
| `<leader>ps` | Insert the ` ```suggestion ` block in-place |

When applying a suggestion, the inserted lines are visually selected so you
can move (`gvd` / `gvp`) or delete (`gvd`) them. 

## Commands

| Command | Action |
|---|---|
| `:PRFix` | Start a PR review session |


# TODO

- [ ] Any highlighting / ghost text on worktree window
    - Add mechanism to keep in sync when lines are inserted/removed
    - Maybe seek the locations from the quickfix list if thats possible?
- [ ] Add PR argument to autojump to a PR, or `.` to process the Current one
- [ ] Buffer with all comments, even those with no files, easy to navigate
- [ ] Restore the windows if one does ^Wo or similar
- [ ] Close all windows when closing the Worktree buffer
