#!/usr/bin/env bash
# fm-check-emit.sh - print a custom check's wake text only when it says
# something new.
#
# Why: a watcher check that prints wakes its supervisor, and a supervisor
# turn re-sends the whole context (~110k tokens on a persistent mate). In
# 2026-11-17..19, 883 of ~3,500 weekly wakes did nothing; on the adclinica
# mate, custom checks that re-printed an unchanged condition every sweep
# (adclinica-pr-flow "no overseer verdict yet", adclinica-deploy-proof) were
# a large share of them. This filter sits at the end of a check script, in
# the check's own file, so the watcher itself is untouched.
#
# Usage, as the last stage of state/<id>.check.sh:
#   <produce the wake text> | exec <firstmate>/bin/fm-check-emit.sh <id> \
#       [--repeat-after <seconds>] [--ignore-numbers] [--ignore <ERE>]
#
#   Prints stdin unchanged when it differs from the text this check last
#   emitted, or when --repeat-after seconds have passed since that emission
#   (default: never repeat an unchanged text). Otherwise prints nothing, which
#   the watcher reads as "no wake". Empty input prints nothing and clears the
#   memory, so a condition that clears and later returns wakes again.
#   --ignore-numbers compares with every digit run replaced, so "idle 31m"
#   and "idle 36m" are the same condition; --ignore <ERE> drops matching lines
#   from the comparison only. The emitted text is always the original.
#
# State: <state>/.check-emit/<id>.{sum,at}. Exit status is always 0 unless
# the arguments are invalid (2), so a filter failure never reads as a wake.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ID=${1:-}
case "$ID" in ''|-*|*/*|*[!A-Za-z0-9._-]*) echo "usage: fm-check-emit.sh <check-id> [--repeat-after <s>] [--ignore-numbers] [--ignore <ERE>]" >&2; exit 2 ;; esac
shift
REPEAT=0
NUMBERS=0
IGNORE=
while [ $# -gt 0 ]; do
  case "$1" in
    --repeat-after) REPEAT=${2:-}; shift 2 ;;
    --ignore-numbers) NUMBERS=1; shift ;;
    --ignore) IGNORE=${2:-}; shift 2 ;;
    *) echo "fm-check-emit: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$REPEAT" in ''|*[!0-9]*) echo "fm-check-emit: --repeat-after needs seconds" >&2; exit 2 ;; esac

DIR="$STATE/.check-emit"
mkdir -p "$DIR" 2>/dev/null || { cat; exit 0; }
TEXT=$(cat; printf x)
TEXT=${TEXT%x}

if [ -z "$TEXT" ] || [ -z "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ]; then
  rm -f "$DIR/$ID.sum" "$DIR/$ID.at"
  exit 0
fi

key=$(printf '%s' "$TEXT" | {
  if [ -n "$IGNORE" ]; then grep -Ev -- "$IGNORE" || true; else cat; fi
} | {
  if [ "$NUMBERS" = 1 ]; then sed -E 's/[0-9]+/N/g'; else cat; fi
} | cksum | tr -d ' \t')

now=$(date +%s)
last=$(cat "$DIR/$ID.sum" 2>/dev/null || true)
at=$(cat "$DIR/$ID.at" 2>/dev/null || echo 0)
case "$at" in ''|*[!0-9]*) at=0 ;; esac
if [ "$key" = "$last" ]; then
  if [ "$REPEAT" -eq 0 ] || [ $((now - at)) -lt "$REPEAT" ]; then
    exit 0
  fi
fi
printf '%s\n' "$key" > "$DIR/$ID.sum" 2>/dev/null || true
printf '%s\n' "$now" > "$DIR/$ID.at" 2>/dev/null || true
printf '%s' "$TEXT"
exit 0
