#!/usr/bin/env bash
# fm-declared-hold.sh - dated hold records that recurring checks skip, plus a
# per-check wake counter.
#
# A held PR or a deliberately paused lane is correct, not stalled, so a check
# that wakes firstmate on it is noise. A declared hold says so once: who owns
# it, why, and until when. Checks skip the key while `until` is in the future
# and wake exactly once when it passes. Dated suppressions only: `declare`
# refuses an undated or already-past `until`, because an undated suppression is
# the original silence (same rule as v10's lib/monitoring/alert-suppressions.ts).
#
# Usage:
#   fm-declared-hold.sh declare <key> --owner <who> --reason <why> --until YYYY-MM-DDTHH:MMZ
#   fm-declared-hold.sh clear <key>
#   fm-declared-hold.sh active <key>              exit 0 = hold in force (skip), 1 = none/expired
#   fm-declared-hold.sh expired [--prefix <p>]    print one wake line per newly expired hold, once each
#   fm-declared-hold.sh list [--active]           --active: only holds still in force (what checks skip)
#   fm-declared-hold.sh count <check>             record one wake for <check>
#   fm-declared-hold.sh counts [--days <n>]       wakes per check per UTC day (default 7 days)
#
# Keys use [A-Za-z0-9._-]; by convention pr-<repo>-<n>, lane-<id>, ask-<id>,
# sa-<repo>. Records live in $FM_HOME/state/declared-holds/<key>.hold as
# key=value lines (owner, reason, until, declared, woken). Wake counts append
# "<epoch> <check>" lines to $FM_HOME/state/check-wakes.log.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HOLDS="$STATE/declared-holds"
WAKES="$STATE/check-wakes.log"

die() { echo "error: $*" >&2; exit 2; }

valid_key() { case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac; }

# until "YYYY-MM-DDTHH:MMZ" (UTC) -> epoch seconds
to_epoch() {
  case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) ;; *) return 1 ;; esac
  date -u -d "${1%Z}:00Z" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${1%Z}:00Z" +%s 2>/dev/null
}

field() { sed -n "s/^$2=//p" "$1" | head -1; }

hold_file() { valid_key "$1" || die "invalid key: $1"; printf '%s/%s.hold\n' "$HOLDS" "$1"; }

cmd=${1:-}; [ "$#" -gt 0 ] && shift
case "$cmd" in
  declare)
    key=${1:-}; [ "$#" -gt 0 ] && shift
    owner='' reason='' until=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --owner) owner=${2:-}; shift 2 ;;
        --reason) reason=${2:-}; shift 2 ;;
        --until) until=${2:-}; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    f=$(hold_file "$key")
    [ -n "$owner" ] && [ -n "$reason" ] && [ -n "$until" ] || die "declare needs --owner, --reason and --until"
    case "$owner$reason" in *$'\n'*) die "owner and reason must be single lines" ;; esac
    ue=$(to_epoch "$until") || die "--until must be YYYY-MM-DDTHH:MMZ (UTC)"
    now=$(date +%s)
    [ "$ue" -gt "$now" ] || die "--until is already past; a hold must be dated in the future"
    mkdir -p "$HOLDS" || die "cannot create $HOLDS"
    tmp=$(mktemp "$HOLDS/.tmp.XXXXXX") || exit 1
    printf 'owner=%s\nreason=%s\nuntil=%s\ndeclared=%s\n' "$owner" "$reason" "$until" "$now" > "$tmp"
    mv -f -- "$tmp" "$f" || exit 1
    echo "declared: $key until $until"
    ;;
  clear)
    f=$(hold_file "${1:-}")
    if [ -f "$f" ]; then rm -f -- "$f"; echo "cleared: $1"; else echo "no hold: $1"; fi
    ;;
  active)
    f=$(hold_file "${1:-}")
    [ -f "$f" ] || exit 1
    ue=$(to_epoch "$(field "$f" until)") || exit 1
    [ "$ue" -gt "$(date +%s)" ]
    ;;
  expired)
    prefix=
    if [ "${1:-}" = --prefix ]; then prefix=${2:-}; fi
    now=$(date +%s)
    for f in "$HOLDS"/"$prefix"*.hold; do
      [ -f "$f" ] || continue
      [ -z "$(field "$f" woken)" ] || continue
      ue=$(to_epoch "$(field "$f" until)") || continue
      [ "$ue" -le "$now" ] || continue
      key=$(basename "$f" .hold)
      printf 'woken=%s\n' "$now" >> "$f"
      echo "declared hold expired: $key (owner $(field "$f" owner); held for: $(field "$f" reason)) - re-check it, then re-declare or clear"
    done
    exit 0
    ;;
  list)
    now=$(date +%s)
    for f in "$HOLDS"/*.hold; do
      [ -f "$f" ] || continue
      if [ "${1:-}" = --active ]; then
        ue=$(to_epoch "$(field "$f" until)") || continue
        [ "$ue" -gt "$now" ] || continue
      fi
      printf '%s\tuntil=%s\towner=%s\t%s\n' "$(basename "$f" .hold)" "$(field "$f" until)" "$(field "$f" owner)" "$(field "$f" reason)"
    done
    exit 0
    ;;
  count)
    check=${1:-}; valid_key "$check" || die "invalid check name: $check"
    mkdir -p "$STATE" && printf '%s %s\n' "$(date +%s)" "$check" >> "$WAKES"
    ;;
  counts)
    days=7; [ "${1:-}" = --days ] && days=${2:-7}
    case "$days" in ''|*[!0-9]*) die "--days must be a number" ;; esac
    [ -f "$WAKES" ] || exit 0
    since=$(( $(date +%s) - days * 86400 ))
    while read -r ts check; do
      [ "$ts" -ge "$since" ] 2>/dev/null || continue
      printf '%s %s\n' "$(date -u -d "@$ts" +%F 2>/dev/null || date -u -r "$ts" +%F)" "$check"
    done < "$WAKES" | sort | uniq -c | awk '{print $2"\t"$3"\t"$1}'
    ;;
  *) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
