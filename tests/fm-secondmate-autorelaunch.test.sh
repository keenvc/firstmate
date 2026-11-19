#!/usr/bin/env bash
# Tests for bin/fm-secondmate-autorelaunch.sh: a second mate recorded dead
# (state/<id>.last-death.txt) and still probing relaunchable is relaunched from
# cron through the shared guarded path, capped at FM_AUTORELAUNCH_MAX attempts
# per window on the real shared ledger, then alerts once; the dispatch hold does
# not block a second-mate relaunch; dry run, the off switch, non-secondmate
# metas, and mates with no death record never relaunch.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v flock >/dev/null 2>&1 || { echo "skip: flock not found"; exit 0; }

AR="$ROOT/bin/fm-secondmate-autorelaunch.sh"
TMP_ROOT=$(fm_test_tmproot fm-autorelaunch)

new_world() {  # <name>
  W="$TMP_ROOT/$1"
  mkdir -p "$W/state" "$W/fake"
  cat > "$W/overrides.sh" <<'SH'
fm_secondmate_liveness_probe() {
  FM_SM_LIVE_STATUS=$(cat "$FAKE_DIR/probe-$2" 2>/dev/null || echo alive)
  FM_SM_LIVE_STATE=dead FM_SM_LIVE_CAUSE='confirmed agent absence' FM_SM_LIVE_WHERE=w1 FM_SM_LIVE_REASON=''
}
fm_secondmate_liveness_relaunch() {
  fm_secondmate_liveness_ledger_add "$2" attempt || return 1
  printf '%s\n' "$2" >> "$FAKE_DIR/relaunched"
  if [ -e "$FAKE_DIR/fail-$2" ]; then
    fm_secondmate_liveness_ledger_add "$2" failed
    FM_SM_LIVE_STATUS=failed FM_SM_LIVE_OUT='spawn failed'
    return 1
  fi
  fm_secondmate_liveness_ledger_add "$2" relaunched
}
SH
}

add_mate() {  # <id> <kind> <probe> [dead]
  printf 'kind=%s\nwindow=w-%s\nhome=%s/home-%s\n' "$2" "$1" "$W" "$1" > "$W/state/$1.meta"
  printf '%s\n' "$3" > "$W/fake/probe-$1"
  [ "${4:-}" != dead ] || printf 'at=2026-11-19T10:00:00Z state=dead cause=confirmed agent absence on existing endpoint\n' > "$W/state/$1.last-death.txt"
}

run_ar() {  # [args...]
  FM_HOME="$W" FM_STATE_OVERRIDE="$W/state" FAKE_DIR="$W/fake" \
    FM_AUTORELAUNCH_TEST_OVERRIDES="$W/overrides.sh" \
    FM_DISPATCH_HOLD_FLAG="$W/dispatch-hold.flag" "$AR" "$@"
}

relaunches() { [ -f "$W/fake/relaunched" ] || { echo 0; return; }; grep -cx "$1" "$W/fake/relaunched" || true; }

test_relaunches_only_recorded_dead_secondmates() {
  new_world basic
  add_mate dead1 secondmate relaunchable dead
  add_mate nodeath secondmate relaunchable
  add_mate alive1 secondmate alive dead
  add_mate worker1 ship relaunchable dead
  run_ar || fail "run failed"
  [ "$(relaunches dead1)" = 1 ] || fail "the recorded-dead mate was not relaunched once"
  [ "$(relaunches nodeath)" = 0 ] || fail "a mate with no death record was relaunched"
  [ "$(relaunches alive1)" = 0 ] || fail "a live mate was relaunched"
  [ "$(relaunches worker1)" = 0 ] || fail "a non-secondmate meta was relaunched"
  grep -q 'attempt' "$W/state/.secondmate-relaunch-dead1" || fail "the attempt was not ledgered on the shared ledger"
  grep -q 'dead1: relaunched' "$W/state/autorelaunch.log" || fail "the relaunch was not logged"
  pass "relaunches only second mates recorded dead and still relaunchable"
}

test_cap_then_single_alert() {
  local i
  new_world cap
  add_mate flaky secondmate relaunchable dead
  : > "$W/fake/fail-flaky"
  for i in 1 2 3 4 5; do run_ar || fail "run $i failed"; done
  [ "$(relaunches flaky)" = 3 ] || fail "expected exactly 3 attempts in the window, got $(relaunches flaky)"
  [ "$(grep -c 'ALERT flaky' "$W/state/autorelaunch.log")" -ge 1 ] || fail "no alert at the cap"
  [ "$(find "$W/state" -maxdepth 1 -name '.autorelaunch-cap-flaky-*' | wc -l)" = 1 ] || fail "the cap alert was not recorded exactly once"
  grep -rqs 'autorelaunch-cap-flaky' "$W/state" --exclude='autorelaunch.log' --exclude='.autorelaunch-cap-*' \
    || fail "the cap alert raised no captain wake"
  pass "caps attempts per window on the shared ledger, then alerts once"
}

test_cap_counts_watcher_attempts() {
  local now
  new_world shared
  add_mate busy secondmate relaunchable dead
  now=$(date +%s)
  printf '%s\tattempt\n%s\tfailed\n%s\tattempt\n%s\tfailed\n%s\tattempt\n%s\tfailed\n' \
    "$now" "$now" "$now" "$now" "$now" "$now" > "$W/state/.secondmate-relaunch-busy"
  run_ar || fail "run failed"
  [ "$(relaunches busy)" = 0 ] || fail "watcher attempts did not count toward the cap"
  pass "watcher attempts in the window count toward the cap"
}

test_dispatch_hold_allows_secondmate_relaunch() {
  new_world hold
  add_mate held secondmate relaunchable dead
  printf 'captain dispatch hold\n' > "$W/dispatch-hold.flag"
  run_ar || fail "run failed"
  [ "$(relaunches held)" = 1 ] || fail "the dispatch hold blocked a second-mate relaunch"
  grep -q 'dispatch hold in force' "$W/state/autorelaunch.log" || fail "the relaunch under the hold was not noted"
  pass "the captain dispatch hold does not block a second-mate relaunch"
}

test_dry_run_and_off_switch() {
  new_world dry
  add_mate d1 secondmate relaunchable dead
  run_ar --dry-run || fail "dry run failed"
  [ "$(relaunches d1)" = 0 ] || fail "dry run relaunched"
  grep -q 'DRY-RUN d1: would relaunch' "$W/state/autorelaunch.log" || fail "dry run did not report the plan"
  : > "$W/state/.autorelaunch-off"
  run_ar || fail "off run failed"
  [ "$(relaunches d1)" = 0 ] || fail "the off switch did not stop relaunches"
  pass "dry run and the off switch never relaunch"
}

set -e
test_relaunches_only_recorded_dead_secondmates
test_cap_then_single_alert
test_cap_counts_watcher_attempts
test_dispatch_hold_allows_secondmate_relaunch
test_dry_run_and_off_switch
echo "ok: fm-secondmate-autorelaunch"
