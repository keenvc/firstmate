Mode: Droid secondmate Stop-hook-owned supervision.

This protocol is emitted only for a droid home that runs its own primary firstmate session, which today means a secondmate home.
A droid main-home primary is not claimed.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. The routine watcher arm and re-arm are owned by the `Stop` hook (`bin/fm-turnend-guard.sh --droid`), never by you.
   droid runs that hook synchronously and feeds its exit-2 stderr back to you as a continuation, so a turn boundary with supervision needed and no live cycle comes back as a repair instruction instead of ending blind.
3. On that follow-up, repair supervision with `bin/fm-watch-arm.sh` as the recovery instruction says.
   Do not arm a watcher after an ordinary wake while supervision is already healthy; the next Stop guards itself.
4. One Stop can be blocked at most once per turn: droid marks the payload `stop_hook_active` after a block, and the guard allows that second Stop.
   Waiting on a live cycle is therefore silent.
5. droid's own `UserPromptSubmit`, `Stop`, `Notification`, and `SessionEnd` hooks write this home's busy record, so a turn that was cancelled with Escape closes as `idle` through its `idle_prompt` notification rather than staying busy.
6. The session-start digest arrives through the `SessionStart` hook (`bin/fm-sessionstart-droid.sh`), which returns it as `hookSpecificOutput.additionalContext`.
   Take the helm from that digest; do not re-run the whole session start because the turn began.

The mate's launch carries all of this wiring in the parent home's `state/<id>.droid-settings.json`, passed to droid through `--settings` for that one process.
The captain's `~/.factory/settings.json` is never rewritten for worker wiring; the only droid write there is the folder-trust pre-registration of the mate's home, which is a per-path entry later launches reuse.
The pre-tool seatbelts are not wired for droid.
See [`turnend-guard.md`](../turnend-guard.md) for the guard predicate, loop bound, and fail-open tradeoffs, and [`sessionstart-nudge.md`](../sessionstart-nudge.md) for the run-tier transport.
