if exists("b:current_syntax")
    finish
endif

syntax match PRFixDate "\d\{4}-\d\{2}-\d\{2} \d\{2}:\d\{2}$"
syntax match PRFixSeparator "^━\+"
syntax match PRFixPrimaryEventMsg "commented in"
syntax match PRFixSecondaryEvent "^\s*[○◇].*"

syntax match PRFixUser "●\s\+\zs\S\+"
syntax match PRFixLocation "\S\+#L\d\+"
syntax match PRFixHeader "^  PR #\d\+.*"
syntax region PRFixCodeBlock start="^\s*[│ ]*```" end="^\s*[│ ]*```"

syntax match PRFixTagOutdated "\[outdated\]"
syntax match PRFixTagOrphaned "\[orphaned\]"
syntax match PRFixTagModified "\[modified\]"


highlight default link PRFixDate            Comment
highlight default link PRFixSeparator       NonText
highlight default link PRFixPrimaryEventMsg Identifier
highlight default link PRFixSecondaryEvent  Comment

highlight default link PRFixUser            Identifier
highlight default link PRFixLocation        Directory
highlight default link PRFixHeader          Title
highlight default link PRFixCodeBlock       String

highlight default link PRFixTagOutdated     WarningMsg
highlight default link PRFixTagOrphaned     ErrorMsg
highlight default link PRFixTagModified     Special

let b:current_syntax = "prhistory"
