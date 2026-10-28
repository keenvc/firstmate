#!/usr/bin/env bash
# Portable Factory Droid worker adapter regression.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$ROOT/bin/fm-quota-axi-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-droid-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI

mkdir -p "$TMP_ROOT/names" "$TMP_ROOT/psbin"
for name in droid droid-helper; do ln -s /bin/bash "$TMP_ROOT/names/$name"; done
real_ps=$(command -v ps)
cat > "$TMP_ROOT/psbin/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"ppid="*"-p \${FM_TEST_STOP_PID:-0}"*|*"-p \${FM_TEST_STOP_PID:-0}"*"ppid="*) printf '1\n' ;;
  *) exec "$real_ps" "\$@" ;;
esac
EOF
chmod +x "$TMP_ROOT/psbin/ps"
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/droid" -c 'FM_TEST_STOP_PID=$$ PATH="$2:$PATH" "$1"; :' _ "$HARNESS" "$TMP_ROOT/psbin")
[ "$out" = droid ] || fail "native Droid ancestry must beat foreign CLAUDECODE: $out"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/droid-helper" -c 'FM_TEST_STOP_PID=$$ PATH="$2:$PATH" "$1" ancestry "$$"; :' _ "$HARNESS" "$TMP_ROOT/psbin")
[ "$out" != 'comm droid' ] || fail "unrelated droid-helper claimed the adapter"
[ "$(fm_agent_process_classify_name /home/azureuser/.local/bin/droid)" = agent ] || fail "liveness lost Droid"
[ "$(fm_agent_process_classify_name droid-helper)" = other ] || fail "liveness claims unrelated executable"
[ "$(fm_quota_single_provider_for_harness droid)" = factory ] || fail "quota single provider for droid must be factory"
[ "$(fm_quota_provider_for_harness droid)" = factory ] || fail "quota provider for droid must be factory"
pass "Droid native identity, anchored liveness, and factory quota mapping"

[ "$(fm_control_interrupt_key droid)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat droid)" = 1 ] || fail 'Droid uses single Escape'
[ -z "$(fm_control_interrupt_clear_key droid)" ] || fail 'Droid must not erase a composer draft'
[ "$(fm_control_exit_command droid)" = /quit ] || fail 'wrong exit command'
fm_control_harness_supports_kind droid ship || fail 'ship refused'
fm_control_harness_supports_kind droid scout || fail 'scout refused'
! fm_control_harness_supports_kind droid secondmate || fail 'secondmate accepted'
pass "worker-only resolution and lifecycle capabilities"

[ "$(fm_composer_classify_content 1 '> Enter to steer · Ctrl+Enter to queue' "$FM_COMPOSER_IDLE_RE_DEFAULT" sensitive '' 1 0)" = empty ] || fail 'Droid active-turn placeholder not empty'
[ "$(fm_composer_classify_content 1 '> unsubmitted draft')" = pending ] || fail 'typed draft not preserved'
for signal in '⠋ Running command... (Press ESC to stop)' '│ > Enter to steer · Ctrl+Enter to queue │'; do
  printf '%s\n' "$signal" | fm_busy_lines_match droid || fail "independent delivery signal lost: $signal"
done
! printf '> unsubmitted draft\n' | fm_busy_lines_match droid || fail 'draft read busy'
! printf 'esc to cancel\n' | fm_busy_lines_match droid || fail 'borrowed another harness signal'
pass "composer draft safety and independent delivery signals"

state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
"$ROOT/bin/fm-droid-settings.sh" "$state" worker "$gen" glm-5.1 high || fail 'settings writer failed'
settings="$state/worker.droid-settings.json"
jq -e '
  .includeCoAuthoredByDroid == false and
  .sessionDefaultSettings.autonomyLevel == "high" and
  .sessionDefaultSettings.autonomyMode == "auto-high" and
  .sessionDefaultSettings.interactionMode == "auto" and
  .sessionDefaultSettings.model == "glm-5.1" and
  .sessionDefaultSettings.reasoningEffort == "high"
' "$settings" >/dev/null || fail 'runtime settings missing expected fields'
run_hook() { bash -c "$(jq -r --arg event "$1" '.hooks[$event][-1].hooks[0].command' "$settings")"; }
run_hook UserPromptSubmit
[ "$(fm_busy_classify tmux fake:w droid worker "$state")" = 'busy droid-hook' ] || fail 'submit did not open busy'
run_hook Stop
[ "$(fm_busy_classify tmux fake:w droid worker "$state")" = 'idle droid-hook' ] || fail 'Stop did not settle'
assert_present "$state/worker.turn-ended" 'Stop notification absent'
run_hook UserPromptSubmit
run_hook SessionEnd
[ "$(fm_busy_classify tmux fake:w droid worker "$state")" = 'idle droid-hook' ] || fail 'SessionEnd did not settle'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook Stop
[ "$(fm_busy_classify tmux fake:w droid worker "$state")" = 'busy fm-spawn' ] || fail 'stale Stop cleared replacement'
assert_absent "$state/worker.turn-ended" 'stale Stop woke replacement'
[ "$(fm_control_harness_wiring_paths droid /unused "$state" worker)" = "$settings" ] || fail 'settings retirement missing'
FM_KEEP_AI_TRAILERS=1 "$ROOT/bin/fm-droid-settings.sh" "$state" worker "$gen" default xhigh || fail 'keep-ai-trailers settings writer failed'
jq -e '(has("includeCoAuthoredByDroid") | not) and (.sessionDefaultSettings | has("model") | not) and (.sessionDefaultSettings | has("reasoningEffort") | not)' "$settings" >/dev/null \
  || fail 'keep-ai-trailers or default/xhigh omission failed'
pass "runtime settings writer, lifecycle hooks, and stale-generation rejection"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" droid
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" droid
fm_git_worktree "$proj" "$wt" droid-test
fm_test_spawn_brief "$home" droid-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" droid-worker "$proj" --scout --harness droid --model glm-5.1 --effort high 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" '--auto high' 'autonomy flag missing'
assert_contains "$launch" "--settings '$home/state/droid-worker.droid-settings.json'" 'runtime settings flag missing'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
assert_grep 'model=glm-5.1' "$home/state/droid-worker.meta" 'model not recorded'
assert_grep 'effort=high' "$home/state/droid-worker.meta" 'effort not recorded'
assert_present "$home/state/droid-worker.droid-settings.json" 'spawn did not write droid settings'
[ "$(fm_busy_classify tmux fake:w droid droid-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" droid-sm "$proj" --secondmate --harness droid 2>&1)
then fail 'Droid secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal'
pass "scout launch carries --auto high, runtime settings, typed brief, and hooks"
