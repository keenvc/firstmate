#!/usr/bin/env bash
# tests/fm-flow-ledger.test.sh - behavior of bin/fm-flow-ledger.sh, the
# deterministic ask -> issue -> owner -> PR -> live breach report.
#
# Every rule is driven end to end through the real executable against a fixture
# home. Linear is replaced by a captured GraphQL payload (FM_FLOW_LEDGER_GRAPHQL),
# so each rule is asserted on its own data rather than on a live account, and a
# frozen --now makes every age exact. The backlog rule (B5) is driven through the
# real bin/fm-tasks-axi.sh against a real backlog the fixture owns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-flow-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-ledger)

# Frozen clock every fixture is built against.
NOW=1800000000

iso() {  # <epoch-or-'> -> ISO-8601 UTC, or null
  if [ "$1" = '-' ]; then
    printf 'null'
    return 0
  fi
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z
}

# iso_json <epoch-or-'-'> -> a JSON string literal, or the null literal
iso_json() {  # <epoch-or-'-'>
  if [ "$1" = '-' ]; then
    printf 'null'
    return 0
  fi
  printf '"%s"' "$(iso "$1")"
}

# issue <id> <title> <created> <updated> <state> <state-type> <labels-csv> \
#       <assignee-or---> <parent-or---> <verified-comment-or--->
# Prints one Linear issue node.
issue() {
  local id=$1 title=$2 created=$3 updated=$4 state=$5 stype=$6 labels=$7
  local assignee=$8 parent=$9 verified=${10}
  local label_json='[]' assignee_json='null' parent_json='null' comments='[]'
  local first=1 name
  if [ "$labels" != '-' ]; then
    label_json='['
    local IFS=,
    for name in $labels; do
      [ "$first" = 1 ] || label_json+=','
      label_json+="{\"name\":\"$name\"}"
      first=0
    done
    label_json+=']'
  fi
  [ "$assignee" = '-' ] || assignee_json="{\"name\":\"$assignee\",\"email\":\"$assignee\"}"
  [ "$parent" = '-' ] || parent_json="{\"identifier\":\"$parent\"}"
  [ "$verified" = '-' ] || comments="[{\"body\":\"$verified\",\"createdAt\":\"$(iso "$((NOW - 600))")\"}]"
  printf '{"identifier":"%s","title":"%s","createdAt":%s,"updatedAt":%s,' \
    "$id" "$title" "$(iso_json "$created")" "$(iso_json "$updated")"
  printf '"state":{"name":"%s","type":"%s"},"assignee":%s,"labels":{"nodes":%s},' \
    "$state" "$stype" "$assignee_json" "$label_json"
  printf '"parent":%s,"children":{"nodes":[]},"comments":{"nodes":%s}}' \
    "$parent_json" "$comments"
}

# fixture_home <name>: a fresh home with an empty ask log, team list, and pools.
fixture_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# write_linear <home> <node>...: captured payload the reader accepts.
write_linear() {  # <home> <node>...
  local home=$1 line body
  shift
  body=''
  for line in "$@"; do
    [ -z "$body" ] || body+=','
    body+="$line"
  done
  printf '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}\n' \
    "$body" > "$home/linear.json"
  printf 'ADC\n' > "$home/config/linear-teams"
}

# write_linear_raw is write_linear for callers that already hold literal JSON
# nodes, which B6 needs to express parents and children together.
write_linear_raw() {  # <home> <json-node>...
  write_linear "$@"
}

run_report() {  # <home> -> report lines
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
  FM_FLOW_LEDGER_GRAPHQL="file:$1/linear.json" FM_FLOW_LEDGER_TEAMS='' \
    bash "$LEDGER" report --now "$NOW" 2>&1
}

# --- B1 ---------------------------------------------------------------------

test_b1_ask_without_issue_is_a_breach_and_a_matching_issue_settles_it() {
  local home out
  home=$(fixture_home b1)
  write_linear "$home" \
    "$(issue ADC-9 'Ticket for the settled ask about exporting invoices' \
      "$((NOW - 3600))" "$((NOW - 60))" Todo unstarted - - - -)"
  printf '{"id":"A1","at":%d,"text":"export the invoices as a spreadsheet"}\n' \
    "$((NOW - 60))" > "$home/state/asks.jsonl"
  printf '{"id":"A2","at":%d,"text":"nobody ever filed this ask anywhere"}\n' \
    "$((NOW - 3600))" >> "$home/state/asks.jsonl"
  printf '{"id":"A3","at":%d,"text":"nobody ever filed this ask anywhere","open":false}\n' \
    "$((NOW - 3600))" >> "$home/state/asks.jsonl"

  out=$(run_report "$home")
  assert_contains "$out" "$(printf 'B1\tbreach\tA2')" \
    "an open ask with no Linear issue must be reported as a B1 breach"
  assert_not_contains "$out" "$(printf 'B1\tbreach\tA1')" \
    "an ask whose words appear in an issue title must be settled by that issue"
  assert_not_contains "$out" "$(printf 'B1\tbreach\tA3')" \
    "a closed ask must never be reported as a breach"
  pass "B1"
}

# --- B2, B3 -----------------------------------------------------------------

test_b2_unowned_and_b3_idle_use_their_own_thresholds() {
  local home out
  home=$(fixture_home b23)
  write_linear "$home" \
    "$(issue ADC-1 'unowned for two hours' "$((NOW - 7200))" "$((NOW - 7200))" \
       Todo unstarted - - - -)" \
    "$(issue ADC-2 'unowned but brand new' "$((NOW - 120))" "$((NOW - 120))" \
       Todo unstarted - - - -)" \
    "$(issue ADC-3 'owned and quiet for five hours' "$((NOW - 90000))" \
       "$((NOW - 18000))" 'In Progress' started agent:superagent - - -)" \
    "$(issue ADC-4 'owned and quiet for nine hours' "$((NOW - 90000))" \
       "$((NOW - 32400))" 'In Progress' started agent:superagent - - -)" \
    "$(issue ADC-5 'assigned person is an owner' "$((NOW - 90000))" \
       "$((NOW - 60))" Todo unstarted - 'someone@example.com' - -)" \
    "$(issue ADC-6 'finished, so neither rule' "$((NOW - 900000))" \
       "$((NOW - 900000))" Done completed - - - -)"

  out=$(run_report "$home")
  assert_contains "$out" "$(printf 'B2\tbreach\tADC-1')" \
    "a non-terminal issue with no owner past 30m must be a B2 breach"
  assert_not_contains "$out" "$(printf 'B2\tbreach\tADC-2')" \
    "an issue still inside its 30m owner window must not breach"
  assert_contains "$out" "$(printf 'B3\twarn\tADC-3')" \
    "an owned issue quiet past 4h must warn"
  assert_not_contains "$out" "$(printf 'B3\tbreach\tADC-3')" \
    "an owned issue quiet past 4h but under 8h must not act"
  assert_contains "$out" "$(printf 'B3\tbreach\tADC-4')" \
    "an owned issue quiet past 8h must breach"
  assert_not_contains "$out" "$(printf 'B2\tbreach\tADC-5')" \
    "an assignee counts as an owner"
  assert_not_contains "$out" "$(printf 'B2\tbreach\tADC-6')" \
    "a terminal issue must never be reported"
  pass "B2 and B3"
}

# --- B4 ---------------------------------------------------------------------

test_b4_pool_under_floor_with_owned_todo_is_a_breach() {
  local home out
  home=$(fixture_home b4)
  printf 'ADC 32\nFDC 10\n# a comment\n' > "$home/config/refill-pools"
  write_linear "$home" \
    "$(issue ADC-1 'owned todo one' "$((NOW - 60))" "$((NOW - 60))" Todo unstarted agent:superagent - - -)" \
    "$(issue ADC-2 'owned todo two' "$((NOW - 60))" "$((NOW - 60))" Todo unstarted agent:v10 - - -)" \
    "$(issue FDC-1 'owned todo one' "$((NOW - 60))" "$((NOW - 60))" Todo unstarted agent:superagent - - -)" \
    "$(issue FDC-2 'owned todo two' "$((NOW - 60))" "$((NOW - 60))" Todo unstarted agent:superagent - - -)" \
    "$(issue FDC-3 'owned todo three' "$((NOW - 60))" "$((NOW - 60))" Todo unstarted agent:superagent - - -)" \
    "$(issue FDC-4 'owned todo four' "$((NOW - 60))" "$((NOW - 60))" Todo unstarted agent:superagent - - -)" \
    "$(issue FDC-5 'owned todo five' "$((NOW - 60))" "$((NOW - 60))" Todo unstarted agent:superagent - - -)"

  out=$(run_report "$home")
  assert_contains "$out" "$(printf 'B4\tbreach\tADC')" \
    "a pool holding 2 of 32 with owned Todo work must breach the 50%% floor"
  assert_not_contains "$out" "$(printf 'B4\tbreach\tFDC')" \
    "a pool at its floor must not breach"
  pass "B4"
}

# --- B6, B7 -----------------------------------------------------------------

test_b6_only_a_parent_whose_children_are_all_stale_breaches() {
  local home out stale fresh
  home=$(fixture_home b6)
  stale=$(iso "$((NOW - 32400))")
  fresh=$(iso "$((NOW - 60))")
  # ADC-1: children all quiet 9h -> breach. ADC-3: one child just moved -> clean.
  write_linear_raw "$home" \
    "{\"identifier\":\"ADC-1\",\"title\":\"parent stalled\",\"createdAt\":\"$(iso "$((NOW - 90000))")\",\"updatedAt\":\"$fresh\",\"state\":{\"name\":\"In Progress\",\"type\":\"started\"},\"assignee\":null,\"labels\":{\"nodes\":[]},\"parent\":null,\"children\":{\"nodes\":[]},\"comments\":{\"nodes\":[]}}" \
    "{\"identifier\":\"ADC-2\",\"title\":\"stale child\",\"createdAt\":\"$(iso "$((NOW - 90000))")\",\"updatedAt\":\"$stale\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"assignee\":null,\"labels\":{\"nodes\":[{\"name\":\"agent:superagent\"}]},\"parent\":{\"identifier\":\"ADC-1\"},\"children\":{\"nodes\":[]},\"comments\":{\"nodes\":[]}}" \
    "{\"identifier\":\"ADC-3\",\"title\":\"parent moving\",\"createdAt\":\"$(iso "$((NOW - 90000))")\",\"updatedAt\":\"$fresh\",\"state\":{\"name\":\"In Progress\",\"type\":\"started\"},\"assignee\":null,\"labels\":{\"nodes\":[]},\"parent\":null,\"children\":{\"nodes\":[]},\"comments\":{\"nodes\":[]}}" \
    "{\"identifier\":\"ADC-4\",\"title\":\"stale child\",\"createdAt\":\"$(iso "$((NOW - 90000))")\",\"updatedAt\":\"$stale\",\"state\":{\"name\":\"Todo\",\"type\":\"unstarted\"},\"assignee\":null,\"labels\":{\"nodes\":[{\"name\":\"agent:superagent\"}]},\"parent\":{\"identifier\":\"ADC-3\"},\"children\":{\"nodes\":[]},\"comments\":{\"nodes\":[]}}" \
    "{\"identifier\":\"ADC-5\",\"title\":\"live child\",\"createdAt\":\"$(iso "$((NOW - 90000))")\",\"updatedAt\":\"$fresh\",\"state\":{\"name\":\"In Progress\",\"type\":\"started\"},\"assignee\":null,\"labels\":{\"nodes\":[{\"name\":\"agent:superagent\"}]},\"parent\":{\"identifier\":\"ADC-3\"},\"children\":{\"nodes\":[]},\"comments\":{\"nodes\":[]}}"

  out=$(run_report "$home")
  assert_contains "$out" "$(printf 'B6\tbreach\tADC-1')" \
    "a parent whose every child is untouched past 8h must breach"
  assert_not_contains "$out" "$(printf 'B6\tbreach\tADC-3')" \
    "a parent with one recently moved child must not breach"
  pass "B6"
}

test_b7_merged_issue_without_a_live_verification_breaches() {
  local home out
  home=$(fixture_home b7)
  write_linear "$home" \
    "$(issue ADC-1 'merged and never verified' "$((NOW - 900000))" \
       "$((NOW - 108000))" 'In Review' started agent:superagent - - -)" \
    "$(issue ADC-2 'merged and verified live' "$((NOW - 900000))" \
       "$((NOW - 108000))" 'In Review' started agent:superagent - - \
       'Verified live abc1234')" \
    "$(issue ADC-3 'merged only a moment ago' "$((NOW - 900000))" \
       "$((NOW - 600))" 'In Review' started agent:superagent - - -)"

  out=$(run_report "$home")
  assert_contains "$out" "$(printf 'B7\tbreach\tADC-1')" \
    "a merged issue with no live verification past 24h must breach"
  assert_not_contains "$out" "$(printf 'B7\tbreach\tADC-2')" \
    "a 'Verified live' comment must settle the merge"
  assert_not_contains "$out" "$(printf 'B7\tbreach\tADC-3')" \
    "an issue merged inside the 24h window must not breach"
  pass "B7"
}

# --- B5 ---------------------------------------------------------------------

test_b5_holds_without_a_recommendation_are_reported() {
  local home out
  home=$(fixture_home b5)
  write_linear "$home"
  mkdir -p "$home/data"
  fm_test_tasks_toml "$home/.tasks.toml"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add hold-bare \
    'a hold with no recommendation' --repo demo >/dev/null 2>&1 ||
    fail "fixture could not file a backlog task"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add hold-recommended \
    'a hold with a recommendation' --repo demo >/dev/null 2>&1 ||
    fail "fixture could not file the second backlog task"
  local bare=hold-bare recommended=hold-recommended

  FM_HOME="$home" bash "$ROOT/bin/fm-captain-hold.sh" hold "$bare" \
    --reason 'Decide whether to ship this now' >/dev/null 2>&1 ||
    fail "fixture could not hold the first task"
  FM_HOME="$home" bash "$ROOT/bin/fm-captain-hold.sh" hold "$recommended" \
    --reason 'Decide whether to ship this now. Recommend: ship it.' >/dev/null 2>&1 ||
    fail "fixture could not hold the second task"

  out=$(run_report "$home")
  assert_contains "$out" "$(printf 'B5\tbreach\t%s\t-' "$bare")" \
    "a captain hold with no Recommend: line must be reported"
  assert_not_contains "$out" "$(printf 'B5\tbreach\t%s' "$recommended")" \
    "a captain hold with a recommendation inside its window must not be reported"
  pass "B5"
}

# --- boundaries -------------------------------------------------------------

test_unreadable_linear_input_is_named_not_reported_clean() {
  local home out
  home=$(fixture_home missing)
  printf 'ADC\n' > "$home/config/linear-teams"
  # An ask that would breach against an empty issue set: an unreadable Linear
  # must never be measured as "zero issues", which would invent this breach.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$LEDGER" record-ask a1 'ship the widget' --now "$((NOW - 86400))" ||
    fail "record-ask must append an ask"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        FM_CONFIG_OVERRIDE="$home/config" FM_FLOW_LEDGER_GRAPHQL='file:/nonexistent' \
        FM_FLOW_LEDGER_TEAMS='' bash "$LEDGER" report --now "$NOW" 2>&1)
  assert_contains "$out" 'linear: read failed' \
    "an unreadable Linear input must be named so a skipped rule is not read as clean"
  assert_not_contains "$out" "$(printf 'B1\tbreach\ta1')" \
    "an unreadable Linear input must never turn an open ask into a false B1 breach"
  pass "unmeasured rules are named"
}

test_missing_teams_is_named_rather_than_silently_clean() {
  local home out
  home=$(fixture_home noteams)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$LEDGER" record-ask a1 'ship the widget' --now "$((NOW - 86400))" ||
    fail "record-ask must append an ask"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        FM_CONFIG_OVERRIDE="$home/config" FM_FLOW_LEDGER_TEAMS='' \
        bash "$LEDGER" report --now "$NOW" 2>&1)
  assert_contains "$out" 'no teams configured' \
    "an absent team list must be named so an unmeasured rule is not read as clean"
  assert_not_contains "$out" "$(printf 'B1\tbreach\ta1')" \
    "an absent team list must never turn an open ask into a false B1 breach"
  pass "absent team list is named"
}

test_ask_log_round_trips_through_record_and_close() {
  local home out
  home=$(fixture_home asklog)
  write_linear "$home"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$LEDGER" record-ask A1 'the captain wants invoices exported' --now "$((NOW - 3600))" ||
    fail "record-ask must append an ask"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$LEDGER" record-ask A1 'a duplicate id' --now "$NOW" >/dev/null 2>&1 &&
    fail "record-ask must refuse a duplicate ask id"

  out=$(run_report "$home")
  assert_contains "$out" "$(printf 'B1\tbreach\tA1')" \
    "a recorded open ask with no issue must breach"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$LEDGER" close-ask A1 || fail "close-ask must settle an ask"
  assert_grep '"open": false' "$home/state/asks.jsonl" \
    "close-ask must mark the ask closed on its own line"

  out=$(run_report "$home")
  assert_not_contains "$out" "$(printf 'B1\tbreach\tA1')" \
    "a closed ask must stop breaching"
  pass "ask log"
}

test_b5_age_is_measured_from_the_frozen_clock() {
  local home out
  home=$(fixture_home b5clock)
  write_linear "$home"
  mkdir -p "$home/data"
  fm_test_tasks_toml "$home/.tasks.toml"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add hold-critical \
    'rotate the leaked production secret' --repo demo >/dev/null 2>&1 ||
    fail "fixture could not file the critical hold"
  FM_HOME="$home" bash "$ROOT/bin/fm-captain-hold.sh" hold hold-critical \
    --reason 'Recommend: rotate now. Decide which keys first.' >/dev/null 2>&1 ||
    fail "fixture could not hold the critical task"

  # tasks-axi records `created` from the backlog's `(since <date>)`, so rewrite
  # it to sit exactly two whole UTC days before the frozen clock. That makes the
  # hold inside the 24h window at NOW and past it at NOW + 48h; a rule reading
  # the wall clock would report the same age for both runs.
  local since later
  since=$(date -u -d "@$((NOW - 172800))" +%Y-%m-%d)
  later=$(date -u -d "@$((NOW + 172800))" +%Y-%m-%d)
  sed -i "s/(since [0-9-]*)/(since $since)/" "$home/data/backlog.md"
  assert_grep "(since $since)" "$home/data/backlog.md" \
    "the fixture must backdate the hold it measures"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        FM_CONFIG_OVERRIDE="$home/config" FM_FLOW_LEDGER_GRAPHQL="file:$home/linear.json" \
        FM_FLOW_LEDGER_TEAMS='' bash "$LEDGER" report --now "$NOW" 2>&1)
  assert_contains "$out" "$(printf 'B5\tbreach\thold-critical')" \
    "a critical hold two days old at the frozen clock must breach"

  # Move the anchor forward so the same hold is only hours old at the later
  # clock. If --now were ignored, the age would be unchanged and still breach.
  sed -i "s/(since [0-9-]*)/(since $later)/" "$home/data/backlog.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        FM_CONFIG_OVERRIDE="$home/config" FM_FLOW_LEDGER_GRAPHQL="file:$home/linear.json" \
        FM_FLOW_LEDGER_TEAMS='' bash "$LEDGER" report --now "$((NOW + 172800))" 2>&1)
  assert_not_contains "$out" "$(printf 'B5\tbreach\thold-critical')" \
    "the same hold must not breach when --now moves with its creation date"
  pass "B5 uses the frozen clock"
}

test_report_is_deterministic_for_the_same_inputs() {
  local home first second
  home=$(fixture_home determinism)
  write_linear "$home" \
    "$(issue ADC-9 'unowned' "$((NOW - 7200))" "$((NOW - 7200))" Todo unstarted - - - -)" \
    "$(issue ADC-2 'also unowned' "$((NOW - 7200))" "$((NOW - 7200))" Todo unstarted - - - -)" \
    "$(issue ADC-7 'too' "$((NOW - 7200))" "$((NOW - 7200))" Todo unstarted - - - -)"
  first=$(run_report "$home")
  second=$(run_report "$home")
  assert_equals "$first" "$second" \
    "the same inputs must produce byte-identical reports"
  pass "determinism"
}

fm_test_run \
  test_b1_ask_without_issue_is_a_breach_and_a_matching_issue_settles_it \
  test_b2_unowned_and_b3_idle_use_their_own_thresholds \
  test_b4_pool_under_floor_with_owned_todo_is_a_breach \
  test_b6_only_a_parent_whose_children_are_all_stale_breaches \
  test_b7_merged_issue_without_a_live_verification_breaches \
  test_b5_holds_without_a_recommendation_are_reported \
  test_unreadable_linear_input_is_named_not_reported_clean \
  test_missing_teams_is_named_rather_than_silently_clean \
  test_b5_age_is_measured_from_the_frozen_clock \
  test_ask_log_round_trips_through_record_and_close \
  test_report_is_deterministic_for_the_same_inputs
