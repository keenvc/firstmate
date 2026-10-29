# droid (Factory Droid CLI) verification

Active empirical evidence for the `droid` adapter, established on Linux on 2026-10-29 with droid 0.251.0 (`droid --version`).
The adapter facts live in [`.agents/skills/harness-adapters/references/harness/droid.md`](../../.agents/skills/harness-adapters/references/harness/droid.md); this record owns how each was proven and what remains unproven.

## Surface facts

```
$ droid --version
0.251.0
```

- Interactive `droid --help` lists no `-m/--model` and no reasoning-effort flag; `-r` is `--resume`.
  `-m`, `-r/--reasoning-effort`, `--spec-model`, and `--auto` exist on `droid exec`.
  The interactive model and effort therefore ride `--settings <path>`, which `droid --help` documents as a settings file "merged for this process only".
- `--auto <level>` (low|medium|high) is a top-level option. A launch with `--auto high` rendered `Auto (High) · allow all commands` in the composer footer.
- A `--settings` file carrying `model`, `reasoningEffort`, and `sessionDefaultSettings.autonomyLevel` rendered `DeepSeek V4.1 Flash 1017 (Low)` with `Auto (High)`, so all three keys are honoured in the interactive TUI.
- `--append-system-prompt` is honoured in the TUI: a launch pinned with "never say the word yes; say affirmative instead" answered `affirmative` to `Reply with just the word: yes`, and its visible reasoning read "Persona overrides".
- Process identity: `tmux display-message -p '#{pane_current_command}'` and `ps -o comm=` both report `droid`.
- Child environment: a shell tool run by `droid exec` reported `FACTORY_SESSION_ID=9e8a90cd-...` and `DROID_PROTECTED_PID=...`. `FACTORY_SESSION_ID` is a per-session UUID and is absent from the launching environment.
  A hook subprocess does NOT receive it: a `SessionStart` and a `Stop` hook each reported `FACTORY_SESSION_ID=<unset>` while `DROID_PROJECT_DIR` and `FACTORY_PROJECT_DIR` were set, so hook context is identified by ancestry alone.
- Ancestry depth: from a droid `SessionStart` hook, the digest is six to seven process levels below the `droid` binary (hook shell, `fm-sessionstart-droid.sh`, and `fm_run_timed`'s timeout wrapper). At an eight-parent bound `bin/fm-harness.sh` answered `unknown` for that hook while answering `droid` from a plain tool subprocess; a twelve-parent bound answers `droid`. `tests/fm-droid-harness.test.sh` pins both the deeper reach and the bound.

## Model validation

```
$ droid exec --list-tools -m deepseek-v4.1-flash-1017 | head -1
Available tools for DeepSeek V4.1 Flash 1017
$ droid exec --list-tools -m definitely-not-a-model-xyz; echo $?
Invalid model: definitely-not-a-model-xyz

Available built-in models:
  auto, claude-fable-5.1, ... deepseek-v4.1-flash-1017, ...
1
```

The probe resolves an id against the account's built-in and custom catalog, takes about 1.9 s, and makes no model call.
`bin/fm-spawn.sh` refuses on the definite `Invalid model:` answer, refuses every `custom:` id before probing because those BYOK endpoints can resolve to openrouter.ai, and launches unvalidated with a notice when the probe cannot answer.
An omitted model is pinned to `deepseek-v4.1-flash-1017` (Droid Core, 0.12x): the user store's own default is `custom:deepseek-v4.1-flash-vercel`, so an unpinned launch would never reach Droid Core.

## Hook surface

`droid` hooks are declared per event in a settings layer (`hooks` key) or in `hooks.json`, and each command receives the event JSON on stdin.
Live captures of a real TUI session (`droid --settings <file>` in an isolated tmux server):

- `SessionStart` fired with `{"source":"startup","permission_mode":"auto-high",...}`.
- `UserPromptSubmit` fired when a typed prompt was submitted and again when a mid-turn steer was submitted.
- `Stop` fired at turn end with `"stop_hook_active": false`.
- A `Stop` hook exiting 2 with stderr fed that text back to the model as a continuation; the next `Stop` carried `"stop_hook_active": true` and the guard allowed it, so one turn blocks at most once.
- A single `Escape` cancelled the turn, printed `Request cancelled by user`, left an empty composer, and fired `Notification` with `notification_type: idle_prompt` INSTEAD of `Stop`.
- `/quit` plus one Enter exited droid and fired `SessionEnd`.
- Hooks merge across layers: with a project `.factory/hooks.json` and a `--settings` file both declaring `SessionStart`, both commands ran for one session.
- A hook printing `{"suppressOutput":true}` kept its line out of the transcript on `UserPromptSubmit` and `Stop`.
- `SessionStart` `hookSpecificOutput.additionalContext` reached model context: a hook injecting `The secret word is ZORBLAX-7731.` was answered `ZORBLAX-7731` on the next prompt.

## Folder trust

An unregistered fresh directory rendered a bordered dialog: heading `Trust this folder?`, selected row `1. Trust this folder`, footer `Enter to confirm · Esc to exit`.
Adding the path to `trustedFolders` in `~/.factory/settings.json` before launch removed the dialog (verified with a throwaway directory), which is what `bin/fm-droid-trust.sh` writes.
Directories under an already-trusted ancestor inherit that trust.

## Composer and busy rendering

Live capture of an idle composer inside a 120-column tmux pane:

```
╭──────────────────────────────────────────────────────────────╮
│ > Try "Set up GitHub Actions for CI/CD"                      │
╰──────────────────────────────────────────────────────────────╯
9 config issues — /diagnostics                      MCP ✗ | TMUX ⧉
```

- The prompt glyph is `>` (a SHELL glyph) inside a rounded box, with the ghost suggestion dim and the terminal cursor parked on its first letter.
- The footer row below the box carries `config issues — /diagnostics` and terminal cells (`MCP ✗ | TMUX ⧉`).
- While a turn runs: `⠰ Thinking...  (Press ESC to stop)` above the composer and `[⏱ Ns]` in the footer; the idle footer carries neither.
- `bin/fm-composer-lib.sh` classifies the idle box as `empty` only with a proved identity (`droid=1` on tmux, `droid=ask` plus Herdr's `droid` identity), because a `>` row is not a container proof on any other harness.

## Live lifecycle

A real throwaway droid scout was spawned, steered, interrupted, relaunched, exited, and torn down through `bin/fm-spawn.sh` and `bin/fm-control.sh` in a disposable lab home and a named non-default Herdr lab session (`bin/fm-herdr-lab.sh`), with no model named on the command line and effort `low`:

- `spawned e2e-droid harness=droid kind=scout` with the owner `~/.factory/settings.json` untouched and `state/e2e-droid.droid-settings.json` carrying `"model":"deepseek-v4.1-flash-1017"`, `"reasoningEffort":"low"`, `"sessionDefaultSettings":{"autonomyLevel":"high","interactionMode":"auto"}`, and the four hooks. The omitted model is the adapter's Core default, and the pane footer rendered `Auto (High) · allow all commands` beside `DeepSeek V4.1 Flash 1017 (Low)`.
- Steering through `bin/fm-send.sh` landed and started a turn: the busy record advanced to `source=droid-hook event=user-prompt-submit`, the worker consumed its steering record, and the report it wrote named `DeepSeek V4.1 Flash 1017`.
- `bin/fm-control.sh interrupt` cancelled the turn; the record closed `idle source=droid-hook event=notification-idle`, with no composer repollution.
  `tests/fm-droid-signals-live-e2e.test.sh` also sends a single `Escape` to a running 3000-word turn and requires the spinner to leave; droid's `Request cancelled by user` row is transient and a capture loop can miss it, so the guard accepts either signal.
- `bin/fm-control.sh relaunch --note ...` replaced the agent in the same pane with `model=deepseek-v4.1-flash-1017 effort=low` and the worker finished its report.
  A relaunch issued within the first seconds of a spawn can refuse with `endpoint reads 'unreadable'` until Herdr has classified the fresh pane; the refusal is safe and the same command succeeds once the endpoint settles.
- `bin/fm-control.sh exit` stopped the agent and returned the pane to a shell prompt, and `bin/fm-teardown.sh` completed with its report in place.

A real droid SECONDMATE home was then seeded (`bin/fm-home-seed.sh`) and spawned twice, the second time on the adapter's Core default:

- `mate spawn rc=0` with `model=deepseek-v4.1-flash-1017` and a runtime settings file carrying both the `SessionStart` transport (`bin/fm-sessionstart-droid.sh`) and the `Stop` guard (`bin/fm-turnend-guard.sh --droid`).
- The mate's own digest arrived as `SessionStart` `additionalContext` with `primary harness: droid`, and the mate carried out the droid protocol's first instruction by running `bin/fm-wake-drain.sh`; it also reasoned "the Stop hook owns watcher arming", both of which appear only in [`docs/supervision-protocols/droid.md`](../supervision-protocols/droid.md).
- The mate ended its turn; its `Stop` hook ran `bin/fm-turnend-guard.sh --droid` from the mate home with `Exit code 0`, and the parent busy record closed `idle source=droid-hook event=stop`, which is the guard's own `.fm-busy-stop` writer.
- Before the ancestry-depth fix above, the same seeded home emitted `primary harness: unknown` and the fallback protocol, which is why that bound is now pinned by a test.

## Still unproven

- A droid MAIN-home primary. No tracked home settings file registers droid hooks, and the main home's own harness is unchanged.
- The pre-tool seatbelts (`fm-arm-pretool-check.sh`, `fm-cd-pretool-check.sh`, `fm-subagent-pretool-check.sh`). They are not wired for droid, so those deny paths do not apply.
- Herdr's native agent state for a droid pane before it settles, which is the relaunch caveat above.
- Model ids outside the account's own catalog, and effort levels a given model clamps rather than rejects.
