#!/usr/bin/env bash
# fm-home-identity-lib.sh - the copied-home guard. A copy of a firstmate home
# carries task records that name the original home's live endpoints, so a sweep
# or lifecycle command running from the copy would classify, close, and replace
# endpoints it does not own.
#
# bin/fm-lock.sh records the physical path of this state directory in
# <state>/.home-id when that file is absent. A copy carries the original's path,
# so a marker naming another directory proves a copy. The state directory rather
# than FM_HOME is recorded so a FM_STATE_OVERRIDE selection stays coherent with
# itself whichever FM_HOME accompanies it.
#
# An absent marker is never a refusal: a fixture or a home that has not acquired
# its lock yet behaves as it always has. Everything that acts on a live endpoint
# calls this before acting (bin/fm-secondmate-liveness-lib.sh, bin/fm-spawn.sh,
# bin/fm-control.sh, bin/fm-teardown.sh, bin/fm-herdr-session-cleanup.sh), while
# read-only digests keep working. A home that was deliberately moved clears the
# refusal by deleting the marker; its next lock acquisition records the new path.

# fm_home_identity_ensure <state-dir>: record this state directory when no marker
# exists. An existing marker is never rewritten, because that would launder a copy.
fm_home_identity_ensure() {
  local state=$1 marker real tmp
  marker="$state/.home-id"
  { [ ! -e "$marker" ] && [ ! -L "$marker" ]; } || return 0
  real=$(CDPATH='' cd -- "$state" 2>/dev/null && pwd -P) || return 1
  tmp=$(mktemp "$marker.XXXXXX" 2>/dev/null) || return 1
  if { printf '%s\n' "$real" > "$tmp" && mv -f "$tmp" "$marker"; } 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# fm_home_identity_check <state-dir>: 0 unless the marker disproves ownership.
# Returns 1 with FM_HOME_IDENTITY_REASON set for a copy or for a marker that
# cannot be read, since neither can show that these records belong to this home.
fm_home_identity_check() {
  local state=$1 marker recorded real
  FM_HOME_IDENTITY_REASON=
  marker="$state/.home-id"
  { [ -e "$marker" ] || [ -L "$marker" ]; } || return 0
  if [ ! -f "$marker" ] || [ -L "$marker" ] || ! recorded=$(cat "$marker" 2>/dev/null); then
    FM_HOME_IDENTITY_REASON="$marker is unreadable, so this state directory cannot prove it owns its recorded endpoints; delete it only if this is the original home"
    return 1
  fi
  real=$(CDPATH='' cd -- "$state" 2>/dev/null && pwd -P) || real=$state
  [ "$recorded" != "$real" ] || return 0
  FM_HOME_IDENTITY_REASON="$real is a copy of $recorded, so its records name endpoints it does not own; delete $marker only if this home was deliberately moved"
  return 1
}

# fm_home_identity_refuse <state-dir> <command-name>: print the one-line refusal
# and fail when the check does.
fm_home_identity_refuse() {
  fm_home_identity_check "$1" && return 0
  echo "error: $2 refused: $FM_HOME_IDENTITY_REASON" >&2
  return 1
}
