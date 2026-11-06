#!/usr/bin/env bash
# tests/fm-watch-lane-pgid.test.sh - a check-sweep lane records its OWN pid and
# forks into its OWN process group (bin/fm-watch.sh check_sweep_lane_launch).
#
# The pid must be the lane's: `$$` inside a subshell still holds the PARENT's
# pid, so recording it named the watcher itself, and every per-lane kill aimed
# at a lane then landed on the watcher.
#
# The group must be the lane's own: the lane forks under `set -m` so its check
# gets a group of its own (recorded as check-pgid). Without that the lane and
# its check shared the watcher's group, so a stop that kills a lane's group
# killed the watcher with it.
#
# The watcher is sourced, not run: its runtime guard returns before the lock and
# loop, so each case drives the real launch and real kill functions against a
# real child process. Only pids this test starts are ever signalled.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ROOT=${ROOT:?}

TMP_ROOT=$(fm_test_tmproot fm-watch-lane-pgid)

# How long the lane's check runs before the test decides it is wedged. The lane
# is expected to outlive this wait by orders of magnitude: it ignores HUP/INT/TERM
# and the test never lets it finish, so a surviving group has to be killed.
LANE_SECS=60

# The whole case runs inside one sourced watcher shell, so `$$` there is a real
# process this test owns, exactly as the bug's `$$` was the watcher's own pid.
# A case reports its verdicts on stdout.
#
# <lane-dir> must be a fresh directory; the driver creates it.
read -r -d '' DRIVER <<'DRIVER'
. "$ROOT/bin/fm-watch.sh"
# A lane that does nothing but hold its shell open, so the kill is the only way
# it ends. FM_CHECK_LANE_CHILD/STATE are what the real launch sets up.
lane_pid=
check_lane_execute() {
  sleep "$LANE_SECS"
}

case_dir=$1
STATE=$case_dir
CHECK_TIMEOUT=1
CHECK_LANE_WAIT_MAX=1

# The "watcher" is this sourced shell. Record what a lane kill would reach.
watcher_pid=$$
watcher_pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')

check_sweep_lane_launch "$case_dir/lane" custom "$case_dir/fake.check.sh" fake
lane_pid=$(cat "$case_dir/lane/pid" 2>/dev/null || true)
[ -n "$lane_pid" ] || { printf 'no-pid\n'; exit 0; }
# Wait for the lane shell to be running its own command, so its group is stable.
_i=0
while [ "$_i" -lt 50 ] && ! kill -0 "$lane_pid" 2>/dev/null; do
  sleep 0.02
  _i=$((_i + 1))
done

if [ "$lane_pid" = "$watcher_pid" ]; then
  printf 'pid-is-watcher\n'
else
  printf 'pid-is-lane\n'
fi

lane_pgid=$(ps -o pgid= -p "$lane_pid" 2>/dev/null | tr -d '[:space:]')
if [ -z "$lane_pgid" ] || [ "$lane_pgid" = "$watcher_pgid" ]; then
  printf 'group-is-watcher\n'
else
  printf 'group-is-own\n'
fi

# Now take the real timeout path. The watcher shell must still be here after.
check_sweep_kill_lane "$case_dir/lane"
sleep 0.3
if kill -0 "$lane_pid" 2>/dev/null; then
  printf 'lane-alive\n'
else
  printf 'lane-dead\n'
fi
printf 'watcher-alive\n'
DRIVER

# run_case <name> <lane-dir>: drive one launch+kill in a sourced watcher shell
# and print its verdict lines. The driver never signals anything it did not start.
run_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/lane"
  ROOT="$ROOT" LANE_SECS="$LANE_SECS" bash -c "$DRIVER" _ "$dir" 2>/dev/null
}

# cleanup_case <dir>: kill only the pids recorded under this case.
cleanup_case() {
  local dir=$1 pid
  pid=$(cat "$dir/lane/pid" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    sleep 0.1
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

verdict() {  # <output> <word>: <output> contains the verdict line.
  case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}

test_lane_records_its_own_pid() {
  local out
  out=$(run_case pid)
  cleanup_case "$TMP_ROOT/pid"
  verdict "$out" pid-is-lane \
    || fail "the lane recorded $(verdict "$out" pid-is-watcher && echo 'the watcher own pid (\$)' || echo 'no usable pid'); a timeout kill would target the watcher: $out"
  pass "the lane records its own pid"
}

test_lane_is_its_own_process_group() {
  local out
  out=$(run_case pgid)
  cleanup_case "$TMP_ROOT/pgid"
  verdict "$out" group-is-own \
    || fail "the lane shared the watcher's process group; kill -KILL -(lane pid) reaches the watcher: $out"
  pass "the lane runs in its own process group"
}

test_killing_the_lane_leaves_the_watcher_alive() {
  local out
  out=$(run_case survive)
  cleanup_case "$TMP_ROOT/survive"
  verdict "$out" lane-dead || fail "the timed-out lane was never killed: $out"
  verdict "$out" watcher-alive \
    || fail "the watcher's group did not survive the lane kill: $out"
  pass "a timed-out lane dies and the watcher survives"
}

test_lane_records_its_own_pid
test_lane_is_its_own_process_group
test_killing_the_lane_leaves_the_watcher_alive
