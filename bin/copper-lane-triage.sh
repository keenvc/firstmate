#!/usr/bin/env bash
# lane-triage: pair every raw lane-sweep finding with the owning home's record
# so copper's weak classifier can never nag about a lane its own supervisor has
# already handled. READ-ONLY.
#
# Usage: bin/copper-lane-triage.sh
# Reads state/lane-sweep.check.sh output on stdin (or runs it) and prints the
# surviving actionable findings in the same format:
#   <kind> <task-id> <home> <detail> <action>
#   <kind> <task-id> <home> <detail> <action>   (only when the record still
#                                                stands after the checks below)
#
# Pairing rules:
#   finished-untended / spawned-no-status -> dropped when the worktree named in
#     the lane's metadata is gone (the owner tore the lane down; its terminal
#     line is history) or the owning home's crew-state reports it torn down.
#   stalled -> kept; the pane digest and busy state already proved silence.
#   check-untrusted -> kept.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SWEEP=${LANE_SWEEP:-$HERE/state/lane-sweep.check.sh}

raw=$(nice -n 19 timeout 200 "$SWEEP" 2>/dev/null) || true

while IFS=$'\t' read -r kind id home detail action; do
  [ -n "$kind" ] || continue
  case "$kind" in
    finished-untended|spawned-no-status)
      wt=$(sed -n 's/^worktree=//p' "$home/state/$id.meta" 2>/dev/null | head -n 1)
      if [ -n "$wt" ] && [ ! -d "$wt" ]; then
        continue
      fi
      state=$("$home/bin/fm-crew-state.sh" "$id" 2>/dev/null | head -n 1)
      case "$state" in
        *"worktree gone"*|*"torn down"*) continue ;;
      esac
      ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$id" "$home" "$detail" "$action"
done <<EOF
$raw
EOF

exit 0
