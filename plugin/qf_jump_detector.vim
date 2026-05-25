vim9script

# plugin/qf_jump_detector.vim
# A global polyfill that emits a User QuickFixJumpPost event

var s_last_qf_id = 0
var s_last_qf_idx = 0

# A bit aggressive but acceptable with Vim9 performance
def DetectQFJump()
    const qf = getqflist({id: 0, idx: 0})
    if qf.id == 0
        return
    endif

    if qf.id != s_last_qf_id || qf.idx != s_last_qf_idx
        s_last_qf_id = qf.id
        s_last_qf_idx = qf.idx
        if exists('#User#QuickFixJumpPost')
            doautocmd <nomodeline> User QuickFixJumpPost
        endif
    endif
enddef

augroup QFJumpDetector
    autocmd!
    autocmd CursorMoved * DetectQFJump()
augroup END
