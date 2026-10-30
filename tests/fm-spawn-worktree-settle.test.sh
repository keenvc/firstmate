#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
window_file="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.window"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  capture-pane) [ ! -f "${FM_FAKE_PANE_TEXT:-}" ] || cat "$FM_FAKE_PANE_TEXT"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0 ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_PANE_TEXT="${PANE_TEXT_FILE:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_unborn_head_project_is_refused_at_once() {
  local rec id out status started elapsed
  id=settle-unborn-head-z5
  rec=$(make_settle_case settle-unborn "$id" 0)
  read_settle_record "$rec"
  PROJ_DIR="$TMP_ROOT/settle-unborn/unborn-project"
  git init -q "$PROJ_DIR"

  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "spawn into a project with no commit should be refused"
  assert_contains "$out" "unborn HEAD" "the refusal did not name the unborn HEAD cause"
  assert_contains "$out" "make one commit" "the refusal did not name the remedy"
  [ "$elapsed" -lt 30 ] || fail "refusal took ${elapsed}s instead of failing before the treehouse wait"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ -z "$(git -C "$PROJ_DIR" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the project"
  pass "a project with an unborn HEAD is refused at once with its cause named"
}

# run_refusal_case <name> <id> <stale_reads> <pane-text>: a pane reporting the
# repository primary for <stale_reads> reads, with <pane-text> as its contents.
# The pane texts below are the shape real treehouse v3.1.7 draws, wrapped at 80
# columns, with no error prefix on its refusals.
run_refusal_case() {
  local name=$1 id=$2 stale_reads=$3 text=$4 rec
  rec=$(make_primary_case "$name" "$id" "$stale_reads")
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  PANE_TEXT_FILE="$TMP_ROOT/$name/pane-text"
  printf '%s\n' "$text" > "$PANE_TEXT_FILE"
  OUT=$(run_settle_spawn "$id")
  STATUS=$?
  READS=$(cat "$COUNTFILE")
  PANE_TEXT_FILE=
}

test_pool_full_refusal_stops_the_wait() {
  local id=settle-pool-full-z6
  run_refusal_case settle-pool-full "$id" 100000 "user@host:~/proj\$ treehouse get
🌳 Setting up worktree...
all 48 worktrees are in use, dirty, or not provably this clone's (max_trees = 48
). Run 'treehouse status' to see details, or increase max_trees in treehouse.tom
l
user@host:~/proj\$"

  [ "$STATUS" -ne 0 ] || fail "spawn succeeded with a full treehouse pool"$'\n'"$OUT"
  assert_contains "$OUT" "treehouse get refused to acquire a worktree" "the refusal did not say treehouse refused"
  assert_contains "$OUT" "all 48 worktrees are in use, dirty, or not provably this clone's" \
    "the refusal did not carry treehouse's own text"
  assert_not_contains "$OUT" "did not enter an isolated worktree" "the refusal waited out the window"
  [ "$READS" -le 3 ] || fail "pool-full refusal took $READS pane reads instead of stopping at once"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a full treehouse pool stops the wait at once with treehouse's own text"
}

test_pool_full_text_alone_stops_the_wait() {
  local id=settle-pool-full-noprompt-z7
  run_refusal_case settle-pool-full-noprompt "$id" 100000 "treehouse get
🌳 Setting up worktree...
all 2 worktrees are in use or dirty (max_trees = 2). Run 'treehouse status'"

  [ "$STATUS" -ne 0 ] || fail "spawn succeeded with a full treehouse pool"$'\n'"$OUT"
  assert_contains "$OUT" "all 2 worktrees are in use or dirty" "the refusal did not carry treehouse's own text"
  [ "$READS" -le 3 ] || fail "pool-full refusal took $READS pane reads instead of stopping at once"
  pass "the pool-full text stops the wait even before a prompt is recognizable"
}

test_other_error_at_prompt_stops_the_wait() {
  local id=settle-bad-base-z8
  run_refusal_case settle-bad-base "$id" 100000 "lab\$ treehouse get
🌳 Setting up worktree...
base branch \"nope\" does not exist: no local branch nope and
no remote-tracking branch origin/nope (fetch first, or fix base_branch/--base)
lab\$"

  [ "$STATUS" -ne 0 ] || fail "spawn succeeded after treehouse refused"$'\n'"$OUT"
  assert_contains "$OUT" 'base branch "nope" does not exist' "the refusal did not carry treehouse's own text"
  assert_not_contains "$OUT" "lab\$ " "the refusal quoted the shell prompt as treehouse's text"
  [ "$READS" -le 3 ] || fail "error refusal took $READS pane reads instead of stopping at once"
  pass "any treehouse text followed by the original prompt stops the wait at once"
}

# A healthy slow acquire has not returned to its prompt, whatever scrolled past
# before the command, including an earlier pool-full refusal in the same pane.
test_slow_healthy_acquire_still_waits() {
  local id=settle-slow-healthy-z9
  run_refusal_case settle-slow-healthy "$id" 25 "lab\$ treehouse get
all 9 worktrees are in use or dirty (max_trees = 9).
lab\$ treehouse get
🌳 Setting up worktree...
Fetching origin
Preparing worktree (detached HEAD)"

  expect_code 0 "$STATUS" "a slow healthy acquire should still reach its worktree"$'\n'"$OUT"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "meta did not record the settled worktree"
  [ "$READS" -gt 25 ] || fail "the wait ended after only $READS reads"
  pass "a slow healthy acquire still waits, and older pane text cannot refuse it"
}

# A successful acquire draws its subshell at the same prompt, and a backend's cwd
# report can trail that prompt. The announcement keeps it from reading as refused.
test_entered_worktree_prompt_is_not_a_refusal() {
  local id=settle-entered-z10
  run_refusal_case settle-entered "$id" 5 "lab\$ treehouse get
🌳 Setting up worktree...
🌳 Entered worktree at ~/.treehouse/proj/1/proj. Type 'exit' to return.
lab\$"

  expect_code 0 "$STATUS" "a successful acquire whose cwd report trails its prompt should succeed"$'\n'"$OUT"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "meta did not record the settled worktree"
  pass "a successful acquire's subshell prompt is not mistaken for a refusal"
}

# A bare prompt with no treehouse output is not a refusal either: the command may
# not have started. It falls through to the deadline with the existing text.
test_true_timeout_keeps_its_refusal_text() {
  local id=settle-timeout-z11
  run_refusal_case settle-timeout "$id" 100000 "lab\$ treehouse get
🌳 Setting up worktree...
lab\$"

  [ "$STATUS" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$OUT"
  assert_contains "$OUT" "treehouse get did not enter an isolated worktree within 180s" \
    "the true timeout lost its refusal text"
  assert_not_contains "$OUT" "refused to acquire" "a pane with no treehouse text was reported as refused"
  pass "the true timeout keeps its existing refusal text"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_unborn_head_project_is_refused_at_once
test_pool_full_refusal_stops_the_wait
test_pool_full_text_alone_stops_the_wait
test_other_error_at_prompt_stops_the_wait
test_slow_healthy_acquire_still_waits
test_entered_worktree_prompt_is_not_a_refusal
test_true_timeout_keeps_its_refusal_text

echo "# all fm-spawn-worktree-settle tests passed"
