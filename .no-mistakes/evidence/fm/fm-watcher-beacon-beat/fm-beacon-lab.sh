#!/usr/bin/env bash
# Live lab: real bin/fm-watch.sh against a real tmux fleet of 100 task records,
# then the real Claude Stop hooks (auto-arm + turn-end guard) mid-sweep.
# $1 = repo worktree, $2 = tag (fixed|base), $3 = optional fm-watch.sh source override
set -u
REPO=$1; TAG=$2; WATCH_SRC=${3:-}
N=${N:-100}
POLL=${POLL:-5}
GRACE=${GRACE:-20}
MIDSWEEP_WAIT=${MIDSWEEP_WAIT:-25}

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
LABTMUX=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
export TMUX_TMPDIR="$LABTMUX"

cleanup() {
  [ -z "${WPID:-}" ] || { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
  tmux kill-server 2>/dev/null
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

# primary-shaped checkout: plain git repo + AGENTS.md + bin/ + state/
git init -q "$LAB"
git -C "$LAB" -c user.name=lab -c user.email=lab@invalid commit -q --allow-empty -m init
: > "$LAB/AGENTS.md"
mkdir -p "$LAB/bin" "$LAB/docs"
cp "$REPO"/bin/*.sh "$LAB/bin/"
cp -R "$REPO/docs/supervision-protocols" "$LAB/docs/supervision-protocols"
[ -z "$WATCH_SRC" ] || cp "$WATCH_SRC" "$LAB/bin/fm-watch.sh"
chmod +x "$LAB"/bin/*.sh
printf '%s\n' "watch.sh sha: $(sha1sum "$LAB/bin/fm-watch.sh" | cut -c1-12)"

# real tmux fleet + one task record per real window
tmux new-session -d -s fleet -c "$REPO" 'bash --norc'
i=1; while [ "$i" -le "$N" ]; do
  tmux new-window -d -t fleet -n "w$i" -c "$REPO" 'bash --norc'
  printf 'window=fleet:w%s\nproject=%s/projects/demo\nworktree=%s/projects/demo\nharness=claude\nkind=ship\nbackend=tmux\nmodel=default\neffort=default\n' \
    "$i" "$LAB" "$LAB" > "$LAB/state/t$i.meta"
  i=$((i + 1))
done
mkdir -p "$LAB/projects/demo"
printf 'windows=%s task-records=%s\n' "$(tmux list-windows -t fleet | wc -l)" "$(ls "$LAB"/state/*.meta | wc -l)"

# fake harness ancestry: a bash named "claude" is the hook's parent
mkdir -p "$LAB/fakebin"; ln -sf /bin/bash "$LAB/fakebin/claude"

export FM_HOME="$LAB" FM_POLL=$POLL FM_GUARD_GRACE=$GRACE FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  FM_HOME_SUMMARY_INTERVAL=999999
"$LAB/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WPID=$!
i=0; while [ ! -e "$LAB/state/.last-watcher-beat" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
printf 'watcher pid=%s lock=%s beacon=%s\n' "$WPID" "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)" "$(cat "$LAB/state/.last-watcher-beat" 2>/dev/null)"

beacon_age() { echo $(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat") )); }
echo "--- beacon during the first real sweep (grace=${GRACE}s, poll=${POLL}s) ---"
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$MIDSWEEP_WAIT" ]; do
  printf 't=%02ds cycle=%s beacon_age=%ss\n' "$(( $(date +%s) - t0 ))" \
    "$(cat "$LAB/state/.last-watcher-beat" 2>/dev/null)" "$(beacon_age)"
  sleep 5
done
kill -0 "$WPID" 2>/dev/null && echo "watcher still running (mid-sweep)" || echo "WATCHER EXITED EARLY"

echo "--- guard predicate mid-sweep ---"
FM_HOME="$LAB" bash -c '. "$1"; if fm_watcher_healthy "$2" "$3" "$4" "$5"; then echo "fm_watcher_healthy: HEALTHY"; else echo "fm_watcher_healthy: UNHEALTHY"; fi' \
  _ "$LAB/bin/fm-wake-lib.sh" "$LAB/state" "$LAB/bin/fm-watch.sh" "$GRACE" "$LAB"

echo "--- real Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) mid-sweep ---"
set +e
printf '%s\n' '{"session_id":"sess-lab","stop_hook_active":false}' \
  | FM_HOME="$LAB" FM_GUARD_GRACE=$GRACE timeout 120 "$LAB/fakebin/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
    ' 2>&1
echo "autoarm exit=$? (124 = still following a healthy watcher when the 120s probe bound hit)"
for f in "$LAB"/state/.claude-autoarm-output.*; do
  [ -e "$f" ] || continue
  echo "arm output: $(cat "$f")"
done
echo "--- real turn-end guard (bin/fm-turnend-guard.sh --claude) mid-sweep ---"
printf '%s\n' '{"session_id":"sess-lab","stop_hook_active":false}' \
  | CLAUDECODE=1 FM_HOME="$LAB" FM_GUARD_GRACE=$GRACE "$LAB/fakebin/claude" -c '
      "$FM_HOME/bin/fm-turnend-guard.sh" --claude
    ' 2>&1
echo "turnend-guard exit=$?"
set -e
echo "--- watcher stderr ---"; tail -5 "$LAB/watch.err"
echo "--- watcher stdout ---"; tail -5 "$LAB/watch.out"
echo "LAB=$LAB TAG=$TAG done"
