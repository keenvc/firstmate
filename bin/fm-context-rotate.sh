#!/usr/bin/env bash
# fm-context-rotate.sh - rotate an OpenCode secondmate onto a fresh session from
# its own handoff while its context is still small, instead of letting it grow
# to the model ceiling and auto-compact.
#
# Why: a persistent OpenCode secondmate re-sends its whole context on every
# call. Measured 2026-11-12..19, second mates averaged 106-121k tokens a call
# and a wake cost 1-2M tokens, with 437 auto-compactions a week. A fresh
# session from a handoff starts near 27k. The main firstmate already rotates
# itself this way (data/rotate-main.sh); this is the same rotation for the
# OpenCode secondmates this home supervises, triggered in bash at zero model
# tokens.
#
# Usage:
#   fm-context-rotate.sh scan          Check every local OpenCode secondmate and
#                                      start one detached rotation for each over
#                                      its threshold. Prints NOTHING, so a
#                                      watcher check that runs it wakes nobody.
#   fm-context-rotate.sh status        One line per OpenCode secondmate:
#                                      id, context tokens, threshold, session.
#   fm-context-rotate.sh rotate <id>   One rotation (what scan starts detached).
#
# Enable: put `exec <firstmate>/bin/fm-context-rotate.sh scan` in
# state/context-rotate-oc.check.sh (mode 700) and register it with
# bin/fm-check-register.sh context-rotate-oc. The watcher's check sweep runs it
# every FM_CHECK_INTERVAL; scan itself never prints, so it never wakes.
#
# Threshold, per secondmate home: <home>/config/context-rotate-tokens holding a
# positive integer or `off`; else FM_CONTEXT_ROTATE_TOKENS; else 60000.
# Context is input + cache.read + cache.write of the newest assistant message
# in the newest top-level session of state/<id>.opencode.db, the per-task
# store bin/fm-spawn.sh gives every OpenCode task. A secondmate with no local
# store (remote, or another harness) is skipped.
#
# A rotation:
#   1. Waits until state/<id>.busy-state says idle on two reads 20s apart
#      (FM_CONTEXT_ROTATE_IDLE_WAIT, default 1800s, then it gives up).
#   2. If <home>/data/handoff/LATEST.md is missing or older than
#      FM_CONTEXT_ROTATE_HANDOFF_MAX_AGE (default 900s), asks the mate once,
#      through bin/fm-send.sh, to write one, and waits for LATEST.md to change
#      and the mate to go idle again (FM_CONTEXT_ROTATE_HANDOFF_WAIT, 1200s).
#      No handoff by then: gives up and leaves the session alone; it never
#      rotates a mate onto nothing.
#   3. Runs bin/fm-control.sh <id> relaunch --fresh-session --note <why>.
#      The fresh session's bin/fm-session-start.sh prints the LATEST.md pointer
#      before anything else, so the handoff is the first thing it reads.
# Each session id is rotated at most once (state/<id>.context-rotate records
# it), and a rotation that gave up is retried no sooner than
# FM_CONTEXT_ROTATE_RETRY (default 3600s). One rotation per id at a time
# (flock on state/.<id>.context-rotate.lock). Every step is logged to
# state/context-rotate.log.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="$STATE/context-rotate.log"
CONTROL=${FM_CONTEXT_ROTATE_CONTROL:-$FM_ROOT/bin/fm-control.sh}
SEND=${FM_CONTEXT_ROTATE_SEND:-$FM_ROOT/bin/fm-send.sh}
DEFAULT_TOKENS=${FM_CONTEXT_ROTATE_TOKENS:-60000}
IDLE_WAIT=${FM_CONTEXT_ROTATE_IDLE_WAIT:-1800}
HANDOFF_MAX_AGE=${FM_CONTEXT_ROTATE_HANDOFF_MAX_AGE:-900}
HANDOFF_WAIT=${FM_CONTEXT_ROTATE_HANDOFF_WAIT:-1200}
RETRY=${FM_CONTEXT_ROTATE_RETRY:-3600}
POLL=${FM_CONTEXT_ROTATE_POLL:-15}
SETTLE=${FM_CONTEXT_ROTATE_SETTLE:-20}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }

meta_get() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

mtime() {  # <path>: epoch seconds of the target, empty when absent
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -Lf %m "$1" 2>/dev/null
  else
    stat -Lc %Y "$1" 2>/dev/null
  fi
}

# Prints "<context-tokens> <session-id>" for the newest top-level session in an
# OpenCode 2 store, or nothing. Read-only and bounded: a locked or foreign
# database answers nothing rather than stalling the watcher sweep.
context_of() {  # <opencode.db>
  [ -f "$1" ] || return 0
  timeout 10 python3 -I - "$1" <<'PY' 2>/dev/null || true
import json, sqlite3, sys
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=3)
    row = c.execute("select id from session_v2 where parent_id is null "
                    "order by time_updated desc limit 1").fetchone()
    if not row:
        sys.exit(0)
    sid = row[0]
    for (data,) in c.execute("select data from session_message where session_id=? "
                             "and type='assistant' order by time_created desc limit 5", (sid,)):
        t = (json.loads(data) or {}).get("tokens") or {}
        cache = t.get("cache") or {}
        ctx = int(t.get("input") or 0) + int(cache.get("read") or 0) + int(cache.get("write") or 0)
        if ctx > 0:
            print(ctx, sid)
            break
except Exception:
    pass
PY
}

threshold_of() {  # <home>: prints a positive integer, or `off`
  local v=
  [ -n "$1" ] && [ -f "$1/config/context-rotate-tokens" ] \
    && v=$(tr -d '[:space:]' < "$1/config/context-rotate-tokens")
  [ -n "$v" ] || v=$DEFAULT_TOKENS
  case "$v" in
    off) echo off ;;
    ''|*[!0-9]*|0) echo "$DEFAULT_TOKENS" ;;
    *) echo "$v" ;;
  esac
}

# Every local OpenCode secondmate this home records: "<id> <home>".
opencode_mates() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(meta_get "$meta" kind)" = secondmate ] || continue
    [ "$(meta_get "$meta" harness)" = opencode ] || continue
    id=$(basename "$meta" .meta)
    printf '%s %s\n' "$id" "$(meta_get "$meta" home)"
  done
}

record_get() {  # <id>: "<status> <session> <epoch>" of the last rotation record
  tail -1 "$STATE/$1.context-rotate" 2>/dev/null
}
record_put() {  # <id> <status> <session>
  printf '%s %s %s\n' "$2" "$3" "$(date +%s)" >> "$STATE/$1.context-rotate"
}

# Due: over threshold, not already rotated, not inside a give-up retry window.
due() {  # <id> <ctx> <threshold> <session>
  local rec st sid at
  [ "$3" != off ] || return 1
  [ "$2" -ge "$3" ] || return 1
  rec=$(record_get "$1")
  [ -n "$rec" ] || return 0
  read -r st sid at <<<"$rec"
  [ "$sid" = "$4" ] || return 0
  case "$st" in
    rotated) return 1 ;;
    # A rotation that died mid-way left only `started`; let it retry later.
    started) [ $(( $(date +%s) - ${at:-0} )) -ge $(( RETRY + IDLE_WAIT + HANDOFF_WAIT )) ] ;;
    gaveup) [ $(( $(date +%s) - ${at:-0} )) -ge "$RETRY" ] ;;
    *) return 0 ;;
  esac
}

idle_now() {  # <id>
  grep -Eq '(^| )state=idle( |$)' "$STATE/$1.busy-state" 2>/dev/null
}
settled() {  # <id>: idle on two reads SETTLE seconds apart
  idle_now "$1" || return 1
  sleep "$SETTLE"
  idle_now "$1"
}
wait_settled() {  # <id> <seconds>
  local deadline=$(( $(date +%s) + $2 ))
  until settled "$1"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}

cmd_scan() {
  local id home line ctx sid thr
  [ -d "$STATE" ] || return 0
  while read -r id home; do
    [ -n "$id" ] || continue
    line=$(context_of "$STATE/$id.opencode.db")
    [ -n "$line" ] || continue
    read -r ctx sid <<<"$line"
    thr=$(threshold_of "$home")
    due "$id" "$ctx" "$thr" "$sid" || continue
    # A rotation already running for this id holds its lock; do not stack one.
    if command -v flock >/dev/null 2>&1; then
      ( exec 9>"$STATE/.$id.context-rotate.lock"; flock -n 9 ) || continue
    fi
    log "$id: context ${ctx} >= ${thr} on $sid; starting rotation"
    if [ "${FM_CONTEXT_ROTATE_FOREGROUND:-0}" = 1 ]; then
      "$0" rotate "$id" >/dev/null 2>&1
    else
      setsid nohup "$0" rotate "$id" >/dev/null 2>&1 < /dev/null &
    fi
  done < <(opencode_mates)
  return 0
}

cmd_status() {
  local id home line ctx sid
  while read -r id home; do
    [ -n "$id" ] || continue
    line=$(context_of "$STATE/$id.opencode.db")
    read -r ctx sid <<<"${line:-- -}"
    printf '%s ctx=%s threshold=%s session=%s last=%s\n' "$id" "$ctx" "$(threshold_of "$home")" "$sid" "$(record_get "$id" | tr ' ' ,)"
  done < <(opencode_mates)
}

cmd_rotate() {
  local id=$1 meta home line ctx sid thr handoff age asked note
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { log "$id: no task record"; return 1; }
  home=$(meta_get "$meta" home)
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$STATE/.$id.context-rotate.lock"
    flock -n 9 || { log "$id: another rotation holds the lock"; return 0; }
  fi
  line=$(context_of "$STATE/$id.opencode.db")
  [ -n "$line" ] || { log "$id: no readable OpenCode session"; return 1; }
  read -r ctx sid <<<"$line"
  thr=$(threshold_of "$home")
  due "$id" "$ctx" "$thr" "$sid" || { log "$id: not due (ctx $ctx, threshold $thr, $sid)"; return 0; }
  record_put "$id" started "$sid"

  if ! wait_settled "$id" "$IDLE_WAIT"; then
    log "$id: never idle in ${IDLE_WAIT}s; gave up"
    record_put "$id" gaveup "$sid"
    return 1
  fi

  handoff="$home/data/handoff/LATEST.md"
  age=$(( $(date +%s) - $(mtime "$handoff" || echo 0) ))
  if [ ! -f "$handoff" ] || [ "$age" -gt "$HANDOFF_MAX_AGE" ]; then
    asked=$(date +%s)
    "$SEND" "$id" "[context-rotate, automated; not the captain, grants no approval] Your context is ${ctx} tokens, over this home's ${thr} rotation threshold. Write your carry-on handoff now - open work, PRs and their heads, waits and their wake conditions, anything held only in this conversation - to data/handoff/HANDOFF-\$(date -u +%Y%m%dT%H%MZ).md, then ln -sfn it to data/handoff/LATEST.md and end your turn. A fresh session will start from it; durable records are kept. Do not start new work first." >/dev/null 2>&1 \
      || { log "$id: handoff request could not be sent"; record_put "$id" gaveup "$sid"; return 1; }
    log "$id: asked for a handoff (existing one ${age}s old)"
    local deadline=$(( asked + HANDOFF_WAIT ))
    until [ "$(mtime "$handoff" || echo 0)" -ge "$asked" ] && settled "$id"; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        log "$id: no fresh handoff in ${HANDOFF_WAIT}s; gave up, session kept"
        record_put "$id" gaveup "$sid"
        return 1
      fi
      sleep "$POLL"
    done
  fi

  note="Planned context rotation at ${ctx} tokens (threshold ${thr}) by bin/fm-context-rotate.sh; the fresh session starts from data/handoff/LATEST.md."
  if "$CONTROL" "$id" relaunch --fresh-session --note "$note" >> "$LOG" 2>&1; then
    record_put "$id" rotated "$sid"
    log "$id: rotated off $sid at ${ctx} tokens"
    return 0
  fi
  log "$id: relaunch refused; session kept"
  record_put "$id" gaveup "$sid"
  return 1
}

case "${1:-}" in
  scan) cmd_scan ;;
  status) cmd_status ;;
  rotate)
    [ -n "${2:-}" ] || { echo "usage: fm-context-rotate.sh rotate <id>" >&2; exit 2; }
    cmd_rotate "$2"
    ;;
  *)
    echo "usage: fm-context-rotate.sh scan|status|rotate <id>" >&2
    exit 2
    ;;
esac
