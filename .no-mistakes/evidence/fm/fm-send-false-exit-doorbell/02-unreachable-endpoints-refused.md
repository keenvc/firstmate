# Live Herdr lab: the two endpoints the doorbell must still refuse

## A. Shell-only pane (w1:p3) - the agent really exited
$ FM_HOME=<lab> bash bin/fm-send.sh texit "steer for texit"   # exit 0
fm-send: doorbell not typed because the agent in fm-lab-fm-doorbell-1317972-4197:w1:p3 has exited; the steer is durably recorded at /tmp/fm-lab.IAhNVN/state/texit.inbox/001.msg for recovery (stuck-crewmate-recovery), and the watcher will not re-ring a dead pane
  pane w1:p3 content before and after the send: IDENTICAL (nothing typed)

## B. Pane whose process view cannot tell (w1:p1) - a non-agent tool in the foreground
$ FM_HOME=<lab> bash bin/fm-send.sh tindet "steer for tindet"   # exit 0
fm-send: doorbell not typed because it could not tell whether the agent in fm-lab-fm-doorbell-1317972-4197:w1:p1 is still running (the runtime reports no agent in the pane and its processes could not show one); the steer is durably recorded at /tmp/fm-lab.IAhNVN/state/tindet.inbox/001.msg and the watcher surfaces it once for recovery (stuck-crewmate-recovery) instead of typing into a pane that may have no agent
  pane w1:p1 content before and after the send: IDENTICAL (nothing typed)
  the refusal never claims the agent exited.

## C. Durable records exist in every case
tlive   /tmp/fm-lab.IAhNVN/state/tlive.inbox/001.msg
texit   /tmp/fm-lab.IAhNVN/state/texit.inbox/001.msg
tindet  /tmp/fm-lab.IAhNVN/state/tindet.inbox/001.msg
tbase   /tmp/fm-lab.IAhNVN/state/tbase.inbox/001.msg

## D. A record, verbatim
schema=fm-task-inbox.v1
at=2026-09-28T01:00:19Z
--
steer for tindet
## E. tmux backend, live, on an isolated tmux server (the collapsed tmux arm)
A shell-only tmux window reads agent_state=dead, process_state=shell, verdict=exited:

    $ FM_HOME=<lab> bash bin/fm-send.sh ttmux2 "steer for ttmux2"   # exit 0
    fm-send: doorbell not typed because the agent in fmt2:w2 has exited; the steer is
    durably recorded at <lab>/state/ttmux2.inbox/001.msg for recovery
    (stuck-crewmate-recovery), and the watcher will not re-ring a dead pane

    tmux pane content before and after: IDENTICAL (nothing typed)

A tmux target the backend cannot resolve reads agent_state=missing and refuses the same way,
also without typing.
