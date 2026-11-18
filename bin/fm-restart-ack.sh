#!/usr/bin/env bash
# Acknowledge a restart request by writing a beacon file, not a chat reply.
#
# Usage: fm-restart-ack.sh <token>
#
# A remote second mate is asked (bin/fm-secondmate-restart.sh) to write down its
# open work before its agent is replaced. It answers by running this command with
# the 16-hex token the request carried, which creates
# $FM_HOME/state/restart-acks/<token>. The parent reads that file through
# fm-remote-secondmate-control.sh ack, so the restart is released by a durable
# file and never by a correlated reply on the parent channel.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ $# -ne 1 ]; then
  echo "usage: fm-restart-ack.sh <16-hex-token>" >&2
  [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && exit 0
  exit 2
fi
token=$1
case "$token" in
  *[!0-9a-f]*|'') echo "error: token must be 16 lowercase hex characters" >&2; exit 2 ;;
esac
[ "${#token}" -eq 16 ] || { echo "error: token must be 16 lowercase hex characters" >&2; exit 2; }
mkdir -p "$STATE/restart-acks"
date +%s > "$STATE/restart-acks/.$token.$$"
mv -f "$STATE/restart-acks/.$token.$$" "$STATE/restart-acks/$token"
echo "acknowledged restart request $token"
