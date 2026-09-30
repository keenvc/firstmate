#!/usr/bin/env bash
# fm-watcher-continuity.sh - keep this home's watcher alive when the harness
# re-arm owner can leave a gap (long OpenCode turns, Cursor park gaps).
#
# Usage:
#   fm-watcher-continuity.sh
#
# Singleton through the shared portable lock (no flock dependency). It keeps one
# handling-successor watcher running (FM_WATCH_HANDLING_SUCCESSOR=1
# bin/fm-watch.sh) and, when another arm already owns a live watcher, attaches
# to that holder instead of starting a second one. A holder is stopped only when
# BOTH its own uptime and the age of state/.last-watcher-beat exceed the stale
# bound, so a fresh start is never killed for a beat left by a previous cycle.
# Only the watcher process touches the beat; this supervisor never does.
#
# The stale bound is floored to max(300, poll+60) because the watcher's own
# grace uses that same derivation and its serial *.check.sh sweep can
# legitimately hold the beat for minutes. A bound below the floor is exactly the
# 2026-09-30 kill loop (70 kills / 125 restarts): the supervisor TERM'd a
# healthy watcher mid-sweep, the sweep never completed, and the next watcher
# restarted the same sweep and was killed again.
#
# REPLACING THIS SCRIPT - read before touching a running supervisor:
# bash parses a whole script into memory at startup, so editing this file does
# NOT change a supervisor already running, and a stale supervisor with an older
# bound can survive beside a new one. Replace it atomically instead: write the
# new content to a temp file, `mv` it over this path, `kill -KILL` the old
# supervisor (it holds state/.watcher-continuity.lock), then start exactly one
# new holder. Never edit a running bash script in place.
#
# Env (all optional):
#   FM_CONTINUITY_STALE_SECS    stuck bound in seconds; floored as above
#   FM_CONTINUITY_POLL_SECS     seconds between liveness checks (default 5)
#   FM_CONTINUITY_RESTART_SECS  seconds between watcher runs (default 2)
set -euo pipefail

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCHER="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
LOG="$STATE/.watcher-continuity.log"
LOCK="$STATE/.watcher-continuity.lock"
PIDFILE="$STATE/.watcher-continuity.pid"

[ -x "$WATCHER" ] || { echo "fm-watcher-continuity: watcher not found: $WATCHER" >&2; exit 1; }

# Portable lock acquisition and pid identity, plus the leaf mtime helper.
# shellcheck source=bin/fm-wake-lib.sh
FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  . "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

positive_int_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}
POLL_SECS=$(positive_int_or "${FM_CONTINUITY_POLL_SECS:-5}" 5)
RESTART_SECS=$(positive_int_or "${FM_CONTINUITY_RESTART_SECS:-2}" 2)
STALE_FLOOR=$((POLL_SECS + 60))
[ "$STALE_FLOOR" -ge 300 ] || STALE_FLOOR=300
STALE_SECS=$(positive_int_or "${FM_CONTINUITY_STALE_SECS:-$STALE_FLOOR}" "$STALE_FLOOR")
[ "$STALE_SECS" -ge "$STALE_FLOOR" ] || STALE_SECS=$STALE_FLOOR

mkdir -p "$STATE"
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
beat_age() {
  local mtime
  mtime=$(fm_lock_path_mtime "$BEAT" 2>/dev/null) || { printf 'none\n'; return 0; }
  printf '%s\n' "$(( $(date +%s) - mtime ))"
}
lock_pid() { cat "$WATCH_LOCK/pid" 2>/dev/null || true; }

if ! fm_lock_try_acquire "$LOCK"; then
  exit 0
fi
printf '%s\n' "$$" > "$PIDFILE"
cleanup() {
  rm -f "$PIDFILE" 2>/dev/null || true
  fm_lock_release "$LOCK" 2>/dev/null || true
}
on_signal() {  # <status>
  cleanup
  exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

log "continuity supervisor acquired lock stale=${STALE_SECS}s floor=${STALE_FLOOR}s poll=${POLL_SECS}s"

while true; do
  lp=$(lock_pid)
  if fm_pid_alive "$lp"; then
    # Another arm owns a live watcher. Attach and watch it, never start a second.
    log "attaching to existing watcher pid=$lp"
    started_at=$(date +%s)
    while fm_pid_alive "$lp"; do
      now=$(date +%s)
      up=$((now - started_at))
      age=$(beat_age)
      if [ "$up" -ge "$STALE_SECS" ] && [ "$age" != "none" ] && [ "$age" -ge "$STALE_SECS" ]; then
        log "watcher pid=$lp stuck (up=${up}s beat=${age}s); TERM"
        kill -TERM "$lp" 2>/dev/null || true
        sleep 0.5
        fm_pid_alive "$lp" && kill -KILL "$lp" 2>/dev/null || true
        break
      fi
      sleep "$POLL_SECS"
      lp=$(lock_pid)
      [ -n "$lp" ] || break
    done
    sleep "$RESTART_SECS"
    continue
  fi

  FM_HOME="$FM_HOME" FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCHER" >> "$STATE/.watch-restart.log" 2>&1 &
  wpid=$!
  started_at=$(date +%s)
  log "started watcher pid=$wpid"
  while fm_pid_alive "$wpid"; do
    now=$(date +%s)
    up=$((now - started_at))
    age=$(beat_age)
    if [ "$up" -ge "$STALE_SECS" ] && [ "$age" != "none" ] && [ "$age" -ge "$STALE_SECS" ]; then
      log "watcher pid=$wpid stuck (up=${up}s beat=${age}s); TERM"
      kill -TERM "$wpid" 2>/dev/null || true
      sleep 0.5
      fm_pid_alive "$wpid" && kill -KILL "$wpid" 2>/dev/null || true
      break
    fi
    sleep "$POLL_SECS"
  done
  wait "$wpid" 2>/dev/null || true
  log "watcher pid=$wpid finished"
  sleep "$RESTART_SECS"
done
