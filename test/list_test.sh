#!/usr/bin/env bash
# Checks the pickers' candidate lists on a throwaway repository with one
# worktree. Needs git, jq and wt; Rex isn't involved.
#
#   bash test/list_test.sh

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/worktrunk.sh

for tool in git jq wt; do
    command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool is not installed"; exit 0; }
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rex-worktrunk-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init
git -C "$repo" branch stale-branch
command wt switch --create feat/demo --no-cd --no-hooks -y -C "$repo" >/dev/null 2>&1
worktree=$(command wt list --format=json -C "$repo" | jq -r '.[] | select(.branch == "feat/demo") | .path')

failed=0

# same LABEL GOT EXPECTED...
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

same "pick lists worktrees and branches" "$(cd "$repo" && "$script" pick --list)" feat/demo main stale-branch
same "pick works from inside a worktree" "$(cd "$worktree" && "$script" pick --list)" feat/demo main stale-branch
same "remove offers worktrees, never main" "$(cd "$repo" && "$script" remove --list)" feat/demo

if (cd "$tmp" && printf '\n' | "$script" remove --list >/dev/null 2>&1); then
    echo "FAIL outside a repository should fail"; failed=1
else
    echo "ok   outside a repository fails"
fi

exit $failed
