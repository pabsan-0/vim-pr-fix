vim9script

if exists('g:loaded_prfix')
    finish
endif
g:loaded_prfix = true

command! PRFix prfix#Start()
