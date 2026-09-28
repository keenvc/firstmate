#!/usr/bin/env bash
# Adversarial live: the fixed watcher is frozen mid-sweep (SIGSTOP on it and its
# per-cycle child). A watcher that is not making progress must stop publishing,
# go stale, and be reported as broken supervision.
set -u
REPO=$1
N=${N:-100}; POLL=${POLL:-5}; GRACE=${GRACE:-20}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
LABTMUX=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB"); export TMUX_TMPDIR="$LABTMUX"
cleanup() {
  [ -z "${WPID:-}" ] || { kill -CONT "$WPID" 2>/dev/null; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
  pkill -CONT -P "${WPID:-0}" 2>/dev/null
  tmux kill-server 2>/dev/null
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT
git init -q "$LAB"
git -C "$LAB" -c user.name=lab -c user.email=lab@invalid commit -q --allow-empty -m init
: > "$LAB/AGENTS.md"; mkdir -p "$LAB/bin" "$LAB/docs" "$LAB/projects/demo"
cp "$REPO"/bin/*.sh "$LAB/bin/"; cp -R "$REPO/docs/supervision-protocols" "$LAB/docs/supervision-protocols"
chmod +x "$LAB"/bin/*.sh
tmux new-session -d -s fleet -c "$REPO" 'bash --norc'
i=1; while [ "$i" -le "$N" ]; do
  tmux new-window -d -t fleet -n "w$i" -c "$REPO" 'bash --norc'
  printf 'window=fleet:w%s\nproject=%s/projects/demo\nharness=claude\nkind=ship\nbackend=tmux\n' "$i" "$LAB" > "$LAB/state/t$i.meta"
  i=$((i+1))
done
mkdir -p "$LAB/fakebin"; ln -sf /bin/bash "$LAB/fakebin/claude"
export FM_HOME="$LAB" FM_POLL=$POLL FM_GUARD_GRACE=$GRACE FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  FM_HOME_SUMMARY_INTERVAL=999999
"$LAB/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WPID=$!
i=0; while [ ! -e "$LAB/state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
sleep 6
echo "watcher pid=$WPID freezing it and its per-cycle child mid-sweep (SIGSTOP)"
kill -STOP "$WPID"; pkill -STOP -P "$WPID" 2>/dev/null
beacon_age() { echo $(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat") )); }
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
  printf 't=%02ds cycle=%s beacon_age=%ss watcher_state=%s\n' "$(( $(date +%s) - t0 ))" \
    "$(cat "$LAB/state/.last-watcher-beat")" "$(beacon_age)" "$(ps -o stat= -p "$WPID" | tr -d ' ')"
  sleep 6
done
echo "--- guard predicate against the frozen watcher ---"
FM_HOME="$LAB" bash -c '. "$1"; if fm_watcher_healthy "$2" "$3" "$4" "$5"; then echo "fm_watcher_healthy: HEALTHY"; else echo "fm_watcher_healthy: UNHEALTHY"; fi' \
  _ "$LAB/bin/fm-wake-lib.sh" "$LAB/state" "$LAB/bin/fm-watch.sh" "$GRACE" "$LAB"
echo "--- real turn-end guard against the frozen watcher ---"
set +e
printf '%s\n' '{"session_id":"sess-frozen","stop_hook_active":false}' \
  | CLAUDECODE=1 FM_HOME="$LAB" FM_GUARD_GRACE=$GRACE "$LAB/fakebin/claude" -c '"$FM_HOME/bin/fm-turnend-guard.sh" --claude' 2>&1
echo "turnend-guard exit=$?"
echo "--- a re-arm over the frozen watcher ---"
FM_HOME="$LAB" FM_GUARD_GRACE=$GRACE FM_WATCHER_STALL_BOUND=999999 "$LAB/bin/fm-watch.sh" 2>&1 | head -3
echo "re-arm exit=${PIPESTATUS[0]}"
