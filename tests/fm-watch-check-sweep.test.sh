#!/usr/bin/env bash
# tests/fm-watch-check-sweep.test.sh - the watcher runs its due checks in
# concurrent lanes (bin/fm-watch.sh check_sweep_*). Each case runs the real
# watcher over registered custom checks and pins the two properties a lane
# exists for: a sweep costs about its slowest check rather than the sum of all
# of them, and the liveness beacon keeps moving while a slow check runs, so the
# long cycles they cause never read as a stalled watcher.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-check-sweep)
# Checks per sweep. Long strides keep every check running for the whole case.
SLOW_SECS=8
SLOW_CHECKS=3
# How long a later sweep is given to start every one of its lanes, measured from
# the moment the watcher starts it.
START_WAIT_SECS=4

# write_check <state> <id> <seconds> <text> <marker>
# A registered custom check that starts (writes <marker>), sleeps, then prints
# <text>. A lane that never starts leaves its marker absent, and the check never
# returns before its sleep is over, so a sweep that dropped or serialized it
# cannot pass by running the others faster.
write_check() {
  local state=$1 id=$2 secs=$3 text=$4 marker=$5
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$marker"
    printf 'sleep %s\n' "$secs"
    printf 'printf %s\\n' "'$text'"
  } > "$state/$id.check.sh"
  chmod 0700 "$state/$id.check.sh"
  FM_STATE_OVERRIDE="$state" "$REGISTER" "$id" >/dev/null || fail "could not register check $id"
}

# run_watcher <case-dir> <state>: a watcher over <state> that sweeps once and
# then uses a long check interval, so a case measures exactly one sweep. Sets
# WATCH_PID; the caller owns stopping it.
run_watcher() {
  local dir=$1 state=$2
  # Backgrounded directly, never through env: the pid must be this shell's own
  # child so wait_for_exit can reap it, and a command substitution would run the
  # watcher in a subshell of its own.
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=3600 FM_HEARTBEAT=999999 \
    FM_CHECK_TIMEOUT=30 "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  WATCH_PID=$!
}

# wait_for <polls> <command...>: poll until the command succeeds.
wait_for() {
  local polls=$1 i=0
  shift
  while [ "$i" -lt "$polls" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# all_started <marker...>: every check has started.
all_started() {
  local marker
  for marker in "$@"; do
    [ -e "$marker" ] || return 1
  done
}

stop_watcher() {  # <pid> <case-dir>
  local pid=$1 dir=$2 status=0
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 200 || status=$?
  [ "$status" -ne 124 ] || {
    cat "$dir/watch.out" >&2
    cat "$dir/watch.err" >&2
    fail "sweep watcher survived TERM"
  }
}

# beacon_age <state>: whole seconds since the watcher last refreshed its beat.
beacon_age() {
  local state=$1
  printf '%s' "$(( $(date +%s) - $(stat -c %Y "$state/.last-watcher-beat" 2>/dev/null || date +%s) ))"
}

test_slow_checks_run_concurrently() {
  local dir state started=0 markers=() i
  dir=$(make_case concurrent)
  state="$dir/state"
  for i in $(seq 1 "$SLOW_CHECKS"); do
    markers+=("$dir/sweep$i.started")
    write_check "$state" "sweep$i" "$SLOW_SECS" "sweep$i done" "$dir/sweep$i.started"
  done
  run_watcher "$dir" "$state"
  wait_for 100 all_started "${markers[@]}" && started=1
  stop_watcher "$WATCH_PID" "$dir"
  # Serial, ${SLOW_CHECKS} ${SLOW_SECS}s checks cannot all be under way before
  # the first one has finished: the later ones never start at all. Concurrent
  # starts every lane within a second or two of the sweep.
  [ "$started" -eq 1 ] \
    || fail "the ${SLOW_CHECKS} slow checks never ran together: $(cat "$dir/watch.out")"
  pass "${SLOW_CHECKS} slow checks ran together"
}

test_beacon_stays_fresh_during_a_slow_sweep() {
  local dir state age worst=0 i began waiting markers=()
  dir=$(make_case beacon)
  state="$dir/state"
  for i in $(seq 1 "$SLOW_CHECKS"); do
    markers+=("$dir/sweep$i.started")
    write_check "$state" "sweep$i" "$SLOW_SECS" "sweep$i done" "$dir/sweep$i.started"
  done
  began=$SECONDS
  run_watcher "$dir" "$state"
  # Sample the beat for the whole span the sweep is under way. The beat refreshes
  # every second while lanes run, so even the span where the watcher is only
  # waiting must stay well inside the guard's grace.
  waiting=1
  while [ "$waiting" -eq 1 ]; do
    age=$(beacon_age "$state")
    [ "$age" -le "$worst" ] || worst=$age
    if all_started "${markers[@]}" && [ "$((SECONDS - began))" -ge "$SLOW_SECS" ]; then
      waiting=0
    else
      sleep 0.25
    fi
  done
  stop_watcher "$WATCH_PID" "$dir"
  [ "$worst" -le 2 ] || fail "beacon went $worst s stale during a ${SLOW_SECS}s sweep"
  pass "beacon stayed fresh (worst ${worst}s) through a ${SLOW_SECS}s sweep"
}

test_every_lane_starts_without_waiting() {
  local dir state markers=() i started
  dir=$(make_case lanes)
  state="$dir/state"
  for i in $(seq 1 "$SLOW_CHECKS"); do
    markers+=("$dir/sweep$i.started")
    write_check "$state" "sweep$i" "$SLOW_SECS" "sweep$i done" "$dir/sweep$i.started"
  done
  run_watcher "$dir" "$state"
  # Every lane must start within a few seconds of the sweep. Serial, each
  # ${SLOW_SECS}s check has to finish before the next one starts, so the last
  # could only begin once the others were through.
  if wait_for $((START_WAIT_SECS * 10)) all_started "${markers[@]}"; then
    started=1
  else
    started=0
  fi
  stop_watcher "$WATCH_PID" "$dir"
  [ "$started" -eq 1 ] \
    || fail "not every check started within ${START_WAIT_SECS}s of the sweep: $(cat "$dir/watch.out")"
  pass "all ${SLOW_CHECKS} lanes started within ${START_WAIT_SECS}s of the sweep"
}

test_slow_checks_run_concurrently
test_beacon_stays_fresh_during_a_slow_sweep
test_every_lane_starts_without_waiting
