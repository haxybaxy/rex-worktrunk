#!/usr/bin/env bash
# Runs every check: the Lua tests against a fake rex, worktrunk.sh on a
# throwaway repository, and shellcheck on the scripts. Exits non-zero if any
# of them fails.
#
#   bash test/run.sh

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

failed=0

# step NAME COMMAND...
step() {
    local name=$1
    shift
    echo "== $name"
    "$@" || { echo "!! $name failed"; failed=1; }
    echo
}

# Rex runs Lua 5.1, so prefer an interpreter that speaks it.
lua=$(command -v luajit || command -v lua5.1 || command -v lua || true)
if [[ -z $lua ]]; then
    echo "!! no Lua interpreter found (luajit, lua5.1 or lua)"
    failed=1
else
    for test in test/*_test.lua; do
        step "$test" "$lua" "$test"
    done
fi

step test/worktrunk_test.sh bash test/worktrunk_test.sh

if command -v shellcheck >/dev/null 2>&1; then
    step shellcheck shellcheck worktrunk.sh test/*.sh
else
    echo "skip: shellcheck is not installed"
fi

exit $failed
