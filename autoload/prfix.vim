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

var s_pending:    number          = 0
var s_raw:        dict<string>    = {}
var s_ctx:        dict<any>       = {}
var s_pr_bufnr:   number          = -1

# Quickfix <-> PR-buffer line mappings (both keyed as strings)
var s_qf_items:   list<dict<any>> = []
var s_lnum_to_qf: dict<number>    = {}   # string(pr_buf_lnum) -> qf idx (1-based)
var s_qf_to_lnum: dict<number>    = {}   # string(qf_idx)      -> pr_buf_lnum


def AssertEnvironment(): bool
    return true
enddef

def FetchPRData(owner: string, repo: string, pr: number)
    s_ctx        = {owner: owner, repo: repo, pr: pr}
    s_raw        = {}
    s_pending    = 0
    s_qf_items   = []
    s_lnum_to_qf = {}
    s_qf_to_lnum = {}

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

    var events: list<dict<any>> = []

    for c in issue_comments
        events->add({
            kind: 'issue_comment',
            user: c.user.login,
            body: c.body,
            time: c.created_at
        })
    endfor

    for r in reviews
        events->add({
            kind: 'review',
            user: r.user.login,
            body: get(r, 'body', ''),
            state: r.state,
            time: r.submitted_at
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
        events->add({
            kind:     'diff_thread',
            user:     head.user.login,
            body:     head.body,
            path:     head.path,
            lineno:   lineno,
            loc:      head.path .. '#L' .. lineno,
            outdated: get(head, 'position', v:null) == v:null,
            replies:  replies,
            time:     head.created_at,
        })
    endfor

    for c in commits
        events->add({
            kind: 'commit',
            user: get(get(c, 'author', {}), 'login', c.commit.author.name),
            sha:  c.sha[ : 6],
            msg:  split(c.commit.message, "\n")[0],
            time: c.commit.author.date,
        })
    endfor

    # Sort all of the stuff we parsed by incoming time
    # Notice that replies are surrogate, they dont get their own time-sorting
    events->sort((a, b) => a.time < b.time ? -1 : a.time > b.time ? 1 : 0)

    # TODO clear function separation here -- split files too

    # Build lines, recording qf positions as we go
    #
    # Header
    var lines: list<string> = [
        '  PR #' .. s_ctx.pr .. '  ·  ' .. s_ctx.owner .. '/' .. s_ctx.repo,
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
            const tag         = e.outdated ? '  [outdated]' : ''
            const has_replies = !empty(e.replies)

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
            s_lnum_to_qf[string(pr_buf_lnum)] = qf_idx
            s_qf_to_lnum[string(qf_idx)]      = pr_buf_lnum

            # Add lines for first comment, then all replies
            lines->add(RightAlign(
                '  ●  ' .. e.user .. '  in ' .. e.loc .. tag, ts))

            # TODO Do I really need the ┌ ?
            const first_pfx = has_replies ? '  ┌  ' : '  │  '
            lines += PrefixBody(e.body, first_pfx, '  │  ')

            for reply in e.replies
                const ts_reply = ShortDate(reply.created_at)
                lines->add(RightAlign('  │  ●  ' .. reply.user.login, ts_reply))
                lines += PrefixBody(reply.body, '  │  │  ', '  │  │  ')
            endfor

            if has_replies
                lines->add('  │')
            endif
        endif
    endfor

    return lines
enddef

# ============================================================
# Buffer
# ============================================================

def CreatePRHistoryBuffer(lines: list<string>)
    const bufname = 'pr://' .. s_ctx.owner .. '/' .. s_ctx.repo
                    .. '/' .. s_ctx.pr

    # Check if buffer exists: load or create
    var bufnr = bufnr(bufname)
    if bufnr == -1
        bufnr = bufadd(bufname)
    endif
    s_pr_bufnr = bufnr

    # Allocate and configure
    bufload(bufnr)
    setbufvar(bufnr, '&buftype',   'nofile')
    setbufvar(bufnr, '&bufhidden', 'hide')
    setbufvar(bufnr, '&swapfile',  0)
    setbufvar(bufnr, '&filetype',  '')

    # Populate
    deletebufline(bufnr, 1, '$')
    setbufline(bufnr, 1, lines)

    # TODO move outside this function, one for creation, one for display
    # If not shown (not in a window), open in split to the right
    if bufwinnr(bufnr) == -1
        execute 'rightbelow vertical sbuffer ' .. bufnr
    endif

    # Pre 9.2 locked window implementation
    const winid = win_getid(bufwinnr(bufnr))
    setwinvar(winid, 'pr_locked_bufnr', bufnr)

    # TODO We'll do this when this is a plugin through filetype
    # ApplySyntax(bufnr)
    # setbufvar(bufnr, '&filetype',  'prcomment')

    PopulateQF()

    # TODO This goes to filetype and is handled automatically
    SetupMappings(bufnr)
enddef

# ============================================================
# Window Locking (Vim 9.0 Workaround)
# ============================================================

def EnforceWinLock()
    # If this window isn't tagged, or it still holds the correct buffer, do nothing.
    if !exists('w:pr_locked_bufnr') || w:pr_locked_bufnr == bufnr()
        return
    endif

    # We are in the PR window, but a different buffer just loaded!
    const hijacked_buf = bufnr()
    const pr_buf = w:pr_locked_bufnr

    # Quietly restore the PR buffer in the current window
    execute 'silent! buffer ' .. pr_buf

    # Shift focus to the code window on the left
    FocusCodeWindow()

    # Open the target code buffer here instead
    execute 'silent! buffer ' .. hijacked_buf
enddef

augroup PRWinLock
    autocmd!
    autocmd BufEnter * EnforceWinLock()
augroup END

# Attempt to move to the left window
# If the window ID hasn't changed, we are the only window: Create a vertical split to the left.
def FocusCodeWindow()
    const pr_win = win_getid()
    wincmd h
    if win_getid() == pr_win
        leftabove vsplit
    endif
enddef

# ============================================================
# Quickfix population
# ============================================================

def PopulateQF()
    setqflist([], 'r', {
        title: 'PR #' .. s_ctx.pr
               .. '  ' .. s_ctx.owner .. '/' .. s_ctx.repo,
        items: s_qf_items,
    })

    # After any :cc/:cn/:cp/:cfile etc., sync the PR buffer.
    augroup PRCommentQFPost
        autocmd!
        autocmd User QuickFixJumpPost SyncPRCursor(getqflist({idx: 0}).idx)
    augroup END
enddef

# ============================================================
# <CR> in the PR buffer
#
# 1. Save position.
# 2. Search backwards for the nearest ● header line.
# 3. If that line has a qf entry, jump to it (opens the file).
# 4. If we didn't leave the PR buffer (no valid file target),
#    restore the cursor.
# 5. Either way, sync the PR buffer cursor to the qf entry's line.
# ============================================================

def PRHistoryBufferOnKeyEnter()
    # Save current location to reset position if needed
    const saved = getcurpos()
    const pr_hist_buf = bufnr()

    # Seek back for a line with an inline comment
    const found = search('^  ●', 'bcnW')
    if found == 0
        return
    endif

    # Check for QF existence
    const lnum = string(found)
    if !has_key(s_lnum_to_qf, lnum)
        return
    endif
    const qf_idx = s_lnum_to_qf[lnum]

    # Move to the left window BEFORE executing the jump
    FocusCodeWindow()

    # Execute jump in the code window
    execute 'cc ' .. qf_idx

    # If :cc didn't open a file (invalid entry) — restore and bail
    if bufnr() == pr_hist_buf
        setpos('.', saved)
        return
    endif
enddef

# ============================================================
# QF → PR buffer sync
# ============================================================

# Move the PR buffer's cursor to the header line for qf entry `idx`.
def SyncPRCursor(idx: number)
    if !has_key(s_qf_to_lnum, string(idx))
        return
    endif

    const pr_lnum = s_qf_to_lnum[string(idx)]
    const pr_window  = bufwinnr(s_pr_bufnr)

    # if prhistbuffer not active, nothing to do
    if pr_window == -1
        return
    endif

    # Else, focus line belonging to QF and center it
    win_execute(win_getid(pr_window), 'normal! ' .. pr_lnum .. 'Gzz')
enddef

# ============================================================
# PR buffer mappings
# ============================================================

# TODO Move this to an ftplugin to apply buffer-local special mappings
def SetupMappings(bufnr: number)
    const winid = win_getid(bufwinnr(bufnr))

    # Trigger cc via enter
    win_execute(winid, 'nnoremap <buffer> <CR> <ScriptCmd>PRHistoryBufferOnKeyEnter()<CR>')

    # TODO buffer easier nav with C-n C-p
enddef

# ============================================================
# Helpers
# ============================================================

def MergePages(raw: string): list<dict<any>>
    const stitched = substitute(trim(raw), ']\s*\[', ',', 'g')
    return empty(stitched) ? [] : json_decode(stitched)
enddef

def RightAlign(left: string, ts: string): string
    const padding = max([1, WIDTH - len(left) - len(ts)])
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


def LoadPullRequest(owner: string, repo: string, prnum: number)
    var r = AssertEnvironment()
    if r == false
        return
    endif

    FetchPRData(owner, repo, prnum)

    const lines = RenderEvents()
    CreatePRHistoryBuffer(lines)

    # EventsToPRFilesBuffer()
    # QuickfixPopulate()
    # These install commands to switch to/from diff view
    # command!
    # command!
    # augroup QF
    #     autocmd!
    #     autocmd QuickFixCmdPost * QuickfixUpdateEvent()
    # augroup
enddef

export def Setup()
    LoadPullRequest("pabsan-0", "vim-pr-fix", 2)
enddef

# TODO Add pr fetching and checking out
# TODO Install a few mappings?
# TODO Add plugin whistleblower
# TODO Add a changed file list
# TODO Add two-pane diff view to edit files with change context?
# TODO Consider location list rather than quickfix?
# TODO Quickfix events autocopy suggestion to p register

# Quickfix events notes:
# - Highlight the current item in PRHistoryBuffer
# - Yank a possible suggestion to P register
