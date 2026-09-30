Live lab: disposable FM_HOME /tmp/fm-lab.EftCLz (bin/fm-lab-home.sh create), private tmux socket -L fm-lab,
real 'claude' CLI as primary; every fm-session-start.sh run was executed by that primary's Bash tool
(so fm-lock.sh found a real harness in ancestry and the digest ran locked, not read-only).
Base = git archive of 3d8c0976 (pre-change); head = 37bad4e5 worktree. Same lab state for both.
s2  locked session start, 300 wake rows: rc=0, 8.21s, WAKE QUEUE rows printed tab-parsed.
s3  3000 wake rows, alternating: base 10.11/10.00s vs head 8.38/8.21s; WAKE QUEUE sections byte-identical (epochs stripped).
s4  herdr cap: user 30 -> endpoint read got 10, other herdr call kept 30; user 3 -> both 3 (not raised).
s5  FM_SESSION_START_TIMEOUT=7 truncates at wake-queue stage; home-summary.json still published.
s6  slow herdr (6s/pane get) x3 tasks: base digest 32.96s vs head 25.78s; summary published in both.
s7  real tasks-axi (logging wrapper): one 'show' per owned record (task-a, task-b, task-c), queued rows started.
base round 1: --- rc=0 elapsed=10.11s summary_present_at_return=yes | summary published after settle: yes
head round 1: --- rc=0 elapsed=8.38s summary_present_at_return=yes | summary published after settle: yes
base round 2: --- rc=0 elapsed=10.00s summary_present_at_return=yes | summary published after settle: yes
head round 2: --- rc=0 elapsed=8.21s summary_present_at_return=yes | summary published after settle: yes
