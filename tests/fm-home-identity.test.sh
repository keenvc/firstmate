#!/usr/bin/env bash
# tests/fm-home-identity.test.sh - the copied-home guard owned by
# bin/fm-home-identity-lib.sh: fm-lock.sh records a state directory's identity,
# and a copy of that home refuses every command that acts on a live endpoint.
# tests/fm-secondmate-liveness.test.sh covers the sweep and relaunch paths.
# Every backend here is a fake that logs its calls, and every home is a fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-identity)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALLS="$TMP_ROOT/backend-calls.log"
: > "$CALLS"
for tool in tmux herdr; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >> "$CALLS"
exit 0
SH
  chmod +x "$FAKEBIN/$tool"
done
ln -s /bin/bash "$FAKEBIN/claude"

# acquire_lock <home> <state-dir>: the real lock script under a stand-in harness.
acquire_lock() {
  # shellcheck disable=SC2016 # expanded by the stand-in harness shell.
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$FAKEBIN:$PATH" \
    FM_HOME="$1" FM_STATE_OVERRIDE="$2" FM_ROOT_OVERRIDE="$ROOT" \
    "$FAKEBIN/claude" -c '"$0/bin/fm-lock.sh"; rc=$?; exit "$rc"' "$ROOT" 2>&1
}

# make_home <name>: a home with one mate record naming a real-looking endpoint.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/mate"
  fm_write_secondmate_meta "$home/state/sm1.meta" "$home/mate" firstmate:fm-sm1 alpha claude
  printf '%s\n' "$home"
}

# run_cmd <home> <command...>: one command under the fixture's fake backend.
run_cmd() {
  local home=$1
  shift
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$FAKEBIN:$PATH" TMUX='' FM_BACKEND=tmux \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$home" "$@" 2>&1
}

test_lock_records_identity_and_never_launders_a_copy() {
  local home copy real out
  home=$(make_home lock-original)
  real=$(cd "$home/state" && pwd -P)

  out=$(acquire_lock "$home" "$home/state")
  assert_contains "$out" "lock acquired" "the fixture should acquire its lock"
  assert_equals "$real" "$(cat "$home/state/.home-id")" "the lock should record this state directory"

  rm -f "$home/state/.lock" "$home/state/.lock-session"
  copy="$TMP_ROOT/lock-copy"
  cp -R "$home" "$copy"
  out=$(acquire_lock "$copy" "$copy/state")
  assert_contains "$out" "lock acquired" "a copy may still hold its own lock for read-only work"
  assert_equals "$real" "$(cat "$copy/state/.home-id")" "acquiring a lock in a copy must not rewrite the original's identity"
  pass "lock: records a home's identity once, and a copy keeps naming the original"
}

test_copy_refuses_every_endpoint_action_with_one_line() {
  local home copy out cmd journal
  home=$(make_home refuse-original)
  (cd "$home/state" && pwd -P) > "$home/state/.home-id"
  copy="$TMP_ROOT/refuse-copy"
  cp -R "$home" "$copy"
  : > "$CALLS"

  out=$(run_cmd "$copy" "$ROOT/bin/fm-spawn.sh" sm1 --secondmate) && fail "fm-spawn ran in a copied home: $out"
  assert_contains "$out" "error: fm-spawn refused: " "fm-spawn should refuse with its name"
  assert_contains "$out" "is a copy of" "fm-spawn should say why"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || fail "the refusal should be one line: $out"

  for cmd in interrupt exit; do
    out=$(run_cmd "$copy" "$ROOT/bin/fm-control.sh" sm1 "$cmd") && fail "fm-control $cmd ran in a copied home: $out"
    assert_contains "$out" "error: fm-control refused: " "fm-control $cmd should refuse with its name"
  done

  out=$(run_cmd "$copy" "$ROOT/bin/fm-teardown.sh" sm1 --force) && fail "fm-teardown ran in a copied home: $out"
  assert_contains "$out" "error: fm-teardown refused: " "fm-teardown should refuse even when forced"
  [ -e "$copy/state/sm1.meta" ] || fail "the refused teardown removed the copied record"

  journal="$copy/state/task.herdr-presentation"
  printf 'journal\n' > "$journal"
  out=$(run_cmd "$copy" "$ROOT/bin/fm-herdr-session-cleanup.sh") || fail "the cleanup must not fail session start: $out"
  assert_contains "$out" "skipped: " "the stale child cleanup should say it skipped"
  assert_contains "$out" "is a copy of" "the stale child cleanup should say why"
  [ -e "$journal" ] || fail "the skipped cleanup removed a journal"

  [ ! -s "$CALLS" ] || fail "a copied home reached a backend: $(cat "$CALLS")"
  pass "copy: fm-spawn, fm-control, fm-teardown, and the stale child cleanup refuse without touching a backend"
}

test_guard_passes_the_original_fixtures_and_overrides() {
  local home other out marker
  home=$(make_home pass-original)
  (cd "$home/state" && pwd -P) > "$home/state/.home-id"
  out=$(run_cmd "$home" "$ROOT/bin/fm-control.sh" no-such-task interrupt) || true
  assert_not_contains "$out" "refused: " "the original home must pass the guard"

  # A fixture that never acquired a lock has no marker and behaves as it always has.
  other=$(make_home pass-unmarked)
  out=$(run_cmd "$other" "$ROOT/bin/fm-control.sh" no-such-task interrupt) || true
  assert_not_contains "$out" "is a copy of" "an unmarked home must pass the guard"
  [ ! -e "$other/state/.home-id" ] || fail "only a lock acquisition may record an identity"

  # FM_STATE_OVERRIDE selects the state directory the identity belongs to, so it
  # stays coherent whichever FM_HOME accompanies it.
  mkdir -p "$TMP_ROOT/override-state"
  out=$(acquire_lock "$other" "$TMP_ROOT/override-state")
  assert_contains "$out" "lock acquired" "an override should acquire its lock"
  out=$(run_cmd "$other" FM_STATE_OVERRIDE="$TMP_ROOT/override-state" "$ROOT/bin/fm-control.sh" no-such-task interrupt) || true
  assert_not_contains "$out" "is a copy of" "an override must match its own identity"
  [ ! -e "$other/state/.home-id" ] || fail "an override's identity belongs in the override"
  cp -R "$TMP_ROOT/override-state" "$TMP_ROOT/override-copy"
  out=$(run_cmd "$other" FM_STATE_OVERRIDE="$TMP_ROOT/override-copy" "$ROOT/bin/fm-control.sh" sm1 interrupt) || true
  assert_contains "$out" "is a copy of" "a copied override must still read as a copy"

  # A deliberately moved home clears the refusal by deleting the marker.
  marker="$TMP_ROOT/override-copy/.home-id"
  rm -f "$marker"
  out=$(run_cmd "$other" FM_STATE_OVERRIDE="$TMP_ROOT/override-copy" "$ROOT/bin/fm-control.sh" no-such-task interrupt) || true
  assert_not_contains "$out" "is a copy of" "deleting the marker should clear the refusal"

  # A marker that cannot be read cannot prove ownership.
  rm -f "$marker"
  ln -s /nonexistent "$marker"
  out=$(run_cmd "$other" FM_STATE_OVERRIDE="$TMP_ROOT/override-copy" "$ROOT/bin/fm-control.sh" sm1 interrupt) || true
  assert_contains "$out" "cannot prove it owns" "an unreadable marker must refuse"
  pass "guard: the original, an unmarked fixture, and a state override pass; a copied override and an unreadable marker refuse"
}

test_lock_records_identity_and_never_launders_a_copy
test_copy_refuses_every_endpoint_action_with_one_line
test_guard_passes_the_original_fixtures_and_overrides

echo "# all fm-home-identity tests passed"
