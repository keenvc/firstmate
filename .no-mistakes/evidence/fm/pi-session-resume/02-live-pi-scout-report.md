# Scout report: Pi session-id launch contract (throwaway lab)

**Task:** live-pi-1 (scout, kind=scout, harness=pi) — *Confirm the Pi session-id launch contract in a throwaway lab.*
**Spec:** "Do nothing; this scout exists only to prove the launch line."
**Verdict:** **CONFIRMED.** The fresh-spawn half and the relaunch half of the Pi session-id contract both held live on this host, end to end.

---

## 1. What "the launch contract" is

The contract, as owned by the Firstmate repo (HEAD `049610f`, worktree
`/home/azureuser/.no-mistakes/worktrees/6f716179fc56/01M3GCE884BCEYSKS0A6H4Y6QN`),
has two halves for a Pi/pi-signed **ship or scout**:

1. **Fresh spawn** — when the resolved `pi` executable's `--help` advertises `--session-id`,
   the launch passes `--session-id <task-id>.<spawn-gen>` and records the *same* value as
   `pi_session_id=` in `state/<id>.meta`. The `<spawn-gen>` component scopes the session to
   one incarnation so a torn-down task id re-spawned into the same copy path opens a **new**
   session rather than recalling the abandoned attempt.
2. **Relaunch** — the launch passes the `pi_session_id` the **prior record** names (and only
   when it names one), continuing that conversation. The runtime-bound Herdr session, when
   present, takes precedence. A secondmate gets neither.

Source anchors (firstmate repo, HEAD `049610f`):

- `bin/fm-spawn.sh:176-182` — header: fresh spawn uses `<task-id>.<spawn-gen>`; relaunch uses the prior record's id.
- `bin/fm-spawn.sh:4833` — `PI_SESSION_ID="$ID.$SPAWN_GEN"` (fresh-spawn value).
- `bin/fm-spawn.sh:4875-4878` — relaunch republishes `RELAUNCH_PI_SESSION_ID`; otherwise the fresh incarnation id.
- `bin/fm-spawn.sh:2590-2625` — `pi_session_args()`: `pi|pi-signed` + `ship|scout` only; relaunch path returns the recorded id.
- `bin/fm-spawn.sh:5042` — substitutes `__PISESSION__` into the launch line.
- `bin/fm-spawn.sh:2300-2301` — `PI_SESSION_FLAG=--session-id` gated on `pi_help_advertises_flag`.
- `bin/fm-control-lib.sh:276-282` — `fm_control_relaunch_resume_flag` (runtime-bound session wins for pi/pi-signed).
- `.agents/skills/harness-adapters/references/harness/pi.md` — the prose contract (Resume row).
- Tests: `tests/fm-spawn-pi-session.test.sh` (fresh spawn) and `tests/fm-control-relaunch.test.sh:1083-1106` (relaunch resumes recorded id).

---

## 2. Live facts observed

Host time of the original spawn: `2026-09-28T04:26:37Z` (epoch 1790569596).
Host time of the relaunch: `2026-09-28T04:28:11Z` (epoch 1790569689).

### 2a. The resolved executable advertises the flag

```
$ pi --version
0.87.1
$ pi --help | grep -i session-id
  --session-id <id>              Use exact project session ID, creating it if missing
```

### 2b. Fresh spawn: the session id is `<task-id>.<spawn-gen>` and is recorded

Environment exported by the spawned Pi to its tool children:

```
$ env | grep '^PI_'
PI_CODING_AGENT=true
PI_MODEL=accounts/fireworks/models/deepseek-v4p1-flash
PI_PROVIDER=fireworks
PI_REASONING_LEVEL=high
PI_SESSION_FILE=/home/azureuser/.pi/agent/sessions/--tmp-fm-lab.qrYLah-treehouse-.treehouse-demo-816e8c-1-demo--/2026-09-28T04-26-37-866Z_live-pi-1.s1790569596.2313238.6035.jsonl
PI_SESSION_ID=live-pi-1.s1790569596.2313238.6035
```

The task record agreed exactly:

```
$ grep -E '^(pi_session_id|spawn_gen|busy_gen|window)=' /tmp/fm-lab.qrYLah/state/live-pi-1.meta   # (original, pre-relaunch)
window=fmses:fm-live-pi-1
pi_session_id=live-pi-1.s1790569596.2313238.6035
busy_gen=g1790569596.2326053.31190
spawn_gen=s1790569596.2313238.6035
```

`PI_SESSION_ID == "<task-id>.<spawn_gen>"`:
`live-pi-1` + `.` + `s1790569596.2313238.6035`. ✅

The session file exists and its own header line names the same id and cwd:

```
$ head -1 "$PI_SESSION_FILE"
{"type":"session","version":3,"id":"live-pi-1.s1790569596.2313238.6035",
 "timestamp":"2026-09-28T04:26:37.866Z",
 "cwd":"/tmp/fm-lab.qrYLah/treehouse/.treehouse/demo-816e8c/1/demo"}
```

### 2c. Relaunch: the prior recorded id is resumed, not replaced

The task was relaunched mid-investigation (progress note: *"lane closed; resume the saved Pi session"*).
The transaction journal `/tmp/fm-lab.qrYLah/state/live-pi-1.control-relaunch` reads:

```
phase=complete
ts=2026-09-28T04:28:11Z
backend=tmux
endpoint=fmses:fm-live-pi-1
from_harness=pi  to_harness=pi
exit_result=stopped
```

Comparing the preserved prior record with the republished one:

| field | prior (`...meta-prior`) | after relaunch (`...meta`) |
|---|---|---|
| `pi_session_id` | `live-pi-1.s1790569596.2313238.6035` | `live-pi-1.s1790569596.2313238.6035` (**unchanged**) |
| `spawn_gen` | `s1790569596.2313238.6035` | `s1790569689.2583343.4981` (**new incarnation**) |
| `busy_gen` | `g1790569596.2326053.31190` | `g1790569689.2588903.11091` (**new incarnation**) |
| `control_relaunch_tx` | — | `2571373.20260928T042806Z.14327` |

So the relaunch keeps the **resumed** session id while it rotates the per-incarnation
`spawn_gen`/`busy_gen` — exactly the contract. It does **not** apply the new
`<task-id>.<spawn_gen>` to a relaunch.

Live environment after relaunch still reports the resumed session:

```
$ env | grep PI_SESSION
PI_SESSION_FILE=/home/azureuser/.pi/agent/sessions/--...--/2026-09-28T04-26-37-866Z_live-pi-1.s1790569596.2313238.6035.jsonl
PI_SESSION_ID=live-pi-1.s1790569596.2313238.6035
```

Process replacement on the same endpoint/worktree (same ancestor chain
`-bash -> treehouse get -> bash -> pi`):

```
# before relaunch: pi pid 2329954
# after  relaunch: pi pid 2592195   (old pid gone, new child of the same /bin/bash 2320177)
```

Conversation continuity is real: the **same** JSONL session file
(`2026-09-28T04-26-37-866Z_...jsonl`, first-line timestamp 04:26:37) contains the
pre-relaunch turns *and* the relaunch progress note:

```
$ grep -c "This task was relaunched" "$PI_SESSION_FILE"
3
$ grep -c "lane closed; resume the saved Pi session" "$PI_SESSION_FILE"
4
$ stat -c '%y %s' "$PI_SESSION_FILE"
2026-09-28 04:28:36 ... 213243     # grown across the relaunch, same file
```

The busy-state owner was re-armed on the new generation, matching the new `busy_gen`:

```
$ cat /tmp/fm-lab.qrYLah/state/live-pi-1.busy-state
v1 gen=g1790569689.2588903.11091 seq=2 state=busy source=pi-ext event=agent-start ts=1790569692
$ cat /tmp/fm-lab.qrYLah/state/live-pi-1.pi-ext.ts   # references the same busy gen and turn_end marker
```

---

## 3. Caveats / limits of the observation

- **`/proc/<pi-pid>/cmdline` shows only `pi`** (with trailing spaces), and
  `/proc/<pi-pid>/environ` does not contain `PI_*`. That is expected: the node-based
  `pi` launcher rewrites its process title, and `PI_SESSION_ID`/`PI_SESSION_FILE` are
  set **for Pi's tool children**, not carried in Pi's own exec environment. I therefore
  did not read the literal `--session-id` argument from argv. The argument is proven
  indirectly and strongly by the value Pi itself reports (`PI_SESSION_ID`) and by the
  session file it opened/attached to naming that exact id — which is what the flag controls.
- tmux `pane_start_command` is empty and the pane's PID is the wrapper `bash`, so the
  composed launch line is not recoverable from the live endpoint. The composed flag
  itself is pinned hermetically by `tests/fm-spawn-pi-session.test.sh` (asserts
  `--session-id '<recorded>'` on the launch line) and `tests/fm-control-relaunch.test.sh:1098`.
- Only the tmux backend was exercised here. Herdr's runtime-bound-session precedence
  (`bin/fm-control-lib.sh:276`) was not exercised by this scout.

---

## 4. Completion gate

Reviewed the whole report surface for captain-owned calls. There are **none**: the
deliverable is a confirmation, with no product choice, destructive action, or open
question. The shared gate was run and verified:

```
$ FM_HOME=/tmp/fm-lab.qrYLah bin/fm-captain-hold.sh complete live-pi-1 --none
complete: live-pi-1 captain-call inventory reviewed
$ FM_HOME=/tmp/fm-lab.qrYLah bin/fm-captain-hold.sh verify live-pi-1
verified: live-pi-1 captain-call inventory
# state/live-pi-1.meta now: decisions_reviewed=1  decision_keys=
```

No visual review artifact was produced, so no Lavish board was armed.

---

## 5. Recommendation

**No code change required.** The contract is confirmed as implemented and as documented.
This lane was a launch-line smoke test, and the launch line (both fresh and relaunch
forms) behaved exactly as `bin/fm-spawn.sh` and `docs/agent-control.md` describe.

Optional follow-ups, none blocking:
- Keep `tests/fm-spawn-pi-session.test.sh` + `tests/fm-control-relaunch.test.sh` as the
  hermetic owners; this report is live corroboration on Pi 0.87.1, not a replacement for them.
- If a future reviewer needs the literal launch bytes, capture them from `bin/fm-spawn.sh`
  at compose time (a debug echo into the task tmp dir) rather than from `/proc`, since the
  node launcher overwrites its title.
