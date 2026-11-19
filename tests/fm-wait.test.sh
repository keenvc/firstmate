#!/usr/bin/env bash
# Behavior tests for bin/fm-wait.sh: it blocks across reads in bash and prints
# exactly one line when the condition is met, times out, or reads keep failing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-wait.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq unavailable\n'; exit 0; }

# fake_gh <dir>: a gh stand-in. `pr view` and `api repos/...` answer the next
# numbered response file (sticking on the last); `api rate_limit` answers
# $dir/rate.json. Each call is logged to $dir/calls.
fake_gh() {
  local dir=$1
  mkdir -p "$dir/resp"
  cat > "$dir/gh" <<'EOF'
#!/usr/bin/env bash
d=$(dirname "$0")
printf '%s\n' "$*" >> "$d/calls"
if [ "$1 $2" = "api rate_limit" ]; then cat "$d/rate.json"; exit 0; fi
n=$(cat "$d/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$d/n"
f="$d/resp/$n"; [ -e "$f" ] || f=$(ls "$d/resp" | grep -v "[.]err$" | sort -n | tail -1 | sed "s|^|$d/resp/|")
[ -s "$f.err" ] && { cat "$f.err" >&2; exit 1; }
cat "$f"
EOF
  chmod +x "$dir/gh"
  printf '{"resources":{"graphql":{"remaining":5000,"reset":0},"core":{"remaining":5000,"reset":0}}}' > "$dir/rate.json"
}

pr_json() {  # <state> <head> <check-status> <conclusion>
  printf '{"state":"%s","headRefOid":"%s","mergeStateStatus":"CLEAN","reviewDecision":"","statusCheckRollup":[{"__typename":"CheckRun","name":"unit tests","status":"%s","conclusion":"%s"},{"__typename":"StatusContext","context":"buildkite/app","state":"SUCCESS"}]}' "$1" "$2" "$3" "$4"
}

run_wait() {  # <dir> <args...>
  local dir=$1
  shift
  FM_WAIT_GH="$dir/gh" FM_WAIT_MIN_INTERVAL=0 "$SCRIPT" "$@" --interval 1
}

test_pr_checks_finish() {
  local dir out rc
  dir=$(fm_test_tmproot fm-wait)
  fake_gh "$dir"
  pr_json OPEN aaaaaaaaaaaaaaaa IN_PROGRESS "" > "$dir/resp/1"
  pr_json OPEN aaaaaaaaaaaaaaaa IN_PROGRESS "" > "$dir/resp/2"
  pr_json OPEN aaaaaaaaaaaaaaaa COMPLETED FAILURE > "$dir/resp/3"
  out=$(run_wait "$dir" pr https://github.com/o/r/pull/1 --until checks --timeout 30); rc=$?
  expect_code 0 "$rc" "checks finishing must exit 0: $out"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "exactly one line expected, got: $out"
  assert_contains "$out" "checks-done" "outcome"
  assert_contains "$out" "fail=1" "fail count"
  assert_contains "$out" "failing=unit_tests" "failing check is named"
  [ "$(grep -c '^pr view' "$dir/calls")" -eq 3 ] || fail "expected three reads, got $(grep -c '^pr view' "$dir/calls")"
  pass "pr --until checks blocks across reads and prints one line naming the failure"
}

test_pr_change_head_move() {
  local dir out rc
  dir=$(fm_test_tmproot fm-wait)
  fake_gh "$dir"
  pr_json OPEN aaaaaaaaaaaaaaaa COMPLETED SUCCESS > "$dir/resp/1"
  pr_json OPEN bbbbbbbbbbbbbbbb COMPLETED SUCCESS > "$dir/resp/2"
  out=$(run_wait "$dir" pr https://github.com/o/r/pull/1 --until head --timeout 30); rc=$?
  expect_code 0 "$rc" "a moved head must exit 0"
  assert_contains "$out" "head-moved" "outcome"
  assert_contains "$out" "head=bbbbbbbbbbbb" "new head"
  pass "pr --until head returns when the head moves"
}

test_pr_timeout_prints_last_state() {
  local dir out rc
  dir=$(fm_test_tmproot fm-wait)
  fake_gh "$dir"
  pr_json OPEN aaaaaaaaaaaaaaaa IN_PROGRESS "" > "$dir/resp/1"
  out=$(run_wait "$dir" pr https://github.com/o/r/pull/1 --until merged --timeout 2); rc=$?
  expect_code 124 "$rc" "a timeout must exit 124"
  assert_contains "$out" "timeout state=OPEN" "the last state is carried"
  pass "a timeout exits 124 with one line carrying the last state"
}

test_read_failures_stop() {
  local dir out rc
  dir=$(fm_test_tmproot fm-wait)
  fake_gh "$dir"
  : > "$dir/resp/1"; echo "HTTP 502 bad gateway" > "$dir/resp/1.err"
  out=$(run_wait "$dir" pr https://github.com/o/r/pull/1 --timeout 60); rc=$?
  expect_code 3 "$rc" "five failed reads in a row must exit 3"
  assert_contains "$out" "error gh:HTTP_502" "the error is named"
  pass "repeated read failures stop with exit 3 and the error"
}

test_budget_floor_backs_off() {
  local dir out rc
  dir=$(fm_test_tmproot fm-wait)
  fake_gh "$dir"
  printf '{"resources":{"graphql":{"remaining":10,"reset":%s}}}' "$(( $(date +%s) + 3600 ))" > "$dir/rate.json"
  pr_json OPEN aaaaaaaaaaaaaaaa IN_PROGRESS "" > "$dir/resp/1"
  out=$(run_wait "$dir" pr https://github.com/o/r/pull/1 --timeout 2); rc=$?
  expect_code 124 "$rc" "under the floor the wait must time out without reading"
  ! grep -q '^pr view' "$dir/calls" || fail "no PR read may happen while the budget is under the floor"
  pass "under the GitHub budget floor it backs off instead of reading"
}

test_commit_status_context() {
  local dir out rc
  dir=$(fm_test_tmproot fm-wait)
  fake_gh "$dir"
  printf '{"state":"pending","statuses":[{"context":"buildkite/app","state":"pending"}]}' > "$dir/resp/1"
  printf '{"state":"failure","statuses":[{"context":"other","state":"success"},{"context":"buildkite/app","state":"failure","target_url":"https://bk/1"}]}' > "$dir/resp/2"
  out=$(run_wait "$dir" status o/r 0123456789abcdef --context buildkite/app --timeout 30); rc=$?
  expect_code 0 "$rc" "a terminal status must exit 0"
  assert_contains "$out" "failure context=buildkite/app url=https://bk/1" "status line"
  pass "status --context waits for that context to finish, with no Buildkite call"
}

test_file_and_pid() {
  local dir out rc pid
  dir=$(fm_test_tmproot fm-wait)
  ( sleep 2; echo "result: done" > "$dir/out.txt" ) &
  out=$("$SCRIPT" file "$dir/out.txt" --grep '^result:' --timeout 20 --interval 1); rc=$?
  expect_code 0 "$rc" "file must appear"
  assert_contains "$out" "matched: result: done" "file line"
  sleep 1 & pid=$!
  out=$("$SCRIPT" pid "$pid" --timeout 20 --interval 1); rc=$?
  expect_code 0 "$rc" "pid must exit"
  assert_contains "$out" "pid $pid exited" "pid line"
  pass "file and pid waits return one line when the condition holds"
}

fm_test_run test_pr_checks_finish test_pr_change_head_move test_pr_timeout_prints_last_state \
  test_read_failures_stop test_budget_floor_backs_off test_commit_status_context test_file_and_pid
