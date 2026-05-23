vim9script

nnoremap <buffer> <CR> <ScriptCmd>prfix#PRHistoryBufferOnKeyEnter()<CR>
nnoremap <buffer> <C-n> :cnext<CR><C-w>w
nnoremap <buffer> <C-p> :cprev<CR><C-w>w
