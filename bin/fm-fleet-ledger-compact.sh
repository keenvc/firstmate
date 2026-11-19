#!/usr/bin/env bash
# fm-fleet-ledger-compact.sh - write a de-duplicated copy of a fleet ledger.
#
# Offline tool for the documented at-least-once duplicates (docs/fleet-ledger.md).
# It only READS <input> and writes a NEW file; it never edits, truncates, or
# replaces the live state/fleet-ledger.jsonl. Swapping the compacted copy in is a
# separate, deliberate step for the operator (see docs/fleet-ledger.md).
#
# Usage: fm-fleet-ledger-compact.sh [--ignore-ts] <input.jsonl> <output.jsonl>
#
# Default: drops a line only when it is byte-for-byte identical to an earlier
# line; the first occurrence stays and order is preserved. Safe, but a replayed
# status record carries the replay's own ts, so it is NOT an exact duplicate and
# survives this mode.
# --ignore-ts: also treats two records as the same when everything but ts matches.
# That removes replayed task.status lines, but it also drops a status line a
# worker legitimately wrote twice (same state and text) at different times, and
# a repeated pr_ready. Use it for analysis or when that loss is acceptable.
#
# Exit status: 0 on success, 2 on a usage error, 1 on any other failure.
set -u
export LC_ALL=C

ignore_ts=0
if [ "${1:-}" = --ignore-ts ]; then ignore_ts=1; shift; fi
[ "$#" -eq 2 ] || { echo "usage: fm-fleet-ledger-compact.sh [--ignore-ts] <input.jsonl> <output.jsonl>" >&2; exit 2; }
in=$1
out=$2
[ -f "$in" ] && [ ! -L "$in" ] || { echo "fm-fleet-ledger-compact: $in is not a regular file" >&2; exit 1; }
[ ! -e "$out" ] && [ ! -L "$out" ] || { echo "fm-fleet-ledger-compact: $out already exists; refusing to overwrite" >&2; exit 1; }
[ "$in" -ef "$out" ] && { echo "fm-fleet-ledger-compact: input and output are the same file" >&2; exit 1; }

tmp="$out.tmp.$$"
trap 'rm -f -- "$tmp"' EXIT
awk -v ignore_ts="$ignore_ts" '
  {
    key = $0
    if (ignore_ts) sub(/^\{"v":1,"ts":[0-9]+,/, "{\"v\":1,", key)
    if (!(key in seen)) { seen[key] = 1; print }
  }
' "$in" > "$tmp" || { echo "fm-fleet-ledger-compact: compaction failed" >&2; exit 1; }
mv -- "$tmp" "$out" || exit 1
trap - EXIT
printf 'fm-fleet-ledger-compact: %s -> %s: %s -> %s lines, %s -> %s bytes\n' "$in" "$out" \
  "$(wc -l < "$in" | tr -d ' ')" "$(wc -l < "$out" | tr -d ' ')" \
  "$(wc -c < "$in" | tr -d ' ')" "$(wc -c < "$out" | tr -d ' ')"
