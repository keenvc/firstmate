#!/usr/bin/env bash
# tests/fm-status-parent-channel-required.test.sh - a secondmate's appended
# status line is a captain-facing outcome, so it must reach the parent channel
# or refuse. It must never land only in the lane's own status log.
#
# The generated secondmate charter hands the mate a status-append command
# (bin/fm-brief.sh's STATUS_APPEND). When that command is a raw append to a
# single path, an unresolvable parent channel - a missing or unreadable
# .fm-secondmate-parent binding, which the seeding paths can leave behind and
# which every publisher in bin/fm-parent-channel-lib.sh already refuses with a
# named rc=3 - silently writes the captain-facing line into the mate's own
# state log instead: exit 0, nothing on the channel, nobody woken. Four
# substantive secondmate reports were lost that way.
#
# The command must resolve the channel the one way the library does
# (fm_parent_channel_report) and refuse with a named error when it cannot,
# while a seeded local mate's line still lands in the parent home's
# state/<id>.status exactly once and a main home's identical line still
# reaches its own state/<id>.status, as on a worker's brief.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-parent-channel-required)
mkdir -p "$TMP_ROOT"

cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

# scaffold_brief <home> <id> <scaffold-args...>: generate a brief the way the
# seeding paths do and echo its path.
scaffold_brief() {  # <home> <id> [args...]
  local home=$1 id=$2
  shift 2
  mkdir -p "$home/data" "$home/state" "$home/config"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$@" >/dev/null 2>&1 \
    || fail "fm-brief.sh could not scaffold $id in $home"
  printf '%s\n' "$home/data/$id/brief.md"
}

# status_command <brief>: the append command exactly as the generated brief
# shows it, with the worker's placeholders filled the way a worker fills them.
status_command() {  # <brief>
  local brief=$1 append now
  # shellcheck disable=SC2016 # Match the literal backticks and braces rendered into the brief.
  append=$(sed -n '/`.*{state} \[at=<epoch>\]/s/^[^`]*`\(.*\)`$/\1/p' "$brief" | head -1)
  [ -n "$append" ] || fail "brief carried no status-append command: $brief"
  now=$(date +%s)
  append=${append//\{state\}/done}
  append=${append//\{one short line\}/the audit is complete}
  append=${append//<epoch>/$now}
  case "$append" in
    *"\$("*) fail "brief left an unevaluated command in its status-append line: $append" ;;
  esac
  printf '%s\n' "$append"
}

# seed_mate <home> <id>: a seeded secondmate home with a local parent binding.
seed_mate() {  # <home> <id>
  local home=$1 id=$2
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
    "$TMP_ROOT/main" > "$home/.fm-secondmate-parent"
}

test_seeded_local_mate_appends_to_the_parent_channel() {
  local home brief append parent_file
  home="$TMP_ROOT/seeded-mate"
  mkdir -p "$home/state" "$TMP_ROOT/main/state"
  seed_mate "$home" mate
  brief=$(scaffold_brief "$home" mate --secondmate --no-projects)
  append=$(status_command "$brief")
  parent_file="$TMP_ROOT/main/state/mate.status"
  FM_HOME="$home" bash -c "$append" || fail "a seeded mate's status append was refused"
  [ -f "$parent_file" ] || fail "a seeded mate's line never reached the parent channel"
  grep -F 'the audit is complete' "$parent_file" >/dev/null \
    || fail "the parent channel did not carry the mate's line: $(cat "$parent_file")"
  [ ! -s "$home/state/mate.status" ] \
    || fail "a seeded mate's line was also written to its own state log"
  pass "a seeded local mate publishes its status line on the parent channel only"
}

test_missing_parent_binding_refuses_instead_of_logging_locally() {
  local home brief append out rc
  home="$TMP_ROOT/unbound-mate"
  mkdir -p "$home/state"
  seed_mate "$home" unbound
  rm -f "$home/.fm-secondmate-parent"
  brief=$(scaffold_brief "$home" unbound --secondmate --no-projects)
  append=$(status_command "$brief")
  out=$(FM_HOME="$home" bash -c "$append" 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an unbound mate home silently accepted a captain-facing status line (rc=0)"
  case "$out" in
    *'parent channel'*) ;;
    *) fail "the refusal did not name the parent channel: $out" ;;
  esac
  [ ! -s "$home/state/unbound.status" ] \
    || fail "the captain-facing line fell back to the lane's local log: $(cat "$home/state/unbound.status")"
  pass "a mate home without a parent binding refuses with a named error instead of logging locally"
}

test_unreadable_parent_binding_refuses() {
  local home brief append out rc
  home="$TMP_ROOT/broken-mate"
  mkdir -p "$home/state"
  seed_mate "$home" broken
  printf 'schema=fm-secondmate-parent.v1\nroute=nowhere\n' > "$home/.fm-secondmate-parent"
  brief=$(scaffold_brief "$home" broken --secondmate --no-projects)
  append=$(status_command "$brief")
  out=$(FM_HOME="$home" bash -c "$append" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unusable parent binding silently accepted a status line (rc=0)"
  case "$out" in
    *'parent channel'*) ;;
    *) fail "the refusal did not name the parent channel: $out" ;;
  esac
  [ ! -s "$home/state/broken.status" ] \
    || fail "the captain-facing line fell back to the lane's local log: $(cat "$home/state/broken.status")"
  pass "a mate home with an unusable parent binding refuses instead of logging locally"
}

test_main_home_brief_still_appends_to_its_own_status() {
  local home brief append
  home="$TMP_ROOT/main-worker"
  mkdir -p "$home/state"
  brief=$(scaffold_brief "$home" mainworker firstmate --mode local-only \
    --project "$TMP_ROOT/main" --intent 'keep the local status path working')
  append=$(status_command "$brief")
  case "$append" in
    *'state/mainworker.status'*) ;;
    *) fail "the local-only brief lost its own status path: $append" ;;
  esac
  FM_HOME="$home" bash -c "$append" || fail "a local-only worker's status append was refused"
  grep -F 'the audit is complete' "$home/state/mainworker.status" >/dev/null \
    || fail "a local-only worker's line did not reach its own status file"
  pass "a local-only worker keeps the plain append to its own status file"
}

test_seeded_local_mate_appends_to_the_parent_channel
test_missing_parent_binding_refuses_instead_of_logging_locally
test_unreadable_parent_binding_refuses
test_main_home_brief_still_appends_to_its_own_status
