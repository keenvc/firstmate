#!/usr/bin/env python3
"""Captain console: read-only page + tiny answer endpoint on 127.0.0.1:4390 (Caddy sends / and /console, /api/console here).
Writes only through fm-inbox.sh note. Accepts a POST only with a valid Cloudflare Access JWT for the allowed email."""
import json, os, re, subprocess, sys, time, hashlib, importlib.machinery, importlib.util, threading, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import jwt
ROOT = "/mnt/workdisk/tmp/fm-console"
# Captain Console v2 shell (captain 2026-11-06). Kept beside this server so /mnt/workdisk cleanup cannot lose it;
# the old read-only shell stays as a fallback at ROOT/index.html.
SHELL = "/home/azureuser/.local/bin/fm-console-v2.html"
# The AdClinica boss-progress page (captain ask 2026-11-12). A standalone page served at
# /console/progress, kept beside the server for the same reason as SHELL: /mnt/workdisk cleanup
# cannot lose it. Its payload is a file written once a minute by fm-adclinica-progress.timer.
PROGRESS = "/home/azureuser/.local/bin/fm-console-progress.html"
FM = "/home/azureuser/firstmate"
# The home whose inbox this console writes into and reads answers from (defect ADC-1234: a note written
# into FM's state/inbox was never answered there, because the firstmate that reads this board's notes and
# publishes replies against them lives in the deck home, which is also the home the Get-update reader and
# the follow-up reader already read). Write and read must be the SAME home, so both sides come from here.
# A board action aimed at another home's asking agent passes that home explicitly (see asker_inbox).
CONSOLE_HOME = os.environ.get("FM_CONSOLE_HOME") or "/home/azureuser/fm-homes/deck"
# Captain decisions (captain 2026-11-06, corr=ba07d8c9986d9bc1): one flashcard per open decision.
# The captain keeps this list by hand; the panel only presents it. A decision leaves the deck when the
# builder's own rule drops it -- an answered commit line, or a DO NOT SHOW verdict from a sweep.
CARD_SRC = FM + "/data/decision-cards/open-decisions.md"
DECK_DIR = FM + "/data/decision-cards"
# Cards are chosen by a numbered key and their buttons by their own text, never by a browser index,
# so a list edited in a background tab cannot turn a click into a different answer.
OPT = re.compile(r"options?\s*(?:per item|each)?\s*(?:are|:|-)?\s*(provide|drop|[a-z]+ / [a-z]+)", re.I)
PAREN = re.compile(r"\(([^()]*?/[^()]*?)\)")
DECOY = re.compile(r"^(yes\s*/\s*no|no\s*/\s*yes|free text|pick)$", re.I)
TEARDROP = re.compile(r"\s*(?:\?\s*)?\bOptions per item:?\s+(provide|drop)\b[^.;]*\.?\s*$", re.I)
SIMPLETOK = {"yes": "Yes", "no": "No", "later": "Later", "not sure": "Not sure", "never": "Never", "skip": "Skip"}

CARD_INSTR = "Pick the card's number in the box, then the option's own text. Every card carries its own key and button labels, so nothing here has to remember an index."
# Real-time board (captain 2026-11-06): local collectors, one for live lanes and
# one for the captain's calls. Both read files only - never a model or a forge.
LIVE_DIR = "/home/azureuser/fm-homes/deck/data/board-live"
LIVE_SCRIPTS = {"/api/console/lanes": LIVE_DIR + "/collect-lanes.py",
                "/api/console/calls": LIVE_DIR + "/collect-calls.py",
                "/api/console/superagent": LIVE_DIR + "/collect-superagent.py"}
LIVE_FILES = {"/api/console/lanes": ROOT + "/lanes-live.json",
              "/api/console/calls": ROOT + "/calls-live.json",
              "/api/console/superagent": ROOT + "/superagent.json"}
# Copper is written by its own 2-minute cron, so it needs no collector: serve the file
# straight through, and let its own `at` field tell the page how fresh the sweep is.
PLAIN_FILES = {"/api/console/copper": ROOT + "/copper.json",
               # Build times (captain ask 2026-11-09): its collector is a Buildkite API sweep on
               # fm-builds.timer, never a per-page-load call, so the page just reads the last file.
               "/api/console/builds": ROOT + "/builds-live.json",
               # PRs per hour (captain ask 2026-11-10): fm-prs-per-hour.timer sweeps GitHub once a
               # minute and writes the file, so a page load never waits on the ~14s GraphQL walk.
               "/api/console/prs-per-hour.json": ROOT + "/prs-per-hour.json",
               # Phase progress (captain ask 2026-11-10, corr=fc4a365818f3bf4c): fm-phases.timer
               # resolves the phases.json registry against GitHub once a minute, so a page load
               # never waits on GraphQL. phases.json itself is the hand-edited INPUT and is never
               # served here - only the derived progress file is.
               "/api/console/phases.json": ROOT + "/phases-progress.json",
               # Ananda task progress (captain ask M365): fm-ananda-tasks.timer reads the Linear
               # project and the ask ledger once a minute and writes this file. Served as-is so a
               # page load never waits on Linear, and its own error field reports a failed read.
               "/api/console/ananda-tasks": LIVE_DIR + "/ananda-tasks.json",
               # ATC panel (captain ask 2026-11-17): fm-atc.timer reads copper's status.json and
               # log.jsonl once a minute and writes this file. Served as-is so a page load never
               # waits on the sweep, and the payload carries its own age and the file's last_sweep
               # so the panel can say RUNNING / STALE / DOWN without guessing.
               "/api/console/atc.json": ROOT + "/atc.json",
               # AdClinica boss-progress page (captain ask 2026-11-12): fm-adclinica-progress.timer
               # reads GitHub, the production health endpoint, the Super Agent ADC instance and the
               # hand-edited tables file once a minute. Served as-is so a page load never waits on
               # a network call, and every failed source names its own error in the payload.
               "/api/console/adclinica-progress": ROOT + "/adclinica-progress.json",
               # Outstanding + AdClinica Progress (captain order 2026-11-15, corr=8cc6b77780a30031):
               # fm-outstanding.timer reads Linear (ADC/FDC/NIC open issues), the open PRs on each
               # deploy branch, adclinica.com/api/health and the AdClinica plan/tracker once a
               # minute. Served as-is so a page load never waits on Linear or GitHub.
               # Flights (captain ask 2026-11-17): fm-flights.timer reads Linear (every issue whose
               # state TYPE is started, in ADC/FDC/NIC/DRO), the lane records, the Super Agent tickets
               # and each linked PR once a minute. Served as-is so a page load never waits on Linear
               # or GitHub, and its own stale flag reports a failed source.
               "/api/console/flights.json": ROOT + "/flights.json",
               "/api/console/outstanding.json": ROOT + "/outstanding-progress.json",
               # The captain's open questions (captain ask 2026-11-17, follow-up 304): one payload
               # swept from live records by fm-urgent-questions.timer once a minute - the numbered
               # cards, every home's captain holds, and the unanswered owner calls. The board's
               # Next questions area and the Lavish page both read THIS file, and its own `at` and
               # `problems` fields say how fresh it is and which source could not be read.
               "/api/console/urgent-questions": "/mnt/workdisk/tmp/fm-console/urgent-questions.json"}
# Nick's questions (captain ask M321, 2026-11-09): what the captain asked in the First Mate
# terminal and what came back. Its collector reads the session transcripts and the ask ledger
# only - no model, no network - and is incremental, so a 3s memo keeps a burst of tabs cheap.
NICKS_SCRIPT = LIVE_DIR + "/collect-nicks-questions.py"
NICKS_FILE = ROOT + "/nicks-live.json"
# Get update (captain order 2026-11-15, ADC-1234): one request per row on "Captain-ordered work and
# ops", carrying that row's Linear key. The note is the same write every other console action makes;
# the reply is read back from the same inbox receipts the rest of the board uses, so there is no
# second store. This module also holds the 5-minute per-key window, so a stale page cannot bypass it.
UPDATE_REQUESTS = LIVE_DIR + "/console-update-requests.py"
# Flight detail (captain ask 2026-11-17): Accelerate and Pause on a flight's modal. Same shape as
# Get update - one note through fm-inbox.sh note - but the ledger is per flight and per action, and
# it carries the owner the note was routed to so the modal can say what it actually asked.
FLIGHT_ACTIONS = LIVE_DIR + "/console-flight-actions.py"
UPDATE_KEY = re.compile(r"^[A-Za-z]{2,5}-\d{1,6}$")
_nick = {"at": 0, "body": None}
_live_lock = threading.Lock()
env = dict(l.strip().split("=", 1) for l in open(os.path.expanduser("~/.config/firstmate/console.env")) if "=" in l)
TEAM, AUD, ALLOWED, TEST_OK = env["CF_TEAM"], env["CF_AUD"], env["ALLOWED_EMAIL"], env.get("TEST_EMAIL", "")
_keys = {"at": 0, "k": {}}
def keys():
    if time.time() - _keys["at"] > 3600:
        d = json.load(urllib.request.urlopen(f"https://{TEAM}/cdn-cgi/access/certs", timeout=15))
        _keys["k"] = {k["kid"]: jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(k)) for k in d["keys"]}; _keys["at"] = time.time()
    return _keys["k"]
def who(h):
    tok = h.headers.get("Cf-Access-Jwt-Assertion")
    if not tok: return None
    try:
        kid = jwt.get_unverified_header(tok)["kid"]
        c = jwt.decode(tok, keys()[kid], algorithms=["RS256"], audience=AUD, issuer=f"https://{TEAM}")
        return c.get("email")
    except Exception:
        return None
LOCK = threading.Lock()
ANS = ROOT + "/answers.jsonl"
def _load_decisions():
    """The structured card deck (captain 2026-11-16): /mnt/workdisk/fm-decisions/open/<project>-<id>.json,
    written only by the asking agent's `fm-decision ask`. The module is the deck's one reader and
    the submit path's one writer, shared with the command, so the two cannot drift apart.
    The tracked copy lives in this repo's bin/ beside the command; an older beside-the-server copy
    is accepted only when the tracked one is absent, so an upgrade never silently keeps stale logic."""
    here = os.path.dirname(os.path.realpath(__file__))
    # The deck home's own tracked bin/ is the copy that ships (UX review 2026-11-18): the old treehouse
    # slot path is gone, which left the Decisions tab reporting "the card deck module is not installed".
    for p in (CONSOLE_HOME + "/bin/fm-console-decisions.py",
              "/mnt/fastpool/.treehouse/deck-6f7161/1/deck/bin/fm-console-decisions.py", here + "/fm-console-decisions.py"):
        if os.path.exists(p):
            ld = importlib.machinery.SourceFileLoader("fm_console_decisions", p)
            sp = importlib.util.spec_from_loader("fm_console_decisions", ld)
            m = importlib.util.module_from_spec(sp); ld.exec_module(m)
            return m
    return None
DEC = _load_decisions()
# Lavish (captain ask 2026-11-17): the captain's urgent questions opened in Lavish from the board.
# Lavish is a LOCAL server on this host, so the board cannot deep-link into its own artifact: the
# page reaches Lavish through the browser, and these constants and the ticket below are what let the
# local server prove that request came from the signed-in board. BOARD_ORIGIN is the only origin
# ever allowed to fetch the ticket, and the ticket is short-lived, single-use and memory-only, so
# nothing durable is written for it and no JWT or Access session is ever handed to Lavish.
BOARD_ORIGIN = "https://board.advancedcare.com"
LAVISH_DIR = "/home/azureuser/firstmate/.lavish"
LAVISH_DOC = "urgent-questions.html"
LAVISH_HTML = LAVISH_DIR + "/" + LAVISH_DOC
LAVISH_OPEN = "/home/azureuser/.local/bin/fm-lavish-open.sh"
URGENT_COLLECT = LIVE_DIR + "/collect-urgent-questions.py"
LAVISH_SEED = "/home/azureuser/.local/bin/fm-lavish-seed.sh"
LAVISH_PORT = os.environ.get("FM_LAVISH_PORT") or "46321"
LAVISH_ORIGINS = "http://127.0.0.1:" + LAVISH_PORT + " http://localhost:" + LAVISH_PORT
class Tickets:
    """Short-lived, single-use tickets minted for the board page and checked by Lavish's bridge."""
    ttl = 120
    def __init__(self): self.k, self.lock = {}, threading.Lock()
    def issue(self, email):
        t = hashlib.sha256(os.urandom(32)).hexdigest()
        with self.lock:
            now = time.time()
            self.k = {a: b for a, b in self.k.items() if b[0] > now}
            self.k[t] = (now + self.ttl, email)
        return t
    def redeem(self, t):
        with self.lock:
            v = self.k.pop(t, None)
        return v[1] if v and v[0] > time.time() else None
TICKETS = Tickets()
def struct_cards():
    """Structured cards, or an explicit problem. An unreadable deck is reported, never shown as empty."""
    if DEC is None:
        return {"open": [], "stale": [], "answered": [], "problems": ["the card deck module is not installed"]}
    try:
        return DEC.state()
    except Exception as ex:
        return {"open": [], "stale": [], "answered": [], "problems": ["the deck could not be read: " + str(ex)[:160]]}
def note(text, rid, home=None):
    """One captain action as one inbox note, written into CONSOLE_HOME -- the same home receipts() below
    (and the Get-update and follow-up readers) reads answers from. `home` is for an action whose reader
    is a different home's asking agent, and must be passed explicitly rather than assumed."""
    r = subprocess.run([FM + "/bin/fm-inbox.sh", "note", "--request-id", rid, "--json", "--", text], capture_output=True, text=True, timeout=30,
                       env={**os.environ, "FM_HOME": home or CONSOLE_HOME})
    try: return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception: return {"error": (r.stderr or r.stdout)[-200:], "rc": r.returncode}
def cards():
    """The open-decision cards, parsed from the captain's own list.

    Never pre-select: a card carries its options as text and nothing else. Damage is reported rather than
    hidden -- an item that yields no option is KEPT and listed under `unparsed` so the panel can show it
    and say why it cannot be answered by button, instead of silently dropping a real decision.
    """
    out = {"at": 0, "cards": [], "unparsed": [], "source": "open-decisions.md", "warning": "", "done_all": False}
    try:
        with open(CARD_SRC, encoding="utf-8") as f:
            raw = f.read()
        out["at"] = int(os.path.getmtime(CARD_SRC))
    except Exception:
        out["warning"] = "The decision list could not be read, so no cards can be shown. This is a read problem, not a statement that you have no decisions left."
        return out
    skip = set()
    for line in raw.splitlines():
        t = line.strip()
        if not t.startswith("#"):
            continue
        head = t.lstrip("#").strip()
        if head.lower().startswith("answered") or head.lower().startswith("closed"):
            for m in re.finditer(r"\b(\d+[a-z]?)\s*,", head.lower() + ","):
                skip.add(m.group(1))
    for line in raw.splitlines():
        t = line.strip()
        if not t or t.startswith("#"):
            continue
        m = re.match(r"^(\d+[a-z]?)[.)]\s+(.*)$", t)
        if m and m.group(1) not in skip:
            out["cards"].append(parse_card(m.group(1), m.group(2)))
    out["unparsed"] = [{"n": c["n"], "question": one_line(c["question"], 150)} for c in out["cards"] if c["unparsed"]]
    if not out["cards"]:
        out["done_all"] = True
        out["warning"] = "The list has no open numbered card. Either every decision is answered, or it has a shape this panel does not read -- the page cannot tell those apart."
    return out


def parse_card(n, text):
    """One numbered item -> the item's own text as the question, a one-line context, and its real options.

    The list's own grammar decides: an explicit `Options per item: provide / drop.` tail, a parenthesised
    choice such as `(cut / more machines / serialise)`, or a closing choice sentence (`? Yes / No / Later.`,
    `yes/no`, `full $124.65 or partial $53.10`). A bare `yes/no` inside the body is a sub-question, not the
    card's choice, so a card whose only parse is that reports itself instead of offering the wrong buttons.
    """
    options, body = [], text
    md = TEARDROP.search(text)
    if md:
        options = ["Provide", "Drop"]; body = text[:md.start()]
    if not options:
        mo = OPT.search(text)
        if mo:
            cand = [o.strip() for o in re.split(r"\s*/\s*|\s+or\s+", mo.group(1)) if o.strip()]
            if len(cand) >= 2:
                options = cand
                body = re.sub(r"options?\s*(?:per item|each)?\s*(?:are|:|-)?\s*" + re.escape(mo.group(1)) + r"\.", "", text, flags=re.I)
    if not options:
        groups = []
        for m in PAREN.finditer(text):
            inner = m.group(1).strip()
            if DECOY.match(inner) or re.search(r"\b(free text|pick)\b", inner, re.I):
                continue
            parts = [p.strip(" .;?") for p in re.split(r"\s*/\s*", inner) if p.strip(" .;?")]
            if len(parts) >= 2 and all(re.fullmatch(r"[A-Za-z][\w' -]{0,40}", p) for p in parts):
                groups.append((tag_for(text[:m.start()]), parts))
        if groups:
            for tag, parts in groups:
                for p in parts:
                    options.append((tag + " \u2192 " + p) if tag else p)
            body = PAREN.sub(" ", text)
    if not options:
        mq = re.search(r"\?\s*([^?.]*?)\s*[.!]?\s*$", text)
        if mq and re.search(r"\byes\b|\bno\b|\bor\b|/", mq.group(1), re.I):
            keep = []
            for p in [p.strip(" .;?!") for p in re.split(r"\s*/\s*|\s+or\s+|,\s*", mq.group(1)) if p.strip(" .;?!")]:
                pl = p.lower()
                if pl in SIMPLETOK:
                    keep.append(SIMPLETOK[pl])
                elif re.match(r"^(full|partial)\b", pl):
                    keep.append(p)
                elif re.match(r"^\$?\d", p):
                    keep.append(p)
            options = keep; body = text[:mq.start()]
    seen, opts = set(), []
    for o in options:
        if o.lower() not in seen:
            seen.add(o.lower()); opts.append(o)
    return {"n": n, "question": _question(text), "context": one_line(body), "options": opts, "unparsed": not opts}

def one_line(s, n=260):
    s = re.sub(r"\s+", " ", s or "").strip(" .;:")
    return s[:n] + ("\u2026" if len(s) > n else "")

def _question(text):
    """The card's own text, shortened only where a long colon head repeats itself.

    `Everything before the first colon is a label ("Logins still needed:", "Short answers:") and that label
    is what the context line already opens with, so the heading starts after it and the reader gets the
    actual contents. The card's number stays above both, so nothing is lost and nothing is invented --
    every word on the card is still a substring of the captain's list.
    """
    head, sep, tail = text.partition(":")
    if sep and 3 <= len(head.strip()) <= 60 and len(tail.strip()) > 40:
        return tail.strip()
    return text.strip()


def tag_for(before):
    seg = re.split(r"[;?.]\s", before)[-1]
    seg = re.sub(r"\b(direction|design|choice|options?)\s*$", "", seg.strip(), flags=re.I)
    seg = re.sub(r"\([^()]*\)", "", seg)
    return seg.strip(" .,;:?-")[-38:]

def record(kind, ident, title, choice, text, test, rid):
    """One answer record, shared by every card kind so one reader can see them all.

    The first record for an id is the captain's actual answer and is never overwritten -- re-clicking
    must not change WHAT was decided. A later identical submission is a no-op; a later different one is
    kept beside it and flagged `conflict`, so a disagreement is visible rather than silently resolved.
    """
    with LOCK:
        prior = []
        try:
            with open(ANS) as f:
                prior = [json.loads(l) for l in f if l.strip()]
        except Exception:
            pass
        mine = [a for a in prior if a.get("qid") == ident]
        real = [a for a in mine if not a.get("test")]
        if real:
            first = real[0]
            same = (first.get("choice", "") or "") == (choice or "") and (first.get("text", "") or "") == (text or "")
            rec = None if same else {"qid": ident, "kind": kind, "rid": rid, "choice": choice or "", "text": text or "",
                                     "at": int(time.time()), "test": False, "conflict": True}
        else:
            rec = {"qid": ident, "kind": kind, "rid": rid, "choice": choice or "", "text": text or "", "at": int(time.time()), "test": test}
        if rec:
            with open(ANS, "a") as f:
                f.write(json.dumps(rec) + "\n")
        return rec


def asker_inbox(asked_by):
    """The agent that asked a card, as a home whose inbox can take a note, or None.

    `asked_by` is free text, so this resolves only what it can prove: "main"/"firstmate" is this
    server's own firstmate home, and any other name is a firstmate home of that name. An unknown
    asker still gets the durable reply file - it just gets no note."""
    a = (asked_by or "").strip().lower()
    a = re.sub(r"\s*\(.*?\)\s*", "", a)                  # "Claude (overseer)" -> "claude"
    if not a:
        return None, None
    if a in ("main", "firstmate", "firstmate main", "deck", "fm"):
        tag = "main"
    else:
        tag = re.sub(r"[^a-z0-9_-]", "", a.split()[0] if a.split() else "")[:32]
    if not tag:
        return None, None
    home = FM if tag == "main" else "/home/azureuser/fm-homes/" + tag
    if not os.path.isdir(home):
        return None, tag
    return home, tag
def submit_card(ident, choice, text, test):
    """One structured-card answer, written in the order the board promises.

    Every step that writes anything happens BEFORE the card leaves open/, and a failure rolls the
    earlier steps back (the deck module owns that), so the page can never show an answer the board
    failed to deliver and the card is never half-written. The returns are (code, payload).
    """
    if DEC is None:
        return 503, {"error": "the card deck module is not installed"}
    c = DEC.find(ident)
    if not c:
        return 409, {"error": "this decision is no longer open - reload the page"}
    opts = c.get("options") or []
    if choice and choice not in [o["label"] for o in opts]:
        return 400, {"error": "that is not one of this card's options"}
    if not choice and not text.strip():
        return 400, {"error": "pick an option or write an answer"}
    if c.get("stale") and not choice and not text.strip():
        return 400, {"error": "this card has expired; answer it anyway or ask for a fresh one"}
    if c.get("answer"):
        return 409, {"error": "this decision already has an answer recorded"}
    now = DEC.iso()
    answered_at = time.time()
    label = ("TEST " if test else "") + "CAPTAIN ANSWER (via console) to [%s]" % ident
    head = label + ((" " + c["ref"]) if c.get("ref") else "") + ((" (" + c["project"] + ")") if c.get("project") else "") + ": "
    body = head + ("Choice: " + choice if choice else "Choice: (none)") + (". Typed: " + text if text else ".")
    if c.get("blocks"):
        body += " Unblocks: " + ", ".join(c["blocks"]) + "."
    body += " Question was: " + c["question"][:300]
    rid = "console-card-%s-%d" % (ident, int(answered_at * 1000))
    res = note(body, rid)
    if "error" in res:
        return 502, {"error": "could not reach firstmate's inbox, so nothing was recorded: " + str(res.get("error"))[:160]}
    answer = {"id": ident, "ref": c.get("ref", ""), "project": c.get("project", ""),
              "asked_by": c.get("asked_by", ""), "question": c.get("question", ""),
              "choice": choice, "text": text, "answered_at": now, "at": int(answered_at),
              "request": rid, "note": res.get("id"), "test": bool(test), "via": "board.advancedcare.com"}
    home, tag = asker_inbox(c.get("asked_by"))
    fan = DEC.DECK + "/answered/" + ident + ".json"
    rec = dict(answer, status="delivered", note_to_asker=None, test=bool(test), card=c)
    # The fan-out file is what the asking agent reads, so it carries the answer, not a card whose
    # own `answer` field is still null.
    fan_body = dict(c, answer=dict(answer), answered=True, status="delivered",
                    note_to_asker=None, via=answer["via"])
    if home and not test:
        # The asking agent is told in its own inbox, the same durable note every other board
        # action writes, so it wakes to the answer rather than to a file it is not watching.
        r = subprocess.run([FM + "/bin/fm-inbox.sh", "note", "--request-id", "card-" + rid, "--json", "--",
                            "CAPTAIN ANSWER (via board) to [%s] from the console: %s%s" %
                            (ident, ("Choice: " + choice + ". ") if choice else "", ("Typed: " + text) if text else "")],
                           capture_output=True, text=True, timeout=30, env={**os.environ, "FM_HOME": home})
        try:
            rj = json.loads(r.stdout.strip().splitlines()[-1])
            rec["note_to_asker"] = {"home": home, "id": rj.get("id"), "outcome": rj.get("outcome")}
            fan_body["note_to_asker"] = rec["note_to_asker"]
            if "error" in rj:
                return 502, {"error": "could not tell %s, so nothing was recorded: %s" % (tag, str(rj.get("error"))[:120])}
        except Exception:
            return 502, {"error": "the note to %s was not confirmed, so nothing was recorded" % tag}
    proj = (c.get("project") or "").strip().lower()
    if proj in DEC.PROJECT_DECISIONS:
        rec["project_file"] = DEC.PROJECT_DECISIONS[proj]
        rec["project_line"] = DEC.project_line(c, answer)
    rec["answered_file"] = fan
    try:
        DEC.record(dict(rec, answered_body=fan_body))
    except Exception as ex:
        return 500, {"error": "the answer could not be written, so the card is still open: " + str(ex)[:160]}
    return 200, {"ok": True, "id": ident, "choice": choice, "text": text, "answered_at": now,
                 "note": res.get("id"), "test": bool(test), "choice_recorded": bool(choice)}
def deck_state():
    """Which cards the captain has already answered, from the console's own answer log."""
    d = cards()
    ans = read_ans()
    recs = read_recs()
    d["recs_at"] = recs_mtime()
    answered, conflict, latest_test = {}, {}, {}
    for a in ans:
        if a.get("kind") != "decision" or not a.get("qid"):
            continue
        if a.get("test"):
            latest_test[a["qid"]] = a
            continue
        if a.get("conflict"):
            conflict[a["qid"]] = a
            continue
        if not (a.get("choice") or a.get("text")):
            continue                      # an empty record must not tick a card off as answered
        answered.setdefault(a["qid"], a)
    for c in d["cards"]:
        k = "decision-" + c["n"]
        c["key"] = k
        c["answered"] = answered.get(k)
        c["conflict"] = conflict.get(k)
        c["test"] = latest_test.get(k)
        r = recs.get(c["n"]) if isinstance(recs.get(c["n"]), dict) else None
        c["rec"] = r
        c["has_rec"] = bool(r and isinstance(r.get("options"), list) and len(r["options"]) > 0)
    d["open"] = [c for c in d["cards"] if not c["answered"]]
    d["answered_n"] = len([c for c in d["cards"] if c["answered"]])
    # Cards the captain must still decide that carry no written options: named back to
    # firstmate so they get filled, never guessed at on the board.
    d["needs_options"] = [{"n": c["n"], "question": one_line(c["question"], 140)}
                          for c in d["open"] if not c["has_rec"] and not c.get("options")]
    # Structured cards (captain 2026-11-16). The legacy list above is kept whole inside the same
    # payload under its own keys, so nothing already on the deck is lost while it moves across.
    dec = struct_cards()
    for c in dec.get("open", []) + dec.get("stale", []):
        c.setdefault("problems", [])
    # The drop-directory cards are ALSO first-class entries in `open`, the list the deck's panels are
    # built from, each with its own id, ref, project, question, context, options with their
    # recommended flag, free_text_prompt and expires_at. A prose card parsed out of open-decisions.md
    # keeps its list today but carries no `recommended` flag, so the panel can never present it as if
    # it had one; it is listed under `unparsed` and in needs_options instead.
    legacy_open = d["open"]
    new_open = list(dec.get("open", [])) + list(dec.get("stale", []))
    for c in new_open:
        c.setdefault("card", True)
    d["open"] = new_open + legacy_open
    d["legacy_open_n"] = len(legacy_open)
    d["open_n"] = len(dec.get("open", []))
    d["stale_n"] = len(dec.get("stale", []))
    d["scards"] = {"open": dec.get("open", []), "stale": dec.get("stale", []),
                   "answered": (dec.get("answered", []) or [])[:60], "problems": dec.get("problems", []),
                   "dir": dec.get("dir", DEC.DECK if DEC else ""), "url": dec.get("url", ""),
                   "open_n": dec.get("open_n", 0), "stale_n": dec.get("stale_n", 0)}
    return d


def receipts():
    r = subprocess.run([FM + "/bin/fm-inbox.sh", "receipts", "--all-pending", "--all-handled", "--all-replies"], capture_output=True, text=True, timeout=30, env={**os.environ, "FM_HOME": CONSOLE_HOME})
    try:
        d = json.loads(r.stdout); return {n["request_id"]: n for n in d.get("pending", []) + d.get("handled", []) if n.get("request_id")}
    except Exception: return {}
def read_ans():
    try: return [json.loads(l) for l in open(ANS)]
    except Exception: return []
def update_state(keys):
    """One row's (or several rows') Get-update state, read by the one module that owns it."""
    if not keys: return {"at": int(time.time()), "window_sec": 300, "rows": {}, "error": None}
    r = subprocess.run([sys.executable, UPDATE_REQUESTS] + list(keys), capture_output=True, text=True, timeout=30)
    try:
        d = json.loads(r.stdout)
        if isinstance(d.get("rows"), dict): return d
    except Exception:
        pass
    return {"at": int(time.time()), "window_sec": 300, "rows": {},
            "error": "update requests unreadable: " + (r.stderr or r.stdout or "no answer")[-160:]}
def flight_state(keys):
    """One flight's (or several flights') Accelerate/Pause state, read by the module that owns it."""
    if not keys: return {"at": int(time.time()), "window_sec": 300, "rows": {}, "error": None}
    r = subprocess.run([sys.executable, FLIGHT_ACTIONS] + list(keys), capture_output=True, text=True, timeout=30)
    try:
        d = json.loads(r.stdout)
        if isinstance(d.get("rows"), dict): return d
    except Exception:
        pass
    return {"at": int(time.time()), "window_sec": 300, "rows": {},
            "error": "flight requests unreadable: " + (r.stderr or r.stdout or "no answer")[-160:]}
# Critical decisions (captain order 2026-11-19, corr=05757a51f125374d): firstmate writes
# data/board-decisions.json (schema board-decisions.v1); the board only READS it, on every request, and
# answers through /api/console/decision. An item vanishes when the file drops it or marks it answered,
# or once the board has recorded a real answer for it (a TEST answer only counts on a test- item).
BOARD_DECISIONS = os.environ.get("FM_BOARD_DECISIONS") or FM + "/data/board-decisions.json"
BOARD_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$")
URGENCY = {"high": 0, "medium": 1, "low": 2}
def board_answered():
    out = {}
    for a in read_ans():
        if a.get("kind") != "board-decision" or not (a.get("choice") or a.get("text")) or a.get("conflict"):
            continue
        qid = str(a.get("qid") or "")
        if a.get("test") and not qid.startswith("test-"):
            continue
        out.setdefault(qid, a)
    return out
def board_decisions():
    """The open items, read live. A file that cannot be read is reported, never shown as empty."""
    try:
        d = json.load(open(BOARD_DECISIONS, encoding="utf-8"))
    except FileNotFoundError:
        return {"schema": "board-decisions.v1", "at": int(time.time()), "items": [], "problems": ["the decisions file does not exist"]}
    except Exception as ex:
        return {"schema": "board-decisions.v1", "at": int(time.time()), "items": [], "problems": ["the decisions file could not be read: " + str(ex)[:160]]}
    probs = [] if d.get("schema") == "board-decisions.v1" else ["unexpected schema %r" % d.get("schema")]
    given = board_answered()
    items = []
    for n, it in enumerate(d.get("items") or []):
        if not isinstance(it, dict) or not BOARD_ID.match(str(it.get("id") or "")):
            probs.append("item %d has no usable id" % n)
            continue
        if it.get("answered") or str(it.get("status") or "").lower() in ("answered", "closed", "done", "removed"):
            continue
        if it["id"] in given:
            continue
        rec = it.get("recommended") if isinstance(it.get("recommended"), dict) and it["recommended"].get("label") else None
        alts = [a for a in (it.get("alternatives") or []) if isinstance(a, dict) and a.get("label")]
        items.append({"id": it["id"], "project": str(it.get("project") or ""), "title": str(it.get("title") or it["id"]),
                      "urgency": str(it.get("urgency") or "low").lower(), "context": str(it.get("context") or ""),
                      "recommended": {"label": str(rec["label"]), "why": str(rec.get("why") or "")} if rec else None,
                      "alternatives": [{"label": str(a["label"]), "why": str(a.get("why") or "")} for a in alts],
                      "order": n})
    items.sort(key=lambda x: (URGENCY.get(x["urgency"], 3), x["order"]))
    return {"schema": "board-decisions.v1", "updated": d.get("updated"), "at": int(time.time()), "items": items, "problems": probs}
def board_item(ident):
    for it in board_decisions().get("items", []):
        if it["id"] == ident:
            return it
    return None
def flight_row(key):
    """The flight as the board's own flights payload shows it, read server-side so an unowned request
    carries the payload's facts rather than whatever the page sent."""
    try:
        d = json.load(open(PLAIN_FILES["/api/console/flights.json"]))
        for f in d.get("flights") or []:
            if isinstance(f, dict) and str(f.get("key") or "").upper() == key:
                return f
    except Exception:
        return None
    return None
def unowned_flight_note(key, action, f):
    """Captain ask 2026-11-18 (corr=c4591dfd5be956c0): a flight no lane or Super Agent ticket owns can
    still be accelerated or paused. The note starts `ACCELERATE <KEY> <title>` (or `PAUSE ...`) and
    carries the flight's state, its PRs, its last update and the reason `no owner`, so firstmate can
    review it and task it to a Super Agent worker. One line, because the inbox note is one line."""
    title = re.sub(r"\s+", " ", str(f.get("title") or "")).strip()[:200]
    stage = {"boarding": "at the gate", "enroute": "en route", "approach": "on approach", "landed": "landed"}.get(f.get("stage"), str(f.get("stage") or ""))
    prs = []
    for p in (f.get("prs") or [])[:12]:
        if isinstance(p, dict) and p.get("number"):
            st = "merged" if p.get("merged") else ("draft" if p.get("draft") else (p.get("kind") or "open"))
            prs.append("%s#%s %s, checks %s" % (p.get("repo") or "", p["number"], st, p.get("checks") or "unknown"))
    age = f.get("ageSec")
    last = str(f.get("updatedAt") or "unknown") + ((" (%dh%02dm ago)" % (int(age) // 3600, int(age) % 3600 // 60)) if isinstance(age, (int, float)) else "")
    head = "%s %s %s" % ("ACCELERATE" if action == "accelerate" else "PAUSE", key, title)
    facts = (" - state: %s (%s); PRs: %s; last update: %s; reason: no owner"
             % (f.get("state") or "unknown", stage, "; ".join(prs) if prs else "none", last))
    if action == "accelerate":
        ask = (". No lane or Super Agent ticket owns this flight. Review it and task it to a Super Agent worker "
               "(or say why not), and reply with what you dispatched. The board started nothing and wrote nothing to Linear.")
    else:
        ask = (". No lane or Super Agent ticket owns this flight, so nothing is running to stop. Record it as held for "
               "the captain so nobody picks it up, and reply with the hold you recorded. The board wrote nothing to Linear.")
    return head + facts + ask
def flight_record(key, rid, action, request, note_id=None, test=False, error=None):
    args = [sys.executable, FLIGHT_ACTIONS, "--record", key, rid, action, request]
    if note_id: args += ["--note-id", note_id]
    if test: args += ["--test"]
    if error: args += ["--error", error]
    try: subprocess.run(args, capture_output=True, text=True, timeout=20)
    except Exception: pass
def update_record(key, rid, note_id=None, test=False, error=None):
    args = [sys.executable, UPDATE_REQUESTS, "--record", key, rid]
    if note_id: args += ["--note-id", note_id]
    if test: args += ["--test"]
    if error: args += ["--error", error]
    try: subprocess.run(args, capture_output=True, text=True, timeout=20)
    except Exception: pass
REC_JSON = DECK_DIR + "/recommendations.json"
def read_recs():
    """Optional per-card recommendations written by firstmate from the real hold
    record/reports (captain 2026-11-07, corr=458a773b1052536e).

    Shape: {"<card n>": {"summary": "...", "links": ["<url>", ...],
                         "options": [{"text": "...", "why": "...", "pick": true}, ...]}}
    A card with no entry is reported as needing options rather than invented -- the
    board never writes a recommendation it was not given.
    """
    try:
        raw = json.load(open(REC_JSON))
        return raw if isinstance(raw, dict) else {}
    except Exception:
        return {}
def recs_mtime():
    try: return int(os.path.getmtime(REC_JSON))
    except Exception: return 0
SPD = ROOT + "/speed.jsonl"
FLOOR = FM + "/config/lane-floor.json"
def lane_floor():
    try: return json.load(open(FLOOR))
    except Exception: return {}
def floor_mtime():
    try: return os.path.getmtime(FLOOR)
    except Exception: return 0
def speed_state():
    cur = lane_floor(); mt = floor_mtime(); last = {}
    try:
        for l in open(SPD):
            r = json.loads(l); last[r["project"]] = r
    except Exception: pass
    out = {}
    for k in ("adclinica", "v10", "fdc"):
        r = last.get(k); o = {"target": cur.get(k), "pending": None}
        if r:
            applied = mt > r["mt"] + 0.5 or cur.get(k) != r["base"]
            o["pending"] = {"action": r["action"], "at": int(r["at"]), "state": "applied" if applied else "sent", "test": r.get("test", False)}
        out[k] = o
    return out
def questions():
    try: q = json.load(open(ROOT + "/questions.json"))
    except Exception: q = {"questions": [], "at": 0}
    rec = receipts(); ans = read_ans(); by = {}
    for a in ans: by.setdefault(a["qid"], []).append(a)
    for x in q["questions"]:
        x["answers"] = []
        for a in by.get(x["id"], [])[-3:]:
            if a.get("kind"):
                continue  # a flashcard answer lives on the cards panel, not on this callback row
            n = rec.get(a["rid"], {})
            x["answers"].append({"text": a["text"], "at": a["at"], "state": "acknowledged" if n.get("acknowledged") else "sent", "reply": (n.get("reply") or {}).get("body") if isinstance(n.get("reply"), dict) else n.get("reply"), "test": a.get("test", False)})
    msgs = [a for a in ans if a["qid"] == "_message"][-5:]
    q["messages"] = [{"text": a["text"], "at": a["at"], "state": "acknowledged" if rec.get(a["rid"], {}).get("acknowledged") else "sent",
                      "reply": (lambda r: r.get("body") if isinstance(r, dict) else r)(rec.get(a["rid"], {}).get("reply")), "test": a.get("test", False)} for a in msgs]
    return q
_live = {"at": 0, "body": {}}
def live(key):
    """Lanes or calls from the 15s collectors, with a 3s memo so a burst of open
    tabs costs one collection. The collectors are pure local reads: no model
    calls, no gh, no Linear. PR/CI titles come from the 60s monitor cache and each
    payload reports that cache's age so the page can say what is cached."""
    with _live_lock:
        now = time.time()
        if now - _live["at"] > 3 or key not in _live["body"]:
            script = LIVE_SCRIPTS.get(key)
            if not script: raise RuntimeError("no collector for " + key)
            out = subprocess.run([sys.executable, script], capture_output=True, timeout=60)
            if out.returncode != 0:
                raise RuntimeError((out.stderr or b"").decode()[:300] or "collector failed")
            _live["body"] = {k: open(p, "rb").read() for k, p in LIVE_FILES.items()}
            _live["at"] = now
        return _live["body"][key]
def nicks():
    """Nick's questions: the collector runs on demand with the same 3s memo as the other live
    views. A collector failure is returned as a read problem, never as an empty list - an
    unreadable transcript set must not look like 'the captain asked nothing'."""
    with _live_lock:
        now = time.time()
        if now - _nick["at"] > 3 or _nick["body"] is None:
            out = subprocess.run([sys.executable, NICKS_SCRIPT], capture_output=True, timeout=120)
            if out.returncode != 0:
                raise RuntimeError((out.stderr or b"").decode()[:300] or "questions collector failed")
            _nick["body"] = open(NICKS_FILE, "rb").read()
            _nick["at"] = now
        return _nick["body"]
class H(BaseHTTPRequestHandler):
    server_version = "fmconsole"
    def log_message(self, *a): pass
    def send(self, code, body, ctype="application/json", extra=None):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store"); self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
    def send_file(self, data, ctype):
        """Bytes served on their own path: the shared CSP allows inline script but no inline FORM
        action, and Lavish's page ships its answer forms inside `<script type=text/html>`, so its
        documents get that policy with form-action opened to this origin and the local Lavish
        port. Nothing is gained there -- the document sits behind the same board login."""
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store"); self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline' 'unsafe-eval'; "
                         "script-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data: blob:; "
                         "font-src 'self' data:; connect-src 'self' " + LAVISH_ORIGINS + "; "
                         "form-action 'self' " + LAVISH_ORIGINS + "; frame-ancestors 'self' " + LAVISH_ORIGINS)
        self.end_headers(); self.wfile.write(data)
    def lavish_file(self, p):
        """One artifact file named by the Lavish page's own bundle, read under `.lavish/` only.

        The path is taken apart rather than trusted: the served document is a fixed name, and every
        other request must land inside the resolved `.lavish/` directory, so no `..` or symlink can
        walk out of it into the rest of this host."""
        # Fold the latest sweep into the page's own seed before serving it, so the copy Lavish hands
        # to a browser never lags the payload by more than this one write.
        try: subprocess.run([LAVISH_SEED], capture_output=True, timeout=30)
        except Exception: pass
        rel = urllib.parse.unquote(p[len("/lavish/"):])
        if rel in ("", LAVISH_DOC):
            try: return self.send_file(open(LAVISH_HTML, "rb").read(), "text/html; charset=utf-8")
            except Exception: return self.send(404, "the Lavish page is not on this host", "text/plain")
        base = os.path.realpath(LAVISH_DIR)
        full = os.path.realpath(os.path.join(base, rel))
        if not full.startswith(base + os.sep) or not os.path.isfile(full):
            return self.send(404, "not found", "text/plain")
        ctype = {"js": "text/javascript", "json": "application/json", "css": "text/css", "svg": "image/svg+xml",
                 "png": "image/png", "woff": "font/woff", "woff2": "font/woff2"}.get(full.rsplit(".", 1)[-1].lower(), "text/plain")
        try: return self.send_file(open(full, "rb").read(), ctype)
        except Exception: return self.send(404, "not found", "text/plain")
    def lavish_open(self):
        """Start (or find) the local Lavish page and its bridge, and say which of the three true
        states the board is in. Plain GET, like every read of this board's state, and it never
        answers a link the captain could not use."""
        r = subprocess.run([LAVISH_OPEN, "--state"], capture_output=True, text=True, timeout=30)
        try: st = json.loads(r.stdout.strip().splitlines()[-1])
        except Exception: st = {"state": "refused", "reason": "the Lavish starter could not be read"}
        if st.get("state") == "stopped":
            r = subprocess.run([LAVISH_OPEN], capture_output=True, text=True, timeout=120)
            try: st = json.loads(r.stdout.strip().splitlines()[-1])
            except Exception: st = {"state": "refused", "reason": (r.stderr or r.stdout or "the Lavish starter failed")[:200]}
        if st.get("state") in ("started", "already"):
            st["page"] = "/lavish/" + LAVISH_DOC
        return self.send(200 if st.get("state") in ("started", "already") else 503, json.dumps(st))
    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/":
            for f in (SHELL, ROOT + "/index.html"):
                try: return self.send(200, open(f, "rb").read(), "text/html; charset=utf-8")
                except Exception: continue
            return self.send(503, "console not available", "text/plain")
        if p in ("/console/progress", "/console/progress/"):
            # The AdClinica boss-progress page (captain ask 2026-11-12). Both spellings are served
            # so a link with or without the trailing slash lands here; Caddy already proxies
            # /console/* behind the board login, so no Caddy change is needed for either form.
            try: return self.send(200, open(PROGRESS, "rb").read(), "text/html; charset=utf-8")
            except Exception: return self.send(503, "progress page not available", "text/plain")
        if p == "/api/console/lavish-auth":
            # Lavish preflight (captain ask 2026-11-17). Lavish is a LOCAL server on this host, so an
            # artifact opened from the public board reads this endpoint through Caddy before it opens
            # anything: the response's Access-Control-Allow-Origin is the browser's proof that this
            # page really is the signed-in board, and its 200 replaces the JWT with a short-lived
            # ticket the page then presents to the local Lavish server. That server can only reach
            # this endpoint over 127.0.0.1, where Cloudflare Access is not in front of it, so the
            # ticket is the only thing that bridges the two -- no session or JWT ever reaches Lavish.
            # Mail is refused here: these pages carry the captain's private decisions, never a share.
            return self.send(200, json.dumps({"ok": True, "ticket": TICKETS.issue(who(self) or ""), "ttl": TICKETS.ttl}),
                             extra={"Access-Control-Allow-Origin": BOARD_ORIGIN, "Vary": "Cf-Access-Jwt-Assertion",
                                    # Chrome's Private Network Access preflight: the board page (public)
                                    # calls the local server on 127.0.0.1, so it announces the request
                                    # as private-network and this is what lets it through.
                                    "Access-Control-Allow-Private-Network": "true"})
        if p == "/api/console/open-lavish":
            # The board's one-click control (captain ask 2026-11-17) calls this to start the local
            # Lavish page and its bridge, then embeds `/lavish/<doc>` here rather than a dead link.
            # It answers with the state that is actually true (`started`, `already`, `refused`), so a
            # host with no page cannot present a button that looks like it worked.
            return self.lavish_open()
        if p.startswith("/lavish/"):
            # The same .lavish/ artifact files Lavish serves on its own port, reached through the
            # board's own login. Lavish rewrites its page for the loopback address, so the frames and
            # bundles it references are fetched under this prefix instead; without this the board's
            # CSP (form-action 'self') would silently drop every answer form bound for 127.0.0.1.
            return self.lavish_file(p)
        f = {"/console/body.html": "body.html"}.get(p)
        if f:
            try: return self.send(200, open(f"{ROOT}/{f}", "rb").read(), "text/html; charset=utf-8")
            except Exception: return self.send(503, "console data not built yet", "text/plain")
        if p.startswith("/console/fonts/"):
            name = p[len("/console/fonts/"):]
            if name not in ("IBMPlexSans-var.woff2", "IBMPlexMono-400.woff2", "IBMPlexMono-500.woff2"):
                return self.send(404, "not found", "text/plain")
            try: return self.send(200, open(f"{ROOT}/fonts/{name}", "rb").read(), "font/woff2")
            except Exception: return self.send(404, "not found", "text/plain")
        if p == "/console/profile-icon.jpg":
            # The captain's profile icon (M256): served from the board itself, behind the
            # same login, never hotlinked. A single 64px copy is crisp at the ~20px slot
            # on any HiDPI display and is the only size requested.
            try: return self.send(200, open(f"{ROOT}/assets/profile-64.jpg", "rb").read(), "image/jpeg")
            except Exception: return self.send(404, "not found", "text/plain")
        if p == "/api/console/summary":
            try: return self.send(200, open(ROOT + "/summary.json", "rb").read())
            except Exception: return self.send(503, json.dumps({"error": "board data not built yet"}))
        if p == "/api/console/urgent-questions" and not os.path.exists(PLAIN_FILES[p]):
            # Nothing swept yet on a fresh host: run the sweep once now rather than answering a 503
            # the page would have to read as a failure.
            try: subprocess.run([sys.executable, URGENT_COLLECT], capture_output=True, timeout=120)
            except Exception: pass
        if p in PLAIN_FILES:
            # Written by another process on its own schedule, so serve it as-is and
            # never pretend it is fresher than it is.
            try: return self.send(200, open(PLAIN_FILES[p], "rb").read())
            except Exception as ex: return self.send(503, json.dumps({"error": "not available: " + str(ex)[:160]}))
        if p in ("/api/console/lanes", "/api/console/calls", "/api/console/superagent"):
            # Real-time views (captain 2026-11-06): the collectors are local file
            # reads only, ~60ms each and no model calls, so running them on demand
            # is cheap. A 3s in-process cache collapses a burst of open tabs onto
            # one collection without making the 15s poll stale.
            try: return self.send(200, live(p))
            except Exception as ex: return self.send(500, json.dumps({"error": "live view failed: " + str(ex)[:200]}))
        if p == "/api/console/speed": return self.send(200, json.dumps(speed_state()))
        if p == "/api/console/nicks":
            try: return self.send(200, nicks())
            except Exception as ex: return self.send(500, json.dumps({"error": "questions view failed: " + str(ex)[:200]}))
        if p == "/api/console/questions": return self.send(200, json.dumps(questions()))
        if p == "/api/console/update-request":
            # The page asks for the current state of the rows it shows, so a reload (or a tab left
            # open) sees the same window the server enforces.
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            keys = [k.upper() for k in re.split(r"[,\s]+", q.get("keys", [""])[0]) if UPDATE_KEY.match(k)]
            return self.send(200, json.dumps(update_state(sorted(set(keys))[:40])))
        if p == "/api/console/flight-action":
            # The modal asks for the current state of the flight it shows, so a reload (or a second
            # tab) sees the same requests the first did.
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            keys = [k.upper() for k in re.split(r"[,\s]+", q.get("key", "")[0]) if UPDATE_KEY.match(k)]
            return self.send(200, json.dumps(flight_state(sorted(set(keys))[:20])))
        if p == "/api/console/board-decisions":
            return self.send(200, json.dumps(board_decisions()))
        if p == "/api/console/decisions":
            try: return self.send(200, json.dumps(deck_state()))
            except Exception as ex: return self.send(500, json.dumps({"error": "decision deck failed: " + str(ex)[:200]}))
        self.send(404, "not found", "text/plain")
    def do_OPTIONS(self):
        # Lavish preflight (captain ask 2026-11-17): the artifact lives in the .lavish/ directory of
        # the home whose decisions it shows, and redeems a single-use ticket there (/redeem) before
        # it forwards an answer. The board page asks this server for the ticket over CORS, so these
        # are answered without a body and without the JSON branch below.
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", BOARD_ORIGIN)
        self.send_header("Vary", "Cf-Access-Jwt-Assertion")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Cf-Access-Jwt-Assertion")
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Access-Control-Max-Age", "600")
        self.send_header("Content-Length", "0")
        self.end_headers()
    def do_POST(self):
        p = self.path.split("?")[0]
        if p in ("/redeem", "/api/redeem"):
            # Lavish bridge (captain ask 2026-11-17): the local Lavish server, never a browser
            # holding an Access session, presents the ticket this console minted for the signed-in
            # board. A 200 says the page may write through the board's own endpoints; a refusal
            # names why. Nothing is written here.
            try:
                n = int(self.headers.get("Content-Length") or 0); d = json.loads(self.rfile.read(min(n, 8000)) or b"{}")
            except Exception: d = {}
            email = TICKETS.redeem(str(d.get("ticket", "")))
            if email in (ALLOWED, TEST_OK):
                return self.send(200, json.dumps({"ok": True, "via": "board"}))
            return self.send(401, json.dumps({"ok": False, "error": "this Lavish page was not opened from the signed-in board, or its ticket is more than %d seconds old; open it from the board's Questions tab" % TICKETS.ttl}))
        if p not in ("/api/console/answer", "/api/console/message", "/api/console/speed", "/api/console/decision", "/api/console/request", "/api/console/followup", "/api/console/update-request", "/api/console/flight-action"): return self.send(404, "not found", "text/plain")
        email = who(self)
        test_only = email is not None and email == TEST_OK and email != ALLOWED
        if email is None or (email != ALLOWED and not test_only): return self.send(403, json.dumps({"error": "not allowed"}))
        if "application/json" not in (self.headers.get("Content-Type") or ""): return self.send(415, json.dumps({"error": "json only"}))
        try: n = int(self.headers.get("Content-Length") or 0); d = json.loads(self.rfile.read(min(n, 8000)))
        except Exception: return self.send(400, json.dumps({"error": "bad json"}))
        # Get update (captain order 2026-11-15, ADC-1234). It must be tested BEFORE the older
        # `endswith("request")` branch below, which also matches this path and would answer
        # "bad request kind" first. One row asks firstmate for a fresh status on its own Linear key,
        # through the same write path and shape as the follow-up branch. The request id is
        # deterministic per key and millisecond, so a double submit replays the one note instead of
        # creating a second. The 5-minute window is checked HERE, on the ledger, because the page is
        # not the authority over its own rate limit.
        if p == "/api/console/flight-action":
            # Captain ask 2026-11-17: a flight's modal carries Accelerate and Pause. One note through
            # the board's only write path, addressed to the lane or Super Agent ticket that owns the
            # flight. Nothing here starts work or writes Linear: firstmate acts on the note. The
            # request id is deterministic per key, action and millisecond, so a double submit replays
            # the one note instead of creating a second; the 5-minute window is enforced HERE, on the
            # ledger, because the page is not the authority over its own rate limit.
            test = bool(d.get("test")) or test_only
            if test_only and not d.get("test"): return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
            key = str(d.get("key", "")).strip().upper()
            if not UPDATE_KEY.match(key): return self.send(400, json.dumps({"error": "a Linear issue key is required, for example ADC-1234"}))
            action = str(d.get("action", "")).strip().lower()
            if action not in ("accelerate", "pause"): return self.send(400, json.dumps({"error": "action must be accelerate or pause"}))
            cur = flight_state([key])
            row = (cur.get("rows") or {}).get(key) or {}
            if row.get("open"):
                return self.send(429, json.dumps({"error": "one request per flight per 5 minutes", "state": row}))
            # The owner comes from the page's own payload (the collector's lanes/workers join), so a
            # flight with nothing running is named as unroutable instead of being sent to a guess.
            owner = str(d.get("owner", "")).strip()[:120]
            home = str(d.get("home", "")).strip()[:200]
            if not owner:
                # An unowned flight (captain ask 2026-11-18): the note goes to firstmate itself to review
                # and task, built from the server's own flights payload. The open-request check above
                # already refuses a second one until firstmate answers, so it cannot be double-sent.
                f = flight_row(key)
                if not f:
                    return self.send(409, json.dumps({"error": "this flight is not on the board's flights payload right now; reload the page", "state": row}))
                rid = f"console-flight-{action}-{key}-{int(time.time() * 1000)}"
                res = note(("TEST " if test else "") + unowned_flight_note(key, action, f), rid)
                if "error" in res:
                    flight_record(key, rid, action, "no owner", test=test, error=res.get("error") or "the inbox refused the note")
                    return self.send(502, json.dumps({"error": "could not reach firstmate inbox"}))
                flight_record(key, rid, action, "no owner", note_id=res.get("id"), test=test)
                return self.send(200, json.dumps({"ok": True, "key": key, "action": action, "request": rid,
                                                  "note": res.get("id"), "test": test, "unowned": True,
                                                  "state": (flight_state([key]).get("rows") or {}).get(key)}))
            if action == "accelerate":
                body = (f"CAPTAIN FLIGHT ACCELERATE (via console) for [{key}]: get this flight moving. "
                        f"Its owner in the flights payload is {owner}" + (f" in {home}" if home else "") +
                        ". Steer that lane or ticket now, or dispatch a worker if nothing live can be steered, "
                        "and reply with what you did and the new state.")
            else:
                body = (f"CAPTAIN FLIGHT PAUSE (via console) for [{key}]: stop work on this flight and record it as held "
                        f"for the captain. Its owner in the flights payload is {owner}" + (f" in {home}" if home else "") +
                        ". Hold it through the captain-hold path rather than starting anything else on it, "
                        "and reply with what you stopped and the hold you recorded.")
            rid = f"console-flight-{action}-{key}-{int(time.time() * 1000)}"
            res = note(("TEST " if test else "") + body, rid)
            if "error" in res:
                flight_record(key, rid, action, owner, test=test, error=res.get("error") or "the inbox refused the note")
                return self.send(502, json.dumps({"error": "could not reach firstmate inbox"}))
            flight_record(key, rid, action, owner, note_id=res.get("id"), test=test)
            return self.send(200, json.dumps({"ok": True, "key": key, "action": action, "request": rid,
                                              "note": res.get("id"), "test": test,
                                              "state": (flight_state([key]).get("rows") or {}).get(key)}))
        if p == "/api/console/update-request":
            test = bool(d.get("test")) or test_only
            if test_only and not d.get("test"): return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
            key = str(d.get("key", "")).strip().upper()
            if not UPDATE_KEY.match(key): return self.send(400, json.dumps({"error": "a Linear issue key is required, for example ADC-1234"}))
            cur = update_state([key])
            row = (cur.get("rows") or {}).get(key) or {}
            if row.get("open"):
                return self.send(429, json.dumps({"error": "one update request per task per 5 minutes", "state": row}))
            rid = f"console-update-{key}-{int(time.time() * 1000)}"
            body = (f"CAPTAIN UPDATE REQUEST (via console) to [{key}] Please reply with: current state, "
                    "percent complete, ETA, and any blockers.")
            res = note(("TEST " if test else "") + body, rid)
            if "error" in res:
                update_record(key, rid, test=test, error=res.get("error") or "the inbox refused the note")
                return self.send(502, json.dumps({"error": "could not reach firstmate inbox"}))
            update_record(key, rid, note_id=res.get("id"), test=test)
            return self.send(200, json.dumps({"ok": True, "key": key, "request": rid, "note": res.get("id"),
                                              "test": test, "state": (update_state([key]).get("rows") or {}).get(key)}))
        if p.endswith("request"):
            # Captain 2026-11-09: capacity requests (more lanes / more Super Agent workers) and
            # Linear issues sent to firstmate to review, plan and delegate to Super Agent.
            # Writes only an inbox note, like every other console action.
            kind = str(d.get("kind", ""))
            test = bool(d.get("test")) or test_only
            if test_only and not d.get("test"): return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
            extra = re.sub(r"\s+", " ", str(d.get("text", ""))).strip()[:600]
            if kind in ("lanes", "superagent"):
                proj = str(d.get("project", ""))
                if proj not in ("adclinica", "v10", "fdc", "all"): return self.send(400, json.dumps({"error": "bad project"}))
                what = "working lanes" if kind == "lanes" else "active Super Agent workers"
                body = f"CAPTAIN REQUEST (via console): increase {what} for {proj}. Find why capacity is idle, fill it now, and report before/after counts." + (f" Note: {extra}" if extra else "")
            elif kind == "linear":
                keys = sorted(set(k.upper() for k in re.findall(r"\b([A-Za-z]{2,5}-\d{1,6})\b", str(d.get("keys", "")))))[:20]
                if not keys: return self.send(400, json.dumps({"error": "no Linear issue keys found (e.g. FDC-657)"}))
                body = ("CAPTAIN LINEAR REVIEW (via console): " + ", ".join(keys) + ". Review each issue, plan it, and delegate it to Super Agent "
                        "the best way (code ticket with a verified-on-main line and proof requirement); non-code or captain-only parts come back as decisions." + (f" Note: {extra}" if extra else ""))
            else:
                return self.send(400, json.dumps({"error": "bad request kind"}))
            rid = f"console-request-{kind}-{int(time.time() * 1000)}"
            res = note(("TEST " if test else "") + body, rid)
            if "error" in res: return self.send(502, json.dumps({"error": "could not reach firstmate inbox"}))
            return self.send(200, json.dumps({"ok": True}))
        if p.endswith("followup"):
            # Nick's questions (captain ask M321): a follow-up posted against one card becomes one
            # inbox note, the same write every other console action performs. It carries the ask id
            # so the answer can be shown back on that card.
            test = bool(d.get("test")) or test_only
            if test_only and not d.get("test"): return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
            ask = re.sub(r"[^A-Za-z0-9-]", "", str(d.get("ask", "")))[:24]
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,23}", ask): return self.send(400, json.dumps({"error": "a card id is required"}))
            extra = re.sub(r"\s+", " ", str(d.get("text", ""))).strip()[:1500]
            if not extra: return self.send(400, json.dumps({"error": "empty follow-up"}))
            rid = f"console-followup-{ask}-{int(time.time() * 1000)}"
            res = note(("TEST " if test else "") + f"CAPTAIN FOLLOW-UP (via console) to [{ask}] {extra}", rid)
            if "error" in res: return self.send(502, json.dumps({"error": "could not reach firstmate inbox"}))
            return self.send(200, json.dumps({"ok": True, "ask": ask, "request": rid, "test": test}))
        if p.endswith("speed"):
            proj, act = str(d.get("project", "")), str(d.get("action", ""))
            if proj not in ("adclinica", "v10", "fdc") or act not in ("faster", "slower", "pause"): return self.send(400, json.dumps({"error": "bad speed request"}))
            test = bool(d.get("test")) or test_only
            if test_only and not d.get("test"): return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
            rid = f"console-speed-{proj}-{int(time.time() * 1000)}"
            res = note(("TEST " if test else "") + f"CAPTAIN SPEED {proj} {act}", rid)
            if "error" in res: return self.send(502, json.dumps({"error": "could not reach firstmate inbox"}))
            with LOCK, open(SPD, "a") as f: f.write(json.dumps({"project": proj, "action": act, "at": time.time(), "rid": rid, "base": lane_floor().get(proj), "mt": floor_mtime(), "test": test}) + "\n")
            return self.send(200, json.dumps({"ok": True}))
        text = re.sub(r"\s+", " ", str(d.get("text", ""))).strip()[:1500]; test = bool(d.get("test")) or test_only
        if test_only and not d.get("test"): return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
        qid = "_message" if p.endswith("message") else re.sub(r"[^A-Za-z0-9_.:-]", "", str(d.get("qid", "")))[:60]
        choice = re.sub(r"[^\w .,'()/:;%$&+?!-]", "", str(d.get("choice", "")))[:300]
        if not text and not choice: return self.send(400, json.dumps({"error": "empty"}))
        title = re.sub(r"\s+", " ", str(d.get("title", "")))[:500]
        if p.endswith("decision"):
            # A critical decision from data/board-decisions.json (captain order 2026-11-19): `board` names
            # the item, `choice` must be one of its own labels verbatim, `text` is the captain's own words.
            # The note is exactly 'CAPTAIN ANSWER (via console) to [<id>] <option label or text>'.
            if d.get("board"):
                ident = str(d.get("board") or "").strip()
                if not BOARD_ID.match(ident):
                    return self.send(400, json.dumps({"error": "bad decision id"}))
                if test_only and not d.get("test"):
                    return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
                it = board_item(ident)
                if not it:
                    return self.send(409, json.dumps({"error": "this decision is no longer open - it was answered or removed"}))
                labels = ([it["recommended"]["label"]] if it.get("recommended") else []) + [a["label"] for a in it["alternatives"]]
                bchoice = str(d.get("choice") or "").strip()
                btext = re.sub(r"\s+", " ", str(d.get("text") or "")).strip()[:1500]
                if bchoice and bchoice not in labels:
                    return self.send(400, json.dumps({"error": "that is not one of this decision's options"}))
                if not bchoice and not btext:
                    return self.send(400, json.dumps({"error": "pick an option or write an answer"}))
                btest = bool(d.get("test")) or test_only
                answer = bchoice + ((". " + btext) if (bchoice and btext) else btext)
                rid = "console-board-%s-%d" % (ident, int(time.time() * 1000))
                res = note(("TEST " if btest else "") + "CAPTAIN ANSWER (via console) to [%s] %s" % (ident, answer), rid)
                if "error" in res:
                    return self.send(502, json.dumps({"error": "could not reach firstmate inbox, so nothing was recorded"}))
                rec = record("board-decision", ident, it["title"], bchoice, btext, btest, rid)
                return self.send(200, json.dumps({"ok": True, "id": ident, "answer": answer, "note": res.get("id"),
                                                  "test": btest, "duplicate": rec is None,
                                                  "conflict": bool(rec and rec.get("conflict"))}))
            # Structured card (captain 2026-11-16): `card` names a file in the deck, and the whole
            # answer - card move, answers.jsonl, the captain record, firstmate's note, the asker's
            # note and the project's decisions line - succeeds before the POST answers anything.
            # A test identity may answer a test card only; a real answer stays a real answer.
            if d.get("card"):
                ident = str(d.get("card") or "").strip()
                if not DEC or not DEC.safe_id(ident):
                    return self.send(400, json.dumps({"error": "bad card id"}))
                if test_only and not d.get("test"):
                    return self.send(403, json.dumps({"error": "this identity may only send test answers"}))
                ctext = re.sub(r"[^\w .,'()/:;%$&+?!-]", "", str(d.get("text", ""))).strip()[:1200]
                cchoice = re.sub(r"[^\w .,'()/:;%$&+?!-]", "", str(d.get("choice", ""))).strip()[:300]
                code, out = submit_card(ident, cchoice, ctext, bool(d.get("test")) or test_only)
                return self.send(code, json.dumps(out))
            raw_n = re.sub(r"[^0-9a-z]", "", str(d.get("n", "")).lower())[:4]
            if not re.fullmatch(r"\d+[a-z]?", raw_n): return self.send(400, json.dumps({"error": "bad card number"}))
            live = cards()["cards"]
            # exact card first ("4b"); a bare number ("4") from an older page resolves only if exactly one card carries it
            cur = [c for c in live if c["n"] == raw_n] or ([c for c in live if re.sub(r"[a-z]$", "", c["n"]) == raw_n] if raw_n.isdigit() else [])
            if len(cur) > 1: return self.send(409, json.dumps({"error": "decision %s matches several cards; reload the page" % raw_n}))
            if not cur: return self.send(409, json.dumps({"error": "decision %s is not on the list that is live now" % raw_n}))
            c = cur[0]
            if choice and choice not in c["options"] and choice not in c["question"] and choice not in c["context"]:
                return self.send(400, json.dumps({"error": "that is not one of this card's options"}))
            ident, kind = "decision-" + cur[0]["n"], "decision"
            body = ("TEST " if test else "") + "CAPTAIN ANSWER (via console) to [%s %s]: %s%s" % (
                ident, c["question"], choice or "(no button)", (". " + text) if text else "")
        else:
            ident, kind = qid, ""
            body = ("TEST " if test else "") + (f"CAPTAIN MESSAGE (via console): {text}" if qid == "_message" else f"CAPTAIN ANSWER (via console) to [{qid}] {title}: {choice or '(no button)'}{'. ' + text if text else ''}")
        rid = f"console-{ident if kind else qid}-{int(time.time() * 1000)}"
        res = note(body, rid)
        if "error" in res: return self.send(502, json.dumps({"error": "could not reach firstmate inbox"}))
        rec = record(kind, ident, title, choice, text, test, rid)
        return self.send(200, json.dumps({"ok": True, "conflict": bool(rec and rec.get("conflict")), "duplicate": rec is None}))
ThreadingHTTPServer(("127.0.0.1", 4390), H).serve_forever()
