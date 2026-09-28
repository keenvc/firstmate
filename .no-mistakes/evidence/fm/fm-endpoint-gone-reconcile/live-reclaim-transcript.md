# Live drive: reclaiming a tmux task whose endpoint was destroyed

Product driven as an operator runs it: a disposable lab firstmate home
(`bin/fm-lab-home.sh create`), a real private tmux server (`tmux -L fm-lab`,
`TMUX_TMPDIR=$LAB/tmux`), a real throwaway git project, a real `treehouse get`
worktree, and a real `claude` harness. No fakes, no stubs.

Task `labscout1` was created by the real launch path:

    $ bin/fm-spawn.sh labscout1 $LAB/projects/labproj --scout --backend tmux --harness claude
    spawned labscout1 harness=claude kind=scout window=firstmate:fm-labscout1 \
      worktree=/tmp/fm-lab.Emxt7W/treehouse/.treehouse/labproj-45721d/1/labproj

A real Claude agent came up in `firstmate:fm-labscout1` (window id @1) and began
working. Work was then staged in the worktree the way the incident describes it:
one commit (HEAD ccf2864), one never-committed file, and a status line
`working: parked at a no-mistakes review gate`.

--------------------------------------------------------------------------------
## 1. Adversarial: endpoint unreadable while the agent is still alive

The recorded window was renamed out from under the record (`tmux rename-window`),
so `firstmate:fm-labscout1` reads `missing` while the real Claude keeps running in
the worktree. Both verbs must refuse rather than launch a second agent.

    $ bin/fm-spawn.sh labscout1 --relaunch --harness claude
    error: task labscout1's recorded endpoint firstmate:fm-labscout1 reads 'missing',
    but agent process 1918852 claude is still working in the recorded worktree
    /tmp/fm-lab.Emxt7W/treehouse/.treehouse/labproj-45721d/1/labproj, so its window may
    be on a tmux server this seat cannot address; stop that process where it runs, or
    address its tmux server from this seat, then retry. An endpoint that cannot be
    proven absent may still hold a live agent on this task's worktree; refusing rather
    than launching a second agent into it (bin/fm-control.sh labscout1 exit and
    relaunch refuse it for the same reason)
    rc=1

    $ bin/fm-control.sh labscout1 exit
    error: task labscout1's endpoint firstmate:fm-labscout1 reads 'missing', but agent
    process 1918852 claude is still working in the recorded worktree ...; exit will not
    claim an agent stopped at an address it cannot trust, nor send lifecycle input to
    one, and relaunch refuses for the same reason
    rc=1

    $ tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name}'
    firstmate:bash
    firstmate:stranded-elsewhere        <- no second window created

PID 1918852 was still alive after both refusals. The refusal names the exact live
process it found.

--------------------------------------------------------------------------------
## 2. The reported deadlock, reproduced at the base commit (30ef650)

The window was then destroyed (`tmux kill-window`), taking the agent with it; zero
processes remained in the worktree. The base-commit scripts were extracted with
`git archive 30ef650` and driven against the same live lab home:

    $ $LAB/base/bin/fm-control.sh labscout1 relaunch --note "..."
    error: task labscout1's endpoint firstmate:fm-labscout1 reads 'missing', but tmux
    absence cannot be proven from a task record: ...
    error: relaunch of labscout1 failed while stopping the old agent and its state is
    'missing', so it was not proven stopped; its original instructions were restored
    and the durable record was retained for recovery

    $ $LAB/base/bin/fm-spawn.sh labscout1 --relaunch --harness claude
    error: task labscout1's recorded endpoint firstmate:fm-labscout1 reads 'missing',
    but tmux absence cannot be proven from a task record: ... refusing rather than
    launching a second agent into it

    $ $LAB/base/bin/fm-control.sh labscout1 exit
    error: task labscout1's endpoint firstmate:fm-labscout1 reads 'missing', but tmux
    absence cannot be proven ...; exit will not claim an agent stopped at an address it
    cannot trust, nor send lifecycle input to one

All three supported commands refuse; there is no route. This is the deadlock the
intent reports, reproduced live before the fix.

--------------------------------------------------------------------------------
## 3. The same state on this branch: exit reports it, relaunch reclaims it

    $ bin/fm-control.sh labscout1 exit
    endpoint-gone labscout1 harness=claude backend=tmux endpoint=firstmate:fm-labscout1 \
      worktree=/tmp/fm-lab.Emxt7W/treehouse/.treehouse/labproj-45721d/1/labproj
    rc=0

    $ bin/fm-control.sh labscout1 relaunch --note "the tmux window was destroyed; pick the work back up"
    relaunched labscout1 harness=claude from=claude model=default effort=default \
      backend=tmux endpoint=firstmate:fm-labscout1 \
      worktree=/tmp/fm-lab.Emxt7W/treehouse/.treehouse/labproj-45721d/1/labproj
    rc=0

    $ tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} id=#{window_id}'
    firstmate:bash id=@0
    firstmate:fm-labscout1 id=@2       <- a NEW window (the destroyed one was @1)

A real Claude came up in the new window, in the same worktree, and picked the work
back up (pane capture: reclaimed-window-pane.txt). Nothing else moved:

  * worktree HEAD ccf2864 before == ccf2864 after
  * the never-committed file is still there, untouched
  * the `parked at a no-mistakes review gate` status line survived
  * the progress note reached the replacement's brief
  * no record was edited by hand at any point

--------------------------------------------------------------------------------
## 4. Refusals name a command that actually runs

With the reclaimed agent alive, the launch owner refuses and names its route:

    $ bin/fm-spawn.sh labscout1 --relaunch --harness claude
    error: task labscout1's endpoint reads 'alive': an agent still runs there, and a
    relaunch requires a positively agent-free endpoint, so replace it with
    bin/fm-control.sh labscout1 relaunch --note "<why>", which stops that agent before
    launching this one
    rc=1

Running exactly the command it named (with a real why) succeeded and reused the
surviving window @2 rather than opening a second one.

--------------------------------------------------------------------------------
## 5. The launch owner reclaims on its own

Window destroyed again; `bin/fm-spawn.sh --relaunch` alone reaches the same verdict:

    $ bin/fm-spawn.sh labscout1 --relaunch --harness claude
    spawned labscout1 harness=claude kind=scout window=firstmate:fm-labscout1 \
      worktree=/tmp/fm-lab.Emxt7W/treehouse/.treehouse/labproj-45721d/1/labproj
    rc=0
    firstmate:fm-labscout1 id=@3       <- again a new window, same worktree

--------------------------------------------------------------------------------
## 6. Adversarial: a foreign window already holds the name

A second session `other` was given a decoy window named `fm-labscout1` (standing in
for another home's deliberately preserved endpoint), and the reclaim was driven from
inside that session, so the new window would land there:

    $ bin/fm-control.sh labscout1 relaunch --note "..."      # run from a pane in session `other`
    error: window other:fm-labscout1 already exists; read it with
    bin/fm-peek.sh other:fm-labscout1 to see what holds it. No control-plane command
    closes a window this home's records do not name, so a leftover or another home's
    window has to be closed where it runs before this task can open its own
    error: the replacement agent for labscout1 could not be launched on claude
    error: labscout1's agent was stopped but the replacement did not launch; no agent is
    running, and its work plus the recorded progress note are preserved at ...; rerun
    bin/fm-control.sh labscout1 relaunch --note "<why>" once the launch failure above is
    resolved
    rc=1

    other:fm-labscout1 id=@5           <- the foreign window is still open, untouched

Closing the decoy and rerunning the command the rollback named succeeded:

    relaunched labscout1 ... endpoint=other:fm-labscout1 ...
    rc=0
    other:fm-labscout1 id=@6           <- fresh window, record rebound to this seat's session

The lab home, its tmux server, its worktree pool and its project were removed in the
same turn.
