#!/usr/bin/env bash
# Behavior tests for bin/fm-context-rotate.sh: an OpenCode secondmate over its
# context threshold is relaunched on a fresh session from its handoff, at most
# once per session, and scan never prints (a printing check would wake).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-context-rotate.sh"

command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 unavailable\n'; exit 0; }
python3 -c 'import sqlite3' 2>/dev/null || { printf 'skip: python3 sqlite3 unavailable\n'; exit 0; }

# make_fixture <dir> <ctx-tokens> : one OpenCode secondmate "oc1" whose newest
# session's last assistant message carries <ctx-tokens> of context.
make_fixture() {
  local dir=$1 ctx=$2
  mkdir -p "$dir/state" "$dir/home/config" "$dir/home/data/handoff" "$dir/bin"
  fm_write_secondmate_meta "$dir/state/oc1.meta" "$dir/home" "default:w1:p1" alpha opencode
  printf 'v1 gen=g1 seq=1 state=idle source=opencode-plugin event=x ts=1\n' > "$dir/state/oc1.busy-state"
  python3 -I - "$dir/state/oc1.opencode.db" "$ctx" <<'PY'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table session_v2 (id text primary key, parent_id text, time_updated integer)")
c.execute("create table session_message (id text primary key, session_id text, type text, time_created integer, data text)")
c.execute("insert into session_v2 values ('ses_old', null, 1)")
c.execute("insert into session_v2 values ('ses_live', null, 5)")
c.execute("insert into session_v2 values ('ses_child', 'ses_live', 9)")
c.execute("insert into session_message values ('m1','ses_old','assistant',1,?)", (json.dumps({"tokens": {"input": 999999}}),))
c.execute("insert into session_message values ('m2','ses_live','assistant',2,?)", (json.dumps({"tokens": {"input": 10, "cache": {"read": 0, "write": 0}}}),))
c.execute("insert into session_message values ('m3','ses_live','assistant',3,?)", (json.dumps({"tokens": {"input": int(sys.argv[2]) - 100, "cache": {"read": 60, "write": 40}}}),))
c.execute("insert into session_message values ('m4','ses_child','assistant',4,?)", (json.dumps({"tokens": {"input": 1}}),))
c.commit()
PY
  cat > "$dir/bin/control" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/control.calls"
EOF
  cat > "$dir/bin/send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/send.calls"
# The mate answers the handoff request by writing one.
[ -z "${FAKE_HANDOFF_HOME:-}" ] || { echo handoff > "$FAKE_HANDOFF_HOME/data/handoff/HANDOFF-new.md"; ln -sfn HANDOFF-new.md "$FAKE_HANDOFF_HOME/data/handoff/LATEST.md"; }
EOF
  chmod +x "$dir/bin/control" "$dir/bin/send"
}

run_rotate() {  # <dir> <subcommand...>
  local dir=$1
  shift
  FM_STATE_OVERRIDE="$dir/state" FM_CONTEXT_ROTATE_CONTROL="$dir/bin/control" \
    FM_CONTEXT_ROTATE_SEND="$dir/bin/send" FM_CONTEXT_ROTATE_FOREGROUND=1 \
    FM_CONTEXT_ROTATE_SETTLE=0 FM_CONTEXT_ROTATE_POLL=0 \
    FM_CONTEXT_ROTATE_HANDOFF_WAIT="${HANDOFF_WAIT:-5}" FM_CONTEXT_ROTATE_IDLE_WAIT=2 \
    "$SCRIPT" "$@"
}

test_under_threshold_does_nothing() {
  local dir out
  dir=$(fm_test_tmproot fm-ctxrot)
  make_fixture "$dir" 40000
  out=$(run_rotate "$dir" scan)
  assert_equals "" "$out" "scan must print nothing"
  [ ! -e "$dir/bin/control.calls" ] || fail "a mate under threshold must not be relaunched"
  pass "under the threshold nothing is sent or relaunched"
}

test_fresh_handoff_relaunches_once() {
  local dir out
  dir=$(fm_test_tmproot fm-ctxrot)
  make_fixture "$dir" 70000
  echo handoff > "$dir/home/data/handoff/HANDOFF-a.md"
  ln -sfn HANDOFF-a.md "$dir/home/data/handoff/LATEST.md"
  out=$(run_rotate "$dir" scan)
  assert_equals "" "$out" "scan must print nothing even when it rotates"
  grep -q '^oc1 relaunch --fresh-session --note ' "$dir/bin/control.calls" \
    || fail "expected a fresh-session relaunch, got: $(cat "$dir/bin/control.calls" 2>/dev/null)"
  [ ! -e "$dir/bin/send.calls" ] || fail "a fresh handoff needs no request"
  grep -q '^rotated ses_live ' "$dir/state/oc1.context-rotate" || fail "rotation must be recorded per session"
  run_rotate "$dir" scan >/dev/null
  [ "$(wc -l < "$dir/bin/control.calls")" -eq 1 ] || fail "a session must be rotated at most once"
  pass "over the threshold with a fresh handoff: one fresh-session relaunch per session"
}

test_stale_handoff_is_requested_first() {
  local dir
  dir=$(fm_test_tmproot fm-ctxrot)
  make_fixture "$dir" 61000
  echo old > "$dir/home/data/handoff/HANDOFF-old.md"
  ln -sfn HANDOFF-old.md "$dir/home/data/handoff/LATEST.md"
  fm_touch_epoch "$(( $(date +%s) - 7200 ))" "$dir/home/data/handoff/HANDOFF-old.md"
  FAKE_HANDOFF_HOME="$dir/home" run_rotate "$dir" scan >/dev/null
  grep -q '^oc1 \[context-rotate' "$dir/bin/send.calls" || fail "a stale handoff must be requested through fm-send"
  grep -q 'relaunch --fresh-session' "$dir/bin/control.calls" || fail "the relaunch must follow the fresh handoff"
  pass "a stale handoff is requested once, then the mate is relaunched"
}

test_no_handoff_gives_up_without_relaunch() {
  local dir
  dir=$(fm_test_tmproot fm-ctxrot)
  make_fixture "$dir" 90000
  HANDOFF_WAIT=1 run_rotate "$dir" scan >/dev/null
  grep -q 'context-rotate' "$dir/bin/send.calls" || fail "the handoff must be requested"
  [ ! -e "$dir/bin/control.calls" ] || fail "no handoff must mean no relaunch"
  grep -q '^gaveup ses_live ' "$dir/state/oc1.context-rotate" || fail "the give-up must be recorded"
  run_rotate "$dir" scan >/dev/null
  [ "$(wc -l < "$dir/bin/send.calls")" -eq 1 ] || fail "a give-up must not be retried inside the retry window"
  pass "no handoff: the session is kept and the retry waits"
}

test_home_override_and_off() {
  local dir
  dir=$(fm_test_tmproot fm-ctxrot)
  make_fixture "$dir" 70000
  echo off > "$dir/home/config/context-rotate-tokens"
  run_rotate "$dir" scan >/dev/null
  [ ! -e "$dir/bin/control.calls" ] || fail "off must disable rotation for that home"
  echo 80000 > "$dir/home/config/context-rotate-tokens"
  run_rotate "$dir" scan >/dev/null
  [ ! -e "$dir/bin/control.calls" ] || fail "a per-home threshold above the context must not rotate"
  run_rotate "$dir" status | grep -q '^oc1 ctx=70000 threshold=80000 session=ses_live' \
    || fail "status must report context, threshold and session: $(run_rotate "$dir" status)"
  pass "per-home threshold and off are honored; status reports the numbers"
}

test_busy_mate_is_not_relaunched() {
  local dir
  dir=$(fm_test_tmproot fm-ctxrot)
  make_fixture "$dir" 70000
  echo handoff > "$dir/home/data/handoff/LATEST.md"
  printf 'v1 gen=g1 seq=2 state=busy source=opencode-plugin\n' > "$dir/state/oc1.busy-state"
  run_rotate "$dir" scan >/dev/null
  [ ! -e "$dir/bin/control.calls" ] || fail "a busy mate must not be relaunched"
  pass "a mate that never goes idle is left alone"
}

fm_test_run test_under_threshold_does_nothing test_fresh_handoff_relaunches_once \
  test_stale_handoff_is_requested_first test_no_handoff_gives_up_without_relaunch \
  test_home_override_and_off test_busy_mate_is_not_relaunched
