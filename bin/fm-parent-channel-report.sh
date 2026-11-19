#!/usr/bin/env bash
# fm-parent-channel-report.sh - a secondmate's own status append.
#
# The generated secondmate charter hands the mate one status command
# (bin/fm-brief.sh STATUS_APPEND). A captain-facing line from a mate belongs on
# its parent channel, never in the lane's own state log, so that command runs
# this script instead of a plain `echo >> path`: the destination is resolved by
# the one owner (bin/fm-parent-channel-lib.sh) from the home's durable identity
# and parent binding, exactly as every publisher resolves it.
#
# When the channel cannot be resolved the line is refused with a named error
# and written nowhere. The previous plain append exited 0 and left the line in
# the lane's local log, so a mate with a missing binding reported into silence.
#
# Usage:
#   fm-parent-channel-report.sh '<state> [at=<epoch>]: <one short line>'
#
# Call it from the secondmate home with FM_HOME set to that home. The line is
# stamped and compared by the library's own contract, so this passes it through
# unchanged. Return codes follow fm-parent-channel-lib.sh: 0 delivered or
# already present, 1 main home, 2 unusable identity, 3 missing or unreadable
# binding, 4 append failed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-parent-channel-report.sh '<line>'
EOF
  exit 2
}

[ $# -eq 1 ] && [ -n "$1" ] || usage
LINE=$1

HOME_DIR=${FM_HOME:-}
if [ -z "$HOME_DIR" ]; then
  echo "error: FM_HOME is required so this home can resolve its parent channel; the line was NOT recorded anywhere" >&2
  exit 1
fi
STATE_DIR=${FM_STATE_OVERRIDE:-$HOME_DIR/state}

RC=0
fm_parent_channel_report "$HOME_DIR" "$STATE_DIR" "$LINE" || RC=$?
case "$RC" in
  0) exit 0 ;;
  1) echo "error: cannot resolve the parent channel from this home: it has no secondmate identity, so it has no parent channel to report on; the line was NOT recorded anywhere" >&2 ;;
  2) echo "error: cannot resolve the parent channel from this home: its secondmate identity marker is unusable; the line was NOT recorded anywhere" >&2 ;;
  3) echo "error: cannot resolve the parent channel from this home: its parent binding is missing or unreadable; the line was NOT recorded anywhere" >&2 ;;
  *) echo "error: cannot write the parent channel from this home (rc=$RC); the line was NOT recorded anywhere" >&2 ;;
esac
exit "$RC"
