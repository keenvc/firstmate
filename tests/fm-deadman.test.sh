#!/usr/bin/env bash
# Behavior tests for bin/fm-deadman.sh, the generic dead-man rule: a scheduled
# job whose last success is older than two cadences raises one line, once,
# carrying the last log line, and a fresh success re-arms it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DEADMAN="$ROOT/bin/fm-deadman.sh"
TMP_ROOT=$(fm_test_tmproot fm-deadman)

make_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/config" "$h/data/job-1"
  printf '%s' "$h"
}

run_deadman() { FM_HOME=$1 bash "$DEADMAN" check 2>&1; }

age_file() {  # <file> <seconds-ago>
  touch -d "@$(($(date +%s) - $2))" "$1"
}

test_stale_job_wakes_once_with_log_line() {
  local h out
  h=$(make_home stale)
  printf 'job\t100\tdata/job-*/report.md\tstate/job.log\n' > "$h/config/deadman.tsv"
  : > "$h/data/job-1/report.md"
  age_file "$h/data/job-1/report.md" 500
  printf 'ok earlier\nerror: dispatch refused\n\n' > "$h/state/job.log"
  out=$(run_deadman "$h")
  assert_contains "$out" "deadman: job has had no success for" "stale job reported"
  assert_contains "$out" "last log line: error: dispatch refused" "log line carried"
  out=$(run_deadman "$h")
  assert_equals "" "$out" "same staleness stays silent"
  pass "stale job wakes once with its log line"
}

test_healthy_job_is_silent_and_new_success_rearms() {
  local h out
  h=$(make_home rearm)
  printf 'job\t100\tdata/job-*/report.md\tstate/job.log\n' > "$h/config/deadman.tsv"
  : > "$h/data/job-1/report.md"
  age_file "$h/data/job-1/report.md" 150
  out=$(run_deadman "$h")
  assert_equals "" "$out" "within two cadences is healthy"
  age_file "$h/data/job-1/report.md" 500
  out=$(run_deadman "$h")
  assert_contains "$out" "deadman: job" "first stale report"
  : > "$h/data/job-1/report.md"
  out=$(run_deadman "$h")
  assert_equals "" "$out" "fresh success is healthy"
  age_file "$h/data/job-1/report.md" 400
  out=$(run_deadman "$h")
  assert_contains "$out" "deadman: job" "goes stale again after a new success"
  pass "new success re-arms the rule"
}

test_job_that_never_succeeded_counts_from_declaration() {
  local h out
  h=$(make_home never)
  printf 'job\t100\tdata/none-*/report.md\tstate/missing.log\n' > "$h/config/deadman.tsv"
  out=$(run_deadman "$h")
  assert_equals "" "$out" "fresh declaration is not yet stale"
  age_file "$h/config/deadman.tsv" 500
  out=$(run_deadman "$h")
  assert_contains "$out" "no log at" "missing log is named as evidence"
  pass "job with no success is caught from its declaration age"
}

fm_test_run \
  test_stale_job_wakes_once_with_log_line \
  test_healthy_job_is_silent_and_new_success_rearms \
  test_job_that_never_succeeded_counts_from_declaration
