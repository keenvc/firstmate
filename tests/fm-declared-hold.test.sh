#!/usr/bin/env bash
# Tests for fm-declared-hold.sh: dated holds that checks skip, one-shot expiry
# wake, refusal of undated/past holds, and the per-check wake counter.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-declared-hold)
export FM_STATE_OVERRIDE="$TMP_ROOT/state"
HOLD="$ROOT/bin/fm-declared-hold.sh"
future=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -v+2H +%Y-%m-%dT%H:%MZ)

"$HOLD" declare pr-adclinica-7556 --owner copper --reason "overseer re-cut" --until "$future" >/dev/null || fail "declare failed"
"$HOLD" active pr-adclinica-7556 || fail "future hold should be active"
"$HOLD" active pr-adclinica-1 && fail "unknown key must not be active"
[ -z "$("$HOLD" expired)" ] || fail "no wake before expiry"

"$HOLD" declare x --owner o --reason r >/dev/null 2>&1 && fail "undated hold must be refused"
"$HOLD" declare x --owner o --reason r --until 2020-01-01T00:00Z >/dev/null 2>&1 && fail "past hold must be refused"
"$HOLD" declare 'bad/key' --owner o --reason r --until "$future" >/dev/null 2>&1 && fail "bad key must be refused"

# Force expiry, then the wake fires once, and the hold stops suppressing.
sed -i.bak 's/^until=.*/until=2020-01-01T00:00Z/' "$FM_STATE_OVERRIDE/declared-holds/pr-adclinica-7556.hold"
"$HOLD" active pr-adclinica-7556 && fail "expired hold must not be active"
[ -z "$("$HOLD" list --active)" ] || fail "expired hold listed as active"
out=$("$HOLD" expired --prefix lane-); [ -z "$out" ] || fail "prefix filter leaked: $out"
out=$("$HOLD" expired --prefix pr-)
case "$out" in *"pr-adclinica-7556"*"copper"*) ;; *) fail "expected one expiry wake, got: $out" ;; esac
[ -z "$("$HOLD" expired)" ] || fail "expiry must wake exactly once"

"$HOLD" clear pr-adclinica-7556 >/dev/null; [ -z "$("$HOLD" list)" ] || fail "clear left a record"

"$HOLD" count pr-sla; "$HOLD" count pr-sla; "$HOLD" count fleet-drive
c=$("$HOLD" counts); today=$(date -u +%F)
printf '%s\n' "$c" | grep -q "^$today	pr-sla	2$" || fail "pr-sla count wrong: $c"
printf '%s\n' "$c" | grep -q "^$today	fleet-drive	1$" || fail "fleet-drive count wrong: $c"
echo "ok: fm-declared-hold"
