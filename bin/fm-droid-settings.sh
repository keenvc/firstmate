#!/usr/bin/env bash
# Write a private Factory Droid runtime settings JSON carrying firstmate's
# worker settings and lifecycle hooks.
# Usage: fm-droid-settings.sh <state-dir> <task-id> <busy-gen> [<model>] [<effort>]
# Output: <state-dir>/<task-id>.droid-settings.json, mode 600, atomically replaced.
# Factory Droid CLI accepts `--settings <path>` and merges that JSON at the
# `runtime` hierarchy level (highest precedence, above folder/project/user/org)
# for that process only. Hooks arrays merge across hierarchy levels, so user
# `~/.factory/settings.json` hooks keep running alongside these per-task hooks.
# Nothing global and nothing in the worktree is edited; fm-control-lib.sh and
# fm-teardown.sh own retirement.
# includeCoAuthoredByDroid=false is forced unless FM_KEEP_AI_TRAILERS=1.
# sessionDefaultSettings sets autonomyLevel="high", autonomyMode="auto-high",
# interactionMode="auto", plus model (when non-empty and not "default") and
# reasoningEffort (when low|medium|high).
# UserPromptSubmit opens a turn; Stop (--turn-ended) and SessionEnd close it.
set -eu
case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state directory required}
ID=${2:?task id required}
GEN=${3:?busy generation required}
MODEL=${4:-}
EFFORT=${5:-}
KEEP=${FM_KEEP_AI_TRAILERS:-0}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
case "$GEN" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid busy generation' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
prefix="$(quote "$SCRIPT_DIR/fm-busy-event.sh") apply $(quote "$STATE") $(quote "$ID")"
suffix="--gen $(quote "$GEN") --source droid-hook"
report() {  # <working|idle|release>
  local verb=report-agent tail="--state $1"
  if [ "$1" = release ]; then verb=release-agent; tail=; fi
  printf '%s' "if [ \"\${HERDR_ENV:-}\" = 1 ] && [ -n \"\${HERDR_PANE_ID:-}\" ]; then \"\${HERDR_BIN_PATH:-herdr}\" pane $verb \"\$HERDR_PANE_ID\" --source firstmate:droid --agent droid $tail >/dev/null 2>&1; fi; true"
}
start="$(report idle)"
submit="$prefix busy $suffix --event user-prompt-submit >/dev/null 2>&1 || true; $(report working)"
stop="$prefix idle $suffix --event stop --turn-ended >/dev/null 2>&1 || true; $(report idle)"
end="$prefix idle $suffix --event session-end >/dev/null 2>&1 || true; $(report release)"
final="$STATE/$ID.droid-settings.json"
umask 077
temp=$(mktemp "$STATE/.$ID.droid-settings.XXXXXX")
trap 'rm -f "$temp"' EXIT
jq -n \
  --arg keep "$KEEP" \
  --arg model "$MODEL" \
  --arg effort "$EFFORT" \
  --arg start "$start" \
  --arg submit "$submit" \
  --arg stop "$stop" \
  --arg end "$end" '
  def hook($cmd): [{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 10}]}];
  ({
    sessionDefaultSettings: (
      {
        autonomyLevel: "high",
        autonomyMode: "auto-high",
        interactionMode: "auto"
      }
      + (if ($model != "" and $model != "default") then {model: $model} else {} end)
      + (if ($effort == "low" or $effort == "medium" or $effort == "high") then {reasoningEffort: $effort} else {} end)
    ),
    hooks: {
      SessionStart: hook($start),
      UserPromptSubmit: hook($submit),
      Stop: hook($stop),
      SessionEnd: hook($end)
    }
  })
  | if $keep == "1" then . else .includeCoAuthoredByDroid = false end
' > "$temp"
chmod 600 "$temp"
mv "$temp" "$final"
trap - EXIT
