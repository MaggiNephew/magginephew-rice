# bash completion for cyber (BlackArch tool browser)
_cyber_complete() {
    local cur opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="-l -s -f --update --help"
    COMPREPLY=( $(compgen -W "$opts $(cyber --completions 2>/dev/null)" -- "$cur") )
    return 0
}
complete -F _cyber_complete cyber
