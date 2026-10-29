#!/usr/bin/env bash
# Factory Droid session-open adapter: the RUN tier transport for the Droid CLI.
#
# Registered by bin/fm-spawn.sh in the firstmate-owned per-task runtime settings
# file (`--settings`) of a SECONDMATE launch, as droid's `SessionStart` hook.
# It is a thin transport around bin/fm-sessionstart-run.sh, which remains the
# single owner of source routing, eligibility, and the digest itself.
#
# droid appends a SessionStart hook's `hookSpecificOutput.additionalContext`
# string to the new session's context, so the digest lands before the first turn
# and the helm is taken without model discretion. Verified live on droid 0.251.0
# (2026-10-29): a SessionStart hook printing a fact was answered from context on
# the very next prompt.
#
# Usage: fm-sessionstart-droid.sh
# droid's SessionStart payload carries its own `source` field
# (startup|resume|clear|compact), which fm-sessionstart-run.sh already reads
# from stdin, so no --source override is needed.
#
# Every path exits 0 and prints either nothing or one JSON object: a non-zero
# hook exit would surface as an error in the session, and a failed session start
# must reach the agent as digest text it can act on, never as a refusal to open
# the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIGEST=$("$SCRIPT_DIR/fm-sessionstart-run.sh" 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -n --arg c "$DIGEST" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null || true
exit 0
