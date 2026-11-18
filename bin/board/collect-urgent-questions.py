#!/usr/bin/env python3
"""collect-urgent-questions.py - the captain's genuinely open questions, swept from live records.

The captain's ask (2026-11-17): his questions must reach the board's Next questions area and the
Lavish page by themselves. Nothing here is written by hand, and nothing on the page is a static
list: this collector runs on a timer (fm-urgent-questions.timer), reads three families of records
from every home on this host, and writes ONE payload the console server serves and both pages poll.

  OUT (/mnt/workdisk/tmp/fm-console/urgent-questions.json)   payload the board and Lavish read

THE THREE FAMILIES, each a real read of its own ledger
  cards     the captain's numbered list  ~/firstmate/data/decision-cards/open-decisions.md, parsed by
            the console server's own /api/console/decisions (so the board and this page can never
            disagree), PLUS the structured deck /mnt/workdisk/fm-decisions/open/*.json, inlined
            from the same payload so the Lavish page can render each card's own options.
  holds     every backlog under ~/fm-homes/*/ and ~/firstmate: the open items the home is holding
            FOR the captain (a `hold:` field whose `hold-kind: captain`, or an owner/captain call
            subject in a home that does not record the kind). A completed item drops out.
  calls     owner calls and escalations: the board's own callback feed (questions.json, the owner /
            captain calls in it, still unanswered) and any `*-owner-call*` record a home keeps.

DEDUPLICATED BY KEY. One question appears once even when two sources name it: a numbered card and
the owner call it came from share the question text's fingerprint, and a hold's own id is the last
resort. The first source in the order above wins and the payload records which sources agreed.

A QUESTION DROPS OFF when its record says so, never when it ages: a card answered on the board is
gone from /api/console/decisions, a held item marked done leaves its backlog, an owner call with an
answer record is not listed. A home or ledger that cannot be read is reported in `problems` with
its path - never silently missing from the list.
"""
import base64, hashlib, json, os, re, subprocess, sys, time
from urllib.parse import urlsplit

OUT = "/mnt/workdisk/tmp/fm-console/urgent-questions.json"
CONSOLE = "http://127.0.0.1:4390"
HOMES = sorted(["/home/azureuser/firstmate"] +
               [os.path.join("/home/azureuser/fm-homes", d)
                for d in os.listdir("/home/azureuser/fm-homes")
                if os.path.isdir(os.path.join("/home/azureuser/fm-homes", d))]) if os.path.isdir("/home/azureuser/fm-homes") else ["/home/azureuser/firstmate"]
QUESTIONS_JSON = "/mnt/workdisk/tmp/fm-console/questions.json"
CALL_RE = re.compile(r"\b(owner|client|captain)[ -](call|decision|consent|go[- ]ahead)\b", re.I)
HOLD_ITEM = re.compile(r"^- \[ \] ([^ ]+) - (.*)$")


def norm(s):
    """A question's fingerprint: its words, without markup, paths, ids or money.
    Two sources that ask the same question normalise to the same key, which is what makes the
    deduplication below a real match rather than a prefix guess."""
    s = re.sub(r"\(repo: [^)]*\)|\(kind: [^)]*\)|\(since [^)]*\)|\(priority: [^)]*\)|\(hold: [^)]*\)|\(hold-kind: [^)]*\)", " ", s or "")
    s = re.sub(r"\b[A-Z]{2,5}-\d{1,6}\b|\b\d{3,}\b|\$\s?[\d.]+", " ", s)
    s = re.sub(r"[^a-z0-9 ]+", " ", s.lower())
    return " ".join(s.split())[:160]


BADGE = re.compile(r"\s*\((?:repo|kind|priority|since|hold-kind|hold|origin|until|blocked-by|branch)\s*:[^()]*\)|\s*\(since \d{4}-\d{2}-\d{2}\)", re.I)


def title_of(subject):
    """A backlog subject carries the board's own badges in one line: (repo: x) (kind: captain)
    (since ...) (hold: ...). The question is everything before them."""
    return re.sub(r"\s+", " ", BADGE.sub("", subject or "")).strip(" -")


def key_of(question, fallback=""):
    n = norm(question)
    if len(n) >= 20:
        return "q-" + hashlib.sha1(n.encode()).hexdigest()[:12], n
    return "r-" + hashlib.sha1((fallback or question or "").encode()).hexdigest()[:12], n


def held_reason(raw):
    """A hold field is `fm-hold-v1:<base64>`; older rows carry plain text. Decode what we can and
    keep the raw field when we cannot, so a reason is never invented."""
    if not isinstance(raw, str) or not raw:
        return ""
    if raw.startswith("fm-hold-v1:"):
        b = raw.split(":", 1)[1]
        try:
            return base64.b64decode(b + "=" * (-len(b) % 4)).decode("utf-8", "replace").strip()
        except Exception:
            return ""
    return raw.strip()


def get(url):
    import urllib.request
    with urllib.request.urlopen(url, timeout=40) as r:
        return json.loads(r.read() or b"{}")


def cards(problems, items):
    """Family 1: the board's decision deck, read through the board's own module of truth."""
    try:
        d = get(CONSOLE + "/api/console/decisions")
    except Exception as ex:
        problems.append({"source": "decision-cards", "path": CONSOLE + "/api/console/decisions",
                         "error": "the board's decision payload could not be read: " + str(ex)[:160]})
        return
    if d.get("error"):
        problems.append({"source": "decision-cards", "path": CONSOLE + "/api/console/decisions", "error": str(d["error"])[:200]})
        return
    if not isinstance(d.get("open"), list) or not isinstance(d.get("scards"), dict):
        problems.append({"source": "decision-cards", "path": CONSOLE + "/api/console/decisions", "error":
                         "the board answered without a decision list, so the numbered cards and the structured deck could not be read"})
        return
    for p in (d.get("scards") or {}).get("problems", []) or []:
        problems.append({"source": "decision-cards", "path": (d.get("scards") or {}).get("dir", "/mnt/workdisk/fm-decisions/open"), "error": str(p)[:200]})
    for c in (d.get("scards") or {}).get("open", []) + (d.get("scards") or {}).get("stale", []):
        items.append({"source": "card", "id": c.get("id"), "ref": c.get("ref", ""), "project": c.get("project", ""),
                      "asked_by": c.get("asked_by", ""), "question": c.get("question", ""), "context": c.get("context", ""),
                      "options": [o if isinstance(o, dict) else {"label": str(o)} for o in (c.get("options") or [])],
                      "blocks": c.get("blocks") or [], "asked_at": c.get("asked_at", ""), "expires_at": c.get("expires_at", ""),
                      "stale": bool(c.get("stale")), "problems": c.get("problems") or [], "card": True,
                      "record": (d.get("scards") or {}).get("dir", "/mnt/workdisk/fm-decisions/open") + "/" + str(c.get("id")) + ".json"})
    for c in d.get("open", []):
        if c.get("card"):
            continue          # already carried above with its structured fields
        items.append({"source": "card", "id": "decision-" + str(c.get("n")), "n": c.get("n"), "project": "",
                      "question": c.get("question", ""), "context": c.get("context", ""),
                      "options": [{"label": o} for o in (c.get("options") or [])],
                      "asked_at": "", "stale": False, "problems": [], "card": False,
                      "record": "/home/azureuser/firstmate/data/decision-cards/open-decisions.md"})


def holds(problems, items):
    """Family 2: held backlog items, every home, read as the plain markdown records they are."""
    for home in HOMES:
        path = os.path.join(home, "data", "backlog.md")
        if not os.path.exists(path):
            problems.append({"source": "holds", "path": path, "error": "this home has no backlog file, so its held items could not be swept"})
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except Exception as ex:
            problems.append({"source": "holds", "path": path, "error": "the backlog could not be read: " + str(ex)[:160]})
            continue
        home_name = "firstmate" if home == "/home/azureuser/firstmate" else os.path.basename(home)
        for block in re.split(r"\n(?=- \[)", "\n" + text):
            m = HOLD_ITEM.match(block.strip().splitlines()[0])
            if not m:
                continue
            title, body = m.group(2), block
            hold = re.search(r"\(hold: ([^)]+)\)", body)
            kind = re.search(r"\(hold-kind: ([^)\s]+)\)", body)
            if not hold and not CALL_RE.search(title):
                continue
            if not hold:
                continue                      # an owner-call subject is only a question while it is held
            if kind and kind.group(1) not in ("captain",):
                continue                      # a work hold is firstmate's queue, not the captain's
            if not kind and not CALL_RE.search(title):
                continue                      # untyped hold with no captain-call wording: not provably his
            items.append({"source": "hold", "id": m.group(1), "home": home_name, "project": home_name,
                          "question": title_of(title), "context": held_reason(hold.group(1)),
                          "options": [], "asked_at": "", "stale": False, "problems": [], "card": False,
                          "record": path})


def calls(problems, items):
    """Family 3: owner calls and escalations still unanswered in the board's callback feed."""
    try:
        q = json.load(open(QUESTIONS_JSON, encoding="utf-8"))
        rows = q.get("questions")
        if not isinstance(rows, list):
            raise ValueError("the feed has no question list")
    except Exception as ex:
        problems.append({"source": "calls", "path": QUESTIONS_JSON, "error": "the board's callback feed could not be read: " + str(ex)[:160]})
        return
    feed_home = "/home/azureuser/fm-homes/deck"
    answered = set()
    try:
        rec = subprocess.run(["/home/azureuser/firstmate/bin/fm-inbox.sh", "receipts", "--all-pending", "--all-handled"],
                             capture_output=True, text=True, timeout=40,
                             env={**os.environ, "FM_HOME": feed_home})
        d = json.loads(rec.stdout)
        for n in d.get("pending", []) + d.get("handled", []):
            if n.get("request_id"):
                answered.add(n["request_id"])
    except Exception as ex:
        problems.append({"source": "calls", "path": feed_home + "/state/inbox", "error":
                         "the answers to the callback feed could not be read: " + str(ex)[:160]})
    for r in rows:
        if not isinstance(r, dict):
            problems.append({"source": "calls", "path": QUESTIONS_JSON, "error": "one feed row is not a record"})
            continue
        kind = str(r.get("kind") or "")
        subject = " ".join(str(r.get(k) or "") for k in ("title", "text"))
        if kind not in ("hold", "captain_call", "owner_call", "captain", "decision") and not CALL_RE.search(subject):
            continue
        if r.get("answers") or r.get("answer") or r.get("id") in answered:
            continue                      # answered, so it is no longer an open question
        if kind not in ("hold", "captain_call", "owner_call", "captain", "decision") and not CALL_RE.search(str(r.get("title") or "")):
            continue                      # the wording alone is not enough on a row that is not a call
        items.append({"source": "call", "id": str(r.get("id") or ""), "home": r.get("home") or "",
                      "project": r.get("project") or r.get("home") or "", "question": str(r.get("title") or r.get("text") or ""),
                      "context": str(r.get("text") or "")[:600], "options": [{"label": str(o)} for o in (r.get("options") or [])],
                      "asked_at": str(r.get("since") or ""), "stale": False, "problems": [], "card": False,
                      "record": QUESTIONS_JSON, "kind": kind})


def main():
    t0 = time.time()
    problems, items = [], []
    for fam in (cards, holds, calls):
        try:
            fam(problems, items)
        except Exception as ex:                       # a family failure is reported, never fatal
            problems.append({"source": fam.__name__, "path": "", "error": "the sweep failed: " + str(ex)[:200]})
    seen, out = {}, []
    for it in items:
        k, n = key_of(it.get("question", ""), str(it.get("id") or ""))
        if k in seen:
            seen[k]["also"] = seen[k].get("also", []) + [it.get("source")]
            continue
        it["key"] = k
        it["norm"] = n
        it["also"] = []
        seen[k] = it
        out.append(it)
    # One question, one card: a legacy numbered card and the owner call behind it are the same
    # question, so the card (which carries the board's buttons) keeps the place and the other
    # source is named in `also` rather than drawn twice.
    payload = {"at": int(time.time()), "took_ms": int((time.time() - t0) * 1000), "count": len(out),
               "by_source": {s: len([i for i in out if i["source"] == s]) for s in ("card", "hold", "call")},
               "items": out, "problems": problems,
               "sources": {"cards": CONSOLE + "/api/console/decisions", "holds": [h + "/data/backlog.md" for h in HOMES],
                           "calls": QUESTIONS_JSON, "homes": HOMES}}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp, OUT)
    print("urgent-questions: %d open (%s), %d problems, %d ms" %
          (payload["count"], ", ".join("%s %d" % kv for kv in payload["by_source"].items()), len(problems), payload["took_ms"]))


if __name__ == "__main__":
    main()
