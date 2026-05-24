vim9script

if exists('g:loaded_prfix')
    finish
endif
g:loaded_prfix = true

command! -nargs=? PRFix prfix#Setup(<q-args>)
