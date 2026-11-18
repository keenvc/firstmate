#!/usr/bin/env bash
# Behavior tests for bin/fm-credit-preflight.sh: a fake curl serves provider
# balance bodies, and the script's exit code and message are asserted.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PRE="$ROOT/bin/fm-credit-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-credit-preflight)
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_BODY_FAIL:-}" ] || exit 22
printf '%s' "$FAKE_BODY"
SH
chmod +x "$FAKEBIN/curl"
printf '%s' '{"openrouter":{"key":"or-key"}}' > "$TMP_ROOT/auth.json"
printf '%s\n' 'DEEPSEEK_API_KEY=ds-key' > "$TMP_ROOT/deepseek.env"

run() { # <model> -> sets OUT, RC
  OUT=$(PATH="$FAKEBIN:$PATH" FM_CREDIT_PREFLIGHT="${PREFLIGHT_SWITCH:-on}" FM_CREDIT_OPENROUTER_AUTH="$TMP_ROOT/auth.json" \
    FM_CREDIT_DEEPSEEK_ENV="$TMP_ROOT/deepseek.env" "$PRE" "$1" 2>&1)
  RC=$?
}

OR_NEG='{"data":{"total_credits":100,"total_usage":100.08}}'
OR_POS='{"data":{"total_credits":100,"total_usage":40}}'
DS_NEG='{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"-0.09"}]}'
DS_POS='{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.50"}]}'

has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
export FAKE_BODY=

test_openrouter_negative_refused() {
  FAKE_BODY=$OR_NEG run openrouter/deepseek/deepseek-v4.1-flash-1017
  [ "$RC" = 1 ] && has "$OUT" "credit is exhausted" || fail "openrouter negative: rc=$RC $OUT"
  pass "openrouter negative balance refused"
}
test_openrouter_positive_allowed() {
  FAKE_BODY=$OR_POS run openrouter/deepseek/deepseek-v4.1-flash-1017
  [ "$RC" = 0 ] || fail "openrouter positive: rc=$RC $OUT"
  pass "openrouter positive balance allowed"
}
test_deepseek_negative_refused() {
  FAKE_BODY=$DS_NEG run deepseek/deepseek-flash
  [ "$RC" = 1 ] || fail "deepseek negative: rc=$RC $OUT"
  pass "deepseek negative balance refused"
}
test_deepseek_positive_allowed() {
  FAKE_BODY=$DS_POS run deepseek/deepseek-flash
  [ "$RC" = 0 ] || fail "deepseek positive: rc=$RC $OUT"
  pass "deepseek positive balance allowed"
}
test_no_balance_provider_says_so() {
  run azure-foundry/DeepSeek-V4.1-Flash-1017
  [ "$RC" = 0 ] && has "$OUT" "exposes no balance" || fail "no-balance provider: rc=$RC $OUT"
  pass "provider without a balance says so and is allowed"
}
test_unreadable_balance_not_blocking() {
  FAKE_BODY_FAIL=1 run openrouter/x
  [ "$RC" = 0 ] && has "$OUT" "could not read" || fail "read failure: rc=$RC $OUT"
  pass "unreadable balance does not block"
}
test_off_switch() {
  FAKE_BODY=$OR_NEG PREFLIGHT_SWITCH=off run openrouter/x
  [ "$RC" = 0 ] || fail "off switch: rc=$RC"
  pass "FM_CREDIT_PREFLIGHT=off skips the check"
}

fm_test_run test_openrouter_negative_refused test_openrouter_positive_allowed \
  test_deepseek_negative_refused test_deepseek_positive_allowed \
  test_no_balance_provider_says_so test_unreadable_balance_not_blocking test_off_switch
