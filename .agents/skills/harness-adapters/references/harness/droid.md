# Factory Droid CLI

Factory's `droid` TUI, verified end to end on 2026-10-29 with droid 0.251.0 on Linux through the Herdr backend.
Verified as a CREWMATE, SCOUT, and SECONDMATE adapter: it is the first adapter whose own hook surface carries every primary duty a secondmate needs (run-tier session start, turn-end blocking, semantic busy state).
`../../../../../docs/verification/droid.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `droid` from `PATH`, refused if absent; a compiled single binary whose live process name is exactly `droid`. |
| Launch | `droid --settings <runtime-settings.json> --auto high --append-system-prompt <role-pin> "<launch-brief doorbell>"`, with the resolved absolute binary. The positional prompt auto-submits on start, so it needs no delivery gate. The prompt is the record-backed doorbell (`bin/fm-operational-input.sh record launch-brief`), not the brief text: a brief in argv is matched by any same-machine `pgrep -f`/`pkill -f` pattern appearing in the brief's own words (incident 2026-10-31T02:24Z: a `pkill -f chrome-devtools-axi` stopped about 21 workers whose briefs named that tool). The short printable doorbell carries no such words. Verified live on droid 1.0.0: the worker reads the named record and acts on it, and `pgrep -f chrome-devtools-axi` does not match the worker. |
| Runtime settings | `--settings <path>` merges a settings file for that ONE process. droid honours `model`, `reasoningEffort`, `sessionDefaultSettings.autonomyLevel`, and a `hooks` key there, and it MERGES each layer's hooks (verified: hooks from `--settings` and from a project `.factory/hooks.json` both fired). Firstmate therefore writes all its worker wiring into a firstmate-owned `state/<id>.droid-settings.json` and never rewrites the captain's `~/.factory/settings.json`. |
| Busy state | `droid-hook`: `UserPromptSubmit` opens a turn, `Stop` closes it, `SessionEnd` closes it, and an Escape interrupt emits a `Notification` with `notification_type=idle_prompt` instead of a `Stop`, so that notification is the interrupt's own close event. Hook output `{"suppressOutput":true}` keeps the hook line out of the transcript on the submit and stop hooks. |
| Turn end | `Stop` with the Claude-compatible contract: exit 2 feeds stderr back to the model as a continuation, and the payload carries `stop_hook_active` (snake_case), so one Stop blocks at most once. A secondmate's Stop is `bin/fm-turnend-guard.sh --droid`, the only Stop writer for that generation, pointed back at the busy writer through `.fm-busy-stop`. |
| Session start | Run tier: droid appends a `SessionStart` hook's `hookSpecificOutput.additionalContext` to the new session's context (verified live: a hook-supplied fact was answered on the next prompt). `bin/fm-sessionstart-droid.sh` is that transport for a secondmate home. |
| Exit | `/quit`, one Enter; the process exits and `SessionEnd` fires. |
| Interrupt | Single `Escape`, which prints `Request cancelled by user` and leaves an empty composer with no repollution, so no clear key follows. The row is transient - a 0.5 s capture loop can miss it while the spinner is already gone - so the live guard accepts the spinner leaving as the cancel proof too. No turn ack is observable (`cancel=unconfirmed`), exactly like claude and agy. |
| Skill | No verified slash-skill form for a worker brief; use natural language. `/skills` manages skills interactively. |
| Autonomy | `--auto high` (equivalently `sessionDefaultSettings.autonomyLevel: "high"`), the documented ceiling that pre-authorizes work at or below that risk level; verified rendering `Auto (High) · allow all commands`. The launch passes it explicitly, so the level never depends on the user store's `sessionDefaultSettings`. |
| MCP isolation | droid reads MCP servers from `<config-home>/mcp.json` and starts every enabled one as a child process; the user and project layers union, the runtime `--settings` layer cannot remove them (verified: `"mcpServers": {}` and per-server `disabled` entries both left seven children running), and no CLI flag exists. Each worker therefore launches with its own `HOME` (`state/<id>.droid-home`): every entry of the captain's home is symlinked in - so git identity, gh auth, and caches keep working - except that `.factory/mcp.json` is omitted and `.factory/settings.json` is generated with the captain's hooks plus folder trust. Measured live: seven MCP children under the captain's home, zero under the per-task home, and the worker still answered its brief. |
| Role pin | `--append-system-prompt` carries one fixed paragraph: the launch brief in the session's first prompt is the role contract and outranks any repository `AGENTS.md`, `CLAUDE.md`, or global instruction assigning a firstmate supervisor role. droid loads the repository's `AGENTS.md` into context, so without the pin a worker in a firstmate-repo worktree adopts the supervisor persona; verified live: a pinned probe reasoned "Persona overrides" and followed the pin against a contradictory prompt. The pin states precedence only, so a secondmate charter still assigns its own home's supervision. |
| Marker | `FACTORY_SESSION_ID`, a per-session UUID exported to every tool and hook subprocess (verified live). Also detected by anchored ancestry on the process name `droid`. |
| Resume | `-r/--resume [sessionId]` and `--fork` exist but carry no verified pane-resume contract; use deterministic relaunch. Top-level `-r` is `--resume`, never reasoning effort. |
| Model | `-m/--model` exists only on `droid exec`. An interactive launch pins the model through the runtime settings file in every case: a dispatch that names none gets `deepseek-v4.1-flash-1017`, a Droid Core id at 0.12x, because the captain's user store defaults to a BYOK custom endpoint rather than a Droid-managed model. Validation uses `droid exec --list-tools -m <id>`, which resolves the id against the account's built-in and custom catalog and exits 1 with `Invalid model: <id>` plus the listing; the probe costs no model call. A `custom:` id is refused before that probe, because those BYOK endpoints can resolve to openrouter.ai. |
| Effort | `reasoningEffort` in the runtime settings file. droid's own vocabulary is `none|dynamic|off|minimal|low|medium|high|xhigh|max`, model-dependent and clamped by droid, so the shared `low|medium|high|xhigh|max` levels map across. |
| Composer | A rounded bordered box whose prompt row leads with `>`, a SHELL glyph, holding the dim ghost `Try "<suggestion>"`. The terminal cursor parks outside the box, on the row under the footer. Classification is identity-gated (`droid=1` on tmux, `droid=ask` plus Herdr's native `droid` agent identity), so no other harness's `>` row can borrow the proof. |

## Trust, and where the decision persists

Every new directory parks droid on a bordered `Trust this folder?` dialog whose selected row is `1. Trust this folder` and whose footer is `Enter to confirm · Esc to exit`.
No launch flag suppresses it.
droid records the answer under `trustedFolders` in the config home it runs with, and it honours an entry written ahead of launch (verified live: a pre-registered fresh directory launched straight into its prompt while an unregistered sibling parked).
A worker's config home is its per-task `HOME` (`state/<id>.droid-home`), so `../../../../../bin/fm-spawn.sh` pre-registers the target through `../../../../../bin/fm-droid-trust.sh` with that `HOME`, in both the worktree and secondmate-home shapes, and the captain's own store is never written.
The launch gate is the backstop: it answers a dialog that renders anyway with one Enter, and on a path that was not pre-registered it refuses to count a busy turn as ready until that dialog has been answered.
Never steer into a pane still showing the dialog.

## Detection

Detected by the `FACTORY_SESSION_ID` marker, tested before `CLAUDECODE` because droid does not scrub an inherited value, and by the anchored process name `droid`, never `*droid*`.
`FACTORY_SESSION_ID` reaches tool subprocesses but NOT hook subprocesses (verified: unset in both a `SessionStart` and a `Stop` hook, while the same tree's ancestry arm answered `droid`), so the hook-launched session start depends on ancestry.
That ancestry walk therefore reaches twelve parents rather than eight: the digest sits behind a hook shell, the `fm-sessionstart-droid.sh` transport, and a bounded timeout wrapper, and at eight it resolved `unknown` from the hook while the identical detection answered `droid` from a tool subprocess.
A structural droid ancestor outranks a retained foreign marker, so the launch-boundary marker clearing is defense in depth rather than the only guard.
droid IS in the session-lock name vocabulary (`../../../../../bin/fm-session-lock-lib.sh`), because a droid secondmate is a primary and must own its home lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms the busy generation for every non-raw droid launch and writes the hooks into the per-task runtime settings file.
A crewmate's Stop closes the record and keeps the watcher's turn-ended touch; a secondmate's Stop is its home's tracked turn-end guard instead, which records `busy` when it blocks the turn into a continuation and `idle` otherwise.
droid runs one Stop hook chain per event, so a second Stop writer cannot land after the guard and flip the verdict.
Retiring the task removes that settings file and the per-task home, which is a symlink farm plus one generated settings file, so no user data is deleted.

## Primary integration

Supported for secondmates only.
`../../../../../docs/supervision-protocols/droid.md` owns the wake protocol, and it is the first protocol backed by the harness's own hooks rather than by rendered output: the session-start digest arrives through `SessionStart` `additionalContext`, and the turn boundary blocks through `Stop` exit 2.
A droid PRIMARY (main home) is not claimed: the main home's own harnesses are unchanged, and no tracked home settings file registers droid hooks.
The pre-tool seatbelts (`../../../../../bin/fm-arm-pretool-check.sh`, `../../../../../bin/fm-cd-pretool-check.sh`, `../../../../../bin/fm-subagent-pretool-check.sh`) are not wired for droid, so those deny paths do not apply to it yet.
