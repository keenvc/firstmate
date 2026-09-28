# Live Herdr lab: fm-send doorbell vs. a lost agent binding

Lab: isolated non-default Herdr session 'fm-lab-fm-doorbell-1317972-4197' (bin/fm-herdr-lab.sh), marked lab FM_HOME /tmp/fm-lab.IAhNVN.
All three panes look IDENTICAL to Herdr - agent None, agent_status unknown - which is the
symptom the report describes. w1:p2 holds a real, authenticated pi (Anthropic sub, claude-opus-4-8)
that Herdr has stopped attributing; w1:p3 is a shell-only pane; w1:p1 runs a non-agent tool.

## 1. What Herdr reports for the three panes
{"pane_id":"w1:p1","agent":null,"agent_status":"unknown"}
{"pane_id":"w1:p2","agent":null,"agent_status":"unknown"}
{"pane_id":"w1:p3","agent":null,"agent_status":"unknown"}

## 2. What the product reads for the same three endpoints
w1:p1  agent_state=dead     process_state=other      verdict=indeterminate
w1:p2  agent_state=dead     process_state=agent      verdict=ring
w1:p3  agent_state=dead     process_state=shell      verdict=exited

## 3. BEFORE - base commit 30ef650 fm-send.sh, sent to the live pi pane w1:p2
$ FM_HOME=<lab> bash <base>/bin/fm-send.sh tbase "..."   # exit 0
fm-send: doorbell not typed because the agent in fm-lab-fm-doorbell-1317972-4197:w1:p2 has exited; the steer is durably recorded at /tmp/fm-lab.IAhNVN/state/tbase.inbox/001.msg for recovery (stuck-crewmate-recovery), and the watcher will not re-ring a dead pane
  -> nothing typed into the pane; the steer was silently stranded.

## 4. AFTER - this change (0215856) fm-send.sh, same pane, same endpoint
$ FM_HOME=<lab> bash bin/fm-send.sh tlive "..."   # exit 0
  stderr carried NO "doorbell not typed" notice.
  The pane itself received the doorbell:
--no-context-files --no-session
azureuser@gemini-proxy-vm:/tmp/fm-doorbell.0eQaXx/project$ : Firstmate instruction waiting: list '/tmp/fm-lab.IAhNVN/sta
te/tlive.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-lab.IAhNVN/stat
e/tlive.inbox'/handled/.
azureuser@gemini-proxy-vm:/tmp/fm-doorbell.0eQaXx/project$ : Firstmate instruction waiting: list '/tmp/fm-lab.IAhNVN/sta
te/tbase.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '/tmp/fm-lab.IAhNVN/stat
e/tbase.inbox'/handled/.
azureuser@gemini-proxy-vm:/tmp/fm-doorbell.0eQaXx/project$

## How the lost binding was induced
Herdr 0.9.1 on this host auto-attributes an agent from the pane's foreground process, so it
re-binds any harness started in a pane. The reported state (agent None / agent_status unknown
while the harness process is alive) was reproduced by pushing the real pi out of the pane's
foreground process group while leaving the process alive: Herdr then attributes no agent to the
pane, exactly as in the report, while the harness is still there. The product's own reads -
`fm_backend_agent_state` = dead, `fm_backend_agent_process_state` = agent - are byte-identical to
the reported production state, and that is what the doorbell decision consumes.
