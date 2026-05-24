vim9script

# ============================================================
# pr_comments.vim  –  Fetch and render PR comments in a buffer
#
# Usage:
#   source pr_comments.vim
#   PRComments('owner', 'repo', 42)
#
# Features:
#   - Parallel gh api fetches for all four endpoints
#   - Chronological event buffer with tree layout
#   - Quickfix list populated with all inline diff comments
#   - <CR> in PR buffer  → jump to qf entry, or no-op if not on a comment
#   - qf navigation      → syncs PR buffer cursor to the matching entry
#   - CursorMoved in qf  → live PR buffer sync as you browse
# ============================================================

const WIDTH = 72

# ---- script-level state ------------------------------------

var s_pending:       number       = 0
var s_raw:           dict<string> = {}
var s_ctx:           dict<any>    = {}
var s_pr_bufnr:      number       = -1
var s_pr_url:        string       = ""
var s_pr_sha_latest: string       = ""


# Quickfix <-> PR-buffer line mappings (both keyed as strings)
var s_qf_items:         list<dict<any>> = []
var s_lnum_to_qf:       dict<number>    = {}   # string(pr_buf_lnum) -> qf idx (1-based)
var s_qf_to_lnum:       dict<number>    = {}   # string(qf_idx)      -> pr_buf_lnum
var s_qf_to_lnum_end:   dict<number>    = {}   # string(qf_idx)      -> pr_buf_lnum
var s_qf_to_lcount:     dict<number>    = {}   # string(qf_idx)      -> qf entry number of lines
var s_qf_to_comment:    dict<string>    = {}   # string(qf_idx)      -> qf entry comment
var s_qf_to_suggestion: dict<dict<any>> = {}   # string(qf_idx)      -> qf entry suggestion object
var s_qf_to_browse_url: dict<string>    = {}   # string(qf_idx)      -> qf entry suggestion object

# ============================================================
# Entrypoint
# ============================================================

def AssertEnvironment(prnum: number): bool
    # Redudant check, we may have arrived from elsewhere
    var r = RunShell('git rev-parse --is-inside-work-tree')
    if !r.ok
        ErrorBuf('[PRFix] Not inside a git repository', r.lines)
        return false
    endif

    # Checkout PR tip. Failure is fatal, the user is responsible
    # for allowing this action if fails (stashing... etc)
    r = RunShell($'gh pr checkout {prnum}')
    if !r.ok
        ErrorBuf($'[PRFix] Failed to checkout PR #{prnum}', r.lines)
        return false
    endif

    return true
enddef

def LoadRepoFromCWD(strict: bool = true): any
    const url = system('git config --get remote.origin.url')->trim()
    if v:shell_error == 0 && !empty(url)
        const clean_url = substitute(url, '\.git$', '', '')
        const matches = matchlist(clean_url, '\v[:/]([^/]+)/([^/]+)$')
        if len(matches) >= 3
            return {owner: matches[1], repo: matches[2]}
        endif
    endif

    if strict
        throw "Not in a Git repository or no remote found."
    endif
    return v:null
enddef

def LoadPullNumFromWorktree(strict: bool = true): number
    const cmd = $"gh pr list --search $(git rev-parse HEAD) --state open --json number -q '.[0].number'"
    const result = system(cmd)
    if v:shell_error != 0
        if strict
            throw "Current branch not sitting in a PR."
        endif
        return -1
    endif

    # Still works if not on tip of PR, but older commit!
    return str2nr(result)
enddef

def LoadPullNumFromPrompt(owner: string, repo: string): number
    const cmd = $"gh pr list --repo {owner}/{repo} --state open --limit 20 --json number,title,author"
    const result = system(cmd)
    if v:shell_error != 0
        echoerr "Failed to fetch PRs."
        return -1
    endif

    const prs = json_decode(result)
    if empty(prs)
        echom "No open PRs found."
        return -1
    endif

    const checked_out_pull = LoadPullNumFromWorktree(false)

    # FIXME Mark the currently checked out PR, if any
    redraw
    echo $"Open PRs for {owner}/{repo}:"
    for pr in prs
        const mark = pr.number == checked_out_pull ? "* " : "  "
        echo $" {mark}#{pr.number}  {pr.title} @{pr.author.login}"
    endfor
    echo ""
    const pr_num = str2nr(input("Enter PR number (empty to cancel): #"))
    echo "\n"

    return pr_num > 0 ? pr_num : -1
enddef

def Load(arg: string = "")
    var target_owner = ""
    var target_repo  = ""
    var target_pr    = -1

    # No arguments: Expects being in repo, will ask for PR number to fix
    if arg == ""
        const info = LoadRepoFromCWD()
        target_owner = info.owner
        target_repo  = info.repo
        target_pr    = LoadPullNumFromPrompt(target_owner, target_repo)

    # Number argument: Expects being in repo. Will go straight to fixing
    elseif arg =~ '^\d\+$'
        const info = LoadRepoFromCWD()
        target_owner = info.owner
        target_repo  = info.repo
        target_pr    = str2nr(arg)

    # Dot: currently checked-out PR
    elseif arg == "."
        const info = LoadRepoFromCWD()
        target_owner = info.owner
        target_repo  = info.repo
        target_pr    = LoadPullNumFromWorktree()
    else
        throw "PRFix: Invalid argument: " .. arg
    endif

    if target_pr == -1
        throw "Could not parse PR number"
    endif

    var r = AssertEnvironment(target_pr)
    if r == false
        return
    endif

    # Main launch
    # FIXME convert callback chain into main()-like function
    FetchPRData(target_owner, target_repo, target_pr)
    const lines = RenderEvents()
    PRHistoryBufferCreate(lines)
enddef

# ============================================================
# GH API PR data fetching
# ============================================================

def FetchPRData(owner: string, repo: string, pr: number)
    s_ctx        = {owner: owner, repo: repo, pr: pr}
    s_raw        = {}
    s_pending    = 0
    s_qf_items   = []
    s_lnum_to_qf = {}
    s_qf_to_lnum = {}
    s_pr_url     = $"https://github.com/{owner}/{repo}/pull/{pr}"

    const base = '/repos/' .. owner .. '/' .. repo

    const endpoints: dict<string> = {
        issue_comments: base .. '/issues/' .. pr .. '/comments',
        reviews:        base .. '/pulls/'  .. pr .. '/reviews',
        diff_comments:  base .. '/pulls/'  .. pr .. '/comments',
        commits:        base .. '/pulls/'  .. pr .. '/commits',
    }

    for [key, endpoint] in items(endpoints)
        s_raw[key] = ''
        s_pending += 1

        const k = key

        def OutCb(channel: channel, line: string)
            s_raw[k] ..= line .. "\n"
        enddef

        def CloseCb(channel: channel)
            s_pending -= 1
        enddef

        def ErrCb(channel: channel, msg: string)
            echoerr '[pr_comments/' .. k .. '] ' .. msg
        enddef

        job_start(
            ['gh', 'api', '--paginate', endpoint],
            {out_cb: OutCb, close_cb: CloseCb, err_cb: ErrCb}
        )
    endfor

    # Dont like that it blocks, should be async
    # But user is expected to wait for this job, else no work to be done
    echom "Fetching PR " .. owner .. '/' .. repo .. '/' pr
    while s_pending > 0
        sleep 50m
    endwhile
enddef

def RenderEvents(): list<string>
    var issue_comments: list<dict<any>> = []
    var reviews:        list<dict<any>> = []
    var diff_comments:  list<dict<any>> = []
    var commits:        list<dict<any>> = []

    try
        issue_comments = MergePages(s_raw['issue_comments'])
        reviews        = MergePages(s_raw['reviews'])
        diff_comments  = MergePages(s_raw['diff_comments'])
        commits        = MergePages(s_raw['commits'])
    catch
        echoerr '[pr_comments] JSON decode failed: ' .. v:exception
        return []
    endtry

    s_pr_sha_latest = commits[-1].sha

    var events: list<dict<any>> = []

    for c in issue_comments
        events->add({
            kind: 'issue_comment',
            user: c.user.login,
            body: c.body,
            time: c.created_at,
            browse_url: c.html_url,
        })
    endfor

    for r in reviews
        events->add({
            kind: 'review',
            user: r.user.login,
            body: get(r, 'body', ''),
            state: r.state,
            time: r.submitted_at,
            browse_url: r.html_url,
        })
    endfor

    # threads is actual storage, thread_roots handles sorting
    var thread_roots: list<string>          = []
    var threads:      dict<list<dict<any>>> = {}
    for c in diff_comments
        var root = has_key(c, 'in_reply_to_id') && c.in_reply_to_id != v:null
            ? string(c.in_reply_to_id)
            : string(c.id)
        if !has_key(threads, root)
            threads[root] = []
            thread_roots->add(root)
        endif
        threads[root]->add(c)
    endfor

    for root in thread_roots
        const head    = threads[root][0]
        const replies = threads[root][1 : ]
        const lineno  = get(head, 'line', get(head, 'original_line', '?'))

        const start_line = get(head, 'start_line', get(head, 'original_start_line', v:null))
        var linecount = 1
        if type(lineno) == v:t_number && type(start_line) == v:t_number
            linecount = lineno - start_line + 1
        endif

        events->add({
            kind:       'diff_thread',
            user:       head.user.login,
            body:       head.body,
            path:       head.path,
            lineno:     lineno,
            linecount:  linecount,
            loc:        head.path .. '#L' .. lineno,
            outdated:   get(head, 'position', v:null) == v:null,
            replies:    replies,
            time:       head.created_at,
            browse_url: head.html_url,
            diff_hunk:  head.diff_hunk,
        })
    endfor

    for c in commits
        events->add({
            kind: 'commit',
            user: get(get(c, 'author', {}), 'login', c.commit.author.name),
            sha:  c.sha[ : 6],
            msg:  split(c.commit.message, "\n")[0],
            time: c.commit.author.date,
            browse_url: c.html_url,
        })
    endfor

    # Sort all of the stuff we parsed by incoming time
    # Notice that replies are surrogate, they dont get their own time-sorting
    events->sort((a, b) => a.time < b.time ? -1 : a.time > b.time ? 1 : 0)

    # TODO clear function separation here

    # Handle possible working tree modifications that mangle line numbers
    ApplyLocalLineOffsets(events)

    # Build lines, recording qf positions as we go
    #
    # Header
    var lines: list<string> = [
        $"  PR #{s_ctx.pr} · {s_ctx.owner}/{s_ctx.repo}",
        repeat('━', WIDTH),
        '',
    ]

    s_qf_items   = []
    s_lnum_to_qf = {}
    s_qf_to_lnum = {}

    for e in events
        const ts = ShortDate(e.time)

        if e.kind == 'commit'
            lines->add(RightAlign(
                '  ○  ' .. e.user .. '  committed  ' .. e.sha .. '  ' .. e.msg, ts))

        elseif e.kind == 'review'
            lines->add(RightAlign(
                '  ◇  ' .. e.user .. '  ' .. ReviewLabel(e.state), ts))

        elseif e.kind == 'issue_comment'
            lines->add(RightAlign('  ●  ' .. e.user .. '  commented', ts))
            lines += PrefixBody(e.body, '  │  ', '  │  ')

        elseif e.kind == 'diff_thread'
            const has_replies = !empty(e.replies)

            var tag = ''
            tag ..= e.outdated ? ' [outdated]' : ''
            tag ..= e.changed ?  ' [orphaned]'  : ''

            # Register diff thread location to quickfix list
            const pr_buf_lnum = len(lines) + 1  # 1-based target line
            const qf_idx      = len(s_qf_items) + 1
            s_qf_items->add({
                filename: e.path,
                lnum:     e.lineno,
                col:      1,
                text:     '@' .. e.user .. '  ' .. e.loc
                          .. '  ' .. split(e.body, "\n")[0],
            })
            s_lnum_to_qf[string(pr_buf_lnum)]  = qf_idx
            s_qf_to_lnum[string(qf_idx)]       = pr_buf_lnum
            s_qf_to_lcount[string(qf_idx)]     = e.linecount
            s_qf_to_comment[string(qf_idx)]    = e.body
            s_qf_to_suggestion[string(qf_idx)] = ParseSuggestionFromEvent(e)
            s_qf_to_browse_url[string(qf_idx)] = e.browse_url

            # Add lines for first comment, then all replies
            lines->add(RightAlign(
                '  ●  ' .. e.user .. '  in ' .. e.loc .. tag, ts))

            lines += PrefixBody(e.body, '  │  ', '  │  ')

            for reply in e.replies
                const ts_reply = ShortDate(reply.created_at)
                lines->add(RightAlign('  │  ●  ' .. reply.user.login, ts_reply))
                lines += PrefixBody(reply.body, '  │  │  ', '  │  │  ')
            endfor

            if has_replies
                lines->add('  │')
            endif

            s_qf_to_lnum_end[string(qf_idx)] = len(lines) + 1
        endif
    endfor

    return lines
enddef



# ============================================================
# PRHistoryBuffer
# ============================================================

export def PRHistoryBufferCreate(lines: list<string>)
    const bufname = 'pr://' .. s_ctx.owner .. '/' .. s_ctx.repo
                    .. '/' .. s_ctx.pr

    # Check if buffer exists: load or create
    var bufnr = bufnr(bufname)
    if bufnr == -1
        bufnr = bufadd(bufname)
    endif

    # Allocate and configure
    bufload(bufnr)
    setbufvar(bufnr, '&buftype',   'nofile')
    setbufvar(bufnr, '&bufhidden', 'hide')
    setbufvar(bufnr, '&swapfile',  0)
    setbufvar(bufnr, '&filetype',  'prhistory')
    setbufvar(bufnr, '&signcolumn', 'no')

    s_pr_bufnr = bufnr

    PRHistoryBufferLoadLines(bufnr, lines)
    PRHistoryBufferShow()
enddef

def PRHistoryBufferLoadLines(bufnr: number, lines: list<string>)
    setbufvar(bufnr, '&modifiable',  1)
    deletebufline(s_pr_bufnr, 1, '$')
    setbufline(s_pr_bufnr, 1, lines)

    setqflist([], 'r', {
        title: 'PR #' .. s_ctx.pr
               .. '  ' .. s_ctx.owner .. '/' .. s_ctx.repo,
        items: s_qf_items,
    })
    setbufvar(bufnr, '&modifiable',  0)
enddef

def PRHistoryBufferShow()
    if s_pr_bufnr == -1
        return
    endif

    # If not shown (not in a window), open in split to the right
    if bufwinnr(s_pr_bufnr) == -1
        execute 'rightbelow vertical sbuffer ' .. s_pr_bufnr

        # Handles focusing the right qf entry
        PRHistoryBufferOnQuickFixJump()
    endif

    # Pre 9.2 locked window implementation
    # Buffer needs to be visible when setting this
    setwinvar(bufwinid(s_pr_bufnr), 'pr_locked_bufnr', s_pr_bufnr)
enddef

def PRHistoryBufferHide()
    if s_pr_bufnr == -1
        return
    endif

    const winid = bufwinid(s_pr_bufnr)
    if winid == -1
        return
    endif

    win_execute(winid, 'close')
enddef

def PRHistoryBufferToggle()
    if bufwinid(s_pr_bufnr) == -1
        PRHistoryBufferShow()
    else
        PRHistoryBufferHide()
    endif
enddef

def PRHistoryBufferEventLineSeekBack(): number
    const curr_lnum = line('.')

    var closest_qf_line = -1
    for lnum in keys(s_lnum_to_qf)->map((_, v) => str2nr(v))->sort('n')
        if curr_lnum >= lnum
            closest_qf_line = lnum
        endif
    endfor

    return closest_qf_line
enddef

export def PRHistoryBufferOnKeyEnter()
    # Save current location to reset position if needed
    const saved = getcurpos()
    const pr_hist_buf = bufnr()

    const lnum = PRHistoryBufferEventLineSeekBack()
    const qf_idx = s_lnum_to_qf[lnum]

    # Move to the left window BEFORE executing the jump
    FocusWindowLeft()

    # Execute jump in the code window
    execute 'cc ' .. qf_idx

    # If :cc didn't open a file (invalid entry) — restore and bail
    if bufnr() == pr_hist_buf
        setpos('.', saved)
        return
    endif
enddef

export def PRHistoryBufferOnKeyo()
    const lnum = PRHistoryBufferEventLineSeekBack()
    const qf_idx = s_lnum_to_qf[lnum]
    CommentBrowse(qf_idx)
enddef

export def PRHistoryBufferOnKeyO()
    Browse()
enddef

export def PRHistoryBufferOnKeyH()
    # Open a helper buffer with suggestion info

    # FIXME make this its own buffer type and allow better handling,
    # autoupdating etc. For now enough, for debugging
    const lnum = PRHistoryBufferEventLineSeekBack()
    const qf_idx = s_lnum_to_qf[lnum]
    const suggestion = s_qf_to_suggestion[string(qf_idx)]

    if !suggestion.exists
        echom "No suggestion in current comment"
        return
    endif

    const scratch_name = 'PRCommentInfo'
    const winid = bufwinid(scratch_name)
    if winid == -1
        execute 'belowright split ' .. scratch_name
        setlocal buftype=nofile bufhidden=hide nobuflisted noswapfile
    endif

    const bnr = bufnr(scratch_name)

    # 1. Assemble all the text pieces in memory
    var payload: list<string> = []

    payload += ['=== Original ===']
    payload += suggestion.original_lines
    payload += ['=== Suggested ===']
    payload += suggestion.lines

    deletebufline(bnr, 1, '$')
    setbufline(bnr, 1, payload)
    execute 'win_execute(' .. bufwinid(bnr) .. ', "resize " .. ' .. max([1, len(payload)]) .. ')'
enddef

def PRHistoryBufferOnQuickFixJump()
    const curr_qf_idx = getqflist({idx: 0}).idx

    # Focus current QF-related comment on PRHistory
    const winid = bufwinid(s_pr_bufnr)
    const pr_lnum = get(s_qf_to_lnum, string(curr_qf_idx), -1)
    const pr_lnum_end = get(s_qf_to_lnum_end, string(curr_qf_idx), -1)

    if winid != -1 && pr_lnum != -1
        # Center in view
        win_execute(winid, $'normal! {pr_lnum}Gzz0ww')

        # Update PRHistory buffer higlighting to adequate lines
        const hl_sign = 'PRHistoryQuickfixActiveLine'
        const hl_group = hl_sign .. 'Group'
        sign_unplace(hl_group, {buffer: s_pr_bufnr})
        for lnum in range(pr_lnum, pr_lnum_end - 1)
            sign_place(0, hl_group, hl_sign, s_pr_bufnr, {lnum: lnum})
        endfor
    endif

    # Inject the suggestion-lines-list into register 'p' as Linewise block ('V')
    # This guarantees it will paste exactly as standard lines of code
    # May be empty and purposefully blow the register
    const suggestion = s_qf_to_suggestion[curr_qf_idx]
    setreg('p', suggestion.lines, 'V')
enddef

def PRHistoryBufferOnBufEnter()
    # If we are in PRHistory and a different buffer loads,
    # restore PRHistory and open the new buffer to the left

    # If this window isn't tagged, or it still holds the correct buffer, do nothing.
    if !exists('w:pr_locked_bufnr') || w:pr_locked_bufnr == bufnr()
        return
    endif

    const newly_opened_buf = bufnr()
    execute 'silent! buffer ' .. w:pr_locked_bufnr
    FocusWindowLeft()
    execute 'silent! buffer ' .. newly_opened_buf
enddef

# ============================================================
# Helpers
# ============================================================

def MergePages(raw: string): list<dict<any>>
    const stitched = substitute(trim(raw), ']\s*\[', ',', 'g')
    return empty(stitched) ? [] : json_decode(stitched)
enddef

def RightAlign(left: string, ts: string): string
    const padding = max([1, WIDTH - strdisplaywidth(left) - strdisplaywidth(ts)])
    return left .. repeat(' ', padding) .. ts
enddef

def ShortDate(iso: string): string
    return iso[ : 9] .. ' ' .. iso[11 : 15]
enddef

def ReviewLabel(state: string): string
    const map: dict<string> = {
        APPROVED:           'approved',
        CHANGES_REQUESTED:  'requested changes',
        DISMISSED:          'dismissed',
        COMMENTED:          'reviewed',
    }
    return get(map, state, tolower(state))
enddef

def PrefixBody(body: string, first_pfx: string, rest_pfx: string): list<string>
    const raw = split(body, "\n", true)
    if empty(raw)
        return []
    endif
    var out: list<string> = [first_pfx .. raw[0]]
    for l in raw[1 : ]
        out->add(rest_pfx .. l)
    endfor
    return out
enddef

def FocusWindowLeft(create: bool = false)
    # Attempt to move to the left window
    # FIXME would wincmd p be safer?
    wincmd h

    # If the window ID hasn't changed, we are the only window: Create a vertical split to the left.
    if win_getid() == bufwinid(s_pr_bufnr) && create == true
        leftabove vsplit
    endif
enddef

def FileReadLines(path: string, top: number, bot: number): list<string>
    const bnr = bufnr(path)

    if bnr != -1 && bufloaded(bnr)
        return getbufline(bnr, top, bot)
    endif

    # Otherwise, read it straight off the hard drive
    if filereadable(path)
        const disk_lines = readfile(path)
        if len(disk_lines) >= bot
            return disk_lines[top - 1 : bot - 1]
        endif
    endif

    return []
enddef

def ErrorBuf(header: string, lines: list<string>)
    botright :15new
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    silent! execute 'filename PRFix\ Errors'
    setline(1, [header, repeat('─', 60), ''] + lines)
    setlocal nomodifiable
enddef

def RunShell(cmd: string): dict<any>
    var out = systemlist(cmd .. ' 2>&1')
    return {ok: v:shell_error == 0, lines: out}
enddef

def ParseSuggestionFromEvent(event: dict<any>): dict<any>
    var suggestion = {
        exists: false,
        lcount: 0,
        lines: [],
        original_lines: [],
    }

    # Actual parsing
    var in_suggestion = false
    for line in split(event.body, "\n")
        if line == '```suggestion'
            in_suggestion = true
            continue
        elseif in_suggestion && line == '```'
            in_suggestion = false
            suggestion.exists = true
            continue
        elseif in_suggestion
            suggestion.lcount += 1
            add(suggestion.lines, line)
        endif
    endfor

    # Store original lines for later
    if suggestion.exists
        const raw_hunk = split(get(event, 'diff_hunk', ''), "\n")
        var needed = event.linecount

        # Keep context (' ') and additions ('+'), strip the first char
        for i in range(len(raw_hunk) - 1, 0, -1)
            const line = raw_hunk[i]
            if line =~ '^@@' || needed <= 0
                break
            endif
            if line[0] == ' ' || line[0] == '+'
                suggestion.original_lines->insert(line[1 : ], 0)
                needed -= 1
            endif
        endfor
    endif

    return suggestion
enddef

# ============================================================
# User interface
# ============================================================

def CommentSelectLines(a_qf_idx: number = -1)
    var curr_qf_idx = a_qf_idx
    if curr_qf_idx == -1
        curr_qf_idx = getqflist({idx: 0}).idx
    endif

    const lcount = s_qf_to_lcount[string(curr_qf_idx)]
    execute 'silent! cc ' .. curr_qf_idx

    execute 'normal! V'
    if lcount > 1
        execute 'normal! ' .. (lcount - 1) .. 'k'
    endif
enddef

def CommentApplySuggestion(a_qf_idx: number = -1)
    var curr_qf_idx = a_qf_idx
    if curr_qf_idx == -1
        curr_qf_idx = getqflist({idx: 0}).idx
    endif

    # Assert comment carries a suggestion
    const suggestion = get(s_qf_to_suggestion, string(curr_qf_idx), {exists: false})
    if !suggestion.exists
        return
    endif

    const qf_item = getqflist()[curr_qf_idx - 1]
    const target_bufnr = qf_item.bufnr
    bufload(target_bufnr)

    const old_lines_count = s_qf_to_lcount[string(curr_qf_idx)]
    const bot = qf_item.lnum
    const top = bot - old_lines_count + 1

    # Verify user hasnt already modified content
    const current_lines = getbufline(target_bufnr, top, bot)
    if current_lines != suggestion.original_lines
        execute $'silent! cc {curr_qf_idx}'
        echom "Target lines have changed: Refusing to auto-apply suggestion."
        return
    endif

    if suggestion.lcount == 0
        # Plain deletion
        deletebufline(target_bufnr, top, bot)
    else
        # Multiline replacement. Setline then delete/append not to mangle QF lnums
        setbufline(target_bufnr, bot, suggestion.lines[-1])
        if old_lines_count > 1
            deletebufline(target_bufnr, top, bot - 1)
        endif
        if suggestion.lcount > 1
            appendbufline(target_bufnr, top - 1, suggestion.lines[0 : suggestion.lcount - 2])
        endif
    endif

    execute $'silent! cc {curr_qf_idx}'
    execute $'normal! {top}GV{bot}G'
enddef

def CommentBrowse(a_qf_idx: number = -1)
    var curr_qf_idx = a_qf_idx
    if curr_qf_idx == -1
        curr_qf_idx = getqflist({idx: 0}).idx
    endif

    const url = s_qf_to_browse_url[string(curr_qf_idx)]
    system("xdg-open " .. url .. " >/dev/null 2>&1")
enddef

def Browse()
    system("xdg-open " .. s_pr_url .. " >/dev/null 2>&1")
enddef

def ApplyLocalLineOffsets(events: list<dict<any>>)
    var file_offsets: dict<list<dict<number>>> = {}

    for e in events
        if e.kind == 'diff_thread'
            # Parse git diff to for changes in the working tree
            if !has_key(file_offsets, e.path)
                var hunks: list<dict<number>> = []

                if filereadable(e.path)
                    const cmd = $'git diff -U0 {s_pr_sha_latest} -- "{e.path}"'
                    const diff_output = systemlist(cmd)
                    var cumulative_delta = 0

                    for line in diff_output
                        if line =~ '^@@'
                            const matches = matchlist(line, '^@@ -\(\d\+\)\%(,\(\d\+\)\)\? +\(\d\+\)\%(,\(\d\+\)\)\? @@')
                            if !empty(matches)
                                const old_start = str2nr(matches[1])
                                const old_count = matches[2] == '' ? 1 : str2nr(matches[2])
                                const new_start = str2nr(matches[3])
                                const new_count = matches[4] == '' ? 1 : str2nr(matches[4])

                                cumulative_delta += (new_count - old_count)

                                hunks->add({
                                    old_start: old_start,
                                    old_end: old_start + old_count - 1,
                                    delta: cumulative_delta
                                })
                            endif
                        endif
                    endfor
                endif

                file_offsets[e.path] = hunks
            endif

            # Calculate the line offset based on the cached hunks
            const hunks = file_offsets[e.path]
            var shift = 0
            var changed = false

            for hunk in hunks
                if e.lineno < hunk.old_start
                    break
                elseif e.lineno >= hunk.old_start && e.lineno <= hunk.old_end
                    changed = true
                    break
                else
                    shift = hunk.delta
                endif
            endfor

            # Apply the results to the event object
            if changed
                e.changed = true
            else
                e.changed = false
                e.lineno += shift
            endif
        endif
    endfor
enddef

# ============================================================
# Entrypoint
# ============================================================

export def Setup(arg: string = "")

    highlight default PRHistoryQuickfixActive ctermbg=237 guibg=#3a3a3a
    sign define PRHistoryQuickfixActiveLine linehl=PRHistoryQuickfixActive

    Load(arg)

    command! -nargs=? PRFixCommentSelectLines     CommentSelectLines(<args>)
    command! -nargs=? PRFixCommentApplySuggestion CommentApplySuggestion(<args>)
    command! -nargs=? PRFixCommentBrowse          CommentBrowse(<args>)

    command! PRFixHistoryToggle PRHistoryBufferToggle()
    command! PRFixBrowse        Browse()

    # command! PRFixFiles
    # command! PRFixQuit

    augroup PRHistoryAutoCmd
        autocmd!
        autocmd BufEnter * PRHistoryBufferOnBufEnter()
        autocmd User QuickFixJumpPost PRHistoryBufferOnQuickFixJump()
    augroup END

enddef

# THIS release
# TODO Add pr fetching and checking out
# TODO Syntax ftplugin

# FUTURE
# TODO Add a changed file list -> this can be done with fugitive Gvdiffsplit
# TODO Add two-pane diff view to edit files with change context?-> this can be done with fugitive Gvdiffsplit
# TODO Add info function
# TODO Need a visual hint on PRHistoryBuffer for the currently active entry
# TODO Add ghost text to qf entries, both on PRHistory and Worktree
# TODO Containerize to allow multiple PRs at once
# TODO Allow changed files w.r. remote
