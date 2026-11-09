#!/usr/bin/env bash
# Behavior test: every verified harness's launch template resolves completely
# through bin/fm-spawn.sh's real substitution path.
#
# Why this exists: a template placeholder whose substitution arm is lost reaches
# the pane as a literal word, so the launch dies at
# `env: '__DROIDBIN__': No such file or directory` before the worker starts
# (2026-11-09: commit f84d5be1 added the cline arm by REPLACING the droid arm, so
# every droid spawn died at launch). The arm table is one line per adapter and
# easy to clobber, so this suite sweeps the whole verified adapter list rather
# than the harness of the day.
#
# Each case runs the REAL bin/fm-spawn.sh against the fake tmux pane, so the
# launch command is composed and captured with no agent started, and asserts the
# rendered command carries no surviving `__NAME__` token. The adapters that gate
# their first launch on pane readiness (kimi, rovo, agy, hermes, cline,
# polytoken) render before that gate, so their spawn may then report the fake
# pane as not ready: the rendered launch is what this suite judges, and it fails
# when no launch was rendered at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-placeholders)
# Node backs the adapters' own probes and firstmate's hook writers, and test
# runners do not keep it in the system bin dirs.
NODE_BIN=$(command -v node) || fail "test needs node"
BASE_PATH=${FM_TEST_BASE_PATH:-$(dirname "$NODE_BIN"):/usr/bin:/bin:/usr/sbin:/sbin}

# Every harness binary answers the probes a spawn makes on it (version, model
# catalog, help identity, settings lookups) and refuses to run a session, so a
# spawn can never start a real agent from this suite.
make_harness_fakebin() {  # <dir>
  local dir=$1 fakebin name
  fakebin=$(make_spawn_fakebin "$dir")
  for name in claude codex opencode pi pi-signed grok kimi cursor-agent gemini \
    muse rovo omp agy devin commandcode polytoken cortex kiro-cli droid hermes cline; do
    cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version|version) printf '99.0.0\n'; exit 0 ;;
  --help) printf 'Start the Cursor Agent\n--tui-mode\n--approve\n'; exit 0 ;;
  models) printf 'fake-model-high\tFake (High)\n'; exit 0 ;;
  exec) printf 'tool one\n'; exit 0 ;;
  config)
    [ "${2:-}" = path ] && printf '%s\n' "$HOME/.hermes/config.yaml"
    [ "${2:-}" = get ] && printf '{}\n'
    exit 0
    ;;
  print)
    [ "${2:-}" = models ] && printf 'fake-model\nfake-model(low)\nfake-model(high)\n'
    exit 0
    ;;
esac
exit 0
SH
    chmod +x "$fakebin/$name"
  done
  printf '%s\n' "$fakebin"
}

# Per-adapter state a spawn requires before it composes a launch: Kimi's managed
# config, Muse's stored credential, Hermes's profile config, and Polytoken's
# global mirror source.
seed_harness_state() {  # <spawn-home>
  local spawn_home=$1
  mkdir -p "$spawn_home/.kimi-code" "$spawn_home/.config/muse" \
    "$spawn_home/.hermes" "$spawn_home/.config/polytoken"
  printf '\n' > "$spawn_home/.kimi-code/config.toml"
  printf '{"apiKey":"fake"}\n' > "$spawn_home/.config/muse/auth.json"
  printf 'model: fake\n' > "$spawn_home/.hermes/config.yaml"
  printf 'default_permission_matcher: bypass_plus\n' > "$spawn_home/.config/polytoken/config.yaml"
}

make_case() {  # <name> <harness> <id> -> "<case>|<home>|<proj>|<wt>|<fakebin>"
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_harness_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_test_spawn_brief "$home" "$id"
  printf '\nDelivery contract: mode=local-only\n' >> "$home/data/$id/brief.md"
  seed_harness_state "$home/user-home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  # shellcheck disable=SC2034 # the whole shared record shape is read here
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <home> <pane> <fakebin> <spawn-args...>
  local home=$1 pane=$2 fakebin=$3
  shift 3
  FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_AGY_READY_POLLS=2 FM_AGY_POLL_INTERVAL=0 FM_AGY_MODELS_TIMEOUT=1 \
    FM_CLINE_READY_POLLS=2 FM_CLINE_POLL_INTERVAL=0 \
    FM_DROID_READY_POLLS=2 FM_DROID_POLL_INTERVAL=0 \
    FM_HERMES_READY_POLLS=2 FM_HERMES_POLL_INTERVAL=0 \
    FM_KIMI_READY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    FM_POLYTOKEN_READY_POLLS=2 FM_POLYTOKEN_POLL_INTERVAL=0 \
    FM_ROVO_READY_POLLS=2 FM_ROVO_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    fm_test_run_spawn "$home" "$pane" "$fakebin" "$@"
}

# One render per verified adapter. The adapter list is read from the control
# plane's canonical verified-harness source, so a newly verified adapter joins
# this sweep automatically and cannot be added without one.
test_every_verified_harness_renders_without_a_placeholder() {
  local harness rec out left rendered=0 case_args
  while read -r harness; do
    [ -n "$harness" ] || continue
    rec=$(make_case "render-$harness" "$harness" "placeholder-$harness-$$")
    read_case "$rec"
    case_args=(--harness "$harness" --mode local-only --yolo off)
    [ "$harness" = polytoken ] && case_args+=(--model fake-model --effort low)
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "placeholder-$harness-$$" "$PROJ_DIR" "${case_args[@]}")
    if [ ! -s "$CASE_DIR/launch.log" ]; then
      fail "$harness spawn rendered no launch command, so its template was never substitution-checked: $out"
    fi
    rendered=$((rendered + 1))
    left=$(grep -o '__[A-Z][A-Z0-9_]*__' "$CASE_DIR/launch.log" | sort -u | tr '\n' ' ')
    if [ -n "$left" ]; then
      fail "$harness launch left placeholder(s) unsubstituted: $left"
    fi
  done < <(fm_control_harnesses)
  [ "$rendered" -ge 20 ] \
    || fail "only $rendered adapter launches were rendered; the sweep covered too little to trust"
  pass "fm-spawn.sh: every verified harness launch renders with no surviving placeholder"
}

# The regression this suite was written for, end to end: droid's launch names the
# resolved executable and the per-task files the substitution arms own, rather
# than leaving the template's tokens for the pane to fail on.
test_droid_launch_names_its_resolved_binary_and_task_files() {
  local rec out launch state
  rec=$(make_case "droid-e2e" droid "placeholder-droid-e2e-$$")
  read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "placeholder-droid-e2e-$$" "$PROJ_DIR" --harness droid --mode local-only --yolo off)
  expect_code 0 $? "a droid spawn must render and launch: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  state="$HOME_DIR/state"
  assert_contains "$launch" "$FAKEBIN_DIR/droid" \
    "droid launch did not name its resolved executable"
  assert_contains "$launch" "HOME='$state/placeholder-droid-e2e-$$.droid-home'" \
    "droid launch did not name its isolated per-task home"
  assert_contains "$launch" "--settings '$state/placeholder-droid-e2e-$$.droid-settings.json'" \
    "droid launch did not name its per-task runtime settings file"
  assert_contains "$launch" "Your role contract is the launch brief" \
    "droid launch did not carry the worker-role system-prompt pin"
  assert_contains "$launch" "--auto high" "droid launch lost its unattended autonomy"
  [ -s "$state/placeholder-droid-e2e-$$.droid-settings.json" ] \
    || fail "droid spawn did not write the runtime settings file its launch names"
  pass "fm-spawn.sh: droid launch carries its resolved binary and per-task files"
}

test_every_verified_harness_renders_without_a_placeholder
test_droid_launch_names_its_resolved_binary_and_task_files
