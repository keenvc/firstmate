#!/usr/bin/env bash
# Behavior tests for the verified Factory Droid CLI adapter.
#
# The facts pinned here are the ones a droid release could silently change and
# the ones a wrong guess would make dangerous:
#   1. Detection: droid publishes FACTORY_SESSION_ID to its children, and its
#      anchored process name is `droid`. The marker is tested before
#      CLAUDECODE because droid does not scrub an inherited value, and a
#      structural droid ancestor outranks a retained foreign marker.
#   2. Control mechanics: single Escape cancels, `/quit` exits, and droid is
#      verified for crewmate, scout, AND secondmate kinds.
#   3. Busy state: only the droid-hook writer is trusted, an idle_prompt
#      Notification closes a cancelled turn, and the launch-prompt backstop
#      recognizes droid's folder-trust dialog without matching ordinary prose.
#   4. Composer: droid's bordered composer closes over a `>` SHELL glyph, which
#      is a container proof only for a proved droid pane; an unproven box stays
#      `unknown`, a droid=ask caller gets need-identity, and a droid identity
#      resolves the idle ghost to `empty` while typed text stays `pending`.
#   5. Turn end: bin/fm-turnend-guard.sh --droid blocks a blind turn end with
#      exit 2, allows one `stop_hook_active` follow-up, and records the parent
#      home's busy verdict through .fm-busy-stop (busy on a block, idle on an
#      allow).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Detection consults verified env markers before ancestry; a suite run from
# inside another harness inherits them. Drop the ambient ones so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FACTORY_SESSION_ID

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
TRUST="$ROOT/bin/fm-droid-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-droid-harness)

droid_trusted_paths() {  # <store>
  node -e 'const fs=require("node:fs");const j=fs.existsSync(process.argv[1])?JSON.parse(fs.readFileSync(process.argv[1],"utf8")):{};for(const p of Object.keys(j.trustedFolders||{}))console.log(p);' "$1"
}

droid_store_value() {  # <store> <key>
  node -e 'const fs=require("node:fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const v=j[process.argv[2]];process.stdout.write(typeof v==="string"?JSON.stringify(v):String(v));' "$1" "$2"
}

assert_droid_trusted() {  # <store> <path> <msg>
  droid_trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_droid_not_trusted() {  # <store> <path> <msg>
  droid_trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

test_marker_detects_droid() {
  local out fakebin base_path
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  # Blind the ancestry walk so the marker is the only evidence: a structural
  # ancestor of another harness outranks a marker, and this suite runs inside
  # whatever harness launched it.
  fakebin=$(fm_fakebin "$TMP_ROOT/marker")
  fm_fake_blind_ancestry "$fakebin"
  out=$(PATH="$fakebin:$base_path" FACTORY_SESSION_ID=523dffff-4099-42b6-a14a-8ed9e22d0504 "$HARNESS")
  [ "$out" = droid ] || fail "FACTORY_SESSION_ID must detect droid, got '$out'"
  # Drive the signals apart: without the marker the same blinded tree must not
  # answer droid.
  out=$(PATH="$fakebin:$base_path" env -u FACTORY_SESSION_ID "$HARNESS")
  [ "$out" != droid ] || fail "no marker must not detect droid, got '$out'"
  pass "fm-harness.sh: FACTORY_SESSION_ID detects droid and nothing else claims it"
}

test_marker_outranks_an_inherited_claude_marker() {
  local out fakebin base_path
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-ordering")
  fm_fake_blind_ancestry "$fakebin"
  # Verified on 0.251.0: droid does not clear an inherited CLAUDECODE, so the
  # marker must win BEFORE the claude arm is consulted.
  out=$(PATH="$fakebin:$base_path" FACTORY_SESSION_ID=abc CLAUDECODE=1 "$HARNESS" 2>/dev/null || true)
  [ "$out" = droid ] \
    || fail "a droid worker under a claude primary must detect as droid, got '$out'"
  # Each signal alone must still produce its own verdict, so the case above
  # cannot go quietly vacuous.
  out=$(PATH="$fakebin:$base_path" env -u FACTORY_SESSION_ID CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  pass "fm-harness.sh: the droid marker outranks an inherited CLAUDECODE"
}

test_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/home/user/.local/bin/droid'; exit 0 ;;
  *"args="*) printf '%s\n' 'droid --settings /tmp/s.json hello'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = droid ] \
    || fail "a natively-named droid command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects the native droid command name"
}

test_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FAKE_PS_COMM=android-tool FAKE_PS_ARGS='android-tool --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != droid ] \
    || fail "an unrelated command containing 'droid' must not detect droid, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo droid --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != droid ] \
    || fail "a shell argument naming droid must not detect droid, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated droid mentions"
}

# A harness that runs its session-start or turn-end hook through wrapper scripts
# spends several process levels before the harness binary. droid's own
# SessionStart reached bin/fm-session-start.sh that way: hook shell, transport
# script, bounded timeout wrapper, then the digest script, and at an
# eight-parent bound the same detection that answered `droid` from a tool
# subprocess answered `unknown` from the hook (measured 2026-10-29). The walk is
# real processes here, with a copied Bash binary named exactly `droid` as the
# ancestor, so the depth itself is what is under test.
test_ancestry_reaches_a_hook_launched_session_start() {
  local dir out
  dir="$TMP_ROOT/anc-depth"
  mkdir -p "$dir/bin"
  cp /bin/bash "$dir/bin/droid" || fail "could not stage the named ancestor binary"
  cat >"$dir/nest.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-0}" -gt 0 ]; then
  bash "$0" $(( $1 - 1 ))
  exit $?
fi
exec "$FM_NEST_HARNESS"
SH
  chmod +x "$dir/nest.sh"
  # Nine nested shells put the named ancestor ten levels above this script's
  # parent, which the eight-parent bound could not reach.
  out=$(FM_NEST_HARNESS="$HARNESS" "$dir/bin/droid" "$dir/nest.sh" 9)
  [ "$out" = droid ] \
    || fail "a hook-launched session start must still detect its harness, got '$out'"
  # The walk stays bounded: far beyond the bound the same tree must not claim it.
  out=$(FM_NEST_HARNESS="$HARNESS" "$dir/bin/droid" "$dir/nest.sh" 20)
  [ "$out" != droid ] \
    || fail "the ancestry walk must stay bounded, got '$out' twenty levels down"
  pass "fm-harness.sh: ancestry reaches a hook-launched session start and stays bounded"
}

test_control_mechanics() {
  assert_equals Escape "$(fm_control_interrupt_key droid)" "droid interrupts with Escape"
  assert_equals 1 "$(fm_control_interrupt_repeat droid)" "droid interrupts with one press"
  assert_equals none "$(fm_control_interrupt_ack_source droid)" "droid has no cancellation ack"
  assert_equals /quit "$(fm_control_exit_command droid)" "droid exits with /quit"
  assert_equals key "$(fm_control_interrupt_transport droid)" "droid interrupts through the keyplane"
  fm_control_harness_supported droid || fail "droid must be a supported control harness"
  fm_control_harness_supports_kind droid secondmate \
    || fail "droid must be verifiable for secondmate kind"
  fm_control_harness_supports_kind droid scout || fail "droid must be verifiable for scout kind"
  pass "fm-control-lib.sh: droid interrupt, exit, and kind support"
}

test_agent_process_reads_the_native_name_as_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name droid)
  [ "$got" = agent ] || fail "tmux liveness must read the droid binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name android-tool)
  [ "$got" = other ] || fail "tmux liveness must not read android-tool as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: droid is an agent, fragments are not"
}

test_busy_source_trust() {
  local sources
  sources=$(fm_busy_sources_for_harness droid)
  case " $sources " in
    *" droid-hook "*) : ;;
    *) fail "droid must trust the droid-hook writer, got '$sources'" ;;
  esac
  case " $sources " in
    *" claude-hook "*|*" gemini-hook "*|*" cortex-hook "*) fail "droid must not borrow another adapter's writer: '$sources'" ;;
  esac
  fm_busy_source_trusted droid droid-hook || fail "a droid-hook record must be trusted for droid"
  fm_busy_source_trusted cortex droid-hook && fail "a droid-hook record must not be trusted for cortex"
  pass "fm-busy-lib.sh: droid trusts only its own hook writer"
}

test_busy_record_classifies() {
  local state id gen
  state="$TMP_ROOT/busy-state"
  id=droid-busy
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "could not arm the busy record"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source droid-hook --event user-prompt-submit >/dev/null || fail "could not apply a busy event"
  assert_equals "busy droid-hook" "$(fm_busy_classify herdr target droid "$id" "$state")" \
    "a droid-hook busy record must classify busy"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source droid-hook --event notification-idle >/dev/null || fail "could not apply an idle event"
  assert_equals "idle droid-hook" "$(fm_busy_classify herdr target droid "$id" "$state")" \
    "an idle_prompt close must classify idle"
  pass "fm-busy-lib.sh: a droid-hook record classifies busy then idle"
}

test_launch_prompt_backstop() {
  local dialog other
  dialog=$(cat <<'EOF'
╭──────────────────────────────────────────────╮
│ Trust this folder?                            │
│ /tmp/fm-task                                 │
│ 1. Trust this folder                          │
│ 2. Exit without trusting                      │
╰──────────────────────────────────────────────╯
Enter to confirm · Esc to exit
EOF
)
  printf '%s' "$dialog" | fm_busy_launch_prompt_parked droid \
    || fail "droid's folder-trust dialog must be recognized"
  other='Trust this folder? is what a worker may write in its own report'
  printf '%s' "$other" | fm_busy_launch_prompt_parked droid \
    && fail "ordinary prose must not match the droid launch-prompt signature"
  pass "fm-busy-lib.sh: the droid folder-trust dialog is recognized, prose is not"
}

# The idle composer a real droid 0.251.0 pane renders at 120 columns: a rounded
# box whose prompt row leads with the shell glyph `>` and holds dim ghost text,
# with the terminal cursor parked on the ghost's first letter, and droid's own
# status cell row directly below the box.
# _droid_box_row <inner> <width>: one side-bordered row padded to <width>
# columns, so the fixture is geometrically consistent with its borders. An
# inconsistent box is deliberately ambiguous and classifies unknown, which is
# the safety property, not the case under test here.
_droid_box_row() {
  local inner=$1 width=$2 pad
  pad=$((width - ${#inner}))
  [ "$pad" -ge 0 ] || pad=0
  printf '│%s%*s│\n' "$inner" "$pad" ''
}

_droid_box_border() {  # <width> <left> <right>
  local width=$1 left=$2 right=$3 line
  line=$(printf '%*s' "$width" '')
  line=${line// /─}
  printf '%s%s%s\n' "$left" "$line" "$right"
}

droid_idle_screen() {
  local inner=' > Try "Set up GitHub Actions for CI/CD"'
  printf '%s\n' '  Auto (High) · allow all commands          Gemini 4 Argon (Low)'
  _droid_box_border 58 '╭' '╮'
  printf '│ \033[38;2;215;95;0m> \033[7m\033[39mT\033[0;2mry "Set up GitHub Actions for CI/CD"\033[0m%*s│\n' \
    $((58 - ${#inner})) ''
  _droid_box_border 58 '╰' '╯'
  printf '%s\n' '9 config issues — /diagnostics                MCP ✗ | TMUX ⧉'
}

test_composer_requires_a_proved_identity() {
  local screen verdict
  screen=$(droid_idle_screen)
  verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1' "$screen" '')
  assert_equals unknown "$verdict" \
    "an unproved shell-glyph box must stay unknown (a dead shell can draw one)"
  pass "fm-composer-lib.sh: an unproved droid-shaped box stays unknown"
}

test_composer_droid_identity_reads_empty() {
  local screen verdict
  screen=$(droid_idle_screen)
  verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\ndroid=ask' "$screen" '')
  assert_equals need-identity "$verdict" "a droid=ask caller must be asked for the identity"
  verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\ndroid=ask' "$screen" '' \
    "$(printf 'droid\tidle')")
  assert_equals empty "$verdict" "a proved droid pane's idle ghost must read empty"
  verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\ndroid=ask' "$screen" '' \
    "$(printf 'claude\tidle')")
  assert_equals unknown "$verdict" "another harness's identity must not prove a droid box"
  pass "fm-composer-lib.sh: a proved droid identity resolves its idle composer to empty"
}

test_composer_typed_text_is_pending() {
  local screen verdict
  local inner=' > please finish the report'
  screen=$(printf '%s\n' \
    "$(_droid_box_border 58 '╭' '╮')" \
    "$(printf '│ \033[38;2;215;95;0m> \033[39mplease finish the report%*s│' $((58 - ${#inner})) '')" \
    "$(_droid_box_border 58 '╰' '╯')" \
    '9 config issues — /diagnostics                MCP ✗ | TMUX ⧉')
  verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\ndroid=1' "$screen" '')
  assert_equals pending "$verdict" "bright typed text in a droid box must read pending"
  pass "fm-composer-lib.sh: typed text in a droid box reads pending"
}

test_delivery_busy_footer() {
  local busy idle
  busy='⠰ Thinking...  (Press ESC to stop)'
  idle='[⏱ 5s] 9 config issues — /diagnostics      MCP ✗ | TMUX ⧉'
  printf '%s\n' "$busy" | fm_busy_lines_match droid \
    || fail "droid's in-flight spinner row must match its delivery busy signature"
  printf '%s\n' "$idle" | fm_busy_lines_match droid \
    && fail "droid's idle status row must not match its busy signature"
  printf '%s\n' "$busy" | fm_busy_lines_match claude \
    && fail "droid's busy token must not acknowledge another harness"
  # The idle footer keeps droid's elapsed cell, so it must never read busy.
  idle='[⏱ 5s] 9 config issues — /diagnostics      MCP ✗ | TMUX ⧉'
  printf '%s\n' "$idle" | fm_busy_lines_match droid \
    && fail "droid's post-turn elapsed footer must not read busy"
  pass "fm-composer-lib.sh: droid's busy footer is scoped to droid"
}

# A guard fixture: a genuine primary home (plain git checkout with AGENTS.md and
# bin/) carrying one in-flight task and no watcher, so supervision is needed and
# no beacon exists.
guard_fixture() {  # <dir> <gen>
  local home=$1
  mkdir -p "$home/state" "$home/bin" "$home/config"
  git -C "$home" init -q || fail "could not initialize the guard fixture repo"
  printf 'fixture\n' >"$home/AGENTS.md"
  printf 'task\n' >"$home/state/probe.meta"
  printf 'probe\n' >"$home/state/probe.status"
  {
    printf 'writer=%s\n' "$ROOT/bin/fm-busy-event.sh"
    printf 'state=%s\n' "$home/state"
    printf 'id=%s\n' probe
    printf 'gen=%s\n' "$2"
  } >"$home/.fm-busy-stop"
  printf '%s\n' "$home"
}

test_guard_blocks_a_blind_droid_turn_end() {
  local home gen out rc verdict
  home="$TMP_ROOT/guard-block"
  mkdir -p "$home/state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" probe) || fail "could not arm the guard fixture"
  guard_fixture "$home" "$gen" >/dev/null
  out=$(printf '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      "$GUARD" --droid 2>&1)
  rc=$?
  expect_code 2 "$rc" "a blind droid turn end must be blocked"
  assert_contains "$out" "TURN WOULD END BLIND" "the block must carry the repair banner"
  verdict=$(cat "$home/state/probe.busy-state" 2>/dev/null || true)
  assert_contains "$verdict" "state=busy" "a blocked Stop must record busy"
  assert_contains "$verdict" "source=droid-hook" "the guard must write its droid source"
  pass "fm-turnend-guard.sh --droid: blocks a blind turn end and records busy"
}

test_guard_allows_one_droid_follow_up() {
  local home gen rc verdict
  home="$TMP_ROOT/guard-allow"
  mkdir -p "$home/state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" probe) || fail "could not arm the guard fixture"
  guard_fixture "$home" "$gen" >/dev/null
  printf '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":true}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      "$GUARD" --droid >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a stop_hook_active follow-up must be allowed"
  verdict=$(cat "$home/state/probe.busy-state" 2>/dev/null || true)
  assert_contains "$verdict" "state=idle" "an allowed Stop must record idle"
  pass "fm-turnend-guard.sh --droid: allows the one bounded follow-up and records idle"
}

test_guard_refuses_an_unknown_mode() {
  local out rc
  out=$(printf '{}' | "$GUARD" --not-a-harness 2>&1)
  rc=$?
  expect_code 2 "$rc" "an unknown guard mode must be refused"
  assert_contains "$out" "usage:" "the refusal must name the usage"
  pass "fm-turnend-guard.sh: refuses an unknown harness mode"
}

make_droid_trust_case() {  # <name> -> "<case>|<proj>|<wt>|<home>"
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/trust-$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-trust-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_droid_trust_case() {
  IFS='|' read -r CASE_DIR PROJ_DIR WT_DIR HOME_DIR <<EOF
$1
EOF
}

run_droid_trust() {  # <home> <worktree> <project>
  HOME="$1" "$TRUST" "$2" "$3" 2>&1
}

test_droid_trust_registers_the_logical_and_resolved_worktree_paths() {
  local rec store out link
  rec=$(make_droid_trust_case fresh)
  read_droid_trust_case "$rec"
  store="$HOME_DIR/.factory/settings.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"sessionDefaultSettings":{"model":"custom:deepseek-v4.1-flash-vercel"},"trustedFolders":{"/home/someone/elsewhere":{"trustedAt":"2026-01-01T00:00:00.000Z"}}}' >"$store"
  link="$CASE_DIR/wt-link"
  ln -s "$WT_DIR" "$link"
  out=$(run_droid_trust "$HOME_DIR" "$link" "$PROJ_DIR") || fail "a fresh linked worktree must be trusted: $out"
  assert_droid_trusted "$store" "$link" "the logical (symlinked) pane path droid compares against was not registered"
  assert_droid_trusted "$store" "$WT_DIR" "the resolved worktree path was not registered alongside the logical one"
  assert_droid_trusted "$store" "/home/someone/elsewhere" "registration dropped an existing trustedFolders entry"
  [ "$(droid_store_value "$store" sessionDefaultSettings)" != undefined ] \
    || fail "registration dropped the unrelated sessionDefaultSettings key"
  out=$(run_droid_trust "$HOME_DIR" "$link" "$PROJ_DIR") || fail "repeat registration must succeed: $out"
  [ "$(droid_trusted_paths "$store" | grep -Fcx "$WT_DIR")" -eq 1 ] \
    || fail "repeat registration duplicated the worktree entry"
  pass "fm-droid-trust.sh: registers the logical and resolved worktree paths and preserves the store"
}

test_droid_trust_creates_a_missing_store() {
  local rec store out
  rec=$(make_droid_trust_case nostore)
  read_droid_trust_case "$rec"
  store="$HOME_DIR/.factory/settings.json"
  out=$(run_droid_trust "$HOME_DIR" "$WT_DIR" "$PROJ_DIR") || fail "a missing store must be created: $out"
  [ -f "$store" ] || fail "no settings store was created at $store"
  assert_droid_trusted "$store" "$WT_DIR" "the worktree was not registered in the created store"
  pass "fm-droid-trust.sh: creates droid's settings store when none exists"
}

test_droid_trust_refuses_out_of_scope_paths() {
  local rec store out rc plain before after
  rec=$(make_droid_trust_case scope)
  read_droid_trust_case "$rec"
  store="$HOME_DIR/.factory/settings.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"trustedFolders":{}}' >"$store"
  rc=0; out=$(run_droid_trust "$HOME_DIR" "$PROJ_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "the primary checkout must be refused"
  assert_contains "$out" "primary checkout" "primary-checkout refusal lacked its reason"
  assert_droid_not_trusted "$store" "$PROJ_DIR" "a refused primary checkout was still registered"
  rc=0; out=$(run_droid_trust "$HOME_DIR" "$HOME_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "the home directory must be refused"
  assert_droid_not_trusted "$store" "$HOME_DIR" "a refused home directory was still registered"
  plain="$CASE_DIR/plain"; mkdir -p "$plain"
  rc=0; out=$(run_droid_trust "$HOME_DIR" "$plain" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a plain directory must be refused"
  assert_droid_not_trusted "$store" "$plain" "a refused plain directory was still registered"
  rc=0; out=$(run_droid_trust "$HOME_DIR" "$WT_DIR/.git" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a path below the worktree root must be refused"
  printf '%s\n' '{not json' >"$store"
  before=$(cat "$store")
  rc=0; out=$(run_droid_trust "$HOME_DIR" "$WT_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unparseable store must be refused"
  after=$(cat "$store")
  [ "$before" = "$after" ] || fail "an unparseable store was rewritten"
  pass "fm-droid-trust.sh: refuses every out-of-scope path and never rewrites a broken store"
}

test_droid_trust_requires_a_marked_secondmate_home() {
  local rec store out rc home
  rec=$(make_droid_trust_case mate)
  read_droid_trust_case "$rec"
  store="$HOME_DIR/.factory/settings.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"trustedFolders":{}}' >"$store"
  rc=0; out=$(HOME="$HOME_DIR" "$TRUST" --secondmate-home "$WT_DIR" mate-id 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a home without the marker must be refused"
  assert_contains "$out" ".fm-secondmate-home" "the refusal must name the missing marker"
  printf 'other-id\n' >"$WT_DIR/.fm-secondmate-home"
  rc=0; out=$(HOME="$HOME_DIR" "$TRUST" --secondmate-home "$WT_DIR" mate-id 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a home marked for another secondmate must be refused"
  printf 'mate-id\n' >"$WT_DIR/.fm-secondmate-home"
  out=$(HOME="$HOME_DIR" "$TRUST" --secondmate-home "$WT_DIR" mate-id 2>&1) \
    || fail "a correctly marked secondmate home must be trusted: $out"
  assert_droid_trusted "$store" "$WT_DIR" "the marked secondmate home was not registered"
  pass "fm-droid-trust.sh: secondmate-home mode requires the matching marker"
}

test_marker_detects_droid
test_marker_outranks_an_inherited_claude_marker
test_ancestry_detects_the_native_command_name
test_ancestry_rejects_unrelated_mentions
test_ancestry_reaches_a_hook_launched_session_start
test_control_mechanics
test_agent_process_reads_the_native_name_as_an_agent
test_busy_source_trust
test_busy_record_classifies
test_launch_prompt_backstop
test_composer_requires_a_proved_identity
test_composer_droid_identity_reads_empty
test_composer_typed_text_is_pending
test_delivery_busy_footer
test_guard_blocks_a_blind_droid_turn_end
test_guard_allows_one_droid_follow_up
test_guard_refuses_an_unknown_mode
test_droid_trust_registers_the_logical_and_resolved_worktree_paths
test_droid_trust_creates_a_missing_store
test_droid_trust_refuses_out_of_scope_paths
test_droid_trust_requires_a_marked_secondmate_home
