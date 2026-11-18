#!/usr/bin/env bash
# fm-pending-reply-expire.sh - close stale pending-reply-missed decisions.
#
# Usage: fm-pending-reply-expire.sh [--apply] [--max-age-secs N]
#
# Lists every pending-reply-missed decision still open after the max age
# (default 24h) in this home's state/*.status logs. Without --apply it only
# lists (dry-run) and writes nothing. With --apply it appends a resolved line
# for each, carrying the exact key and via=stale, and marks the record resolved.
# A decision naming a captain-held task is skipped. The rule lives in
# fm_pending_reply_expire_stale (bin/fm-pending-reply-lib.sh).
#
# Requires an explicit FM_HOME. Output: one "would-close|closed|skipped-held|
# failed <status-file> <key> age=<secs>" line per candidate, then a summary line
# "summary: candidates=N held=N unresolved-open=N apply=0|1".
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apply=0
max=${FM_PENDING_REPLY_STALE_SECS:-86400}
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,15{s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    --apply) apply=1; shift ;;
    --max-age-secs)
      [ $# -ge 2 ] || { echo "error: --max-age-secs needs a value" >&2; exit 2; }
      max=$2; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$max" in ''|*[!0-9]*) echo "error: max age must be a non-negative integer" >&2; exit 2 ;; esac
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
out=$(fm_pending_reply_expire_stale "$STATE" "$apply" "$max")
[ -z "$out" ] || printf '%s\n' "$out"
cand=$(printf '%s\n' "$out" | grep -c '^\(would-close\|closed\|failed\) ' || true)
held=$(printf '%s\n' "$out" | grep -c '^skipped-held ' || true)
open=0
for f in "$STATE"/*.status; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  n=$(status_open_decisions "$f" | grep -c "^pending-reply-" || true)
  open=$((open + n))
done
printf 'summary: candidates=%s held=%s unresolved-open=%s apply=%s\n' "$cand" "$held" "$open" "$apply"
