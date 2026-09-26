#!/usr/bin/env bash
# Per-home opt-out for one declared inherited config item (config/inherit-optout).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-config-inherit-optout)

test_ping_pong_without_optout_repro() {
  local d primary sm report1 report2 changed
  d="$TMP_ROOT/ping-pong"
  primary="$d/primary"
  sm="$d/sm"
  mkdir -p "$primary/config" "$sm/config"
  printf '{"primary":"v10"}\n' > "$primary/config/crew-dispatch.json"
  printf '{"secondmate":"fdc-custom"}\n' > "$sm/config/crew-dispatch.json"
  report1="$d/r1"
  report2="$d/r2"
  FM_INHERITABLE_CONFIG=crew-dispatch.json FM_CONFIG_INHERIT_REPORT="$report1" \
    propagate_inheritable_config "$primary/config" "$sm/config" >/dev/null 2>/dev/null \
    || fail "first propagation failed"
  assert_contains "$(cat "$report1")" $'crew-dispatch.json\tpushed\t' \
    "first propagation should push divergent crew-dispatch"
  printf '{"secondmate":"fdc-custom"}\n' > "$sm/config/crew-dispatch.json"
  FM_INHERITABLE_CONFIG=crew-dispatch.json FM_CONFIG_INHERIT_REPORT="$report2" \
    propagate_inheritable_config "$primary/config" "$sm/config" >/dev/null 2>/dev/null \
    || fail "second propagation failed"
  assert_contains "$(cat "$report2")" $'crew-dispatch.json\tpushed\t' \
    "second propagation re-pushes after local restore (ping-pong defect)"
  changed=$(fm_config_reread_changed_items "$report2")
  [ "$changed" = crew-dispatch.json ] || fail "second push would trigger another config-reread"
  pass "repro: two runs without opt-out both report pushed"
}

test_optout_stops_resend_and_reports_skipped() {
  local d primary sm report1 report2 line changed1 changed2
  d="$TMP_ROOT/optout-stop"
  primary="$d/primary"
  sm="$d/sm"
  mkdir -p "$primary/config" "$sm/config"
  printf '{"primary":"v10"}\n' > "$primary/config/crew-dispatch.json"
  printf '{"secondmate":"fdc-custom"}\n' > "$sm/config/crew-dispatch.json"
  printf '%s\n' 'crew-dispatch.json' > "$sm/config/inherit-optout"
  report1="$d/r1"
  report2="$d/r2"
  FM_INHERITABLE_CONFIG=crew-dispatch.json FM_CONFIG_INHERIT_REPORT="$report1" \
    propagate_inheritable_config "$primary/config" "$sm/config" >/dev/null 2>"$d/e1" \
    || fail "first opt-out propagation failed"
  line=$(awk -F '\t' '$1 == "crew-dispatch.json" { print; exit }' "$report1")
  assert_contains "$line" $'crew-dispatch.json\tskipped\t' \
    "opted-out item must be skipped on first pass"
  assert_contains "$line" "destination home opted out" \
    "skip must name opt-out reason"
  [ "$(cat "$sm/config/crew-dispatch.json")" = '{"secondmate":"fdc-custom"}' ] \
    || fail "opt-out must leave the home's crew-dispatch bytes untouched"
  changed1=$(fm_config_reread_changed_items "$report1")
  [ -z "$changed1" ] || fail "opt-out must not produce config-reread changed items on first pass"
  FM_INHERITABLE_CONFIG=crew-dispatch.json FM_CONFIG_INHERIT_REPORT="$report2" \
    propagate_inheritable_config "$primary/config" "$sm/config" >/dev/null 2>"$d/e2" \
    || fail "second opt-out propagation failed"
  line=$(awk -F '\t' '$1 == "crew-dispatch.json" { print; exit }' "$report2")
  assert_contains "$line" $'crew-dispatch.json\tskipped\t' \
    "second pass must still skip, not push"
  changed2=$(fm_config_reread_changed_items "$report2")
  [ -z "$changed2" ] || fail "opt-out must not produce config-reread changed items on second pass"
  pass "opt-out stops ping-pong and reports skipped twice"
}

test_unchanged_pass_emits_no_reread_items() {
  local d primary sm report changed
  d="$TMP_ROOT/unchanged-reread"
  primary="$d/primary"
  sm="$d/sm"
  mkdir -p "$primary/config" "$sm/config"
  printf 'codex\n' > "$primary/config/crew-harness"
  printf 'codex\n' > "$sm/config/crew-harness"
  report="$d/report"
  FM_INHERITABLE_CONFIG=crew-harness FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_inheritable_config "$primary/config" "$sm/config" >/dev/null 2>/dev/null \
    || fail "unchanged propagation failed"
  changed=$(fm_config_reread_changed_items "$report")
  [ -z "$changed" ] || fail "unchanged crew-harness must not appear in reread changed set"
  line=$(awk -F '\t' '$1 == "crew-harness" { print; exit }' "$report")
  assert_contains "$line" $'crew-harness\tunchanged\t' \
    "unchanged item must be reported unchanged"
  pass "unchanged convergence sends no config-reread items"
}

test_normal_items_still_converge_with_optout_present() {
  local d primary sm report
  d="$TMP_ROOT/converge-other"
  primary="$d/primary"
  sm="$d/sm"
  mkdir -p "$primary/config" "$sm/config"
  printf '{"primary":"v10"}\n' > "$primary/config/crew-dispatch.json"
  printf '{"secondmate":"fdc-custom"}\n' > "$sm/config/crew-dispatch.json"
  printf 'pi\n' > "$primary/config/crew-harness"
  printf 'codex\n' > "$sm/config/crew-harness"
  printf '%s\n' 'crew-dispatch.json' > "$sm/config/inherit-optout"
  report="$d/report"
  FM_INHERITABLE_CONFIG="crew-dispatch.json crew-harness" FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_inheritable_config "$primary/config" "$sm/config" >/dev/null 2>"$d/err" \
    || fail "mixed propagation failed"
  assert_contains "$(cat "$report")" $'crew-dispatch.json\tskipped\t' \
    "opted-out dispatch must be skipped"
  assert_contains "$(cat "$report")" $'crew-harness\tpushed\t' \
    "non-opted-out item must still converge"
  [ "$(cat "$sm/config/crew-harness")" = pi ] || fail "crew-harness did not converge"
  [ "$(cat "$sm/config/crew-dispatch.json")" = '{"secondmate":"fdc-custom"}' ] \
    || fail "opted-out dispatch must remain local"
  pass "opt-out for one item does not block other inherited items"
}

test_ping_pong_without_optout_repro
test_optout_stops_resend_and_reports_skipped
test_unchanged_pass_emits_no_reread_items
test_normal_items_still_converge_with_optout_present
