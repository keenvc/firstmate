#!/usr/bin/env bash
# tests/fm-classify-current-line-cursor.test.sh - the per-cycle status readers
# must be cursor-backed, not whole-file folds.
#
# status_current_line, status_own_open_decisions and status_end_position sit on
# per-lane, per-poll paths (bin/fm-crew-state.sh once per lane in a check sweep,
# the display-only mark syncs, the steering-inbox loss check, and the stale-wake
# accounted-position capture). A whole-file re-fold of a multi-megabyte status
# log on any of them starves the watcher's heartbeat - the bug this suite
# guards. These tests drive the REAL functions over crafted, growing status
# logs and assert three things: the verdicts stay identical to the whole-file
# fold's, each call reads only the bytes appended since the previous one
# (through the FM_OPEN_DECISIONS_READ_PROBE seam), and a truncated or replaced
# log invalidates the cursor rather than serving a stale open set.
# The fold itself is covered by tests/fm-classify-decision-key.test.sh; the
# drain-level cursor by tests/fm-wake-drain-open-decisions-cursor.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-current-line-cursor-tests)

# Fresh per-case dir so each case's cursor sidecar cannot leak into another.
case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s' "$d"
}

# Append <count> routine filler lines (never an open/close verb) to <file> and
# print the exact number of bytes appended.
append_filler() {  # <file> <count>
  local file=$1 count=$2 i=0 before after
  before=$(LC_ALL=C wc -c < "$file" | tr -d '[:space:]')
  [ -n "$before" ] || before=0
  while [ "$i" -lt "$count" ]; do
    printf 'working: routine filler padding line %04d of a growing status log\n' "$i" >> "$file"
    i=$((i + 1))
  done
  after=$(LC_ALL=C wc -c < "$file" | tr -d '[:space:]')
  printf '%s\n' "$((after - before))"
}

# Bytes the read probe recorded for <file> on the MOST RECENT fold call.
last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

# The whole-file verdict for the same bytes, computed on a copy in a separate
# directory so the copy's own cursor cannot mask a divergence.
whole_file_line() {  # <status-file> <copy-dir>
  local copy="$2/$(basename "$1")"
  cp "$1" "$copy"
  status_current_line "$copy"
}

test_current_line_reads_only_new_bytes_and_keeps_the_verdict() {
  local dir state probe status mirror increment probe_bytes got want
  dir=$(case_dir current-line)
  state="$dir/state"
  mirror="$dir/mirror"
  mkdir -p "$mirror"
  probe="$dir/probe.tsv"
  status="$state/task1.status"
  : > "$probe"
  printf 'kind=ship\n' > "$state/task1.meta"

  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$status"
  append_filler "$status" 300 >/dev/null

  # Cold call: establishes the cursor and pays the one-time whole-log fold.
  got=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_current_line "$status")
  [ "$got" = 'needs-decision [key=api-shape]: pick REST or RPC' ] \
    || fail "cold current line mismatch: got '$got'"

  # Warm call after a small append: the same verdict, reading only that append.
  increment=$(append_filler "$status" 5)
  got=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_current_line "$status")
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$got" = 'needs-decision [key=api-shape]: pick REST or RPC' ] \
    || fail "warm current line dropped the buried decision: got '$got'"
  [ "$probe_bytes" = "$increment" ] \
    || fail "current line read $probe_bytes bytes, expected only the $increment-byte append"

  # A later decision wins as the most-recently-opened one, still bounded.
  printf 'blocked [key=ci]: waiting on CI capacity\n' >> "$status"
  got=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_current_line "$status")
  want=$(whole_file_line "$status" "$mirror")
  [ "$got" = "$want" ] \
    || fail "current line diverged from the whole-file fold: got '$got' want '$want'"
  [ "$got" = 'blocked [key=ci]: waiting on CI capacity' ] \
    || fail "the newest open decision did not become the current line: got '$got'"

  # Resolving it returns to the earlier still-open decision.
  printf 'resolved [key=ci]: capacity granted\n' >> "$status"
  got=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_current_line "$status")
  want=$(whole_file_line "$status" "$mirror")
  [ "$got" = "$want" ] \
    || fail "current line after resolve diverged: got '$got' want '$want'"
  [ "$got" = 'needs-decision [key=api-shape]: pick REST or RPC' ] \
    || fail "resolving the newest decision did not reveal the earlier open one: got '$got'"
  pass "current line reads only new bytes and keeps the whole-file verdict"
}

test_current_line_truncation_invalidates_the_cursor() {
  local dir state status got want
  dir=$(case_dir current-line-truncate)
  state="$dir/state"
  status="$state/task1.status"
  printf 'kind=secondmate\n' > "$state/task1.meta"

  printf 'needs-decision [key=old]: ask the old question\n' > "$status"
  append_filler "$status" 50 >/dev/null
  got=$(status_current_line "$status")
  [ "$got" = 'needs-decision [key=old]: ask the old question' ] \
    || fail "pre-truncation current line mismatch: got '$got'"

  # Truncate in place (same inode, smaller than the recorded offset): the stale
  # open set must not survive.
  printf 'working: fresh log after truncation\n' > "$status"
  got=$(status_current_line "$status")
  want=$(whole_file_line "$status" "$dir")
  [ "$got" = "$want" ] \
    || fail "post-truncation current line diverged: got '$got' want '$want'"
  case "$got" in
    *'key=old'*) fail "truncation served the stale open decision: $got" ;;
  esac

  # Truncate to empty: nothing is open and nothing is declared.
  : > "$status"
  got=$(status_current_line "$status")
  [ -z "$got" ] || fail "empty status log still reported a current line: '$got'"

  # A decision appended after the empty reset is seen again.
  printf 'blocked [key=new]: fresh blocker\n' >> "$status"
  got=$(status_current_line "$status")
  [ "$got" = 'blocked [key=new]: fresh blocker' ] \
    || fail "post-truncation append was not folded: got '$got'"
  pass "truncation invalidates the current-line cursor"
}

test_current_line_replacement_invalidates_the_cursor() {
  local dir state status got want
  dir=$(case_dir current-line-replace)
  state="$dir/state"
  status="$state/task1.status"
  printf 'kind=ship\n' > "$state/task1.meta"

  printf 'needs-decision [key=first]: the first question\n' > "$status"
  status_current_line "$status" > /dev/null

  # Replace by rename: new inode, same path - a rotated log.
  printf 'blocked [key=second]: the replacement blocker\n' > "$status.new"
  mv -f "$status.new" "$status"
  got=$(status_current_line "$status")
  want=$(whole_file_line "$status" "$dir")
  [ "$got" = "$want" ] \
    || fail "replaced-log current line diverged: got '$got' want '$want'"
  [ "$got" = 'blocked [key=second]: the replacement blocker' ] \
    || fail "the rotated log's content was not folded: got '$got'"
  pass "replacement invalidates the current-line cursor"
}

test_current_line_falls_back_when_the_cursor_cannot_be_written() {
  local dir state status cursor got want
  dir=$(case_dir current-line-fallback)
  state="$dir/state"
  status="$state/task1.status"
  printf 'kind=ship\n' > "$state/task1.meta"
  printf 'needs-decision [key=shape]: still answerable\n' > "$status"
  append_filler "$status" 20 >/dev/null

  # A directory where the cursor file belongs: the fold's atomic rename onto it
  # fails, so the reader must fall back to the whole-file fold rather than
  # answering from an empty set.
  cursor=$(_fm_open_decisions_cursor_path "$status")
  mkdir -p "$cursor"
  got=$(status_current_line "$status")
  want=$(whole_file_line "$status" "$dir")
  [ "$got" = "$want" ] \
    || fail "unwritable-cursor current line diverged: got '$got' want '$want'"
  [ "$got" = 'needs-decision [key=shape]: still answerable' ] \
    || fail "unwritable cursor lost the open decision: got '$got'"
  pass "current line falls back to the whole-file fold when the cursor cannot be written"
}

test_own_open_decisions_filters_reserved_keys_and_reads_only_new_bytes() {
  local dir state status probe increment probe_bytes got
  dir=$(case_dir own-decisions)
  state="$dir/state"
  probe="$dir/probe.tsv"
  status="$state/task1.status"
  : > "$probe"
  printf 'kind=ship\n' > "$state/task1.meta"

  printf 'blocked [key=pending-reply-abc]: pending-reply-delivery-unknown: task=task1\n' > "$status"
  printf 'blocked [key=own]: a blocker the task raised itself\n' >> "$status"
  append_filler "$status" 100 >/dev/null

  got=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_own_open_decisions "$status")
  [ "$got" = "$(printf 'own\tblocked\ta blocker the task raised itself')" ] \
    || fail "own open decisions included a reserved key: got '$got'"

  increment=$(append_filler "$status" 4)
  got=$(FM_OPEN_DECISIONS_READ_PROBE="$probe" status_own_open_decisions "$status")
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$got" = "$(printf 'own\tblocked\ta blocker the task raised itself')" ] \
    || fail "warm own open decisions changed the set: got '$got'"
  [ "$probe_bytes" = "$increment" ] \
    || fail "own open decisions read $probe_bytes bytes, expected only the $increment-byte append"

  # Reserved-only set: nothing of the task's own is open.
  printf 'resolved [key=own]: answered\n' >> "$status"
  got=$(status_own_open_decisions "$status")
  [ -z "$got" ] || fail "a reserved-only open set was reported as the task's own: '$got'"
  pass "own open decisions stay cursor-bounded and drop reserved keys"
}

test_end_position_matches_the_span_endpoint_without_folding() {
  local dir state status record end ident span size rc
  dir=$(case_dir end-position)
  state="$dir/state"
  status="$state/task1.status"

  printf 'needs-decision [key=shape]: answer me\n' > "$status"
  record=$(status_end_position "$status") || fail "end position refused a readable status log"
  end=${record%%$'\t'*}
  ident=${record#*$'\t'}
  size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  [ "$end" = "$size" ] || fail "end position $end != file size $size"

  _fm_status_read_ident_size "$status" || fail "identity read failed"
  [ "$ident" = "$_FM_STAT_IDENTITY" ] \
    || fail "end position identity '$ident' != '$_FM_STAT_IDENTITY'"

  # The span reader reports the same endpoint pair, so a caller that only needs
  # "accounted through here" never has to fold the log.
  span=$(status_span_first_actionable_record "$status" 0) || true
  [ "${span%%$'\t'*}" = "$end" ] \
    || fail "end position disagrees with the span reader's offset: '${span%%$'\t'*}' != '$end'"
  span=${span#*$'\t'}
  [ "${span%%$'\t'*}" = "$ident" ] \
    || fail "end position disagrees with the span reader's identity"

  # Appends move the endpoint; nothing is read in between.
  printf 'working: more work\n' >> "$status"
  size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  record=$(status_end_position "$status") || fail "end position failed after append"
  [ "${record%%$'\t'*}" = "$size" ] \
    || fail "end position did not follow the append: ${record%%$'\t'*} != $size"

  # Missing and symlinked logs are refused, exactly as the span reader refuses.
  status_end_position "$state/missing.status" > /dev/null && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "missing status log returned $rc, expected 2"
  ln -s "$status" "$state/link.status"
  status_end_position "$state/link.status" > /dev/null && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "symlinked status log returned $rc, expected 2"
  pass "end position matches the span endpoint without folding"
}

test_current_line_reads_only_new_bytes_and_keeps_the_verdict
test_current_line_truncation_invalidates_the_cursor
test_current_line_replacement_invalidates_the_cursor
test_current_line_falls_back_when_the_cursor_cannot_be_written
test_own_open_decisions_filters_reserved_keys_and_reads_only_new_bytes
test_end_position_matches_the_span_endpoint_without_folding
