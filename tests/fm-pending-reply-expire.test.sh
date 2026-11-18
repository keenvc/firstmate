#!/usr/bin/env bash
# Stale pending-reply expiry (bin/fm-pending-reply-expire.sh) and the
# fire-and-forget re-read notices that must never arm a pending reply.
#
#   1. Dry-run lists only the missed-reply decisions older than the max age and
#      writes nothing.
#   2. --apply closes exactly those with a resolved line carrying the exact key
#      and via=stale; the keyed fold then no longer holds them open, a fresh
#      decision stays open, and a second pass finds nothing.
#   3. The re-read nudge delivery id is 16 lowercase hex and differs per call.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pending-reply-expire)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
STATUS="$HOME_DIR/state/alpha.status"
NOW=1800000000
OLD=$((NOW - 90000))
NEW=$((NOW - 3600))
cat > "$STATUS" <<LINES
blocked [key=pending-reply-aaaaaaaaaaaaaaaa] [at=$OLD]: pending-reply-missed: task=alpha pending-reply-id=aaaaaaaaaaaaaaaa request=old one
blocked [key=pending-reply-bbbbbbbbbbbbbbbb] [at=$NEW]: pending-reply-missed: task=alpha pending-reply-id=bbbbbbbbbbbbbbbb request=fresh one
blocked [key=pending-reply-cccccccccccccccc] [at=$OLD]: pending-reply-missed: task=alpha pending-reply-id=cccccccccccccccc request=answered one
resolved [key=pending-reply-cccccccccccccccc] [at=$((OLD + 10))]: pending-reply-resolved: task=alpha pending-reply-id=cccccccccccccccc via=status
LINES
BEFORE=$(cksum < "$STATUS")

run_expire() { FM_HOME="$HOME_DIR" FM_PENDING_REPLY_NOW=$NOW bash "$ROOT/bin/fm-pending-reply-expire.sh" "$@"; }

out=$(run_expire) || fail "dry-run exited nonzero: $out"
assert_contains "$out" "would-close $STATUS pending-reply-aaaaaaaaaaaaaaaa age=90000" "dry-run must list the stale key"
assert_not_contains "$out" "bbbbbbbbbbbbbbbb" "a fresh key must not be listed"
assert_not_contains "$out" "cccccccccccccccc" "an already resolved key must not be listed"
assert_contains "$out" "summary: candidates=1 held=0 unresolved-open=2 apply=0" "dry-run summary must count the open keys"
assert_equals "$BEFORE" "$(cksum < "$STATUS")" "dry-run must not write the status log"

out=$(run_expire --apply) || fail "apply exited nonzero: $out"
assert_contains "$out" "closed $STATUS pending-reply-aaaaaaaaaaaaaaaa" "apply must close the stale key"
assert_grep 'resolved [key=pending-reply-aaaaaaaaaaaaaaaa]' "$STATUS" "the close line must carry the exact key"
assert_grep 'pending-reply-id=aaaaaaaaaaaaaaaa via=stale' "$STATUS" "the close line must carry the exact key and via=stale"
assert_no_grep 'resolved [key=pending-reply-bbbbbbbbbbbbbbbb]' "$STATUS" "the fresh key must stay open"

out=$(run_expire) || fail "second dry-run exited nonzero: $out"
assert_contains "$out" "summary: candidates=0 held=0 unresolved-open=1 apply=0" "a second pass must find nothing stale"

# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$ROOT/bin/fm-secondmate-nudge-lib.sh"
a=$(fm_secondmate_nudge_delivery_id)
b=$(fm_secondmate_nudge_delivery_id)
case "$a" in *[!a-f0-9]*|'') fail "nudge delivery id is not lowercase hex: $a" ;; esac
assert_equals 16 "${#a}" "nudge delivery id must be 16 characters"
assert_not_equals "$a" "$b" "each nudge needs its own delivery id"

printf 'ok - pending-reply expiry tests passed\n'
