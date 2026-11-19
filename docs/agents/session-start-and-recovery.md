# Session start and recovery

Read this document once per session when reading the session-start digest, and before any recovery or reconciliation (`AGENTS.md` sections 3 and 5).
It is an on-demand part of the `AGENTS.md` supervisor contract and carries the same authority as text written there; the hard rules and captain instruction precedence in `AGENTS.md` still govern it. Section numbers refer to `AGENTS.md` sections, each of which names the document that now holds its detail.

## Session start

- Run `bin/fm-session-start.sh` exactly once at session start.
- Its header is the single owner of composed commands, ordering, and digest contents.
- `bin/fm-supervision-instructions.sh` renders the emitted supervision block from `docs/supervision-protocols/`.
- Do not reimplement it by separately running its lock, bootstrap, initial wake-drain, or deferred-network components.
- Run-tier harness surfaces run this command for you at session open while the rest only nudge it, so confirm the digest is present in this session and run it yourself when it is not; `docs/sessionstart-nudge.md` owns adapter tiers, source routing, and compatibility.

Read the complete digest once and trust it as this turn's startup and recovery input.
If the harness shows only a preview and persists the full output to a file, read that file before acting.
Do not separately re-read the context, backlog, metadata, or bulk status inputs it just printed unless a source was reported absent or corrupt, older history is specifically needed, or a targeted workflow must inspect before writing.
An `ABSENT` captain, shared-captain, secondmate, or learnings file means the firstmate repo's built-in defaults, no shared captain preferences, no registered secondmates, or no captured learnings; rebuild an absent or stale project registry from the clones before dispatch.

If the session lock cannot be acquired and verified, report its exact diagnostic and remain read-only; another active session is only one possible cause.
A lock-refused session must not spawn, steer, merge, drain the wake queue, repair supervision, repair a checkout, or perform any other fleet mutation.

When the digest's `NETWORK CHECKS` section reports checks still in progress, treat none of the named checks as passed until `bin/fm-startup-network.sh report` returns the finished result; a failed or otherwise actionable result also arrives as a `check: startup-network` wake.
Load `session-start-recovery` when the digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.

## Recovery

After the one session-start digest, reconcile reality with durable records before taking new work.
Honor lock-refused read-only mode exactly as section 3 requires.
Treat digest status tails as wake-event history and use targeted current-state reconciliation when the live state matters.

Reconcile only this home's recorded direct reports and their recorded backend inventory; never sweep a shared endpoint namespace for matching names or claim another home's work.
For an ordinary direct report whose endpoint is dead or metadata has no window, load `stuck-crewmate-recovery` and preserve the recorded worktree and unlanded work while reconciling ownership.
For a dead secondmate direct report, load `secondmate-provisioning` and reconcile only that secondmate, never its whole child tree from the main home.
Each secondmate reconciles work already in its own home and then idles; recovery never authorizes it to invent work.

If `state/.afk` is present, load `/afk` in away mode or `/quiet` in quiet mode (`bin/fm-wake-lib.sh`'s `fm_afk_mode`); where its daemon runs, let the daemon own supervision rather than arming another cycle, and on Pi keep the ordinary supervision session, which runs in both postures with main parked while the record exists.
Surface only captain-relevant decisions, review-ready PRs, failures, and credential needs; otherwise resume the emitted supervision protocol silently.
A restart must be a non-event because durable state and live backend inventory, not conversation memory, are authoritative.
