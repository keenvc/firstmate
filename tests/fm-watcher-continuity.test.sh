#!/usr/bin/env bash
# tests/fm-watcher-continuity.test.sh - behavior of bin/fm-watcher-continuity.sh.
# Two contracts, both through the real script:
#   - the stale bound is floored so a mis-set FM_CONTINUITY_STALE_SECS cannot
#     recreate the 2026-09-30 kill loop, which TERM'd a healthy watcher whose
#     beacon was merely old;
#   - a graceful TERM removes the pidfile and actually exits.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONT="$ROOT/bin/fm-watcher-continuity.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-continuity)

CONT_PIDS=()
cleanup_test() {
  local pid
  for pid in "${CONT_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_test EXIT INT TERM

wait_dead() {  # <pid> <limit-ticks>: 0 dead, 1 still alive
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_stale_bound_floor_and_graceful_term() {
  local home state holder cpid
  home="$TMP_ROOT/home"
  state="$home/state"
  mkdir -p "$state/.watch.lock"
  # A live watcher singleton whose beacon is ancient. With the mis-set 1s bound
  # applied literally the supervisor would TERM it on the first check, which is
  # exactly the kill loop; the floor must hold it instead.
  sleep 60 &
  holder=$!
  disown "$holder" 2>/dev/null || true
  CONT_PIDS+=("$holder")
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  touch -t 202001010000 "$state/.last-watcher-beat"

  FM_HOME="$home" FM_CONTINUITY_STALE_SECS=1 FM_CONTINUITY_POLL_SECS=1 \
    "$CONT" > "$TMP_ROOT/continuity.out" 2>&1 &
  cpid=$!
  CONT_PIDS+=("$cpid")

  sleep 3
  kill -0 "$holder" 2>/dev/null \
    || fail "stale bound floor must not kill a live holder with an ancient beat"
  kill -0 "$cpid" 2>/dev/null || fail "continuity supervisor exited before TERM"
  grep -q 'attaching to existing watcher' "$state/.watcher-continuity.log" \
    || fail "continuity supervisor must attach to a live holder instead of starting a second watcher"
  grep -q 'stale=300s' "$state/.watcher-continuity.log" \
    || fail "continuity supervisor must report the floored stale bound"

  kill -TERM "$cpid"
  wait_dead "$cpid" 50 \
    || fail "TERM must stop the continuity supervisor (its handler must exit)"
  [ ! -e "$state/.watcher-continuity.pid" ] \
    || fail "TERM must remove the continuity pidfile"

  pass "continuity stale bound is floored and TERM stops the supervisor"
}

test_stale_bound_floor_and_graceful_term
