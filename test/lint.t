#!/bin/sh
# lint.t - shellcheck, in POSIX-dash mode, over every shell file in the repo.
#
# WITHOUT THIS THE .shellcheckrc IS INERT. A config nothing runs is the same
# silent no-op the fail-loud config format exists to refuse: it would read as
# "this repo is shellcheck-clean" while nothing had ever checked. So the rc and
# its runner land together.
#
# The file list is DISCOVERED, not enumerated, so a script cannot be added
# without being linted. It cannot key on `*.sh` either: the naming rules give an
# executed script a BARE name, so a suffix glob would find almost none of them
# and would shrink further with every rename.
#
# SKIPS when shellcheck is absent rather than failing. It is a developer tool,
# not a runtime dependency, and a fresh box running the suite should not fail
# for lacking it.
. "$(dirname "$0")/harness_lib"
harness_init lint

command -v shellcheck >/dev/null 2>&1 || skip "shellcheck absent"

# The file list is built as a real ARGUMENT LIST rather than a space-separated
# string, so nothing depends on word-splitting an unquoted variable. It is done
# inside a function for a second reason: `set --` would otherwise replace this
# script's own positional parameters, which the harness's pass/fail read.
#
# test/conventions.t is skipped because it is VENDORED from
# ~/src/shared-notes/_conventions.t and has to stay byte-identical (tackup notes
# check compares them), so a finding in it belongs in the canonical copy
# upstream rather than in a local edit here.
_run_shellcheck() {
  set --
  for _f in "$HERE"/setup.sh "$HERE"/bin/* "$HERE"/test/run \
            "$HERE"/test/harness_lib "$HERE"/test/*.t; do
    [ -f "$_f" ] || continue
    case "$_f" in *test/conventions.t) continue ;; esac
    set -- "$@" "$_f"
  done
  printf '%s\n' "$#" > "$T/nfiles"
  # The rc is read from the directory the checker runs in. (Careful when
  # editing: a comment whose first word is the tool's own name is a DIRECTIVE.)
  cd "$HERE" || return 2
  shellcheck -s dash -f gcc "$@" 2>&1
}

if ! _out=$(_run_shellcheck); then
  [ -z "$_out" ] || printf '%s\n' "$_out" >&2
  fail "shellcheck findings (above); fix them, or add an inline reason"
fi
[ -z "$_out" ] || { printf '%s\n' "$_out" >&2; fail "unexpected output"; }

pass "$(cat "$T/nfiles") shell files, shellcheck clean"
