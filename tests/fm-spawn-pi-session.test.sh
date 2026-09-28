#!/usr/bin/env bash
# The deterministic Pi session contract: a fresh pi/pi-signed ship or scout
# runs the task's own persistent session, `--session-id <task-id>`, and the
# task record carries pi_session_id= so a relaunch can resume it.
#
# Pinned here, hermetically (fake tmux/treehouse, a stub pi that records its
# arguments):
#   1. A fresh pi ship spawn records pi_session_id= and launches with
#      --session-id <task-id>.
#   2. A fresh pi-signed spawn does the same under its own executable name.
#   3. A fresh pi scout records it too.
#   4. A secondmate on pi does neither: its session lifecycle is its own
#      home's, and the deterministic id is a crewmate/scout contract.
#
# The relaunch half of the contract - resuming the recorded id when the
# endpoint is gone or agent-free - is pinned by tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-session)

# new_case <name> <crew-harness> [pi-executable-name] -> sets the case globals.
# The stub <pi-executable-name> exists only to answer the launch's `--help`
# version probe; the launch itself is never executed, so every assertion reads
# the composed launch line from the fake tmux's FM_FAKE_LAUNCH_LOG.
new_case() {
  local name=$1 harness=$2 bin_name=${3:-pi}
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  cat > "$FAKEBIN/$bin_name" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --help) printf '%s\n' 'Options: --tui-mode <mode> --session-id <id>'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/$bin_name"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ" "$WT" "wt-$name"
  : > "$CASE/launch.log"
}

spawn_ship() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" \
    --mode no-mistakes --yolo off "$@"
}

meta_field() {  # <id> <key>
  grep "^$2=" "$HOME_DIR/state/$1.meta" | tail -1 | cut -d= -f2-
}

test_fresh_pi_ship_spawn_records_and_runs_its_own_session() {
  local out rc id=pi-s1
  new_case fresh-pi pi
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a fresh pi ship spawn should succeed"$'\n'"$out"
  [ "$(meta_field "$id" pi_session_id)" = "$id" ] \
    || fail "the task record must carry pi_session_id=$id, got '$(meta_field "$id" pi_session_id)'"
  assert_contains "$(cat "$CASE/launch.log")" "--session-id '$id'" \
    "the launch must run the task's deterministic session id"
  assert_not_contains "$(cat "$CASE/launch.log")" "--session '" \
    "a fresh spawn has no runtime reference to resume"
  pass "fm-spawn: a fresh pi ship runs the task's own persistent session and records it"
}

test_fresh_pi_signed_ship_spawn_records_and_runs_its_own_session() {
  local out rc id=pi-signed-s1
  new_case fresh-pi-signed pi-signed pi-signed
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a fresh pi-signed ship spawn should succeed"$'\n'"$out"
  [ "$(meta_field "$id" pi_session_id)" = "$id" ] \
    || fail "the task record must carry pi_session_id=$id, got '$(meta_field "$id" pi_session_id)'"
  assert_contains "$(cat "$CASE/launch.log")" "--session-id '$id'" \
    "the signed wrapper's launch must run the task's deterministic session id"
  pass "fm-spawn: a fresh pi-signed ship runs the task's own persistent session and records it"
}

test_fresh_pi_scout_spawn_records_and_runs_its_own_session() {
  local out rc id=pi-scout1
  new_case fresh-pi-scout pi
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --scout); rc=$?
  expect_code 0 "$rc" "a fresh pi scout spawn should succeed"$'\n'"$out"
  [ "$(meta_field "$id" pi_session_id)" = "$id" ] \
    || fail "the scout record must carry pi_session_id=$id, got '$(meta_field "$id" pi_session_id)'"
  assert_contains "$(cat "$CASE/launch.log")" "--session-id '$id'" \
    "the scout launch must run the task's deterministic session id"
  pass "fm-spawn: a fresh pi scout runs the task's own persistent session and records it"
}

test_pi_secondmate_spawn_gets_no_deterministic_session() {
  local out rc id=pi-sm1 sm
  new_case fresh-pi-sm pi
  printf 'pi\n' > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$sm/state" "$sm/projects"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a pi secondmate spawn should succeed"$'\n'"$out"
  [ -z "$(meta_field "$id" pi_session_id)" ] \
    || fail "a secondmate record must not carry the deterministic session id"
  assert_not_contains "$(cat "$CASE/launch.log")" "--session-id" \
    "a secondmate owns its session lifecycle; the deterministic id is not passed"
  pass "fm-spawn: a pi secondmate keeps its own session lifecycle, with no deterministic id"
}

test_fresh_pi_ship_spawn_records_and_runs_its_own_session
test_fresh_pi_signed_ship_spawn_records_and_runs_its_own_session
test_fresh_pi_scout_spawn_records_and_runs_its_own_session
test_pi_secondmate_spawn_gets_no_deterministic_session
