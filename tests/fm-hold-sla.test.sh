#!/usr/bin/env bash
# Tests for bin/fm-hold-sla.sh and the `sla-close` outcome of
# bin/fm-captain-hold.sh: every open captain hold gets a deadline and a default;
# at expiry routine classes (duplicate, moot, pr-merge, ask) resolve to that
# default, captain-only classes stay open and land in one daily digest, a dry
# run changes nothing, a re-run is idempotent, and the one-off report is
# read-only. Synthetic identities and text only.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "skip: flock not found"; exit 0; }

SLA="$ROOT/bin/fm-hold-sla.sh"
TMP_ROOT=$(fm_test_tmproot fm-hold-sla)
NOW=$(date +%s)
OLD=$((NOW - 3 * 86400))

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

tasks_in() { local h=$1; shift; (cd "$h" && tasks-axi "$@"); }
captain_in() { local h=$1; shift; env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$h" "$ROOT/bin/fm-captain-hold.sh" "$@"; }

# Fake gh: PR 7 of o/r is open, green, docs-only, and carries a CLEAN verdict
# on its head; PR 9 is merged. Mutations are logged, never performed.
make_fake_gh() {  # <dir>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
case "$1 $2" in
  "pr view")
    case "$3" in
      7) printf '%s' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","headRefOid":"abcdef1234567890","title":"docs: tidy wording","labels":[{"name":"captain-hold"}],"files":[{"path":"docs/guide.md"}],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"},{"name":"Mergify Merge Protections","state":"PENDING"}],"comments":[{"body":"## Claude review\nHead: abcdef1\nVERDICT: CLEAN"}]}' ;;
      8) printf '%s' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","headRefOid":"abcdef1234567890","title":"fix: thread view","body":"Stops the thread view showing the wrong patient chart.","labels":[],"files":[{"path":"app/thread.ts"}],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"comments":[{"body":"Head: abcdef1\nVERDICT: CLEAN"}]}' ;;
      9) printf '%s' '{"state":"MERGED","isDraft":false,"mergeable":"UNKNOWN","headRefOid":"1111111111111111","title":"docs: old","labels":[],"files":[],"statusCheckRollup":[],"comments":[]}' ;;
      *) exit 1 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$1/gh"
}

make_fake_send() {  # <dir>
  # shellcheck disable=SC2016 # expanded by the fake, not here
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${FAKE_SEND_LOG:?}"\n' > "$1/fm-send"
  chmod +x "$1/fm-send"
}

run_sla() {  # <home> <args...>
  local h=$1; shift
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" \
    FM_HOLD_SLA_GH="$TMP_ROOT/bin/gh" FM_HOLD_SLA_SEND="$TMP_ROOT/bin/fm-send" \
    FAKE_GH_LOG="$TMP_ROOT/gh.log" FAKE_SEND_LOG="$TMP_ROOT/send.log" \
    FM_HOLD_SLA_NOTIFY_MAX_AGE_HOURS="${FM_HOLD_SLA_NOTIFY_MAX_AGE_HOURS:-0}" \
    FM_HOLD_SLA_NOW="$NOW" "$SLA" "$@"
}

open_keys() {  # <status-file>
  ( . "$ROOT/bin/fm-classify-lib.sh"; status_open_decisions "$1" | cut -f1 | sort | tr '\n' ' ' )
}

setup_world() {
  MAIN=$(make_home main) MATE=$(make_home mate)
  mkdir -p "$TMP_ROOT/bin"; make_fake_gh "$TMP_ROOT/bin"; make_fake_send "$TMP_ROOT/bin"
  : > "$TMP_ROOT/gh.log"; : > "$TMP_ROOT/send.log"
  printf 'kind=secondmate\nhome=%s\nworktree=%s\nwindow=w1\n' "$MATE" "$MATE" > "$MAIN/state/mate.meta"
  # Mate-home question rows: one still held, one already answered elsewhere.
  captain_in "$MATE" hold wording-q --title "Captain call: which wording?" --reason "which wording? Recommend: keep the short form" >/dev/null \
    || fail "could not hold wording-q in the mate home"
  captain_in "$MATE" hold gone-q --title "Captain call: old ask" --reason "old ask" >/dev/null || fail "could not hold gone-q"
  printf 'answered elsewhere\n' > "$TMP_ROOT/ans.txt"
  captain_in "$MATE" answer gone-q --decision-file "$TMP_ROOT/ans.txt" >/dev/null || fail "could not answer gone-q"
  cat > "$MAIN/state/mate.status" <<EOF
needs-decision [key=ux-copy] [at=$OLD]: which button label for the form? Recommend: keep Save
needs-decision [key=prod-flip] [at=$OLD]: write the migrated rows into production data? Recommend: write them
needs-decision [key=fresh-ask] [at=$((NOW - 60))]: naming for the tab? Recommend: Inbox
needs-decision [key=captain-hold-gone-q-1] [at=$OLD]: captain hold gone-q: old ask
needs-decision [key=captain-hold-wording-q-1] [at=$OLD]: captain hold wording-q: which wording? Recommend: keep the short form
needs-decision [key=dup-a] [at=$OLD]: merge https://github.com/o/r/pull/7 now?
needs-decision [key=dup-b] [at=$((OLD + 10))]: ok to merge https://github.com/o/r/pull/7 once green?
needs-decision [key=landed] [at=$OLD]: merge https://github.com/o/r/pull/9 ?
needs-decision [key=no-rec] [at=$OLD]: what should the lane do next?
needs-decision [key=fresh-amb] [at=$((NOW - 60))]: how should the retry behave? Recommend: retry twice
needs-decision [key=prod-mention] [at=$OLD]: the prod deploy of v147 is ready; deploy now? Recommend: deploy it
needs-decision [key=soft-irrev] [at=$OLD]: the prod contact list is ready; Recommend: email every contact
needs-decision [key=crit-norec] [at=$OLD]: PHI exposed on the intake page
needs-decision [key=pr-phi] [at=$OLD]: ok to merge https://github.com/o/r/pull/8 ?
needs-decision [key=baa-call] [at=$OLD]: [class=legal] does the vendor contract cover us? Recommend: sign it
EOF
}

test_classify_protects_captain_only_classes() {
  local out
  out=$("$SLA" classify "rotate the leaked API key for the vendor")
  assert_contains "$out" "class=captain-only:" "a credential hold was not captain-only"
  out=$("$SLA" classify "approve the ad spend top-up of 200 USD")
  assert_contains "$out" "class=captain-only:money" "a spending hold was not captain-only: $out"
  out=$("$SLA" classify "rename the nav label? Recommend: Inbox")
  assert_contains "$out" "class=quick" "a naming call did not resolve immediately: $out"
  assert_contains "$out" "default=Inbox" "the recorded recommendation was not taken as the default: $out"
  out=$("$SLA" classify "write the clinic rows into production data")
  assert_contains "$out" "class=captain-only:prod-data" "a production data write was not critical: $out"
  out=$("$SLA" classify "[class=incident] keep the flag off")
  assert_contains "$out" "class=captain-only:incident" "an explicit critical class was ignored: $out"
  out=$("$SLA" classify "should the worker retry the flaky step")
  assert_contains "$out" "class=returned" "a hold with no recommendation was not returned: $out"
  assert_contains "$out" "decide this yourself" "the returned hold carries no instruction: $out"
  out=$("$SLA" classify "prod deploy of v147? Recommend: deploy it")
  assert_contains "$out" "class=ambiguous" "a normal prod deploy was treated as critical: $out"
  out=$("$SLA" classify "merge the PR touching migrations and deploy config? Recommend: merge")
  assert_contains "$out" "class=ambiguous" "touching migration paths made a hold critical: $out"
  out=$("$SLA" classify "flip the dev flag? Recommend: flip it")
  assert_contains "$out" "class=ambiguous" "a dev flag flip was not an auto-resolving hold: $out"
  out=$("$SLA" classify "the prod contact list is ready; Recommend: email every contact")
  assert_contains "$out" "class=returned" "an irreversible recommendation was applied for the owner: $out"
  out=$("$SLA" classify "adc1235-captain-pause: work held until the captain lifts it")
  assert_contains "$out" "class=captain-only:captain" "a captain-paused hold was not the captain's: $out"
  out=$("$SLA" classify "see the recommendations in the report, then ship")
  assert_contains "$out" "class=returned" "a mid-word recommendation fragment was taken as a default: $out"
  pass "classify keeps only critical holds for the captain"
}

# The six holds a dry run on 2026-11-19 wrongly auto-resolved (synthetic text
# in their shape). Each MUST be captain-only, in classify and in a live sweep.
SIX_KEYS='v12008-shared-number-disclosure v10-11910-security-blocker adc1490-q5 ci-adc-gh-token-annotation nic3306-billing-modifiers-25-95 pr-flow-billing-bases m273-demographics-live-proof'
six_status() {  # <epoch>
  printf '%s\n' \
    "needs-decision [key=v12008-shared-number-disclosure] [at=$1]: the captain path on a shared number shows an activity-picked record to the wrong caller. Recommend: merge the guard" \
    "blocked [key=v10-11910-security-blocker] [at=$1]: PR 11910 has carried an unanswered blocker for 14 hours. Recommend: merge once fixed" \
    "needs-decision [key=adc1490-q5] [at=$1]: re-mint, or in-place add with a fresh one? Recommend: in-place add" \
    "needs-decision [key=ci-adc-gh-token-annotation] [at=$1]: annotate the step output? Recommend: add the annotation" \
    "needs-decision [key=nic3306-billing-modifiers-25-95] [at=$1]: apply 25 and 95 on these lines? Recommend: merge" \
    "blocked [key=pr-flow-billing-bases] [at=$1]: two PRs sit on stale bases. Recommend: rebase both" \
    "blocked [key=m273-demographics-live-proof] [at=$1]: the proof run is blocked by the rig. Recommend: retry tomorrow"
}

test_six_missed_holds_are_captain_only() {
  local line key out open h
  while IFS= read -r line; do
    key=${line#*\[key=}; key=${key%%\]*}
    out=$("$SLA" classify "$key: ${line#*]: }")
    assert_contains "$out" "class=captain-only:" "$key auto-resolved: $out"
  done < <(six_status "$OLD")
  h=$(make_home six)
  mkdir -p "$TMP_ROOT/bin"; make_fake_gh "$TMP_ROOT/bin"; make_fake_send "$TMP_ROOT/bin"
  six_status "$OLD" > "$h/state/w.status"
  out=$(run_sla "$h" sweep --live) || fail "sweep failed: $out"
  open=$(open_keys "$h/state/w.status")
  for key in $SIX_KEYS; do
    case " $open " in *" $key "*) ;; *) fail "live sweep resolved critical hold $key" ;; esac
    assert_contains "$(cat "$h/state/hold-sla/digest-latest.md")" "$key" "$key is missing from the digest"
  done
  pass "the six previously missed holds stay captain-only and reach the digest"
}

test_no_recommendation_is_returned_never_applied() {
  local h out
  h=$(make_home norec)
  mkdir -p "$TMP_ROOT/bin"; make_fake_gh "$TMP_ROOT/bin"; make_fake_send "$TMP_ROOT/bin"; : > "$TMP_ROOT/send.log"
  printf 'kind=secondmate\nhome=%s\n' "$h" > "$h/state/w.meta"
  printf 'needs-decision [key=what-next] [at=%s]: what should the lane do next?\n' "$OLD" > "$h/state/w.status"
  out=$(run_sla "$h" sweep --live) || fail "sweep failed: $out"
  grep -q 'expire returned .*key=what-next' "$h/state/hold-sla/hold-sla.log" || fail "the hold was not returned"
  grep -q 'what-next.*applied' "$h/state/hold-sla/hold-sla.log" && fail "a hold with no recommendation was logged as applied"
  grep -q 'resolved \[key=what-next\].*sla-returned' "$h/state/w.status" || fail "the hold was not closed as sla-returned"
  grep -q 'w --fire-and-forget .*what-next.*decide this yourself' "$TMP_ROOT/send.log" || fail "the owner was not told to decide"
  pass "a hold with no recommendation is returned to its owner, never applied"
}

test_scratch_dir_dry_run_leaves_state_alone() {
  local h out
  h=$(make_home scratch)
  six_status "$OLD" > "$h/state/w.status"
  printf 'needs-decision [key=ux-label] [at=%s]: which label? Recommend: keep Save\n' "$OLD" >> "$h/state/w.status"
  out=$(FM_HOLD_SLA_DIR="$TMP_ROOT/scratch-sla" run_sla "$h" sweep --live) || fail "scratch sweep failed: $out"
  [ ! -e "$h/state/hold-sla" ] || fail "a scratch-dir sweep wrote state/hold-sla"
  [ -f "$TMP_ROOT/scratch-sla/digest-latest.md" ] || fail "the scratch dir has no digest"
  grep -q 'DRY expire quick .*key=ux-label' "$TMP_ROOT/scratch-sla/hold-sla.log" || fail "a scratch-dir sweep ran live"
  grep -q 'resolved \[key=ux-label\]' "$h/state/w.status" && fail "a scratch-dir sweep closed a hold"
  pass "FM_HOLD_SLA_DIR dry runs write only to the scratch dir and never act"
}

test_report_is_read_only() {
  local out before after
  setup_world
  before=$(cksum < "$MAIN/state/mate.status")
  run_sla "$MAIN" report --out "$TMP_ROOT/report.md" >/dev/null || fail "report failed"
  after=$(cksum < "$MAIN/state/mate.status")
  [ "$before" = "$after" ] || fail "report changed a status log"
  [ ! -e "$MAIN/state/hold-sla" ] || fail "report wrote SLA state"
  out=$(cat "$TMP_ROOT/report.md")
  assert_contains "$out" "open holds: 15" "report headline count is wrong"
  assert_contains "$out" "captain-only:prod-data" "report did not list the production hold as critical"
  assert_contains "$out" "returned to the raising agent (no recommendation, not critical): 2" "report returned count is wrong"
  assert_contains "$out" "truly captain-only: 4" "report captain-only count is wrong"
  assert_contains "$out" "resolve IMMEDIATELY (duplicate, moot, green+CLEAN PR, quick call, captain-parked): 7" "report immediate count is wrong"
  assert_contains "$out" "| moot |" "report did not list the moot mirror"
  grep -q 'pr edit\|pr comment\|pr merge' "$TMP_ROOT/gh.log" && fail "report mutated a PR"
  [ ! -s "$TMP_ROOT/send.log" ] || fail "report sent a message"
  pass "report classifies the backlog without changing anything"
}

test_dry_run_changes_nothing() {
  local before after out
  setup_world
  before=$(cksum < "$MAIN/state/mate.status")
  out=$(run_sla "$MAIN" sweep) || fail "dry sweep failed: $out"
  after=$(cksum < "$MAIN/state/mate.status")
  [ "$before" = "$after" ] || fail "dry sweep changed a status log"
  tasks_in "$MATE" show wording-q | grep -q 'held: yes' || fail "dry sweep closed a held task"
  grep -q 'pr edit\|pr comment\|pr merge' "$TMP_ROOT/gh.log" && fail "dry sweep mutated a PR"
  [ ! -s "$TMP_ROOT/send.log" ] || fail "dry sweep sent a message"
  grep -q '^.* DRY expire quick .*key=ux-copy' "$MAIN/state/hold-sla/hold-sla.log" || fail "dry sweep did not log the planned ask resolution"
  [ -f "$MAIN/state/hold-sla/digest-latest.md" ] || fail "dry sweep wrote no digest"
  compgen -G "$MAIN/state/hold-sla/records/*ux-copy*" >/dev/null || fail "dry sweep did not record the SLA at first sight"
  pass "a dry sweep records SLAs and plans but changes nothing"
}

test_live_sweep_resolves_routine_and_escalates_the_rest() {
  local out open show digest lines
  setup_world
  out=$(run_sla "$MAIN" sweep --live) || fail "live sweep failed: $out"
  open=$(open_keys "$MAIN/state/mate.status")
  for k in ux-copy captain-hold-gone-q-1 captain-hold-wording-q-1 dup-a dup-b landed fresh-ask no-rec prod-mention soft-irrev; do
    case " $open " in *" $k "*) fail "non-critical hold $k stayed open: $open" ;; esac
  done
  for k in prod-flip baa-call fresh-amb crit-norec pr-phi; do
    case " $open " in *" $k "*) ;; *) fail "hold $k should stay open: $open" ;; esac
  done
  show=$(tasks_in "$MATE" show wording-q --full)
  assert_contains "$show" "state: done" "the expired mate question was not closed in its own home"
  assert_contains "$show" "Resolution mode: sla-default" "the SLA close did not record its mode"
  assert_contains "$show" "SLA default applied:" "the SLA close did not label its record"
  case "$show" in *"Captain decision:"*) fail "an SLA close was recorded as the captain's words" ;; esac
  grep -q 'pr comment 7 -R o/r' "$TMP_ROOT/gh.log" || fail "the green CLEAN PR was not queued"
  grep -q 'pr edit 7 -R o/r --remove-label captain-hold' "$TMP_ROOT/gh.log" || fail "the hold label was not lifted"
  grep -q 'pr comment 9\|pr edit 9' "$TMP_ROOT/gh.log" && fail "the merged PR was touched"
  grep -q 'mate --fire-and-forget .*ux-copy.*keep Save' "$TMP_ROOT/send.log" || fail "the quick default was not delivered to its owner"
  grep -q 'mate --fire-and-forget .*no-rec.*sla-returned.*decide this yourself' "$TMP_ROOT/send.log" || fail "a hold with no recommendation was not returned to its owner"
  grep -q 'resolved \[key=no-rec\].*sla-returned' "$MAIN/state/mate.status" || fail "the returned hold was not closed as sla-returned"
  grep -q 'mate --fire-and-forget .*crit-norec.*critical captain call' "$TMP_ROOT/send.log" || fail "a critical hold with no recommendation did not ask its owner for one"
  digest=$(cat "$MAIN/state/hold-sla/digest-latest.md")
  assert_contains "$digest" "prod-flip" "the production hold is missing from the digest"
  assert_contains "$digest" "baa-call" "the legal hold is missing from the digest"
  assert_contains "$digest" "sign it" "the critical hold's recommendation is missing from the digest"
  case "$digest" in *no-rec*) fail "a non-critical hold reached the digest" ;; esac
  assert_contains "$digest" "recommendation requested from mate" "the critical hold without a recommendation shows a blank"
  assert_contains "$digest" 'bin/fm-send.sh mate --resolve-key prod-flip "yes"' "the digest has no answer command"
  case "$digest" in *fresh-amb*) fail "a hold inside its deadline reached the digest" ;; esac
  grep -rqs 'hold-sla-digest-' "$MAIN/state" --include='*' --exclude-dir=hold-sla || fail "the digest raised no captain wake"
  lines=$(wc -l < "$MAIN/state/mate.status")
  out=$(run_sla "$MAIN" sweep --live) || fail "second live sweep failed: $out"
  [ "$(wc -l < "$MAIN/state/mate.status")" = "$lines" ] || fail "a re-run appended again"
  [ "$(grep -c 'pr comment 7' "$TMP_ROOT/gh.log")" = 1 ] || fail "a re-run queued the PR twice"
  pass "a live sweep resolves routine holds, keeps captain-only ones, and is idempotent"
}

test_overrides_cannot_unprotect() {
  local out
  setup_world
  run_sla "$MAIN" set prod-flip --class quick --default "flip it" >/dev/null
  run_sla "$MAIN" set ux-copy --class captain-only:manual >/dev/null
  out=$(run_sla "$MAIN" sweep --live) || fail "sweep failed: $out"
  out=$(open_keys "$MAIN/state/mate.status")
  case " $out " in *" prod-flip "*) ;; *) fail "an override made a production hold routine" ;; esac
  case " $out " in *" ux-copy "*) ;; *) fail "an override could not make a hold critical" ;; esac
  pass "overrides tighten but never loosen protection"
}

test_action_cap_drains_gradually() {
  local out before after
  setup_world
  before=$(open_keys "$MAIN/state/mate.status" | wc -w)
  out=$(FM_HOLD_SLA_MAX_ACTIONS=2 run_sla "$MAIN" sweep --live) || fail "capped sweep failed: $out"
  after=$(open_keys "$MAIN/state/mate.status" | wc -w)
  [ $((before - after)) -le 2 ] || fail "the action cap let $((before - after)) holds resolve in one sweep"
  grep -q 'action cap 2 reached' "$MAIN/state/hold-sla/hold-sla.log" || fail "the cap was not logged"
  pass "a live sweep acts on at most FM_HOLD_SLA_MAX_ACTIONS holds"
}

test_sla_close_refuses_held_work_and_replays() {
  local home out rc
  home=$(make_home work)
  tasks_in "$home" add work-item "Build the thing" --kind ship >/dev/null
  captain_in "$home" hold work-item --reason "proceed? Recommend: yes" >/dev/null || fail "could not hold the work item"
  printf 'default applied\n' > "$TMP_ROOT/ev.txt"
  set +e
  out=$(captain_in "$home" sla-close work-item --evidence-file "$TMP_ROOT/ev.txt" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "sla-close closed a held work item"
  assert_contains "$out" "--release" "the refusal did not point at --release: $out"
  captain_in "$home" sla-close work-item --evidence-file "$TMP_ROOT/ev.txt" --release >/dev/null || fail "sla-close --release failed"
  tasks_in "$home" show work-item | grep -q 'held: no' || fail "sla-close --release did not lift the work hold"
  tasks_in "$home" show work-item | grep -q 'state: done' && fail "sla-close --release closed the work"
  captain_in "$home" hold q --title "Captain call: q" --reason "q? Recommend: a" >/dev/null || fail "hold q"
  captain_in "$home" sla-close q --evidence-file "$TMP_ROOT/ev.txt" >/dev/null || fail "sla-close of a question failed"
  captain_in "$home" sla-close q --evidence-file "$TMP_ROOT/ev.txt" >/dev/null || fail "an exact sla-close retry was not idempotent"
  printf 'captain words\n' > "$TMP_ROOT/cw.txt"
  captain_in "$home" hold q2 --title "Captain call: q2" --reason "q2" >/dev/null
  captain_in "$home" answer q2 --decision-file "$TMP_ROOT/cw.txt" >/dev/null
  set +e
  captain_in "$home" sla-close q2 --evidence-file "$TMP_ROOT/cw.txt" >/dev/null 2>&1; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "sla-close replayed over a captain answer"
  pass "sla-close closes question rows, releases work items, and never overwrites a captain answer"
}

test_hold_requires_a_critical_class_when_enforced() {
  local home out rc
  home=$(make_home enforce)
  : > "$home/config/hold-require-class"
  set +e
  out=$(FM_CONFIG_OVERRIDE="$home/config" captain_in "$home" hold soft-q --title "Captain call: soft" --reason "which tab name?" 2>&1); rc=$?
  set -e
  [ "$rc" = 3 ] || fail "an unclassified hold was not converted (rc=$rc): $out"
  assert_contains "$out" "converted: soft-q" "the conversion was not reported: $out"
  tasks_in "$home" show soft-q >/dev/null 2>&1 && fail "a converted hold still created a task"
  FM_CONFIG_OVERRIDE="$home/config" captain_in "$home" hold spend-q --title "Captain call: spend" --class spend --reason "buy the plan? Recommend: no" >/dev/null \
    || fail "a classified hold was refused"
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show spend-q | grep -q "class=spend" || fail "the class was not stored on the hold"
  set +e
  FM_CONFIG_OVERRIDE="$home/config" captain_in "$home" hold spend-q --class nonsense --reason x >/dev/null 2>&1; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unknown class was accepted"
  pass "with enforcement on, only a critical class can raise a captain hold"
}

test_old_holds_close_without_waking_their_owner() {
  local out
  setup_world
  out=$(FM_HOLD_SLA_NOTIFY_MAX_AGE_HOURS=24 run_sla "$MAIN" sweep --live) || fail "live sweep failed: $out"
  grep -q 'resolved \[key=ux-copy\]' "$MAIN/state/mate.status" || fail "the old quick hold was not closed"
  grep -q 'resolved \[key=no-rec\].*sla-returned' "$MAIN/state/mate.status" || fail "the old returned hold was not closed"
  grep -q 'ux-copy\|no-rec\|crit-norec' "$TMP_ROOT/send.log" && fail "a hold older than 24h woke its owner"
  grep -q 'owner wake skipped for ux-copy (mate): hold is 72h old, over 24h' "$MAIN/state/hold-sla/hold-sla.log" || fail "the skipped wake was not logged"
  pass "holds older than FM_HOLD_SLA_NOTIFY_MAX_AGE_HOURS close without waking their owner"
}

set -e
test_classify_protects_captain_only_classes
test_six_missed_holds_are_captain_only
test_no_recommendation_is_returned_never_applied
test_scratch_dir_dry_run_leaves_state_alone
test_report_is_read_only
rm -rf "$TMP_ROOT/main" "$TMP_ROOT/mate"
test_dry_run_changes_nothing
rm -rf "$TMP_ROOT/main" "$TMP_ROOT/mate"
test_live_sweep_resolves_routine_and_escalates_the_rest
rm -rf "$TMP_ROOT/main" "$TMP_ROOT/mate"
test_old_holds_close_without_waking_their_owner
rm -rf "$TMP_ROOT/main" "$TMP_ROOT/mate"
test_overrides_cannot_unprotect
rm -rf "$TMP_ROOT/main" "$TMP_ROOT/mate"
test_action_cap_drains_gradually
test_sla_close_refuses_held_work_and_replays
test_hold_requires_a_critical_class_when_enforced
echo "ok: fm-hold-sla"
