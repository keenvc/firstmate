#!/usr/bin/env bash
# tests/fm-mgr-dispatch.test.sh - behavior tests for bin/fm-mgr-dispatch.py, the
# ranked-queue dispatcher (NIC-3380).
#
# Every test runs the real script as a subprocess against fixture Linear data
# injected through the dispatcher's `reader_cmd` seam: the command prints a
# queue document on stdout and every write is logged to a file. No test reaches
# the network or touches Linear.
#
# The issues each fixture serves are passed in as JSON with no promise about
# their order, so dispatch order has to come from the ranking and never from
# the fixture's arrival order.
#
# Covered here: order is (priority, sortOrder) for a shuffled queue; an empty
# queue refuses; a task with no Linear issue is refused, logged and never
# started; a non-Linear key is refused; WIP 1 refuses a second In Progress claim
# until the first is In Review; an unowned Urgent issue blocks non-Urgent
# claims and is offered first; `check` exits non-zero for unowned Urgent and
# for a lane over WIP 1 and zero when clean; `claim --dry-run` writes nothing
# and a real claim writes exactly In Progress, agent:<lane> and the lease
# comment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISPATCH="$ROOT/bin/fm-mgr-dispatch.py"
TMP_ROOT=$(fm_test_tmproot fm-mgr-dispatch-tests)
FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
WRITES="$TMP_ROOT/writes.log"
: > "$WRITES"

if ! command -v python3 >/dev/null 2>&1; then
  printf '1..1\nok - fm-mgr-dispatch: skipped, python3 is not installed\nFM_TEST_COMPLETE\n'
  exit 0
fi

# The reader seam: the dispatcher runs this command and reads a queue document
# from its stdout. FM_MGR_QUEUE is a JSON object {team: [issue, ...]}.
cat > "$FAKEBIN/queue-reader" <<'PY'
#!/usr/bin/env python3
import json, os, sys
teams = [t.strip().upper() for t in os.environ.get("FM_MGR_TEAMS", "ADC,NIC,FDC").split(",") if t.strip()]
doc = json.load(open(os.environ["FM_MGR_QUEUE"]))
# Every call is counted so a test can prove which subcommands bypass the cache.
count = os.environ.get("FM_MGR_READS")
if count:
    with open(count, "a") as f:
        f.write("read\n")
print(json.dumps({"teams": {t: doc.get(t, []) for t in teams}}))
PY
chmod +x "$FAKEBIN/queue-reader"

# The writer seam: records every mutation and echoes it back.
cat > "$FAKEBIN/queue-writer" <<'PY'
#!/usr/bin/env python3
import json, os, sys
op = json.loads(sys.stdin.read() or "{}")
with open(os.environ["FM_MGR_WRITES"], "a") as f:
    f.write(json.dumps(op, sort_keys=True) + "\n")
print(json.dumps({"ok": True}))
PY
chmod +x "$FAKEBIN/queue-writer"

# dispatch <queue-json-file> <args...> - run the dispatcher against a fixture.
# Prints stdout, then stderr after a banner, then exits with the dispatcher's code.
# Every call starts from an empty cache and an empty write log, because issues
# are identified and not ids: a stale cache would answer this fixture with the
# last one's board, and a stale write log would credit this call with an earlier
# call's writes.
dispatch() {
  local queue=$1
  shift
  local out rc
  rm -rf "$TMP_ROOT/state"
  : > "$WRITES"
  out=$(FM_MGR_QUEUE="$queue" FM_MGR_WRITES="$WRITES" \
        FM_MGR_READER="$FAKEBIN/queue-reader" FM_MGR_WRITER="$FAKEBIN/queue-writer" \
        FM_MGR_DISPATCH_STATE="$TMP_ROOT/state" \
        python3 "$DISPATCH" "$@" 2>&1)
  rc=$?
  printf '%s\n' "$out"
  return $rc
}

# dispatch_keep_cache <queue-json-file> <reads-log> <args...> - like dispatch,
# but keeps the cache and the write log between calls, so a test can see that a
# second call re-read the board rather than answering from the first call's
# cached copy. Every read the script makes is appended to <reads-log>.
dispatch_keep_cache() {
  local queue=$1 reads=$2
  shift 2
  local out rc
  out=$(FM_MGR_QUEUE="$queue" FM_MGR_WRITES="$WRITES" FM_MGR_READS="$reads" \
        FM_MGR_READER="$FAKEBIN/queue-reader" FM_MGR_WRITER="$FAKEBIN/queue-writer" \
        FM_MGR_DISPATCH_STATE="$TMP_ROOT/state" \
        python3 "$DISPATCH" "$@" 2>&1)
  rc=$?
  printf '%s\n' "$out"
  return $rc
}

# issue <identifier> <priority> <sortOrder> <state> [labels-csv]
issue() {
  python3 - "$@" <<'PY'
import json, sys
ident, priority, sort, state = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
labels = [l for l in (sys.argv[5].split(",") if len(sys.argv) > 5 and sys.argv[5] else []) if l]
row = {"identifier": ident, "title": f"title for {ident}", "priority": priority,
       "state": json.loads(state) if state.startswith("{") else state,
       "labels": [{"name": l} for l in labels],
       "url": f"https://linear.app/x/issue/{ident.lower()}"}
# A `none` sortOrder reproduces the CLI's payload, which carries no sortOrder
# at all: the key is absent rather than null, exactly as a real client sends it.
if sort != "none":
    row["sortOrder"] = float(sort)
print(json.dumps(row))
PY
}

# queue <team>=<json-array-of-issues>... - write a fixture queue file.
queue() {
  local path=$1
  shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path, pairs = sys.argv[1], sys.argv[2:]
doc = {}
for pair in pairs:
    team, _, body = pair.partition("=")
    doc[team.upper()] = json.loads(body) if body else []
with open(path, "w") as f:
    json.dump(doc, f)
PY
}

state_json() {  # <state-name> -> {"name":..,"type":..}
  python3 - "$1" <<'PY'
import json, sys
name = sys.argv[1]
types = {"Todo": "unstarted", "Backlog": "backlog", "In Progress": "started",
         "In Review": "started", "Done": "completed", "Canceled": "canceled"}
print(json.dumps({"name": name, "type": types.get(name, "unstarted")}))
PY
}

assert_contains() {  # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3 (missing: $2; got: $1)" ;;
  esac
}

assert_not_contains() {  # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) fail "$3 (unexpected: $2; got: $1)" ;;
    *) pass "$3" ;;
  esac
}

assert_empty_writes() {  # <label>
  if [ -s "$WRITES" ]; then
    fail "$1 (wrote: $(cat "$WRITES"))"
  fi
  pass "$1"
}

# --- the tests --------------------------------------------------------------

# A shuffled fixture: the same issues arrive in an order that matches neither
# priority nor sortOrder, so only the ranking can produce the dispatch order.
Q_SHUFFLED="$TMP_ROOT/shuffled.json"
make_shuffled_queue() {
  queue "$Q_SHUFFLED" \
    "ADC=[$(issue ADC-10 3 -500 'Todo'),
           $(issue ADC-11 1 -10 'Todo'),
           $(issue ADC-12 2 -900 'Todo'),
           $(issue ADC-13 1 -40 'Todo'),
           $(issue ADC-14 0 -1 'Todo'),
           $(issue ADC-15 4 -9999 'Todo')]" \
    "NIC=[$(issue NIC-10 2 -100 'Todo'),
           $(issue NIC-11 1 -20 'Todo'),
           $(issue NIC-12 3 -700 'Todo')]" \
    "FDC=[$(issue FDC-10 2 -50 'Todo'),
           $(issue FDC-11 1 -30 'Todo')]"
}

t_order_is_priority_then_sortorder() {
  make_shuffled_queue
  local out
  out=$(dispatch "$Q_SHUFFLED" list) || fail "list exited non-zero: $out"
  local got want
  got=$(printf '%s\n' "$out" | awk '/^ +[0-9]+\./ {print $2}' | paste -sd' ')
  # Priority bands in order, and inside each band Linear's sortOrder ascending
  # (observed live: the top NIC issue has the largest negative sortOrder).
  #   Urgent: -40 ADC-13, -30 FDC-11, -20 NIC-11, -10 ADC-11
  #   High:  -900 ADC-12, -100 NIC-10, -50 FDC-10
  #   Medium: -700 NIC-12, -500 ADC-10   (Low: ADC-15)   (No priority: ADC-14)
  want='ADC-13 FDC-11 NIC-11 ADC-11 ADC-12 NIC-10 FDC-10 NIC-12 ADC-10 ADC-15 ADC-14'
  if [ "$got" = "$want" ]; then
    pass "list orders strictly by (priority, sortOrder) for a shuffled fixture"
  else
    fail "list order (want: $want; got: $got)"
  fi
}

t_next_equals_queue_head() {
  make_shuffled_queue
  local out queue_head
  out=$(dispatch "$Q_SHUFFLED" next lane-a) || fail "next exited non-zero: $out"
  queue_head=$(dispatch "$Q_SHUFFLED" list | awk '/^ +1\./ {print $2}')
  assert_contains "$out" "$queue_head" "next returns the head of the same queue list prints"
  assert_contains "$out" "ADC-13" "the top issue is the Urgent issue with the lowest sortOrder"
}

t_empty_queue_refuses() {
  local q="$TMP_ROOT/empty.json"
  queue "$q" "ADC=[]" "NIC=[]" "FDC=[]"
  local out rc=0
  out=$(dispatch "$q" next lane-a) || rc=$?
  if [ "$rc" -eq 1 ]; then pass "next refuses an empty queue with exit 1"; else fail "next exited $rc"; fi
  assert_contains "$out" "REFUSED" "the empty-queue refusal is stated"
  assert_contains "$out" "queue is empty" "the empty-queue reason is logged in the output"
}

t_claim_refuses_task_without_linear_issue() {
  make_shuffled_queue
  local out rc=0
  out=$(dispatch "$Q_SHUFFLED" claim lane-a backlog-1234) || rc=$?
  if [ "$rc" -eq 1 ]; then pass "claim refuses a task with no Linear issue"; else fail "claim exited $rc"; fi
  assert_contains "$out" "names no Linear issue" "the refusal says why a non-Linear task is refused"
  assert_contains "$out" "backlog.md" "the refusal names the local files that never start work"
  assert_empty_writes "a refused non-Linear claim writes nothing to Linear"
  local logged
  logged=$(FM_MGR_DISPATCH_STATE="$TMP_ROOT/state" python3 "$DISPATCH" log -n 50)
  assert_contains "$logged" "refused-claim" "the refusal reason is recorded in the dispatch log"
  assert_contains "$logged" "backlog-1234" "the log names the refused task"
}

t_claim_refuses_foreign_team_key() {
  make_shuffled_queue
  local out rc=0
  out=$(dispatch "$Q_SHUFFLED" claim lane-a AVALAN-12) || rc=$?
  if [ "$rc" -eq 1 ]; then pass "claim refuses a Linear key outside ADC/NIC/FDC"; else fail "claim exited $rc"; fi
  assert_contains "$out" "names no Linear issue" "the foreign-team key is refused for naming no managed issue"
  assert_empty_writes "a refused foreign-team claim writes nothing to Linear"
}

# WIP 1: the lane already holds NIC-11 In Progress. A new claim is refused, and
# it is allowed again once that issue is In Review.
t_wip_one_refuses_second_claim() {
  local q="$TMP_ROOT/wip.json"
  queue "$q" \
    "NIC=[$(issue NIC-11 1 -20 "{\"name\":\"In Progress\",\"type\":\"started\"}" 'agent:lane-a'),
           $(issue NIC-12 3 -700 'Todo')]" \
    "ADC=[]" "FDC=[]"
  local out rc=0
  out=$(dispatch "$q" claim lane-a NIC-12) || rc=$?
  if [ "$rc" -eq 1 ]; then pass "WIP 1 refuses a lane's second claim"; else fail "claim exited $rc"; fi
  assert_contains "$out" "WIP 1" "the refusal names the WIP rule"
  assert_contains "$out" "NIC-11" "the refusal names the issue the lane must finish first"
  assert_empty_writes "a WIP refusal writes nothing to Linear"

  local out2 rc2=0
  out2=$(dispatch "$q" next lane-a) || rc2=$?
  if [ "$rc2" -eq 1 ]; then pass "next refuses a lane at WIP 1"; else fail "next exited $rc2"; fi
  assert_contains "$out2" "at WIP 1" "next states the same WIP reason"

  queue "$q" \
    "NIC=[$(issue NIC-11 1 -20 "{\"name\":\"In Review\",\"type\":\"started\"}" 'agent:lane-a'),
           $(issue NIC-12 3 -700 'Todo')]" \
    "ADC=[]" "FDC=[]"
  local out3 rc3=0
  out3=$(dispatch "$q" claim lane-a NIC-12) || rc3=$?
  if [ "$rc3" -eq 0 ]; then pass "In Review releases the lane to claim again"; else fail "claim exited $rc3: $out3"; fi
  assert_contains "$out3" "claimed: NIC-12" "the second claim is granted once the first is In Review"
}

t_unowned_urgent_blocks_nonurgent() {
  local q="$TMP_ROOT/urgent.json"
  queue "$q" \
    "NIC=[$(issue NIC-11 1 -20 'Todo'),
           $(issue NIC-12 3 -9999 'Todo')]" \
    "ADC=[]" "FDC=[]"
  local out rc=0
  out=$(dispatch "$q" claim lane-a NIC-12) || rc=$?
  if [ "$rc" -eq 1 ]; then pass "an unowned Urgent issue blocks a non-Urgent claim"; else fail "claim exited $rc"; fi
  assert_contains "$out" "unowned Urgent" "the refusal names the blocking rule"
  assert_contains "$out" "NIC-11" "the refusal names the Urgent issue that must be taken first"
  assert_empty_writes "the blocked non-Urgent claim writes nothing to Linear"

  local out2
  out2=$(dispatch "$q" next lane-a) || fail "next should offer the Urgent issue: $out2"
  assert_contains "$out2" "NIC-11" "next offers the unowned Urgent issue rather than the non-Urgent head"

  local out3 rc3=0
  out3=$(dispatch "$q" claim lane-a NIC-11) || rc3=$?
  if [ "$rc3" -eq 0 ]; then pass "claiming the unowned Urgent issue is allowed"; else fail "claim exited $rc3: $out3"; fi
}

t_check_exit_codes() {
  local clean="$TMP_ROOT/clean.json"
  queue "$clean" "NIC=[$(issue NIC-12 3 -1 'Todo' 'agent:lane-a'),
                         $(issue NIC-13 2 -2 "{\"name\":\"In Progress\",\"type\":\"started\"}" 'agent:lane-b')]" \
    "ADC=[]" "FDC=[]"
  local out rc=0
  out=$(dispatch "$clean" check) || rc=$?
  if [ "$rc" -eq 0 ]; then pass "check exits 0 on a clean board"; else fail "check exited $rc: $out"; fi

  local over="$TMP_ROOT/over.json"
  queue "$over" "NIC=[$(issue NIC-12 3 -1 "{\"name\":\"In Progress\",\"type\":\"started\"}" 'agent:lane-a'),
                        $(issue NIC-13 2 -2 "{\"name\":\"In Progress\",\"type\":\"started\"}" 'agent:lane-a')]" \
    "ADC=[]" "FDC=[]"
  local out2 rc2=0
  out2=$(dispatch "$over" check) || rc2=$?
  if [ "$rc2" -eq 1 ]; then pass "check exits 1 for a lane over WIP 1"; else fail "check exited $rc2"; fi
  assert_contains "$out2" "lane-a" "check names the lane over WIP 1"
  assert_contains "$out2" "NIC-12" "check lists both of that lane's In Progress issues"

  local urgent="$TMP_ROOT/urgent-check.json"
  queue "$urgent" "NIC=[$(issue NIC-14 1 -5 'Todo')]" "ADC=[]" "FDC=[]"
  local out3 rc3=0
  out3=$(dispatch "$urgent" check) || rc3=$?
  if [ "$rc3" -eq 1 ]; then pass "check exits 1 for an unowned Urgent issue"; else fail "check exited $rc3"; fi
  assert_contains "$out3" "NIC-14" "check lists the unowned Urgent issue"
}

t_dry_run_writes_nothing_and_real_claim_writes_three() {
  local q="$TMP_ROOT/claim.json"
  queue "$q" "NIC=[$(issue NIC-12 3 -1 'Todo')]" "ADC=[]" "FDC=[]"
  local out rc=0
  out=$(dispatch "$q" claim lane-a NIC-12 --dry-run) || rc=$?
  if [ "$rc" -eq 0 ]; then pass "claim --dry-run exits 0"; else fail "dry-run exited $rc: $out"; fi
  assert_contains "$out" "would claim" "dry run says what it would do"
  assert_empty_writes "claim --dry-run writes nothing to Linear"

  local out2 rc2=0
  out2=$(dispatch "$q" claim lane-a NIC-12) || rc2=$?
  if [ "$rc2" -eq 0 ]; then pass "a real claim exits 0"; else fail "claim exited $rc2: $out2"; fi
  local writes
  writes=$(cat "$WRITES")
  assert_contains "$writes" '"state": "In Progress"' "the claim moves the issue to In Progress"
  assert_contains "$writes" 'agent:lane-a' "the claim labels ownership agent:<lane>"
  assert_contains "$writes" '"op": "label"' "the claim writes the ownership label"
  assert_contains "$writes" 'lease-until:' "the claim records a lease-until comment"
  local n
  n=$(grep -c . "$WRITES")
  if [ "$n" -eq 3 ]; then pass "the claim is exactly state, label and comment"; else fail "claim wrote $n operations"; fi
}

# A row without a numeric sortOrder cannot be ranked. Failing is the point:
# sorting it to the back would collapse a priority tier into identifier order
# and still look like a working queue.
t_row_without_sortorder_is_refused() {
  local q="$TMP_ROOT/nosortorder.json"
  queue "$q" \
    "NIC=[$(issue NIC-10 2 -100 'Todo'),
           $(issue NIC-11 2 none 'Todo')]" \
    "ADC=[]" "FDC=[]"
  local out rc=0
  out=$(dispatch "$q" list) || rc=$?
  if [ "$rc" -eq 2 ]; then pass "an unrankable row stops the queue with exit 2"; else fail "list exited $rc: $out"; fi
  assert_contains "$out" "no numeric sortOrder" "the failure names the missing sortOrder"
  assert_contains "$out" "NIC-11" "the failure names the row it cannot rank"

  local out2 rc2=0
  out2=$(dispatch "$q" next lane-a) || rc2=$?
  if [ "$rc2" -eq 2 ]; then pass "next fails too rather than offering an unranked issue"; else fail "next exited $rc2: $out2"; fi
}

# The write path and the alerting view must never answer from a cached board:
# a claim decided on a stale board could take an issue already finished or
# already taken, and check could report a lane as free while it is working.
t_claim_and_check_read_fresh() {
  local q="$TMP_ROOT/fresh.json" reads="$TMP_ROOT/reads.log"
  queue "$q" \
    "NIC=[$(issue NIC-10 2 -100 'Todo'),
           $(issue NIC-11 2 -200 'Todo')]" \
    "ADC=[]" "FDC=[]"
  rm -rf "$TMP_ROOT/state"
  : > "$reads"
  : > "$WRITES"

  local out
  out=$(dispatch_keep_cache "$q" "$reads" list) || fail "list exited non-zero: $out"
  local after_list
  after_list=$(grep -c . "$reads")

  out=$(dispatch_keep_cache "$q" "$reads" check) || fail "check exited non-zero: $out"
  local after_check
  after_check=$(grep -c . "$reads")
  if [ "$after_check" -gt "$after_list" ]; then
    pass "check re-reads the board instead of answering from the cache"
  else
    fail "check answered from the cache (reads before: $after_list, after: $after_check)"
  fi

  out=$(dispatch_keep_cache "$q" "$reads" claim lane-a NIC-10) || fail "claim exited non-zero: $out"
  local after_claim
  after_claim=$(grep -c . "$reads")
  if [ "$after_claim" -gt "$after_check" ]; then
    pass "claim re-reads the board instead of answering from the cache"
  else
    fail "claim answered from the cache (reads before: $after_check, after: $after_claim)"
  fi
}

# The label is written before the state change. An In Progress issue with no
# owner is the dangerous half-failure: it would be invisible to the Urgent gate
# and to WIP 1, and two lanes could then take the same work.
t_claim_labels_before_moving_state() {
  local q="$TMP_ROOT/order.json"
  queue "$q" "NIC=[$(issue NIC-12 3 -1 'Todo')]" "ADC=[]" "FDC=[]"
  local out
  out=$(dispatch "$q" claim lane-a NIC-12) || fail "claim exited non-zero: $out"
  local first second
  first=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).readline())['op'])" "$WRITES")
  second=$(python3 -c "import json,sys; print(json.loads(open(sys.argv[1]).readlines()[1])['op'])" "$WRITES")
  if [ "$first" = "label" ] && [ "$second" = "state" ]; then
    pass "the claim writes the ownership label before the In Progress state"
  else
    fail "claim write order (first: $first, second: $second)"
  fi
}

# A hand-back moves an issue to Todo or Backlog and leaves the claim label
# behind. The label alone is a stale record: reading it as ownership would keep
# the issue out of the Urgent gate and keep its lane stuck at WIP 1.
t_handed_back_issue_is_not_owned() {
  local q="$TMP_ROOT/handback.json"
  queue "$q" \
    "NIC=[$(issue NIC-11 1 -20 'Todo' 'agent:lane-b'),
           $(issue NIC-12 3 -9999 'Todo')]" \
    "ADC=[]" "FDC=[]"
  local out rc=0
  out=$(dispatch "$q" check) || rc=$?
  if [ "$rc" -eq 1 ]; then pass "check still sees a handed-back Urgent issue as unowned"; else fail "check exited $rc: $out"; fi
  assert_contains "$out" "UNOWNED URGENT" "the handed-back Urgent issue is reported unowned"
  assert_contains "$out" "NIC-11" "the handed-back Urgent issue is named"

  local out2
  out2=$(dispatch "$q" next lane-b) || fail "next exited non-zero: $out2"
  if printf '%s\n' "$out2" | grep -q '^NIC-11'; then
    pass "the handed-back Urgent issue is offered first, not treated as lane-b's work"
  else
    fail "next did not offer the handed-back Urgent issue: $out2"
  fi

  local out3 rc3=0
  out3=$(dispatch "$q" claim lane-b NIC-11) || rc3=$?
  if [ "$rc3" -eq 0 ]; then pass "lane-b can reclaim the issue it handed back"; else fail "claim exited $rc3: $out3"; fi
}

fm_test_run \
  t_order_is_priority_then_sortorder \
  t_next_equals_queue_head \
  t_empty_queue_refuses \
  t_claim_refuses_task_without_linear_issue \
  t_claim_refuses_foreign_team_key \
  t_wip_one_refuses_second_claim \
  t_unowned_urgent_blocks_nonurgent \
  t_check_exit_codes \
  t_dry_run_writes_nothing_and_real_claim_writes_three \
  t_row_without_sortorder_is_refused \
  t_claim_and_check_read_fresh \
  t_claim_labels_before_moving_state \
  t_handed_back_issue_is_not_owned
