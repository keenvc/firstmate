# Supervision protocol details

Read this document on a `check:`, `stale:`, or merged-PR wake, a `RECORD DIVERGENCE` section, a Relay milestone, a contributions signal, or a guard warning (`AGENTS.md` section 8).
It is an on-demand part of the `AGENTS.md` supervisor contract and carries the same authority as text written there; the hard rules and captain instruction precedence in `AGENTS.md` still govern it. Section numbers refer to `AGENTS.md` sections, each of which names the document that now holds its detail.

Fleet supervision is a binding operational contract whose essentials stay in `AGENTS.md` section 8; `docs/architecture.md`, `docs/turnend-guard.md`, the emitted session-start block, and script help own mechanisms and harness-specific recipes.

## Wake queue details

- Session start is the only exception because its one-shot digest already presented the queue while locked or deliberately left it untouched in lock-refused read-only mode.
- Treat any `RECORD DIVERGENCE` section as a contradiction between two records of one captain call, never as proof the captain ruled; load `captain-hold-lifecycle` and reconcile it in whichever direction the evidence supports.
- After handling all emitted wakes and reconciling the OPEN DECISIONS and UNREAD STATUS sections, run the exact generation-bound `--ack-through` command printed as `WAKE_ACK_REQUIRED`; interruption before that acknowledgement deliberately leaves the work durable for idempotent re-handling.
- After any supervision-branch acknowledgement succeeds or reports that a sequence is already processed, never acknowledge that sequence again or retry the refusal.
- `bin/fm-classify-lib.sh` owns the distinction between declared `paused:` waits and `blocked:` events needing firstmate action; `bin/fm-brief.sh` owns worker declaration instructions.

## Actionable wake details

2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker; a deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, contribution signals, Relay events, process-to-event source results, and captain inbox notes; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
   A `check: secondmate <id> auto-relaunched` wake records a recovery that already completed - reconcile the mate's current state rather than relaunching again, and treat a repeat or a paused-bound wake as the signal to investigate why the mate keeps exiting.
   When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script header owns the reply contract) rather than leaving the answer only in this transcript.

Load `bearings` on a contributions check wake or when filing work linked to an upstream issue; its contribution-follow-up section owns triage and exact signal acknowledgement.

When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.

A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a quiet pane as stale.

## Guard warnings

Guard warnings do not replace the contract.
Queued wakes must be presented before other action and acknowledged only after handling, stale liveness must be repaired through the emitted protocol, and the worktree-tangle warning must be resolved without touching unlanded work.
The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout.
Harness-aware turn-end guards are structural backstops, not permission to omit the live cycle.
