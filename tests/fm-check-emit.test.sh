#!/usr/bin/env bash
# Behavior tests for bin/fm-check-emit.sh: a custom check's unchanged wake text
# is printed once, not on every sweep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-check-emit.sh"

emit() { printf '%s' "$1" | FM_STATE_OVERRIDE="$DIR" "$SCRIPT" "${@:2}"; }

test_unchanged_text_wakes_once() {
  DIR=$(fm_test_tmproot fm-ce)
  assert_equals "PR 7 has no verdict" "$(emit 'PR 7 has no verdict' c1)" "first emission prints"
  assert_equals "" "$(emit 'PR 7 has no verdict' c1)" "the same text is silent"
  assert_equals "PR 8 has no verdict" "$(emit 'PR 8 has no verdict' c1)" "a changed text prints"
  assert_equals "" "$(emit '' c1)" "empty input prints nothing"
  assert_equals "PR 8 has no verdict" "$(emit 'PR 8 has no verdict' c1)" "a condition that cleared and returned prints again"
  pass "an unchanged check text wakes once; a change or a return wakes again"
}

test_numbers_ignore_and_repeat() {
  DIR=$(fm_test_tmproot fm-ce)
  emit 'lane x idle 31m' c2 --ignore-numbers >/dev/null
  assert_equals "" "$(emit 'lane x idle 36m' c2 --ignore-numbers)" "only the number moved"
  emit $'stuck lane y\nchecked at 10:01' c3 --ignore '^checked at' >/dev/null
  assert_equals "" "$(emit $'stuck lane y\nchecked at 10:06' c3 --ignore '^checked at')" "an ignored line does not count"
  emit 'still red' c4 --repeat-after 1 >/dev/null
  printf '%s\n' "$(( $(date +%s) - 5 ))" > "$DIR/.check-emit/c4.at"
  assert_equals "still red" "$(emit 'still red' c4 --repeat-after 1)" "repeat-after re-emits"
  pass "--ignore-numbers, --ignore and --repeat-after shape what counts as new"
}

fm_test_run test_unchanged_text_wakes_once test_numbers_ignore_and_repeat
