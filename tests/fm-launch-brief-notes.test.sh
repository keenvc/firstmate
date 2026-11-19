#!/usr/bin/env bash
# The launch copy of a brief carries only the newest relaunch progress notes
# (bin/fm-spawn.sh launch_brief_body); the source brief keeps them all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Load the one function under test from its single owner.
eval "$(sed -n '/^  launch_brief_body() {/,/^  }$/p' "$ROOT/bin/fm-spawn.sh")"
command -v launch_brief_body >/dev/null 2>&1 || fail "launch_brief_body not found in bin/fm-spawn.sh"

write_brief() {  # <path> <notes>
  local i
  { printf '# Task\nDo the thing.\n\n# Rules\n1. Be careful.\n'
    for i in $(seq 1 "$2"); do
      printf '\n## Progress note (2026-11-%02dT10:00:00Z)\n\nnote body %s\n## not a note heading\n' "$i" "$i"
    done
  } > "$1"
}

test_old_notes_are_collapsed() {
  local dir out
  dir=$(fm_test_tmproot fm-lbn)
  write_brief "$dir/brief.md" 6
  out=$(launch_brief_body "$dir/brief.md")
  assert_contains "$out" "1. Be careful." "the brief before the notes is kept verbatim"
  [ "$(printf '%s\n' "$out" | grep -c '^## Progress note')" -eq 3 ] || fail "three notes expected: $out"
  assert_contains "$out" "note body 6" "the newest note is kept"
  assert_contains "$out" "note body 4" "the third-newest note is kept"
  case "$out" in *"note body 3"*) fail "an older note leaked into the launch copy" ;; esac
  assert_contains "$out" "3 earlier progress notes are omitted from this launch copy; the full text is in $dir/brief.md" "the omission names the source"
  pass "older progress notes collapse to one pointer at the source brief"
}

test_few_notes_unchanged() {
  local dir
  dir=$(fm_test_tmproot fm-lbn)
  write_brief "$dir/brief.md" 3
  launch_brief_body "$dir/brief.md" | cmp -s - "$dir/brief.md" || fail "a brief within the note budget must pass through byte for byte"
  write_brief "$dir/brief.md" 5
  FM_LAUNCH_BRIEF_PROGRESS_NOTES=5 launch_brief_body "$dir/brief.md" | cmp -s - "$dir/brief.md" || fail "the budget must be configurable"
  pass "a brief within the note budget passes through unchanged"
}

fm_test_run test_old_notes_are_collapsed test_few_notes_unchanged
