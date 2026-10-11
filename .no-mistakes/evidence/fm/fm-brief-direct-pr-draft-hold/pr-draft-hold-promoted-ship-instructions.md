Your scout task has been promoted to a ship task, mode=direct-PR. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Ship the v10 draft-hold feature.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-hold-9` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-hold-9 --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=direct-PR.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `/tmp/fm-lab.iqYXM5/data/promote-hold-9/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch (push only your `fm/promote-hold-9` branch). Never merge a PR.

# Definition of done
Delivery contract: mode=direct-PR pr-draft-hold=do-not-auto-ready
Ship branch: fm/promote-hold-9
This task ships **direct-PR** with **draft hold**: you raise a draft pull request yourself, without the no-mistakes pipeline, and leave it a draft until firstmate or the captain marks it ready after review.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a **draft** pull request with `gh-axi`.
Apply the hold label `do-not-auto-ready` with `gh-axi pr edit <number> --add-label do-not-auto-ready` (where <number> is the PR number from your PR URL).
Before you report done, read the PR back from the forge and confirm it is still a draft (`gh-axi pr view <number>` must print `draft: yes`) and lists the hold label; do **not** mark it ready with `gh-axi pr ready <number>`.
On keenvc/v10, the `do-not-auto-ready` label matches the repository workflow that otherwise undrafts green pull requests and lets the merge queue merge before a different-model review.
Then append `done [at=<epoch>]: PR {url} draft hold` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR after it is marked ready; firstmate relays the outcome.
