# Live validation: watcher liveness beacon republished as a cycle progresses

Branch fm/fm-watcher-beacon-beat (base 3c2a91d7, target df9b7965).

Every live run below uses a disposable lab home minted with `bin/fm-lab-home.sh create`
plus a private tmux server on that lab's own `tmux-dir` socket, a real tmux "fleet"
session of 101 windows, 100 real task records, the real `bin/fm-watch.sh`, and the
real Stop hooks (`bin/fm-claude-stop-autoarm.sh`, `bin/fm-turnend-guard.sh --claude`).
No fleet home, default tmux server, or production state was touched; every lab was
removed in the same turn. Real sweeps over 100 records take ~45s per cycle, so
FM_GUARD_GRACE was compressed from its 300s default to 20s in both arms of the A/B -
that is how a 45s real sweep stands in for the minutes-long sweeps the intent reports
against a 300s grace.

| file | what it shows |
| --- | --- |
| live-lab-base.log | BASE code, reproduction: beacon age climbs 0->20s during one real sweep while the watcher works; `fm_watcher_healthy` UNHEALTHY; the real auto-arm prints the reported notice verbatim ("auto-arm FAILED ... no live watcher with a fresh beacon was verified" + "lock held by live pid 3133944 but heartbeat is stale for 26s (>20s)"), exit 2 |
| live-lab-fixed.log | TARGET code, same lab: beacon age 0s for the whole sweep, `fm_watcher_healthy` HEALTHY, auto-arm exit 0 with no notice, turn-end guard exit 0. The arm's own line, read from state/.claude-autoarm-output.*, was `watcher: attached pid=341457 (beacon 0s)` |
| live-lab-frozen-watcher.log | ADVERSARIAL: the target watcher and its per-cycle child SIGSTOPped mid-sweep. Beacon stops advancing and ages past the grace, predicate UNHEALTHY, turn-end guard blocks (exit 2), re-arm still refuses with "heartbeat is stale for 33s (>20s)" |
| live-blind-home-guard.log | The reworded operator banner, captured live on a home with work in flight and no watcher: "1 task(s) in flight, but no watcher is publishing liveness for this home (last beat: never)" |
| watcher-lock.log | tests/fm-watcher-lock.test.sh - the four new real-process cases (long sweep keeps the beacon fresh through 11s of one cycle, wedged step goes stale, exited watcher detected absent, unpublishable beacon recorded) |
| affected-suites.log | tests/fm-watch-triage.test.sh, fm-turnend-guard.test.sh, fm-home-summary-refresh.test.sh, fm-wake-queue.test.sh |
| pending-reply.log | tests/fm-pending-reply.test.sh - legacy one-argument `fm_pending_reply_tick` callers after the optional progress-fn parameter was added |
| fm-beacon-lab.sh, fm-stop-lab.sh, fm-blind-lab.sh | the exact lab drivers used, kept so a reviewer can re-run them |
