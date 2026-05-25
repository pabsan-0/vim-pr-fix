vim9script

nnoremap <buffer> <CR> <ScriptCmd>prfix#PRHistoryBufferOnKeyEnter()<CR>
nnoremap <buffer> <C-n> :cnext<CR><C-w>w
nnoremap <buffer> <C-p> :cprev<CR><C-w>w
nnoremap <buffer> o <ScriptCmd>prfix#PRHistoryBufferOnKeyo()<CR>
nnoremap <buffer> O <ScriptCmd>prfix#PRHistoryBufferOnKeyO()<CR>
nnoremap <buffer> H <ScriptCmd>prfix#PRHistoryBufferOnKeyH()<CR>
nnoremap <buffer> r <ScriptCmd>prfix#PRHistoryBufferOnKeyr()<CR>
