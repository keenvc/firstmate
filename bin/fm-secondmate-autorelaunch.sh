#!/usr/bin/env bash
# fm-secondmate-autorelaunch.sh - cron-driven, zero-token relaunch of a second
# mate that was recorded dead, independent of the watcher being up.
#
# The watcher's secondmate_liveness_tick relaunches a dead mate within a minute,
# but only while the watcher runs, and it parks a mate for good after
# FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS attempts in an hour (until a probe reads it
# live again). A mate whose relaunch failed while the watcher was down or parked
# therefore waited hours for a human. This command closes that gap from cron:
#
#   for every kind=secondmate meta that has a state/<id>.last-death.txt record,
#   under the same per-mate liveness lock the watcher and bootstrap use, probe
#   the endpoint (poll mode, read-only for remote routes). Only a `relaunchable`
#   verdict (confirmed dead or confidently missing) acts:
#     - fewer than FM_AUTORELAUNCH_MAX (3) ledgered attempts in the last
#       FM_AUTORELAUNCH_WINDOW_SECS (3600): relaunch through the shared guarded
#       path fm_secondmate_liveness_relaunch (bin/fm-secondmate-liveness-lib.sh:
#       the same fm-spawn.sh --secondmate respawn from the mate's own home and
#       handoff that session start and the watcher use, with the same attempt
#       ledger, so the cap is shared with the watcher). A watcher park marker
#       does not stop it once the window has room again.
#     - at the cap: one `check` wake per mate per window ("relaunch it manually
#       or retire the route") and nothing else.
#   Every other verdict (alive, skipped, unreadable, silent) does nothing.
#
# The captain's dispatch hold (FM_DISPATCH_HOLD_FLAG, default
# /home/azureuser/fm-local/dispatch-hold.flag) forbids spawning workers, not
# relaunching a second mate: the relaunch proceeds, is logged as made under the
# hold, and this command never spawns a worker itself. Disable entirely with
# state/.autorelaunch-off. Never kills a live agent; the shared library only
# closes an endpoint the probe proved dead.
#
# Usage: fm-secondmate-autorelaunch.sh [--dry-run]
#   cron: */5 * * * * FM_HOME=/home/azureuser/firstmate /home/azureuser/firstmate/bin/fm-secondmate-autorelaunch.sh >/dev/null 2>&1
# Log: state/autorelaunch.log
set -uo pipefail

DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="$STATE/autorelaunch.log"
MAX=${FM_AUTORELAUNCH_MAX:-3}
WINDOW=${FM_AUTORELAUNCH_WINDOW_SECS:-3600}
TIMEOUT=${FM_AUTORELAUNCH_TIMEOUT:-300}
HOLD_FLAG=${FM_DISPATCH_HOLD_FLAG:-/home/azureuser/fm-local/dispatch-hold.flag}
case "$MAX" in ''|*[!0-9]*|0) MAX=3 ;; esac
case "$WINDOW" in ''|*[!0-9]*|0) WINDOW=3600 ;; esac

[ -d "$STATE" ] || exit 0
log() { printf '[%s] %s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([ "$DRY" = 1 ] && echo 'DRY-RUN ')" "$*" >> "$LOG"; }
[ ! -e "$STATE/.autorelaunch-off" ] || { log "disabled by state/.autorelaunch-off"; exit 0; }

exec 9>"$STATE/.autorelaunch.flock" || exit 1
flock -n 9 || { log "another run holds the lock; exit"; exit 0; }

# shellcheck source=bin/fm-secondmate-liveness-lib.sh
FM_ROOT_OVERRIDE="$FM_ROOT" . "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh" || { log "cannot load the liveness library"; exit 1; }
# Test seam: a file sourced after the library may replace the probe and the
# relaunch with fixtures; the ledger, locks, and cap stay the real ones.
if [ -n "${FM_AUTORELAUNCH_TEST_OVERRIDES:-}" ]; then
  # shellcheck source=/dev/null
  . "$FM_AUTORELAUNCH_TEST_OVERRIDES" || exit 1
fi

alert() {  # <id> <text>
  local key="autorelaunch-cap-$1-$(( $(date +%s) / WINDOW ))"
  log "ALERT $1: $2"
  [ "$DRY" = 0 ] || return 0
  [ ! -e "$STATE/.$key" ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  if FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh" \
    && fm_wake_append check "$key" "check: $2"; then
    : > "$STATE/.$key"
  fi
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(fm_meta_get "$meta" kind 2>/dev/null)" = secondmate ] || continue
  id=${meta##*/}; id=${id%.meta}
  case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  [ -f "$STATE/$id.last-death.txt" ] || continue
  if ! fm_secondmate_liveness_lock "$id"; then
    log "$id: liveness lock busy (watcher or bootstrap mid-episode); skip"
    continue
  fi
  fm_secondmate_liveness_probe "$meta" "$id" poll
  if [ "$FM_SM_LIVE_STATUS" != relaunchable ]; then
    [ "$FM_SM_LIVE_STATUS" = alive ] || log "$id: probe $FM_SM_LIVE_STATUS${FM_SM_LIVE_REASON:+ ($FM_SM_LIVE_REASON)}; no action"
    fm_secondmate_liveness_unlock "$id"
    continue
  fi
  if ! attempts=$(fm_secondmate_liveness_recent_attempts "$id" "$WINDOW"); then
    log "$id: relaunch ledger unreadable; endpoint left $FM_SM_LIVE_STATE"
    fm_secondmate_liveness_unlock "$id"
    continue
  fi
  if [ "$attempts" -ge "$MAX" ]; then
    alert "$id" "secondmate $id is still $FM_SM_LIVE_STATE after $attempts relaunch attempts in ${WINDOW}s; auto-relaunch stops for this window - relaunch it manually (bin/fm-spawn.sh $id --secondmate) or retire the route. Last death: state/$id.last-death.txt"
    fm_secondmate_liveness_unlock "$id"
    continue
  fi
  hold_note=''
  [ ! -e "$HOLD_FLAG" ] || hold_note=' (captain dispatch hold in force: relaunching the second mate only, no worker is spawned here)'
  if [ "$DRY" = 1 ]; then
    log "$id: would relaunch: $FM_SM_LIVE_CAUSE ($FM_SM_LIVE_WHERE), attempts in window $attempts/$MAX$hold_note"
    fm_secondmate_liveness_unlock "$id"
    continue
  fi
  log "$id: relaunching after $FM_SM_LIVE_CAUSE ($FM_SM_LIVE_WHERE), attempt $((attempts + 1))/$MAX$hold_note"
  if fm_secondmate_liveness_relaunch "$meta" "$id" "$TIMEOUT"; then
    # The watcher's park marker is left for the watcher: its next live probe
    # ledgers `rearmed` and clears it, as for any manually recovered mate.
    log "$id: relaunched"
  else
    log "$id: relaunch ${FM_SM_LIVE_STATUS}: $(fm_sm_live_first_line "${FM_SM_LIVE_REASON:-$FM_SM_LIVE_OUT}")"
    if [ $((attempts + 1)) -ge "$MAX" ]; then
      alert "$id" "secondmate $id auto-relaunch failed $((attempts + 1)) times in ${WINDOW}s; relaunch it manually (bin/fm-spawn.sh $id --secondmate) or retire the route. Last death: state/$id.last-death.txt"
    fi
  fi
  fm_secondmate_liveness_unlock "$id"
done
exit 0
