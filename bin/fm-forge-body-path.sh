#!/usr/bin/env bash
# Print the task-unique path for PR or issue body text (--body-file).
# Usage: fm-forge-body-path.sh <task-id>
set -euo pipefail
d=${BASH_SOURCE[0]%/*}
[ "$d" != "${BASH_SOURCE[0]}" ] || d=.
# shellcheck source=bin/fm-forge-lib.sh
. "$(cd "${d:-/}" && pwd)/fm-forge-lib.sh"
[ $# -eq 1 ] || { echo "usage: fm-forge-body-path.sh <task-id>" >&2; exit 2; }
fm_forge_body_file "$1"
