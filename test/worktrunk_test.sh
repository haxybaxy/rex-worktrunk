#!/usr/bin/env bash
# Checks worktrunk.sh on a throwaway repository: what the pickers list, and
# what a pick or a removal hands back to Rex. git, jq and wt are real; fzf and
# rex are stand-ins that answer with $FZF_ANSWER and write down their arguments.
#
#   bash test/worktrunk_test.sh

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/worktrunk.sh

for tool in git jq wt; do
    command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool is not installed"; exit 0; }
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rex-worktrunk-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)   # the path git and wt report

# Keep the user's worktrunk config, and any hooks in it, out of the test.
: >"$tmp/worktrunk.toml"
export WORKTRUNK_CONFIG_PATH=$tmp/worktrunk.toml
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkdir "$tmp/bin"
cat >"$tmp/bin/fzf" <<'STUB'
#!/usr/bin/env bash
# Answers like fzf: prints $FZF_ANSWER and exits $FZF_STATUS.
cat >/dev/null
[[ -n ${FZF_ANSWER:-} ]] && printf '%s\n' "$FZF_ANSWER"
exit "${FZF_STATUS:-0}"
STUB
cat >"$tmp/bin/rex" <<'STUB'
#!/usr/bin/env bash
# Writes its arguments to $REX_LOG, one line per call.
echo "$*" >>"$REX_LOG"
STUB
chmod +x "$tmp/bin/fzf" "$tmp/bin/rex"
export PATH=$tmp/bin:$PATH
export REX_LOG=$tmp/rex.log

repo=$tmp/repo
mkdir "$repo"
git -C "$repo" init -q -b main
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" branch stale-branch
command wt switch --create feat/demo --no-cd --no-hooks -y -C "$repo" >/dev/null 2>&1
worktree=$(command wt list --format=json -C "$repo" | jq -r '.[] | select(.branch == "feat/demo") | .path')

failed=0

# same LABEL GOT EXPECTED...
# sed indents every line of multi-line output, which ${var//…} can't anchor.
# shellcheck disable=SC2001
same() {
    local label=$1 got=$2
    shift 2
    local expected
    expected=$(printf '%s\n' "$@")
    if [[ $got == "$expected" ]]; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        echo "  expected:"; sed 's/^/    /' <<<"$expected"
        echo "  got:";      sed 's/^/    /' <<<"$got"
        failed=1
    fi
}

# Run the script in DIR with fzf answering ANSWER, and print what it asked of
# rex. Its own output is kept out of the way; stdin is not a terminal, so an
# error is printed without waiting for a key.
handed_back() {
    local dir=$1 answer=$2
    shift 2
    : >"$REX_LOG"
    (cd "$dir" && FZF_ANSWER=$answer "$script" "$@" >"$tmp/out.log" 2>&1 </dev/null) || true
    cat "$REX_LOG"
}

echo "the lists"
same "pick lists worktrees and branches" "$(cd "$repo" && "$script" pick --list)" feat/demo main stale-branch
same "pick works from inside a worktree" "$(cd "$worktree" && "$script" pick --list)" feat/demo main stale-branch
same "remove offers worktrees, never main" "$(cd "$repo" && "$script" remove --list)" feat/demo

if (cd "$tmp" && "$script" remove --list >/dev/null 2>&1 </dev/null); then
    echo "FAIL outside a repository should fail"; failed=1
else
    echo "ok   outside a repository fails"
fi

echo
echo "picking"
# fzf --print-query prints the query, then the selection if there is one.
same "a match opens its worktree, saying where the pick came from" \
    "$(handed_back "$repo" $'dem\nfeat/demo' pick)" \
    "do worktree_go path=$worktree from=$repo branch=feat/demo main=$repo"
same "the main checkout's branch opens the main checkout" \
    "$(handed_back "$worktree" $'mai\nmain' pick)" \
    "do worktree_go path=$repo from=$worktree branch=main main=$repo"
same "a branch without a worktree gets one" \
    "$(handed_back "$repo" $'stale\nstale-branch' pick)" \
    "do worktree_go path=$repo.stale-branch from=$repo branch=stale-branch main=$repo"
same "a new name creates a branch and its worktree" \
    "$(handed_back "$repo" 'new-idea' pick --base @)" \
    "do worktree_go path=$repo.new-idea from=$repo branch=new-idea main=$repo"
same "a new branch starts from --base" \
    "$(git -C "$repo" rev-parse new-idea)" "$(git -C "$repo" rev-parse main)"
same "--slugify turns a typed title into a branch name" \
    "$(handed_back "$repo" 'Fix Login Bug' pick --slugify)" \
    "do worktree_go path=$repo.fix-login-bug from=$repo branch=fix-login-bug main=$repo"
same "a worktrunk shortcut passes through, with the branch it stands for" \
    "$(handed_back "$worktree" '^' pick)" \
    "do worktree_go path=$repo from=$worktree branch=main main=$repo"
same "cancelling hands nothing back" "$(FZF_STATUS=130 handed_back "$repo" '' pick)" ""

echo
echo "removing"
same "a removed worktree's session is closed" \
    "$(handed_back "$repo" 'new-idea' remove)" \
    "do worktree_close path=$repo.new-idea main=$repo"
same "and the worktree is gone" "$([[ -d $repo.new-idea ]] && echo there || echo gone)" gone
same "cancelling removes nothing" \
    "$(handed_back "$repo" '' remove)$([[ -d $worktree ]] && echo there)" there

exit $failed
