# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4.
OpenCode 2.0.19 re-verified 2026-09-29 for launch, model config, and `--standalone`.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | None on the interactive launch path. OpenCode 2.x removed the top-level `--model` flag (`opencode run --model` remains for non-interactive `run`). Firstmate writes the resolved model into `OPENCODE_CONFIG_CONTENT` as a top-level `"model"` field, or as `agent.build.model` when a reasoning variant is also emitted, and launches with `opencode --standalone --prompt` so that JSON is honored instead of ignored by the shared background service (verified 2.0.19). |
| Effort flag | None for Firstmate's interactive `opencode --standalone --prompt` launch; `opencode run` has `--variant`, but that is not this path. The effort instead rides the launch's `OPENCODE_CONFIG_CONTENT` JSON as the `build` agent's `variant` keyed to the resolved model, the config schema's per-model reasoning-effort field verified on 1.18.32. It is emitted only when the resolved model's provider is known to expose that effort as a variant (`anthropic/*`: high, max; `openai/*`: low, medium, high, xhigh); with no model resolved, another provider, or an effort outside its family's list, the variant is omitted and only the top-level model field (when resolved) is added alongside the permission block. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.

## OpenCode 2.x launch verification (2026-09-29)

Environment: `opencode v2.0.19` on the task host, Firstmate worktree launch template from `bin/fm-spawn.sh`.

Before (reproduced pre-fix launch shape): `opencode --model 'anthropic/claude-sonnet-4-5' --prompt '…'` fails immediately with `Unrecognized flag: --model in command opencode` because 2.x only accepts `--model` on `opencode run`.

After (post-fix): `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"},"model":"openrouter/stealth/space-bunny-alpha"}' opencode --standalone --prompt '…'` starts the interactive TUI and honors the configured model (standalone required; without it, attaching to the background service ignores `OPENCODE_CONFIG_CONTENT` model).

Permission block: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"},"model":"…"}'` with `--standalone` continues to auto-approve tools per the permission JSON (same contract as pre-2.x launches).

Busy-state plugin, turn-end `session.idle` touch, and composer queued-Enter policy are unchanged on the interactive TUI path; portable regression remains `tests/fm-busy-adapter-wiring.test.sh` and `tests/fm-tmux-submit-busy.test.sh`.
