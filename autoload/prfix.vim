vim9script

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
    botright 15new
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

# ── Layout ─────────────────────────────────────────────────────────────────────

def OpenLayout(pr_number: number)
    tabnew

    # Populate the quickfix list
    var items: list<dict<any>> = []
    for c in s_comments
        items->add({
            filename: c.filename,
            lnum:     c.lnum,
            text:     Truncate(split(c.text, "\n")[0], 72),
        })
    endfor
    setqflist([], ' ', {title: $'PR #{pr_number}', items: items})

    # QF window at the bottom (left panel)
    botright copen 12
    s_qf_buf = bufnr('%')

    # Highlight for marked-as-fixed entries
    hi PrfixDone gui=strikethrough cterm=strikethrough guifg=#777777 ctermfg=8
    matchadd('PrfixDone', '.*\[x\].*')

    nnoremap <buffer><silent> <leader>x <ScriptCmd>prfix#MarkFixed()<CR>
    nnoremap <buffer><silent> <leader>s <ScriptCmd>prfix#ApplySuggestion()<CR>

    execute $'autocmd BufUnload <buffer={s_qf_buf}> ++once prfix#Cleanup()'

    # Comment preview — vertical split to the right of QF
    vertical rightbelow new
    s_comment_buf = bufnr('%')
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile wrap
    silent! execute 'file PR\ Comment'
    setlocal nomodifiable

    wincmd h   # back to QF

    augroup PrfixSession
        autocmd!
        autocmd CursorMoved * prfix#UpdatePreview()
        autocmd BufWinEnter * prfix#AddGhostText()
    augroup END

    s_last_idx = -1
    UpdatePreview()
    silent! cc 1
enddef

# ── Preview panel ──────────────────────────────────────────────────────────────

export def UpdatePreview()
    if s_comment_buf < 0 | return | endif

    var idx = -1
    if bufnr('%') == s_qf_buf
        idx = line('.') - 1
    else
        var info = getqflist({idx: 0})
        if type(info) == v:t_dict && has_key(info, 'idx') && info.idx > 0
            idx = info.idx - 1
        endif
    endif

    if idx == s_last_idx || idx < 0 || idx >= len(s_comments)
        return
    endif
    s_last_idx = idx

    var lines = split(s_comments[idx].text, "\n", true)
    setbufvar(s_comment_buf, '&modifiable', 1)
    deletebufline(s_comment_buf, 1, '$')
    setbufline(s_comment_buf, 1, lines)
    setbufvar(s_comment_buf, '&modifiable', 0)
enddef

# ── Ghost text ─────────────────────────────────────────────────────────────────

export def AddGhostText()
    if empty(s_comments) | return | endif

    if !has('patch-9.0.0067')
        if !exists('g:prfix_ghost_warned')
            g:prfix_ghost_warned = true
            echohl WarningMsg
            echom '[prfix] Ghost text requires Vim >= 9.0.0067 — annotation disabled'
            echohl None
        endif
        return
    endif

    if !s_prop_ready
        prop_type_add('prfix_ghost', {highlight: 'PrfixGhost'})
        hi PrfixGhost ctermfg=238 guifg=#606060 gui=italic cterm=italic
        s_prop_ready = true
    endif

    var buf = bufnr('%')
    var rel = fnamemodify(bufname(buf), ':.')

    for c in s_comments
        if c.filename != rel | continue | endif
        var lnum = c.lnum
        if lnum < 1 || lnum > line('$') | continue | endif
        if !empty(prop_list(lnum, {bufnr: buf, types: ['prfix_ghost']}))
            continue
        endif
        var pad = repeat(' ', max([1, 80 - len(getline(lnum))]))
        prop_add(lnum, 1, {
            bufnr:      buf,
            type:       'prfix_ghost',
            text:       pad .. '<-- change requested',
            text_align: 'after',
        })
    endfor
enddef

# ── Mark as fixed ──────────────────────────────────────────────────────────────

export def MarkFixed()
    var idx = line('.') - 1
    if idx < 0 || idx >= len(s_comments) | return | endif
    if s_marked[idx] | return | endif
    s_marked[idx] = true

    var qf   = getqflist()
    qf[idx].text = '[x] ' .. qf[idx].text
    var save = line('.')
    setqflist(qf, 'r')
    cursor(save, 1)
enddef

# ── Apply suggestion ───────────────────────────────────────────────────────────

export def ApplySuggestion()
    var idx = line('.') - 1
    if idx < 0 || idx >= len(s_comments) | return | endif

    var suggestion = ParseSuggestion(s_comments[idx].text)
    if empty(suggestion)
        echo '[prfix] No ```suggestion block in this comment.'
        return
    endif

    execute $'cc {idx + 1}'

    var lnum = s_comments[idx].lnum
    append(lnum, suggestion)

    # Leave block visually selected so gvd / gvp feel natural
    var top = lnum + 1
    var bot = lnum + len(suggestion)
    execute $'normal! {top}GV{bot}G'
enddef

def ParseSuggestion(body: string): list<string>
    var result: list<string> = []
    var inside = false
    for ln in split(body, "\n")
        if ln =~# '^```suggestion'
            inside = true
        elseif ln =~# '^```' && inside
            break
        elseif inside
            result->add(ln)
        endif
    endfor
    return result
enddef

# ── Cleanup ────────────────────────────────────────────────────────────────────

export def Cleanup()
    augroup PrfixSession
        autocmd!
    augroup END
    s_comments    = []
    s_marked      = []
    s_comment_buf = -1
    s_qf_buf      = -1
    s_last_idx    = -1
    if s_prop_ready
        silent! prop_type_delete('prfix_ghost')
        s_prop_ready  = false
    endif
enddef
