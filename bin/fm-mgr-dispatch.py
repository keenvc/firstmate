#!/usr/bin/env python3
"""fm-mgr-dispatch.py - the ranked-queue dispatcher (Firstmate Manager, NIC-3380).

Linear is the only tracker. This script owns the one ranked queue across the
ADC, NIC and FDC teams and answers the question every lane, Firstmate and
SuperAgent asks before starting work: what may I start now, and why not.

  next  <lane>          Print the top eligible issue for a lane, or the refusal reason.
  claim <lane> <issue>  Take that issue: move it to In Progress and label it
                        `agent:<lane>`. The only writing subcommand; run by hand.
  check                 Report unowned Urgent issues and lanes over WIP 1.
  list                  Print the whole ranked queue in dispatch order.
  log                   Print recent dispatch records.

Queue order is Linear's own priority numbering (Urgent=1, High=2, Medium=3,
Low=4, No priority=0) and then Linear's manual sortOrder within each priority.
Nothing else orders the queue, so `list` shows exactly what `next` can return.

The rules this script enforces (spec 4a, approved 2026-11-19):

* Pull only. A task that names no open Linear issue in one of the teams is
  refused and logged. Nothing starts from backlog.md, the hold digest,
  tasks-axi or any other local file.
* WIP is one issue per lane. A lane holding an In Progress issue is refused
  until that issue reaches Done, In Review or another non-In-Progress state,
  or the lane hands it back with a reason comment.
* An unowned Urgent issue blocks new non-Urgent starts. Ownership is the
  `agent:<lane>` label and never the Linear assignee, because every agent
  writes through Nick's own account. While an Urgent issue has no owner, the
  dispatcher offers that Urgent issue first, and refuses any other claim.
* Every refusal prints one reason line and appends it to the dispatch log, so
  a quiet queue can never be mistaken for a filtered one.

Reads come from the Linear GraphQL API, the only source that returns the
numeric `sortOrder` this queue ranks by; the `linear` CLI does not return one,
so it is used for writes and never for reads. A row without a numeric
sortOrder, or a read that ends before its last page, is a hard failure rather
than a shorter or reshuffled board. Reads are cached under
FM_MGR_DISPATCH_STATE for FM_MGR_DISPATCH_TTL seconds (default 90) for `next`
and `list`; `claim`, the write path, and `check`, the alerting view, always
read fresh, and every claim drops the cache.

Lanes on a shared host may be team-scoped: `ADC:firstmate` keeps two homes that
both run a lane called `firstmate` apart on Linear, and a bare lane name is
written literally. A lane key shaped like a Linear identifier (ADC-1605) is
lower-cased so its label never collides with the claim ontology.

Exit status: `next` and `claim` exit 0 when they answer and 1 when they refuse;
`check` exits 1 when an unowned Urgent issue or a lane over WIP 1 exists; 2
means Linear could not be read or written at all.

Usage:
  fm-mgr-dispatch.py next <lane> [--json]
  fm-mgr-dispatch.py claim <lane> <issue> [--dry-run] [--lease-minutes N]
  fm-mgr-dispatch.py check [--json]
  fm-mgr-dispatch.py list [--priority P] [--team T] [--unowned] [--json]
  fm-mgr-dispatch.py log [-n N]

Environment:
  FM_MGR_TEAMS            comma-separated team keys (default ADC,NIC,FDC)
  FM_MGR_DISPATCH_STATE   cache and log directory (default <home>/state/manager)
  FM_MGR_DISPATCH_TTL     read-cache lifetime in seconds (default 90, <=0 disables)
  FM_MGR_LINEAR_BIN       the `linear` CLI (default: PATH, then ~/.cargo/bin/linear)
  LINEAR_API_KEY          GraphQL key for cache-miss reads; falls back to ~/.hermes/secrets/linear.env
  FM_MGR_READER           test seam: a command printing a queue document on stdout
  FM_MGR_WRITER           test seam: a command receiving claim operations on stdin
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

TEAMS = tuple(t.strip().upper()
              for t in os.environ.get("FM_MGR_TEAMS", "ADC,NIC,FDC").split(",") if t.strip())

# Linear's own priority scale, kept unchanged because it is the ranking.
PRIORITY_RANK = {1: 1, 2: 2, 3: 3, 4: 4, 0: 5}
PRIORITY_LABEL = {1: "Urgent", 2: "High", 3: "Medium", 4: "Low", 0: "No priority"}

CLAIM_LABEL = "agent:"
API = "https://api.linear.app/graphql"
DEFAULT_LEASE_MINUTES = 90

# Non-In-Progress started states. WIP is one issue per lane, and "In Review"
# is a finish for the lane: the work moved on and the lane is free again.
LANE_RELEASING_STATES = ("in review", "review", "in-review")

# Linear state types that mean work has begun. A claim is placed here, and only
# a started issue can be owned, so an issue handed back to Todo or Backlog
# drops its owner with the state change.
STARTED_TYPES = ("started", "in progress", "in-progress", "inprogress", "claimed",
                 "active", "in review", "review")

TEAM_QUERY = """
query($t:String!,$a:String){ teams(first:1, filter:{key:{eq:$t}}){
  nodes{
    key
    issues(first:100, after:$a, filter:{state:{type:{nin:["completed","canceled","duplicate"]}}}){
      pageInfo{hasNextPage endCursor}
      nodes{ id identifier title priority sortOrder url createdAt
             state{ id name type }
             labels(first:50){ nodes{ name } } } } } } }
"""


class Refusal(Exception):
    """The lane may not start this work. Printed, logged, exit 1."""


class LinearError(Exception):
    """Linear could not be read or written. Exit 2."""


# --------------------------------------------------------------------------
# Paths, log, cache
# --------------------------------------------------------------------------

def home():
    return os.environ.get("FIRSTMATE_HOME") or os.path.expanduser("~/firstmate")


def state_dir():
    d = os.environ.get("FM_MGR_DISPATCH_STATE") or os.path.join(home(), "state", "manager")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def log(event, **fields):
    """Append one JSON record. Never raises: the log is evidence, not a gate."""
    rec = {"at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "event": event}
    rec.update({k: v for k, v in fields.items() if v is not None})
    try:
        with open(os.path.join(state_dir(), "dispatch.log"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, sort_keys=True) + "\n")
    except OSError as e:
        print(f"warning: dispatch log unwritable: {e}", file=sys.stderr)


def _ttl():
    try:
        return int(os.environ.get("FM_MGR_DISPATCH_TTL", "90"))
    except ValueError:
        return 90


def _cache_path(team):
    return os.path.join(state_dir(), f"cache-{team}.json")


def cached(team):
    if _ttl() <= 0:
        return None
    try:
        with open(_cache_path(team), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    if doc.get("at", 0) + _ttl() < now:
        return None
    return doc.get("data")


def store(team, data):
    if _ttl() <= 0:
        return
    path = _cache_path(team)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".cache-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            stamp = datetime.datetime.now(datetime.timezone.utc).timestamp()
            json.dump({"at": stamp, "data": data}, f)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def drop_cache():
    for team in TEAMS:
        try:
            os.unlink(_cache_path(team))
        except OSError:
            pass


# --------------------------------------------------------------------------
# Linear transport
# --------------------------------------------------------------------------

def _linear_bin():
    explicit = os.environ.get("FM_MGR_LINEAR_BIN")
    if explicit:
        return explicit
    found = shutil.which("linear")
    if found:
        return found
    cargo = os.path.expanduser("~/.cargo/bin/linear")
    if os.access(cargo, os.X_OK):
        return cargo
    raise LinearError("the `linear` CLI is not on PATH (set FM_MGR_LINEAR_BIN)")


def _api_key():
    key = os.environ.get("LINEAR_API_KEY")
    if key:
        return key.strip()
    try:
        with open(os.path.expanduser("~/.hermes/secrets/linear.env"), encoding="utf-8") as f:
            for line in f:
                if line.startswith("LINEAR_API_KEY="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    raise LinearError("no LINEAR_API_KEY in the environment or ~/.hermes/secrets/linear.env")


def gql(query, variables):
    import urllib.error
    import urllib.request
    req = urllib.request.Request(
        API, json.dumps({"query": query, "variables": variables}).encode(),
        {"Authorization": _api_key(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            out = json.load(r)
    except urllib.error.HTTPError as e:
        raise LinearError(f"Linear API HTTP {e.code}") from e
    except (urllib.error.URLError, OSError) as e:
        raise LinearError(f"Linear API unreachable: {e}") from e
    if out.get("errors"):
        raise LinearError(f"Linear API error: {json.dumps(out['errors'])[:300]}")
    return out["data"]


def run_linear(args):
    """Run the `linear` CLI non-interactively; return its stdout.

    Never passes --json, whose shape is the CLI's own business: every value the
    dispatcher depends on is read through the GraphQL contract below."""
    writer = os.environ.get("FM_MGR_WRITER")
    if writer:
        return _write_seam(writer, args)
    try:
        out = subprocess.run([_linear_bin()] + args, capture_output=True, text=True,
                             timeout=180, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise LinearError(f"`linear {' '.join(args[:2])}` failed: {e}") from e
    if out.returncode != 0:
        raise LinearError(f"`linear {' '.join(args[:2])}` exited {out.returncode}: "
                          f"{(out.stderr or out.stdout).strip()[:300]}")
    return out.stdout


def _write_seam(writer, args):
    """Tests receive the claim's operations here instead of reaching Linear.

    One JSON operation per line: {"op": state|label|comment, "issue": ..., ...}."""
    if args[:2] == ["issue", "update"]:
        if "--state" in args:
            op = {"op": "state", "issue": args[2], "state": args[args.index("--state") + 1]}
        elif "--add-label" in args:
            op = {"op": "label", "issue": args[2], "label": args[args.index("--add-label") + 1]}
        elif "--label" in args:
            # A full-set label write would strip every other label; only the
            # additive form is ever allowed to reach Linear.
            raise LinearError("refusing --label: it replaces the whole label set; use --add-label")
        else:
            raise LinearError(f"unsupported update: {args}")
    elif args[:3] == ["issue", "comment", "create"]:
        op = {"op": "comment", "issue": args[3], "body": args[args.index("--body") + 1]
              if "--body" in args else ""}
    else:
        raise LinearError(f"unsupported write: {args}")
    try:
        out = subprocess.run(writer, shell=True, capture_output=True, text=True, timeout=60,
                             input=json.dumps(op), )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise LinearError(f"writer {writer!r} failed: {e}") from e
    if out.returncode != 0:
        raise LinearError(f"writer {writer!r} exited {out.returncode}: "
                          f"{(out.stderr or out.stdout).strip()[:300]}")
    return out.stdout


def read_team(team):
    """Every open issue of one team, or a hard failure.

    One source only: the GraphQL API, because ranking needs each row's
    numeric `sortOrder` and the `linear` CLI's issue query does not return one.
    A CLI fallback would answer with every issue inside a priority tier tied
    and ordered by identifier, so it is deliberately not used for reads:
    ranking fails closed rather than reading a board it cannot order right.
    The CLI is still what performs writes, and it is what supplies the API
    credential for an operator who logged in there."""
    reader = os.environ.get("FM_MGR_READER")
    if reader:
        return _read_team_seam(reader, team)
    return _read_team_api(team)


def _read_team_seam(reader, team):
    """Tests inject fixture data here, exactly as the CLI and API do."""
    try:
        out = subprocess.run(reader, shell=True, capture_output=True, text=True,
                             timeout=120, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise LinearError(f"reader {reader!r} failed: {e}") from e
    if out.returncode != 0:
        raise LinearError(f"reader {reader!r} exited {out.returncode}: "
                          f"{(out.stderr or out.stdout).strip()[:300]}")
    try:
        doc = json.loads(out.stdout)
    except ValueError as e:
        raise LinearError(f"reader {reader!r} printed no JSON") from e
    issues = (doc.get("teams") or {}).get(team) or []
    return {"key": team, "issues": [_norm_issue(i) for i in issues if _is_open(i)]}


MAX_PAGES = 20


def _read_team_api(team):
    """Every open issue of one team, or LinearError: never a partial board.

    A truncated read is the dangerous failure here: a missed Urgent issue
    silently opens the Urgent gate, and a missed In Progress issue silently
    frees a lane that is still working, so an unfinished pagination ends in
    LinearError rather than a shorter list."""
    nodes, after = [], None
    pages = 0
    while True:
        found = gql(TEAM_QUERY, {"t": team, "a": after}).get("teams", {}).get("nodes") or []
        if not found:
            raise LinearError(f"no {team} team in the workspace")
        page = found[0].get("issues")
        if not isinstance(page, dict) or "nodes" not in page or "pageInfo" not in page:
            raise LinearError(f"{team}: Linear returned a malformed issue page")
        nodes += page["nodes"]
        pages += 1
        info = page["pageInfo"] or {}
        if not info.get("hasNextPage"):
            return {"key": team, "issues": [_norm_issue(i) for i in nodes]}
        after = info.get("endCursor")
        if not after:
            raise LinearError(f"{team}: Linear reported another page with no cursor")
        if pages >= MAX_PAGES:
            raise LinearError(f"{team}: partial read after {MAX_PAGES} pages of "
                              f"{len(nodes)} issues; ranking refuses a truncated board")


def _state_of(i):
    """The issue's state as {name, type}, whatever source shape carried it.

    The CLI and the seam can hand back a bare name string where GraphQL returns
    a state object, so both are accepted and normalized here."""
    st = i.get("state")
    if isinstance(st, str):
        return {"name": st, "type": _state_type_of_name(st)}
    if not isinstance(st, dict):
        return {"name": "", "type": ""}
    return {"name": st.get("name") or "", "type": (st.get("type") or "").lower()}


def _state_type_of_name(name):
    n = (name or "").strip().lower()
    if n in ("done", "completed"):
        return "completed"
    if n in ("canceled", "cancelled"):
        return "canceled"
    if n == "duplicate":
        return "duplicate"
    if n == "backlog":
        return "backlog"
    if n == "triage":
        return "triage"
    if n in ("in progress", "in-progress", "inprogress", "started", "claimed", "active",
             "in review", "review"):
        return "started"
    return "unstarted"


def _is_open(issue):
    st = _state_of(issue)
    if st["type"] in ("completed", "canceled", "duplicate"):
        return False
    return st["name"].strip().lower() not in ("done", "canceled", "cancelled", "duplicate")


def _norm_issue(i):
    """One issue in the shape the rules read, from either source.

    The GraphQL API and the CLI disagree here: GraphQL returns
    `labels: {nodes: [{name}]}` and the CLI returns `labels: [{name}]`."""
    st = _state_of(i)
    labels = i.get("labels")
    if isinstance(labels, dict):
        labels = labels.get("nodes") or []
    names = []
    for label in labels or []:
        if isinstance(label, str):
            names.append(label)
        elif isinstance(label, dict) and label.get("name"):
            names.append(str(label["name"]))
    return {
        "id": i.get("id"),
        "identifier": i.get("identifier"),
        "title": i.get("title") or "",
        "priority": i.get("priority"),
        "sortOrder": i.get("sortOrder"),
        "url": i.get("url"),
        "state": st,
        "labels": names,
    }


def load_board(use_cache=True):
    """{team: [issue, ...]} for every configured team, in no particular order."""
    board = {}
    for team in TEAMS:
        data = cached(team) if use_cache else None
        if data is None:
            data = read_team(team)
            store(team, data)
        board[team] = data["issues"]
    return board


# --------------------------------------------------------------------------
# The ranking, and the facts the rules read
# --------------------------------------------------------------------------

def priority_rank(issue):
    try:
        return PRIORITY_RANK.get(int(issue.get("priority")), 5)
    except (TypeError, ValueError):
        return 5


def priority_label(issue):
    try:
        return PRIORITY_LABEL.get(int(issue.get("priority")), "No priority")
    except (TypeError, ValueError):
        return "No priority"


def rank_key(issue):
    """(priority, sortOrder, identifier). Linear's sortOrder is the tie-break,
    and the identifier only ever separates two issues Linear itself left tied.

    A row without a numeric sortOrder raises instead of sorting to the back:
    otherwise one unreadable field silently collapses a priority tier into
    identifier order, which looks like a working queue and is not one."""
    so = issue.get("sortOrder")
    if isinstance(so, bool) or not isinstance(so, (int, float)):
        raise LinearError(f"{issue.get('identifier') or 'an issue'} has no numeric sortOrder "
                          f"({so!r}); the queue cannot be ranked without one")
    return (priority_rank(issue), so, issue.get("identifier") or "")


def ordered(board):
    """Every open issue of every team in strict queue order, each tagged with its team."""
    out = []
    for team in TEAMS:
        for issue in board[team]:
            out.append(dict(issue, team=team))
    return sorted(out, key=rank_key)


def owners_of(issue):
    """The lanes that own this issue, or none if it is not owned any more.

    A hand-back moves the issue back to Todo or Backlog and leaves the claim
    label behind, so a label on an unstarted issue is a stale record rather
    than an owner: counting it would keep the issue out of the Urgent gate and
    keep a lane at WIP 1 for work nobody is doing. Ownership therefore reads
    as the label AND the issue still being started."""
    if state_type(issue) not in STARTED_TYPES:
        return []
    labels = issue.get("labels") or []
    return [n[len(CLAIM_LABEL):] for n in labels
            if n.startswith(CLAIM_LABEL) and len(n) > len(CLAIM_LABEL)]


def state_name(issue):
    return ((issue.get("state") or {}).get("name") or "").strip()


def state_type(issue):
    return ((issue.get("state") or {}).get("type") or "").strip().lower()


def is_urgent(issue):
    try:
        return int(issue.get("priority")) == 1
    except (TypeError, ValueError):
        return False


def is_in_progress(issue):
    """True while the issue is the lane's one WIP item.

    A team may rename In Progress, so its name is matched first and its type
    second; In Review is never WIP because it releases the lane to take the
    next issue."""
    name = state_name(issue).lower()
    if name in LANE_RELEASING_STATES or state_type(issue) in ("completed", "canceled", "duplicate"):
        return False
    if name in ("in progress", "in-progress", "inprogress", "started", "claimed", "active"):
        return True
    return state_type(issue) == "started"


def wip_issues(board, lane):
    """The issues this lane holds In Progress. More than one means over WIP."""
    return [i for i in ordered(board) if lane in owners_of(i) and is_in_progress(i)]


def unowned_urgent(board):
    """Unowned Urgent issues across all managed teams, in queue order."""
    return [i for i in ordered(board) if is_urgent(i) and not owners_of(i)]


def normalize_lane(lane):
    """A lane name as it is written on Linear. See the header for the two forms."""
    lane = str(lane or "").strip()
    if not lane:
        return ""
    head, _, _ = lane.partition("-")
    if "-" in lane and head.upper() in TEAMS and lane.rsplit("-", 1)[-1].isdigit():
        return lane.lower()
    team, sep, name = lane.partition(":")
    if sep and team.upper() in TEAMS and name.strip():
        return f"{team.upper()}:{name.strip()}"
    return lane


def as_linear_key(text):
    """The Linear issue a task really names, or None.

    Pull-only in practice: a task id or brief that does not resolve to an open
    issue in one of the managed teams is not something this queue can start."""
    cand = str(text or "").strip().upper()
    head, sep, tail = cand.partition("-")
    if not sep or head not in TEAMS or not tail.isdigit():
        return None
    return cand


def describe(issue):
    return f"{issue['identifier']}  {priority_label(issue)}  {issue.get('title') or ''}"


# --------------------------------------------------------------------------
# next
# --------------------------------------------------------------------------

def select_next(board, lane):
    """The top issue this lane may start now, with the facts behind it.

    Raises Refusal carrying the exact reason when it may start nothing."""
    held = wip_issues(board, lane)
    if held:
        names = ", ".join(f"{i['identifier']} ({state_name(i) or 'In Progress'})" for i in held)
        raise Refusal(f"lane {lane} is at WIP 1: {names} is still In Progress; it reaches Done or "
                      "In Review, or is handed back with a reason comment, before another claim")

    queue = ordered(board)
    if not queue:
        raise Refusal(f"the queue is empty: no open issue in {', '.join(TEAMS)}")

    urgent = [i for i in queue if is_urgent(i) and not owners_of(i)]
    if urgent:
        pick = urgent[0]
        why = [f"unowned Urgent blocks every new non-Urgent start: {len(urgent)} Urgent issue(s) "
               f"have no owner",
               f"top unowned Urgent in queue order: {pick['identifier']}"]
        return pick, why

    for issue in queue:
        owners = owners_of(issue)
        if not owners or lane in owners:
            return issue, [f"top of the queue: {describe(issue)}"]

    owned = [i for i in queue if owners_of(i)]
    raise Refusal("every open issue is owned by another lane: "
                  + ", ".join(f"{i['identifier']} ({owners_of(i)[0]})" for i in owned[:8]))


def cmd_next(args):
    board = load_board()
    lane = normalize_lane(args.lane)
    try:
        issue, why = select_next(board, lane)
    except Refusal as r:
        log("refused-next", lane=lane, reason=str(r))
        print(f"REFUSED lane={lane}: {r}")
        if args.json:
            print(json.dumps({"lane": lane, "refused": True, "reason": str(r)}, indent=2))
        return 1
    log("next", lane=lane, issue=issue["identifier"])
    print(f"{issue['identifier']}  {priority_label(issue)}  {issue.get('title') or ''}")
    print(f"  state: {state_name(issue) or '-'}   team: {issue['team']}"
          f"   sortOrder: {issue.get('sortOrder')}")
    print(f"  url: {issue.get('url') or '-'}")
    for line in why:
        print(f"  {line}")
    print(f"  claim: fm-mgr-dispatch.py claim {lane} {issue['identifier']}")
    if args.json:
        print(json.dumps({"lane": lane, "refused": False, "issue": issue["identifier"],
                          "priority": issue.get("priority"), "sortOrder": issue.get("sortOrder"),
                          "state": state_name(issue), "team": issue["team"],
                          "url": issue.get("url"), "why": why}, indent=2))
    return 0


# --------------------------------------------------------------------------
# claim
# --------------------------------------------------------------------------

def find_issue(board, ident):
    for issue in ordered(board):
        if (issue.get("identifier") or "").upper() == ident:
            return issue
    return None


def plan_claim(board, lane, task, lease_minutes=DEFAULT_LEASE_MINUTES):
    """Every refusal a claim must make, checked before anything is written.

    Returns (issue, plan) or raises Refusal."""
    if not lane:
        raise Refusal("claim needs a lane name")
    ident = as_linear_key(task)
    if ident is None:
        raise Refusal(f"task {task!r} names no Linear issue in {', '.join(TEAMS)}; nothing starts "
                      "from backlog.md, the hold digest or any other local file")

    issue = find_issue(board, ident)
    if issue is None:
        raise Refusal(f"{ident} is not an open issue in {', '.join(TEAMS)} "
                      "(missing, finished, canceled, or outside the teams)")

    others = [o for o in owners_of(issue) if o != lane]
    if others:
        raise Refusal(f"{ident} is already owned by {others[0]}")

    held = wip_issues(board, lane)
    if held and all(h["identifier"] != ident for h in held):
        raise Refusal(f"lane {lane} is at WIP 1: {held[0]['identifier']} is still In Progress; it "
                      "reaches Done or In Review, or is handed back with a reason comment, before "
                      f"{ident} is claimed")

    blocking = [i for i in unowned_urgent(board) if i["identifier"] != ident]
    if blocking and not is_urgent(issue):
        raise Refusal(f"{len(blocking)} unowned Urgent issue(s) block new non-Urgent starts; "
                      f"take {blocking[0]['identifier']} first (see `next {lane}`)")

    lease = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=lease_minutes)
    return issue, {
        "move": not is_in_progress(issue),
        "label": f"{CLAIM_LABEL}{lane}",
        "comment": (f"**Claimed by `{lane}`**\n\n"
                    f"lease-until: {lease.strftime('%Y-%m-%dT%H:%M')}Z"),
    }


def cmd_claim(args):
    # The write path reads fresh on purpose. Every refusal is a statement about
    # the board as it is now - that lane's WIP, that issue's owner, the Urgent
    # gate - and a cached board could let a claim through against an issue that
    # was finished or taken since the cache was filled. next and list keep the
    # cache; a claim never does.
    board = load_board(use_cache=False)
    lane = normalize_lane(args.lane)
    try:
        issue, plan = plan_claim(board, lane, args.issue, args.lease_minutes)
    except Refusal as r:
        log("refused-claim", lane=lane, issue=args.issue, reason=str(r))
        print(f"REFUSED claim lane={lane} issue={args.issue}: {r}", file=sys.stderr)
        return 1

    summary = (f"{issue['identifier']} -> In Progress, label {plan['label']}, "
               f"{plan['comment'].splitlines()[-1]}")
    if args.dry_run:
        print(f"would claim: {summary}")
        return 0

    done = []
    try:
        if plan["label"] not in (issue.get("labels") or []):
            # Label first, state second. A claim's dangerous half-failure is an
            # In Progress issue nobody owns: it would be invisible to the Urgent
            # gate and to WIP 1, and two lanes could then pick up the same work.
            # A label without the state change is just an owner that has not
            # started yet, which the next claim attempt can complete.
            # --add-label, never --label: --label replaces the whole label set,
            # which would silently strip an issue's other labels on claim.
            run_linear(["issue", "update", issue["identifier"],
                        "--add-label", plan["label"], "--no-input"])
            done.append("label")
        if plan["move"]:
            run_linear(["issue", "update", issue["identifier"],
                        "--state", "In Progress", "--no-input"])
            done.append("state")
        run_linear(["issue", "comment", "create", issue["identifier"],
                    "--body", plan["comment"], "--no-input"])
        done.append("comment")
    except LinearError as e:
        drop_cache()
        log("claim-failed", lane=lane, issue=issue["identifier"], error=str(e), applied=done)
        print(f"FAILED claim {issue['identifier']} for {lane}: {e} "
              f"(applied: {', '.join(done) or 'nothing'})", file=sys.stderr)
        return 2

    drop_cache()
    log("claim", lane=lane, issue=issue["identifier"], applied=done)
    print(f"claimed: {summary}")
    return 0


# --------------------------------------------------------------------------
# check and list
# --------------------------------------------------------------------------

def build_check(board):
    urgent = [{"issue": i["identifier"], "team": i["team"], "title": i.get("title") or "",
               "url": i.get("url") or ""} for i in unowned_urgent(board)]
    lanes = {}
    for issue in ordered(board):
        for lane in owners_of(issue):
            if is_in_progress(issue):
                lanes.setdefault(lane, []).append(issue["identifier"])
    over = [{"lane": lane, "issues": ids} for lane, ids in sorted(lanes.items()) if len(ids) > 1]
    return {"teams": list(TEAMS), "unowned_urgent": urgent, "over_wip": over,
            "in_progress": dict(sorted(lanes.items()))}


def cmd_check(args):
    # Fresh, never cached: check is the alerting view an operator reads before
    # acting, and a stale board would report a lane as blocked or as working
    # when the previous claim or a teammate's hand-back has already changed it.
    report = build_check(load_board(use_cache=False))
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"teams: {', '.join(TEAMS)}")
        if report["unowned_urgent"]:
            print(f"UNOWNED URGENT ({len(report['unowned_urgent'])}): "
                  "every new non-Urgent start is blocked")
            for u in report["unowned_urgent"]:
                print(f"  {u['issue']}  {u['title']}  {u['url'] or ''}")
        else:
            print("unowned Urgent: none")
        if report["over_wip"]:
            print(f"LANES OVER WIP 1 ({len(report['over_wip'])}):")
            for o in report["over_wip"]:
                print(f"  lane {o['lane']}: {len(o['issues'])} in progress "
                      f"({', '.join(o['issues'])})")
        else:
            print("lanes over WIP 1: none")
        if report["in_progress"]:
            print("in progress by lane: "
                  + ", ".join(f"{k}={len(v)}" for k, v in report["in_progress"].items()))
    log("check", unowned_urgent=len(report["unowned_urgent"]), over_wip=len(report["over_wip"]))
    return 1 if (report["unowned_urgent"] or report["over_wip"]) else 0


def cmd_list(args):
    rows = ordered(load_board())
    if args.priority:
        want = args.priority.strip().lower()
        num = {v.lower(): k for k, v in PRIORITY_LABEL.items()}.get(want)
        rows = [r for r in rows if priority_rank(r) == PRIORITY_RANK.get(num, 5)]
    if args.team:
        rows = [r for r in rows if r["team"] == args.team.upper()]
    if args.unowned:
        rows = [r for r in rows if not owners_of(r)]
    if args.json:
        print(json.dumps([{"identifier": r["identifier"], "title": r["title"],
                           "priority": r.get("priority"), "sortOrder": r.get("sortOrder"),
                           "team": r["team"], "state": state_name(r),
                           "owners": owners_of(r), "url": r.get("url")} for r in rows], indent=2))
        return 0
    for n, r in enumerate(rows, 1):
        owners = owners_of(r)
        print(f"{n:3d}. {r['identifier']:<9} P{r.get('priority')} so={r.get('sortOrder')} "
              f"{r['team']:<4} {state_name(r) or '-':<12} "
              f"{('[' + owners[0] + ']') if owners else '':<18} {r.get('title') or ''}")
    return 0


def cmd_log(args):
    path = os.path.join(state_dir(), "dispatch.log")
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        print(f"no dispatch log at {path}")
        return 0
    for line in lines[-args.n:]:
        print(line.rstrip())
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="fm-mgr-dispatch.py",
        description="Ranked Linear queue dispatcher: next/claim/check/list/log.")
    sub = p.add_subparsers(dest="cmd", required=True)

    n = sub.add_parser("next", help="print the top eligible issue for a lane, or the refusal")
    n.add_argument("lane")
    n.add_argument("--json", action="store_true")
    n.set_defaults(func=cmd_next)

    c = sub.add_parser("claim", help="claim an issue for a lane: In Progress + agent:<lane>")
    c.add_argument("lane")
    c.add_argument("issue")
    c.add_argument("--dry-run", action="store_true")
    c.add_argument("--lease-minutes", type=int, default=DEFAULT_LEASE_MINUTES)
    c.set_defaults(func=cmd_claim)

    k = sub.add_parser("check", help="list unowned Urgent issues and lanes over WIP 1")
    k.add_argument("--json", action="store_true")
    k.set_defaults(func=cmd_check)

    ls = sub.add_parser("list", help="print the ranked queue in dispatch order")
    ls.add_argument("--priority")
    ls.add_argument("--team")
    ls.add_argument("--unowned", action="store_true")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(func=cmd_list)

    lg = sub.add_parser("log", help="print recent dispatch records")
    lg.add_argument("-n", type=int, default=20)
    lg.set_defaults(func=cmd_log)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except LinearError as e:
        print(f"fm-mgr-dispatch: {e}", file=sys.stderr)
        log("linear-error", cmd=args.cmd, error=str(e))
        return 2


if __name__ == "__main__":
    sys.exit(main())
