# Factory Droid CLI

Verified on 2026-10-28 with Factory Droid CLI 0.251.0 (`/home/azureuser/.local/bin/droid`).
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Native `UserPromptSubmit` opens, `Stop` closes normal completion (`--turn-ended`), and `SessionEnd` closes shutdown through the generation-bound writer; `../../../bin/fm-busy-lib.sh` owns trust. |
| Exit command | `/quit`, with the shared slash-command settle before Enter. |
| Interrupt | One Esc cancels a running turn (`(Press ESC to stop)`); no restored draft and no clear key. |
| Skill invocation | `/<skill>` or interactive Skill tool; Droid discovers skills from `.agents/skills` and `.factory/skills`. |
| Resume | `droid -r <session-id>` or `droid resume <session-id>`. |
| Model and effort | Interactive `droid` sets `sessionDefaultSettings.model` and `sessionDefaultSettings.reasoningEffort` (`low`, `medium`, `high`) through `--settings <path>` (`../../../bin/fm-droid-settings.sh`). |
| Quota provider | `factory` in `../../../bin/fm-quota-axi-lib.sh`. |
| Marker | None; anchored native `droid` ancestry identifies the adapter and outranks foreign inherited markers. |
| Autonomy | `--auto high` on disposable worker branches, reinforced by `sessionDefaultSettings.autonomyLevel = "high"` and `autonomyMode = "auto-high"` in the per-task runtime settings JSON. |
| Commit attribution | Unless the home sets `config/keep-ai-trailers` (`../../../../../docs/configuration.md` "Commit attribution"), the runtime settings JSON sets `includeCoAuthoredByDroid` false; `../../../bin/fm-git-strip-ai-trailers.sh` also strips `factory-droid[bot]` trailers at the git hook layer. |

## Worker lifecycle and settings

`../../../../../bin/fm-spawn.sh` owns autonomy, typed brief delivery, and per-task runtime settings generation.
`../../../../../bin/fm-droid-settings.sh` writes `<state-dir>/<task-id>.droid-settings.json` (mode 600) passed to `--settings <path>`.
Factory Droid merges `--settings` at the `runtime` hierarchy level (highest precedence) for that process only and merges `hooks` arrays across hierarchy levels, so user `~/.factory/settings.json` hooks continue to run and no global or worktree file is edited.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified rounded composer box around `> `, the active-turn placeholder (`Enter to steer · Ctrl+Enter to queue`), and the spinner interrupt hint (`(Press ESC to stop)`).

## Primary integration

No primary Stop guard or wake protocol is verified for Factory Droid.
Do not launch a primary or secondmate with this adapter.
