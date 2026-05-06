Just a bunch of code to do tests:


```
# ── State ──────────────────────────────────────────────────────────────────────
var s_comments:    list<dict<any>> = []
var s_marked:      list<bool>      = []
var s_comment_buf: number          = -1
var s_qf_buf:      number          = -1
var s_last_idx:    number          = -1
var s_prop_ready:  bool            = false

# ── Helpers ────────────────────────────────────────────────────────────────────

def Run(cmd: string): dict<any>
    var out = systemlist(cmd .. ' 2>&1')
    return {ok: v:shell_error == 0, lines: out}
enddef

def ErrorBuf(header: string, lines: list<string>)
    botright :15new
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    silent! execute 'file PRFix\ Errors'
    setline(1, [header, repeat('─', 60), ''] + lines)
    setlocal nomodifiable
enddef

def Truncate(s: string, n: number): string
    return len(s) > n ? s[: n - 4] .. '...' : s
enddef

# ── Entry point ────────────────────────────────────────────────────────────────

export def Start()
    # 1. Git repo check
    var r = Run('git rev-parse --is-inside-work-tree')
    if !r.ok
        ErrorBuf('[prfix] Not inside a git repository', r.lines)
        return
    endif

    # 2. Fetch open PRs
    r = Run('gh pr list --json number,title,headRefName')
    if !r.ok
        ErrorBuf('[prfix] Failed to list pull requests', r.lines)
        return
    endif
    var prs: list<dict<any>> = json_decode(join(r.lines, ''))
    if empty(prs)
        ErrorBuf('[prfix] No open pull requests found', [])
        return
    endif

    # 3. Default to PR whose branch matches HEAD
    r = Run('git branch --show-current')
    if !r.ok
        ErrorBuf('[prfix] Could not get current branch', r.lines)
        return
    endif
    var cur_branch = r.lines[0]

    var default_idx = 0
    for i in range(len(prs))
        if prs[i].headRefName == cur_branch
            default_idx = i
            break
        endif
    endfor

    # 4. Prompt — 0 or Enter keeps default (marked with *)
    var menu: list<string> = ['Select a PR to review  (0 / Enter = *)']
    for i in range(len(prs))
        var mark = (i == default_idx) ? '* ' : '  '
        menu->add(printf('  %d)  %s#%d  %s', i + 1, mark, prs[i].number, prs[i].title))
    endfor
    var sel = inputlist(menu)
    var chosen_idx: number
    if sel == 0
        chosen_idx = default_idx
    elseif sel >= 1 && sel <= len(prs)
        chosen_idx = sel - 1
    else
        return
    endif
    var pr = prs[chosen_idx]

    # 5. Checkout — any failure is fatal, dump stderr
    r = Run($'gh pr checkout {pr.number}')
    if !r.ok
        ErrorBuf($'[prfix] Failed to checkout PR #{pr.number}', r.lines)
        return
    endif

    # 6. Fetch inline review comments
    r = Run($'gh api repos/:owner/:repo/pulls/{pr.number}/comments')
    if !r.ok
        ErrorBuf('[prfix] Failed to fetch inline comments', r.lines)
        return
    endif
    var raw: list<dict<any>> = json_decode(join(r.lines, ''))
    s_comments = raw->mapnew((_, item): dict<any> => ({
        filename: item.path,
        lnum:     get(item, 'line', get(item, 'original_line', 1)),
        text:     substitute(item.body, '\r', '', 'g'),
    }))
    s_marked = repeat([false], len(s_comments))

    if empty(s_comments)
        echo $'[prfix] No inline comments for PR #{pr.number}.'
        return
    endif

    OpenLayout(pr.number)
enddef

```
