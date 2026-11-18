#!/usr/bin/env bash
# fm-deadman.sh - generic dead-man rule for scheduled jobs, as one watcher check.
#
# Usage:
#   fm-deadman.sh [check]
#   fm-deadman.sh arm
#   fm-deadman.sh disarm
#   fm-deadman.sh --help
#
# Declaration: $FM_HOME/config/deadman.tsv, one job per line, tab separated:
#   <name> <cadence-seconds> <success-glob> <log-file>
# Blank lines and lines starting with # are ignored. The glob and the log are
# relative to FM_HOME (or absolute) and must hold no whitespace. A job's last
# success is the newest modification time among the files its glob matches,
# e.g. data/velocity-audit-*/report.md, so a job needs no change to be covered.
# A glob with no match counts from the declaration file's own age, so a job
# that never succeeded is still caught.
#
# `check` prints one line when a job's last success is older than two
# cadences, naming the job, its age, and the last non-empty line of its log
# (the evidence); the watcher turns that line into a `check:` wake. It prints
# that job once per last-success value: the marker state/.deadman-<name> holds
# the success time already reported, so the same stale job stays silent until
# it succeeds again and then goes stale again. Healthy jobs print nothing.
#
# `arm` writes state/deadman.check.sh and binds its bytes with
# fm-check-register.sh; `disarm` removes it through fm-check-unregister.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DECL="$CONFIG/deadman.tsv"
CHECK_ID=deadman

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# newest_mtime <glob>: newest mtime among matches, empty when none match.
newest_mtime() {
  local best= m f
  for f in $1; do
    [ -f "$f" ] || continue
    m=$(mtime "$f") || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best=$m; fi
  done
  printf '%s' "$best"
}

# last_line <file>: last non-empty line, control characters dropped, bounded.
last_line() {
  [ -f "$1" ] || { printf 'no log at %s' "$1"; return; }
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | tr -d '\000-\037' | cut -c1-300
}

run_check() {
  local name cadence glob log last now age decl_m marker reported
  [ -f "$DECL" ] || return 0
  now=$(date +%s)
  decl_m=$(mtime "$DECL") || decl_m=$now
  while IFS=$'\t' read -r name cadence glob log _rest; do
    case "$name" in ''|'#'*) continue ;; esac
    case "$name" in *[!A-Za-z0-9._-]*) continue ;; esac
    case "$cadence" in ''|*[!0-9]*) continue ;; esac
    [ "$cadence" -gt 0 ] || continue
    [ -n "$glob" ] && [ -n "$log" ] || continue
    case "$glob" in /*) ;; *) glob="$FM_HOME/$glob" ;; esac
    case "$log" in /*) ;; *) log="$FM_HOME/$log" ;; esac
    last=$(newest_mtime "$glob")
    [ -n "$last" ] || last=$decl_m
    age=$((now - last))
    [ "$age" -gt $((2 * cadence)) ] || continue
    marker="$STATE/.deadman-$name"
    reported=$(cat "$marker" 2>/dev/null || true)
    [ "$reported" != "$last" ] || continue
    printf 'deadman: %s has had no success for %ss (cadence %ss); last log line: %s\n' \
      "$name" "$age" "$cadence" "$(last_line "$log")"
    printf '%s' "$last" > "$marker" 2>/dev/null || true
  done < "$DECL"
}

case "${1:-check}" in
  check) run_check ;;
  arm)
    shim="$STATE/$CHECK_ID.check.sh"
    [ ! -L "$shim" ] || { echo "error: $shim is a symlink" >&2; exit 1; }
    umask 077
    printf '#!/usr/bin/env bash\nexec %q check\n' "$SCRIPT_DIR/fm-deadman.sh" > "$shim" || exit 1
    chmod 0700 "$shim" || exit 1
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID"
    ;;
  disarm)
    rm -f -- "$STATE"/.deadman-* 2>/dev/null
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID"
    ;;
  --help|-h) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: fm-deadman.sh [check|arm|disarm|--help]" >&2; exit 2 ;;
esac
