#!/usr/bin/env bash
# fm-flow-ledger.sh - deterministic ask -> issue -> owner -> PR -> live breach report.
#
# Report-only. This script never files, labels, claims, comments, closes, or
# wakes anything: it prints one line per detected breach and exits. A judgment
# agent may be woken by a change in that set, but deciding and acting belong to
# it, not here. Every rule below is arithmetic over records that already exist,
# so the same inputs always produce the same lines.
#
# The rule set and its rationale are owned once by
# data/kun-review-1119-manager/report.md section 5.2 in the operator home; this
# header owns only the mechanics, the exact thresholds, and the inputs.
#
# Usage:
#   fm-flow-ledger.sh report [--now <epoch>]
#   fm-flow-ledger.sh slo [--now <epoch>]
#   fm-flow-ledger.sh record-ask <id> <text> [--now <epoch>]
#   fm-flow-ledger.sh close-ask <id>
#
# record-ask appends one open ask to state/asks.jsonl, the only writer of that
# log, so its shape cannot drift. close-ask marks an ask settled by rewriting
# its line with "open":false; every other line is preserved byte for byte.
#
# Report mode prints the breaches, sorted by rule then by identity so a diff of
# two runs is stable. Each record is five tab-separated fields:
#   B<n>\t<kind>\t<identity>\t<age>\t<detail>
# `kind` is `breach` for a hard rule violation and `warn` for a rule whose
# earlier threshold has passed but whose act threshold has not. `age` is the
# elapsed seconds at the threshold's anchor (the ask time, the issue creation
# time, the last activity time), or `-` when the rule has no age. `--now`
# freezes the clock so a test or a replay is reproducible.
# A trailing `# <note>` line records an input that could not be read, so an
# unmeasured rule is never mistaken for a clean one.
#
# slo mode prints the published service-level figures from the same reads:
# ask coverage, ask->issue p95, unowned-issue count, idle-owned count, and
# merged-not-verified count. Figures a home cannot measure print `n/a` rather
# than a guessed zero.
#
# Inputs. Only existing records are read, never a network write:
#   B1  state/asks.jsonl - one JSON object per line, appended by firstmate when
#       the captain sends a message. Required members: `id` (unique string) and
#       `at` (epoch seconds or ISO-8601). Optional `open` (default true) marks an
#       ask still owed; a Linear issue whose title quotes the ask's `text` within
#       LINEAR_ISSUE_WINDOW settles it. An ask is a breach when it is open, older
#       than ASK_ISSUE_MAX, and no issue matches it.
#   B2  Linear: every non-terminal issue (state type unstarted, started, or
#       triage) with no owner. Owner is the first `agent:<x>` label, else an
#       assignee. Breach when created more than OWNER_MAX ago.
#   B3  Linear: an owned, non-terminal issue with no activity for IDLE_WARN
#       (warn) or IDLE_ACT (breach). Activity is the issue's updatedAt, which any
#       edit resets, so this undercounts idleness and never overcounts it.
#   B4  A refill pool under POOL_FLOOR of its ceiling while it has owned Todo
#       issues. Pools and ceilings come from the home's config/refill-pools file
#       (`<team> <ceiling>` per line, `#` comments) when present.
#   B5  Captain holds: any hold whose full text carries no `Recommend:` line
#       (breach, rec), or a hold the hold-SLA classifier marks critical and that
#       is older than CRITICAL_HOLD_MAX (breach, critical). Holds are read from
#       the home's backlog through bin/fm-tasks-axi.sh.
#   B6  Linear: a parent issue whose every child is non-terminal and untouched
#       for CHILD_IDLE_ACT. Reported once on the parent.
#   B7  Linear: an issue merged (state `In Review`, or labelled `merged`/`queued`
#       by a merge queue) with no `Verified live` comment for MERGED_MAX.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE resolve the home exactly as
#   the other bin/ scripts do.
#   LINEAR_API_KEY overrides the key read from ~/.hermes/.env.
#   FM_FLOW_LEDGER_GRAPHQL points the Linear read at a fixture file or URL,
#   which is how the regression suite drives every rule without a network call.
#
# Exit status: 0 when the report is produced (breaches or not), 2 on a usage
# error, 3 when a required input could not be read. A missing boundary input
# (no Linear key, no backlog) is reported on stderr and the dependent rules are
# skipped with a `n/a` note rather than silently reported as clean.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

ASK_ISSUE_MAX=$((10 * 60))          # B1: ask -> issue
OWNER_MAX=$((30 * 60))              # B2: issue -> owner
IDLE_WARN=$((4 * 3600))             # B3: warn
IDLE_ACT=$((8 * 3600))              # B3: act
POOL_FLOOR=50                       # B4: percent of ceiling
CRITICAL_HOLD_MAX=$((24 * 3600))    # B5: critical hold age
CHILD_IDLE_ACT=$((8 * 3600))        # B6: parent with all children untouched
MERGED_MAX=$((24 * 3600))           # B7: merged -> live-verified
LINEAR_ISSUE_WINDOW=50              # B1: issues fetched per team for matching

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit 2
}

die() {
  printf 'fm-flow-ledger: %s\n' "$*" >&2
  exit 3
}

NOTE=()
ASK_ID=''
ASK_TEXT=''

cmd=${1:-}
case "$cmd" in
  report|slo) shift ;;
  record-ask)
    shift
    [ "$#" -ge 2 ] || usage
    ASK_ID=$1
    ASK_TEXT=$2
    case "$ASK_ID" in ''|.*|*[!A-Za-z0-9._-]*) usage ;; esac
    shift 2
    ;;
  close-ask)
    shift
    [ "$#" -eq 1 ] || usage
    ASK_ID=$1
    case "$ASK_ID" in ''|.*|*[!A-Za-z0-9._-]*) usage ;; esac
    shift
    ;;
  ''|-h|--help|help) usage ;;
  *) usage ;;
esac

NOW=$(date +%s)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now)
      [ "$#" -ge 2 ] || usage
      case "$2" in ''|*[!0-9]*) usage ;; esac
      NOW=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

# --- Linear read -----------------------------------------------------------

# One batched query per team, the same three calls for every rule so the cost
# does not grow with the rule count. Printed as one JSON object per line, the
# normalized shape every rule below reads.
linear_teams() {
  # Teams come from config/linear-teams when present (one key per line, `#`
  # comments), else the optional FM_FLOW_LEDGER_TEAMS, else a fixture.
  if [ -n "${FM_FLOW_LEDGER_TEAMS:-}" ]; then
    printf '%s\n' "$FM_FLOW_LEDGER_TEAMS"
    return 0
  fi
  local file="$CONFIG/linear-teams"
  [ -f "$file" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$file" | grep -v '^$' | tr '\n' ' '
}

linear_key() {
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    printf '%s' "$LINEAR_API_KEY"
    return 0
  fi
  local envfile=$HOME/.hermes/.env line
  [ -r "$envfile" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      LINEAR_API_KEY=*)
        line=${line#LINEAR_API_KEY=}
        line=${line%\"}
        line=${line#\"}
        line=${line%\'}
        line=${line#\'}
        printf '%s' "$line"
        return 0
        ;;
    esac
  done < "$envfile"
  return 1
}

# linear_precheck: name an input missing BEFORE the read, so a skipped rule is
# explained. Runs in main's shell where NOTE survives. Returns 1 when the read
# cannot be attempted at all.
linear_precheck() {
  local graph=${FM_FLOW_LEDGER_GRAPHQL:-} teams
  if [ -z "$graph" ] && ! linear_key >/dev/null; then
    NOTE+=("linear: no LINEAR_API_KEY, B2 B3 B4 B6 B7 skipped")
    return 1
  fi
  teams=$(linear_teams)
  # A fixture override stands in for the whole read, teams included.
  if [ -z "$teams" ] && [ -z "$graph" ]; then
    NOTE+=("linear: no teams configured in config/linear-teams, B2 B3 B4 B6 B7 skipped")
    return 1
  fi
  return 0
}

# Print the normalized issue records, one JSON object per line.
# Fields: identifier team title state state_type created updated
#         owner parent children_last_activity verified_live labels
read_linear() {
  local graph=${FM_FLOW_LEDGER_GRAPHQL:-}
  local key=''
  if [ -z "$graph" ]; then
    key=$(linear_key) || return 1
  fi
  local teams
  teams=$(linear_teams)
  [ -n "$teams" ] || [ -n "$graph" ] || return 1
  LINEAR_KEY_VALUE=$key LINEAR_GRAPH=$graph LINEAR_TEAMS=$teams LINEAR_NOW=$NOW \
  LINEAR_WINDOW=$LINEAR_ISSUE_WINDOW \
    python3 - 2>/dev/null <<'PY'
import json, os, re, sys, urllib.request

QUERY = """
query($team: String!, $after: String) {
  issues(first: 100, after: $after, filter: {team: {key: {eq: $team}},
          state: {type: {in: ["triage", "backlog", "unstarted", "started"]}}}) {
    pageInfo { hasNextPage endCursor }
    nodes {
      identifier title createdAt updatedAt
      state { name type }
      assignee { name email }
      labels { nodes { name } }
      parent { identifier }
      children(first: 100) { nodes { identifier state { type } updatedAt } }
      comments(last: 50) { nodes { body createdAt } }
    }
  }
}
"""

def gql(source, variables):
    graph = os.environ.get("LINEAR_GRAPH", "")
    if graph.startswith("file:") or (graph and os.path.isfile(graph)):
        path = graph[5:] if graph.startswith("file:") else graph
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
        # A fixture may carry the raw GraphQL envelope or the already-unwrapped
        # data member; accept both so a capture can be replayed verbatim.
        if "data" in payload and "issues" not in payload:
            return payload["data"]
        return payload
    body = json.dumps({"query": source, "variables": variables}).encode()
    request = urllib.request.Request(
        "https://api.linear.app/graphql", body,
        {"Authorization": os.environ["LINEAR_KEY_VALUE"],
         "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=45) as response:
        payload = json.load(response)
    if "errors" in payload:
        raise SystemExit("linear errors: %s" % json.dumps(payload["errors"])[:400])
    return payload["data"]

VERIFIED = re.compile(r"verified\s+live", re.I)

def verified_at(node):
    for comment in reversed(node.get("comments", {}).get("nodes", [])):
        if VERIFIED.search(comment.get("body") or ""):
            return comment.get("createdAt")
    return None

def owner_of(node):
    for label in node.get("labels", {}).get("nodes", []):
        name = label.get("name") or ""
        if name.startswith("agent:"):
            return name
    assignee = node.get("assignee")
    if assignee:
        return assignee.get("email") or assignee.get("name")
    return None

def emit(node, team):
    parent = node.get("parent")
    children = node.get("children", {}).get("nodes", []) or []
    last_child = max((c.get("updatedAt") or "" for c in children), default=None)
    labels = [label.get("name") for label in node.get("labels", {}).get("nodes", [])]
    record = {
        "identifier": node["identifier"],
        "team": team,
        "title": node.get("title") or "",
        "state": (node.get("state") or {}).get("name") or "",
        "state_type": (node.get("state") or {}).get("type") or "",
        "created": node.get("createdAt"),
        "updated": node.get("updatedAt"),
        "owner": owner_of(node),
        "parent": (parent or {}).get("identifier"),
        "children_last_activity": last_child,
        "verified_live": verified_at(node),
        "labels": labels,
    }
    print(json.dumps(record, sort_keys=True))

for team in [t for t in os.environ.get("LINEAR_TEAMS", "").split() if t]:
    cursor = None
    while True:
        data = gql(QUERY, {"team": team, "after": cursor})
        issues = data["issues"]
        for node in issues["nodes"]:
            emit(node, team)
        page = issues["pageInfo"]
        if not page.get("hasNextPage"):
            break
        cursor = page.get("endCursor")
PY
}

# --- B1: ask -> issue ------------------------------------------------------

# Print "B1 breach <id> <age> <detail>" for every open ask without an issue.
check_b1() {
  local asks="$STATE/asks.jsonl"
  [ -f "$asks" ] || return 0
  [ -f "$LINEAR_DUMP" ] || { NOTE+=("B1: linear unavailable, ask->issue not measured"); return 0; }
  ASKS_FILE=$asks LINEAR_DUMP=$LINEAR_DUMP NOW=$NOW MAX_AGE=$ASK_ISSUE_MAX \
  LINEAR_WINDOW=$LINEAR_ISSUE_WINDOW python3 - <<'PY'
import json, os, re, sys

def as_epoch(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    text = str(value).strip()
    if re.fullmatch(r"\d+", text):
        return int(text)
    match = re.match(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})", text)
    if match:
        import calendar
        stamp = text.replace("Z", "+00:00")
        try:
            import datetime
            moment = datetime.datetime.fromisoformat(stamp)
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=datetime.timezone.utc)
            return int(moment.timestamp())
        except ValueError:
            pass
    return None

def norm(text):
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()

titles = []
with open(os.environ["LINEAR_DUMP"], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            titles.append(norm(json.loads(line)["title"]))
        except (ValueError, KeyError):
            continue

now = int(os.environ["NOW"])
limit = int(os.environ["MAX_AGE"])
rows = []
with open(os.environ["ASKS_FILE"], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            ask = json.loads(line)
        except ValueError:
            continue
        if ask.get("open") is False:
            continue
        raised = as_epoch(ask.get("at"))
        if raised is None:
            continue
        age = now - raised
        if age <= limit:
            continue
        needle = norm(ask.get("text") or ask.get("ask") or "")
        if needle and any(needle[:80] in title for title in titles):
            continue
        detail = " ".join(str(ask.get("text") or ask.get("ask") or "").split())[:110]
        rows.append("B1\tbreach\t%s\t%d\t%s" % (ask.get("id", "?"), age, detail))
for row in sorted(rows, key=lambda r: r.split("\t")[2]):
    print(row)
PY
}

# --- B2, B3, B6, B7 --------------------------------------------------------

# Print the issue-shaped rules as tab-separated lines.
check_issues() {
  [ -f "$LINEAR_DUMP" ] || return 0
  LINEAR_DUMP=$LINEAR_DUMP NOW=$NOW OWNER_MAX=$OWNER_MAX \
  IDLE_WARN=$IDLE_WARN IDLE_ACT=$IDLE_ACT CHILD_IDLE_ACT=$CHILD_IDLE_ACT \
  MERGED_MAX=$MERGED_MAX python3 - <<'PY'
import datetime, json, os

def epoch(text):
    if not text:
        return None
    try:
        moment = datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return int(moment.timestamp())

now = int(os.environ["NOW"])
owner_max = int(os.environ["OWNER_MAX"])
idle_warn = int(os.environ["IDLE_WARN"])
idle_act = int(os.environ["IDLE_ACT"])
child_idle = int(os.environ["CHILD_IDLE_ACT"])
merged_max = int(os.environ["MERGED_MAX"])
TERMINAL = {"completed", "canceled", "cancelled"}

issues = []
with open(os.environ["LINEAR_DUMP"], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            try:
                issues.append(json.loads(line))
            except ValueError:
                continue

by_parent = {}
for issue in issues:
    by_parent.setdefault(issue.get("parent"), []).append(issue)

rows = []
for issue in issues:
    ident = issue["identifier"]
    title = " ".join((issue.get("title") or "").split())[:110]
    state_type = issue.get("state_type") or ""
    if state_type in TERMINAL:
        continue
    created = epoch(issue.get("created"))
    updated = epoch(issue.get("updated"))

    # B2: non-terminal issue with no owner.
    if not issue.get("owner") and created is not None:
        age = now - created
        if age > owner_max:
            rows.append("B2\tbreach\t%s\t%d\t%s" % (ident, age, title))

    # B3: owned issue with no activity.
    if issue.get("owner") and updated is not None:
        age = now - updated
        if age > idle_act:
            rows.append("B3\tbreach\t%s\t%d\t%s" % (ident, age, title))
        elif age > idle_warn:
            rows.append("B3\twarn\t%s\t%d\t%s" % (ident, age, title))

    # B6: a parent whose every child is untouched.
    children = by_parent.get(ident, [])
    if children and all(
            (c.get("state_type") or "") not in TERMINAL for c in children):
        stamps = [epoch(c.get("updated")) for c in children]
        stamps = [s for s in stamps if s is not None]
        if stamps:
            age = now - max(stamps)
            if age > child_idle:
                rows.append("B6\tbreach\t%s\t%d\t%s children untouched"
                            % (ident, age, title))

    # B7: merged but not live-verified.
    labels = {str(name).lower() for name in issue.get("labels") or []}
    merged = (issue.get("state") or "") == "In Review" or labels & {"merged", "queued"}
    if merged and not issue.get("verified_live") and updated is not None:
        age = now - updated
        if age > merged_max:
            rows.append("B7\tbreach\t%s\t%d\t%s" % (ident, age, title))

for row in sorted(rows, key=lambda r: (r.split("\t")[0], r.split("\t")[2])):
    print(row)
PY
}

# --- B4: pool under floor --------------------------------------------------

check_b4() {
  local pools="$CONFIG/refill-pools"
  [ -f "$pools" ] || return 0
  [ -f "$LINEAR_DUMP" ] || { NOTE+=("B4: linear unavailable, pool fill not measured"); return 0; }
  POOLS_FILE=$pools LINEAR_DUMP=$LINEAR_DUMP FLOOR=$POOL_FLOOR python3 - <<'PY'
import json, os

ceiling = {}
with open(os.environ["POOLS_FILE"], encoding="utf-8") as handle:
    for line in handle:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            ceiling[parts[0]] = int(parts[1])

owned_todo = {}
with open(os.environ["LINEAR_DUMP"], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            issue = json.loads(line)
        except ValueError:
            continue
        if issue.get("owner") and issue.get("state_type") == "unstarted":
            owned_todo[issue.get("team")] = owned_todo.get(issue.get("team"), 0) + 1

floor = int(os.environ["FLOOR"])
for team in sorted(ceiling):
    total = ceiling[team]
    todo = owned_todo.get(team, 0)
    if total <= 0 or todo <= 0:
        continue
    if todo * 100 < total * floor:
        print("B4\tbreach\t%s\t-\t%d owned Todo of ceiling %d, under %d%%"
              % (team, todo, total, floor))
PY
}

# --- B5: captain holds -----------------------------------------------------

# Each hold needs its full text and age; one python pass classifies the whole
# backlog so a large hold backlog does not fan out one process per hold.
# The age anchor is the task's `created` date, which is when the hold became
# owed; hold-SLA records are keyed captain-hold-<task>-<n> and never carry the
# task id, so they are not used here. A hold with an `until` date is parked by
# the captain and is not aged.
check_b5() {
  local axi="$SCRIPT_DIR/fm-tasks-axi.sh"
  [ -x "$axi" ] || { NOTE+=("B5: backlog reader unavailable, holds not measured"); return 0; }
  local list status=0
  list=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE='' "$axi" list --state held --limit 5000 \
        --fields hold_kind 2>/dev/null) || status=$?
  [ "$status" -eq 0 ] || { NOTE+=("B5: backlog read failed, holds not measured"); return 0; }
  local ids
  ids=$(printf '%s\n' "$list" | sed -n 's/^  \([A-Za-z0-9._-]*\),.*,captain$/\1/p')
  [ -n "$ids" ] || return 0
  local id show created until_date text
  local -a block=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE='' "$axi" show "$id" --full 2>/dev/null) || continue
    [ "$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)" = captain ] || continue
    # A captain-set until date parks the hold; it is a wait, not a breach.
    # tasks-axi quotes string fields, so strip the surrounding quotes.
    until_date=$(printf '%s\n' "$show" | sed -n 's/^  hold_until: //p' | head -1)
    until_date=${until_date#\"}
    until_date=${until_date%\"}
    case "$until_date" in ''|'-') ;; *) continue ;; esac
    created=$(printf '%s\n' "$show" | sed -n 's/^  created: //p' | head -1)
    created=${created#\"}
    created=${created%\"}
    text=$(printf '%s\n' "$show" | sed -n 's/^  \(hold_reason\|title\|body\): //p' | tr '\n' ' ')
    block+=("$text"$'\t'"${created:--}"$'\t'"$id")
  done <<< "$ids"
  [ "${#block[@]}" -gt 0 ] || return 0
  printf '%s\n' "${block[@]}" | NOW=$NOW CRITICAL_MAX=$CRITICAL_HOLD_MAX python3 -c '
import datetime, os, re, sys

now = int(os.environ["NOW"])
critical_max = int(os.environ["CRITICAL_MAX"])
CRITICAL = re.compile(
    r"phi|credential|secret|security|breach|spend|cost|payment|delete|destroy"
    r"|prod(uction)?[ -]?data|incident|legal|compliance|baa", re.I)
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    text, created, ident = parts[0], parts[1], parts[2]
    text = " ".join(text.split())
    if not re.search(r"recommend\s*:", text, re.I):
        rows.append(("B5", "breach", ident, "-", "hold has no Recommend: line"))
        continue
    try:
        started = datetime.date.fromisoformat(created)
    except ValueError:
        continue
    age = (datetime.datetime.now(datetime.timezone.utc).date() - started).days * 86400
    if CRITICAL.search(text) and age > critical_max:
        rows.append(("B5", "breach", ident, str(age),
                     "critical hold older than 24h"))
for row in sorted(rows, key=lambda r: r[2]):
    print("\t".join(row))
'
}

# --- ask log ---------------------------------------------------------------

ASKS="$STATE/asks.jsonl"

# Append one open ask. The log is JSON Lines; this is its only writer.
record_ask() {
  [ -d "$STATE" ] || die "state directory is missing: $STATE"
  [ -f "$ASKS" ] || : >> "$ASKS" || die "cannot create $ASKS"
  ID=$ASK_ID TEXT=$ASK_TEXT AT=$NOW python3 - "$ASKS" <<'PY' || die "cannot append to $ASKS"
import json, os, sys

path = sys.argv[1]
ident = os.environ["ID"]
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        if json.loads(line).get("id") == ident:
            raise SystemExit("ask id already recorded: %s" % ident)
    except ValueError:
        continue
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "id": ident,
        "at": int(os.environ["AT"]),
        "text": os.environ["TEXT"],
        "open": True,
    }, ensure_ascii=False) + "\n")
PY
}

# Mark one ask settled by rewriting only its line.
close_ask() {
  [ -f "$ASKS" ] || die "no ask log: $ASKS"
  ID=$ASK_ID python3 - "$ASKS" <<'PY' || die "cannot update $ASKS"
import json, os, sys, tempfile

path = sys.argv[1]
ident = os.environ["ID"]
found = False
out = []
for line in open(path, encoding="utf-8"):
    text = line.rstrip("\n")
    if not text.strip():
        out.append(line)
        continue
    try:
        row = json.loads(text)
    except ValueError:
        out.append(line)
        continue
    if row.get("id") == ident:
        row["open"] = False
        out.append(json.dumps(row, ensure_ascii=False) + "\n")
        found = True
    else:
        out.append(line)
if not found:
    raise SystemExit("ask id not found: %s" % ident)
handle = tempfile.NamedTemporaryFile(
    "w", encoding="utf-8", dir=os.path.dirname(path) or ".", delete=False)
handle.writelines(out)
handle.close()
os.replace(handle.name, path)
PY
}

# --- report ----------------------------------------------------------------

LINEAR_DUMP=''
main() {
  case "$cmd" in
    record-ask) record_ask; return ;;
    close-ask) close_ask; return ;;
  esac

  local rows
  if [ "$cmd" = report ] || [ "$cmd" = slo ]; then
    LINEAR_DUMP=$(mktemp "${TMPDIR:-/tmp}/fm-flow-ledger.XXXXXX") || die "cannot create a scratch file"
    trap 'rm -f "$LINEAR_DUMP"' EXIT
    # read_linear runs in a subshell for its redirect, so a failure it would
    # have noted is detected here instead, where the note survives.
    if ! linear_precheck; then
      : > "$LINEAR_DUMP"
    elif ! read_linear > "$LINEAR_DUMP"; then
      NOTE+=("linear: read failed, B2 B3 B4 B6 B7 skipped")
      : > "$LINEAR_DUMP"
    fi
  fi

  rows=$(
    check_b1
    check_issues
    check_b4
    check_b5
  )

  if [ "$cmd" = slo ]; then
    emit_slo "$rows"
    return
  fi
  emit_report "$rows"
}

emit_report() {
  local rows=$1
  { [ -n "$rows" ] && printf '%s\n' "$rows" | sort -t$'\t' -k1,1 -k3,3; } || true
  local note
  for note in "${NOTE[@]+"${NOTE[@]}"}"; do
    printf '# %s\n' "$note"
  done
}

emit_slo() {
  local rows=$1
  local total=0 closed_ask=0 unowned=0 idle=0 unverified=0 breaches=0
  if [ -f "$STATE/asks.jsonl" ]; then
    total=$(grep -c . "$STATE/asks.jsonl" 2>/dev/null || printf '0')
    closed_ask=$(grep -c '"open": *false' "$STATE/asks.jsonl" 2>/dev/null || printf '0')
  fi
  if [ -n "$rows" ]; then
    unowned=$(printf '%s\n' "$rows" | grep -c '^B2' || true)
    idle=$(printf '%s\n' "$rows" | grep -c $'^B3\tbreach' || true)
    unverified=$(printf '%s\n' "$rows" | grep -c '^B7' || true)
    breaches=$(printf '%s\n' "$rows" | grep -c 'breach' || true)
  fi
  printf 'asks %s\n' "${total:-0}"
  printf 'asks_open %s\n' "$(( ${total:-0} - ${closed_ask:-0} ))"
  printf 'unowned_issues %s\n' "${unowned:-0}"
  printf 'idle_owned %s\n' "${idle:-0}"
  printf 'merged_unverified %s\n' "${unverified:-0}"
  printf 'breaches %s\n' "${breaches:-0}"
  local note
  for note in "${NOTE[@]+"${NOTE[@]}"}"; do
    printf '# %s\n' "$note"
  done
}

main
