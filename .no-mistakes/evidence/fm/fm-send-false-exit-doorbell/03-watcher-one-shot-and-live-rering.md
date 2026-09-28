# Live watcher (bin/fm-watch.sh) against the same real Herdr endpoints

Eleven real watcher starts were driven over the marked lab home with the live Herdr backend.

## Poll 1 - the shell-only pane (w1:p3, task texit) surfaces once
stale: fm-lab-fm-doorbell-1317972-4197:w1:p3 (unread firstmate instruction: /tmp/fm-lab.IAhNVN/state/texit.inbox/001.msg is unhandled and the worker's agent has exited or its endpoint is missing, so the doorbell was not typed; recover the worker)
  wake queue after that poll held exactly 1 entry for texit.
  Seven further watcher starts followed: texit never surfaced again (0 further entries),
  and pane w1:p3 was never typed into.

## Later poll - the indeterminate pane (w1:p1, task tindet) surfaces once, with honest wording
stale: fm-lab-fm-doorbell-1317972-4197:w1:p1 (unread firstmate instruction: /tmp/fm-lab.IAhNVN/state/tindet.inbox/001.msg is unhandled and the doorbell was not typed because the runtime reports no agent in the pane and its processes could not show whether one is running; check the worker)
  Six further watcher starts followed: tindet stayed at exactly 1 entry,
  and pane w1:p1 was never typed into.

## Final wake queue
1790557343	2	stale	fm-lab-fm-doorbell-1317972-4197:w1:p1	stale: fm-lab-fm-doorbell-1317972-4197:w1:p1 (unread firstmate instruction: /tmp/fm-lab.IAhNVN/state/tindet.inbox/001.msg is unhandled and the doorbell was not typed because the runtime reports no agent in the pane and its processes could not show whether one is running; check the worker)

## Durable state left behind
one .escalated one-shot per unreachable endpoint, the ordinary re-ring ladder for the LIVE
pane, and NO .unavailable recheck marker anywhere (the dropped subsystem):
  /tmp/fm-lab.IAhNVN/state/texit.inbox/.escalated = 001.msg
  /tmp/fm-lab.IAhNVN/state/tindet.inbox/.escalated = 001.msg
  /tmp/fm-lab.IAhNVN/state/tbase.inbox/.ring-state = 001.msg	1	1790557278
  .unavailable markers found: 0

## The live pane whose binding is lost is RE-RUNG by the watcher, never escalated
pane w1:p2 after the watcher poll (second doorbell, task tbase, typed by the watcher):
te/tlive.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-lab.IAhNVN/stat
e/tlive.inbox'/handled/.
azureuser@gemini-proxy-vm:/tmp/fm-doorbell.0eQaXx/project$ : Firstmate instruction waiting: list '/tmp/fm-lab.IAhNVN/sta
te/tbase.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-lab.IAhNVN/stat
e/tbase.inbox'/handled/.
azureuser@gemini-proxy-vm:/tmp/fm-doorbell.0eQaXx/project$
