# PR grade cache for review and steward lanes

A grade (CLEAN, BLOCK, low-risk skip, human hold) is a fact about one
`(repo, PR, head SHA)`. Only a new push makes a new head, and only a new head
needs a new grade. `bin/fm-grade-cache.sh` keeps those facts in
`state/pr-grade-cache.tsv` so a looping lane asks "which open heads have no
grade yet" in one `gh pr list` instead of re-reading every open PR each sweep.

## Why

The standing steward `pr-flow-steward-1106` (scout, OpenCode, DeepSeek-V4.1
Flash) spent 1,977 gh calls and 1.54B prompt tokens in 2026-11-12..19. Its
brief tells it to "list open PRs and act on any that lacks a passing
review/verdict" every ~10 minutes, and its relaunch note says "post short
guard verdicts on open non-draft PRs lacking one or with a moved head". It
has no durable record of what it graded, so after every compaction or
relaunch it re-reads each PR and its checks to find out again.

Its brief also carried 51 relaunch progress notes (72.6k characters, ~18k
tokens on every call). The launch-brief collapse in `bin/fm-spawn.sh` cuts
that to 17.0k on its next relaunch.

## Proposed brief addendum (lead to apply)

Append to `data/pr-flow-steward-1106/brief.md` (and to the scaffold of any
future steward), then relaunch it so the launch copy carries it:

```markdown
## Grade cache (required, 2026-11-19)

Before reading any PR, ask the cache which heads still need you - one gh call per repo:
`'/home/azureuser/firstmate/bin/fm-grade-cache.sh' todo keenvc/adclinica --exclude-author vstorm83`
(likewise keenvc/v10 and keenvc/frontdeskclinic). It prints only open, non-draft PRs whose
current head has no recorded grade, oldest first. An empty answer means there is nothing to
grade this sweep: write nothing, read nothing else, and wait for the next sweep with
`'/home/azureuser/firstmate/bin/fm-wait.sh'` rather than `sleep`.
Grade only the listed heads. Right after you post a verdict, a low-risk skip, or a
human-hold note for a head, record it:
`'/home/azureuser/firstmate/bin/fm-grade-cache.sh' put <repo> <pr> <head-sha> <CLEAN|BLOCK|SKIP-LOW-RISK|HUMAN-HOLD> <one-line reason>`.
Never re-grade a head the cache already holds; a new push is a new head and shows up in `todo`
by itself. To wait for a listed PR's build, use `fm-wait.sh pr <url> --until checks` or
`fm-wait.sh status <repo> <sha> --context buildkite/<pipeline>`, never repeated `gh pr checks`.
```

## Expected effect

Steady state, a sweep with no new pushes costs three `gh pr list` calls and
one short turn instead of a view-and-checks pass per open PR. The gh-call
cut scales with the number of open PRs per sweep, and each avoided gh call
is also an avoided full-context model call, which is where the 1.54B weekly
tokens went. Not measured yet: compare `state/pr-grade-cache.tsv` growth and
the steward's gh-call count for a day after the addendum lands.
