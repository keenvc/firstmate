#!/usr/bin/env bash
# Behavior tests for bin/fm-grade-cache.sh: a head that already has a grade is
# never listed for grading again; a new head is.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-grade-cache.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq unavailable\n'; exit 0; }

setup() {  # <dir>: a gh stand-in answering `pr list` from $dir/prs.json
  local dir=$1
  cat > "$dir/gh" <<'G'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls"
cat "$(dirname "$0")/prs.json"
G
  chmod +x "$dir/gh"
  cat > "$dir/prs.json" <<'J'
[{"number":12,"headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","isDraft":false,"author":{"login":"dev"},"title":"second","createdAt":"2026-11-19T10:00:00Z"},
 {"number":11,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","isDraft":false,"author":{"login":"dev"},"title":"first","createdAt":"2026-11-19T09:00:00Z"},
 {"number":13,"headRefOid":"cccccccccccccccccccccccccccccccccccccccc","isDraft":true,"author":{"login":"dev"},"title":"draft","createdAt":"2026-11-19T08:00:00Z"},
 {"number":14,"headRefOid":"dddddddddddddddddddddddddddddddddddddddd","isDraft":false,"author":{"login":"vstorm83"},"title":"his","createdAt":"2026-11-19T08:00:00Z"},
 {"number":15,"headRefOid":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","isDraft":false,"author":{"login":"mergify"},"title":"merge queue: embarking","createdAt":"2026-11-19T08:00:00Z"}]
J
}

gc() { FM_GRADE_CACHE="$DIR/cache.tsv" FM_GRADE_CACHE_GH="$DIR/gh" "$SCRIPT" "$@"; }

test_todo_skips_graded_heads() {
  local out
  DIR=$(fm_test_tmproot fm-gc)
  setup "$DIR"
  out=$(gc todo o/r --exclude-author vstorm83)
  [ "$(printf '%s\n' "$out" | sed -n 1p | cut -d' ' -f1)" = 11 ] || fail "oldest first expected: $out"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ] || fail "drafts, merge-queue and excluded authors must be skipped: $out"
  gc put o/r 11 aaaaaaaaaaaa CLEAN "read diff, low risk"
  out=$(gc todo o/r --exclude-author vstorm83)
  assert_equals "12 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$(printf '%s' "$out" | cut -d' ' -f1-2)" "a graded head (short sha) must not be listed again"
  [ "$(wc -l < "$DIR/calls")" -eq 2 ] || fail "todo must cost exactly one gh call each time"
  pass "todo lists only ungraded heads, oldest first, from one gh call"
}

test_new_head_needs_new_grade() {
  DIR=$(fm_test_tmproot fm-gc)
  setup "$DIR"
  gc put o/r 11 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BLOCK "file.ts:10 bug"
  gc get o/r 11 aaaaaaa >/dev/null || fail "get must hit on a short prefix of the graded head"
  ! gc get o/r 11 ffffffffffff >/dev/null || fail "a different head must miss"
  ! gc get o/r 12 aaaaaaaaaaaa >/dev/null || fail "another PR must miss"
  gc put o/r 11 aaaaaaaaaaaa CLEAN "round 2"
  gc get o/r 11 aaaaaaaaaaaa | grep -q $'\tCLEAN\t' || fail "the newest grade for a head must win"
  [ "$(gc list o/r | wc -l)" -eq 2 ] || fail "list must show one line per head key: $(gc list o/r)"
  pass "a grade is keyed by repo, PR and head; a new head misses"
}

fm_test_run test_todo_skips_graded_heads test_new_head_needs_new_grade
