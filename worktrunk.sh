#!/usr/bin/env bash
#
# rex-worktrunk pickers, ported from the herdr-worktrunk plugin
# (https://github.com/devashish2203/herdr-worktrunk). Started by init.lua in
# a floating terminal whose working directory is the repo to act on.
#
#   worktrunk.sh pick [--base BRANCH] [--remotes] [--slugify]
#   worktrunk.sh remove
#   worktrunk.sh pick|remove --list      # print the candidates and exit
#
# pick:   fzf over this repo's worktrees and local branches (remote-tracking
#         branches too with --remotes). Enter on a match switches to it; a typed
#         name that matches nothing is created with `wt switch --create` from
#         --base; alt-enter forces the typed name even when it fuzzy-matches.
#         worktrunk shortcuts (^ default, - previous, pr:N, mr:N, PR/MR URLs)
#         pass straight through. The worktree then opens as a Rex session via
#         `rex do worktree_go`.
# remove: fzf over removable worktrees (never the main checkout), then
#         `wt remove --foreground` with worktrunk's own confirmation and
#         safety checks, then the worktree's Rex session is closed via
#         `rex do worktree_close`.

set -uo pipefail

# Output helpers
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
hold()   { printf '\n\033[31m%s\033[0m press any key to close' "$*"; read -r -n1; echo; }

need() {
    command -v "$1" >/dev/null 2>&1 || { hold "$1 not found on PATH"; exit 1; }
}

in_repo() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || { hold "not a git repository: $PWD"; return 1; }
}

# True when NAME is a token worktrunk resolves itself: a branch shortcut
# (^ default, - previous) or `:` syntax (pr:N, mr:N, a PR/MR URL). These go to
# `wt switch` as-is, never with --create.
is_shortcut() {
    case $1 in
        '^'|'-'|*:*) return 0 ;;
        *) return 1 ;;
    esac
}

# True when NAME is an existing local or remote-tracking branch.
ref_exists() {
    git show-ref --quiet --verify "refs/heads/$1" \
        || git show-ref --quiet --verify "refs/remotes/$1"
}

# Print TEXT as a lowercase, hyphenated branch name ("Fix Login Bug" ->
# fix-login-bug). Keeps / . and _; fails when no valid name is left.
branch_slug() {
    local slug
    slug=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E '
        s#[^a-z0-9._/]+#-#g
        s#-*/+-*#/#g
        s#\.{2,}#.#g
        s#/\.+#/#g
        s#^[-/.]+##
        s#[-/.]+$##
    ')
    [[ -n $slug ]] && git check-ref-format "refs/heads/$slug" || return 1
    printf '%s\n' "$slug"
}

# One `wt list` item per line with kind, path and is_main at the top level,
# whichever worktrunk JSON schema was printed.
list_items() {
    jq -c '
        def normalize:
            . + {
                kind: (.kind // (if (.worktree | type) == "object" then "worktree" else "branch" end)),
                path: (.path // .worktree.path // null),
                is_main: (.is_main // .worktree.main // false)
            };
        if type == "array" then
            .[] | normalize
        elif type == "object" and ((.items | type) == "array") then
            .items[] | normalize
        else
            error("unsupported worktrunk list JSON schema")
        end
    '
}

wt_items() {
    command wt list --format=json 2>/dev/null | list_items
}

# Switch / create picker
pick() {
    local base="" remotes=false slugify=false list_only=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --base)    base=$2; shift 2 ;;
            --remotes) remotes=true; shift ;;
            --slugify) slugify=true; shift ;;
            --list)    list_only=true; shift ;;
            *) red "unknown pick option: $1" >&2; exit 2 ;;
        esac
    done
    in_repo || return 1

    local refs=(refs/heads)
    $remotes && refs+=(refs/remotes)

    # Refs first (instant), then `wt list` (stats every checkout); dedupe.
    # Drop origin/HEAD, whose short form is just "origin".
    candidates() {
        {
            git for-each-ref --format='%(refname) %(refname:short)' "${refs[@]}" 2>/dev/null \
                | awk '$1 !~ /\/HEAD$/ {print $2}'
            wt_items | jq -r 'select(.branch != null) | .branch'
        } | awk '!seen[$0]++ { print; fflush() }'
    }

    if $list_only; then candidates; return 0; fi
    need fzf; need jq; need wt

    local base_label="default branch"
    if [[ $base == "@" ]]; then
        local current
        current=$(git branch --show-current 2>/dev/null || true)
        [[ -n $current ]] && base_label="current branch ($current)" || base_label="current HEAD"
    elif [[ -n $base ]]; then
        base_label="$base"
    fi

    # --print-query returns a typed-but-unmatched name so it can be created;
    # alt-enter prints only the query, forcing the typed name over a fuzzy match.
    local choice ret name
    choice=$(candidates | fzf --print-query --reverse --info=inline \
        --bind=alt-enter:print-query \
        --prompt='worktree ❯ ' \
        --header="↵ on a match → switch · type a new name + ↵ → create from ${base_label} · alt-↵ → force typed name · esc → cancel")
    ret=$?
    [[ $ret -gt 1 ]] && return 0      # 130 = esc/abort (0 = picked, 1 = typed a new name)
    name=${choice##*$'\n'}            # last line: the selection if any, else the query
    [[ -z $name ]] && return 0

    if $slugify && ! is_shortcut "$name" && ! ref_exists "$name"; then
        local slug
        if ! slug=$(branch_slug "$name"); then
            hold "no valid branch name in: $name"; return 1
        fi
        name=$slug
    fi

    local wtargs
    if is_shortcut "$name" || ref_exists "$name"; then
        wtargs=(switch "$name")
    else
        wtargs=(switch --create "$name")
        [[ -n $base ]] && wtargs+=(--base "$base")
    fi

    # Let worktrunk create/switch and run its hooks here, where the output is
    # visible; --no-cd because this shell is not the one that will live there.
    local result
    if ! result=$(command wt "${wtargs[@]}" --no-cd --format=json); then
        hold "wt switch failed (see above)."; return 1
    fi

    local wtpath
    wtpath=$(jq -r '.path // empty' <<<"$result" 2>/dev/null)
    if [[ -z $wtpath ]]; then
        wtpath=$(wt_items | jq -r --arg b "$name" 'select(.branch == $b and .kind == "worktree") | .path' | head -n1)
    fi
    if [[ -z $wtpath ]]; then
        hold "worktrunk returned no worktree path for: $name"; return 1
    fi

    # shellcheck disable=SC1010
    if ! rex do worktree_go path="$wtpath" >/dev/null; then
        hold "Could not open a session for $wtpath."; return 1
    fi
}

# Remove picker
remove() {
    local list_only=false
    [[ ${1:-} == --list ]] && list_only=true
    in_repo || return 1
    need jq; need wt

    local items cands
    items=$(wt_items) || { hold "failed to list worktrees"; return 1; }
    # Any real worktree except the main one. The current worktree is included.
    cands=$(jq -r 'select(.kind == "worktree" and .branch != null and .is_main != true) | .branch' <<<"$items")

    if $list_only; then printf '%s\n' "$cands"; return 0; fi
    if [[ -z $cands ]]; then
        yellow "No removable worktrees (only the main worktree exists)."; sleep 2; return 0
    fi
    need fzf

    local name
    name=$(fzf --reverse --info=inline \
        --prompt='remove worktree ❯ ' \
        --header='↵ to remove · worktrunk refuses unmerged branches and dirty worktrees · esc to cancel' <<<"$cands")
    [[ -z $name ]] && return 0

    local wtpath mainpath
    wtpath=$(jq -r --arg b "$name" 'select(.kind == "worktree" and .branch == $b) | .path' <<<"$items" | head -n1)
    mainpath=$(jq -r 'select(.kind == "worktree" and .is_main == true) | .path' <<<"$items" | head -n1)

    # wt remove refuses unmerged branches without -D and dirty worktrees without
    # -f, and asks before anything it considers risky: run it interactively here.
    # -C runs it from the main worktree, so it never has to cd this shell away.
    if ! command wt remove --foreground -C "$mainpath" "$name"; then
        hold "wt remove failed (see above)."; return 0
    fi

    # shellcheck disable=SC1010
    rex do worktree_close path="$wtpath" main="$mainpath" >/dev/null \
        || hold "Removed $name, but could not close its Rex session."
}

case ${1:-} in
    pick)   shift; pick "$@" ;;
    remove) shift; remove "$@" ;;
    *) red "usage: worktrunk.sh pick [--base BRANCH] [--remotes] [--slugify] | remove" >&2; exit 2 ;;
esac
