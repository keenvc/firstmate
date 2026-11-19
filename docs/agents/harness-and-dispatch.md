# Harness and runtime dispatch

Read this document at every crewmate, scout, or secondmate intake, before every spawn, and before choosing a dispatch profile, account, effort, or backend (`AGENTS.md` section 4).
It is an on-demand part of the `AGENTS.md` supervisor contract and carries the same authority as text written there; the hard rules and captain instruction precedence in `AGENTS.md` still govern it. Section numbers refer to `AGENTS.md` sections, each of which names the document that now holds its detail.

- Load `harness-adapters` before every spawn or recovery and before trust handling, skill invocation, interrupt, exit, resume, or adapter verification.
- The verified harnesses are `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, `omp`, `agy`, and `droid`, plus `muse`, `gemini`, `rovo`, `devin`, `commandcode` (Command Code), `polytoken`, `cortex`, `kiro`, `hermes`, and `cline` for crewmates and scouts only; never dispatch on an unverified adapter.
- If static `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, report it and fall back only to a verified adapter rather than launching it.
- Only the captain chooses or changes a worker account pin or declared account list (`config/claude-account`, `config/pi-account`, `config/claude-accounts`), so on a pin refusal report the needed login and never edit or remove the file to unblock a spawn.

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile required by `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Firstmate alone resolves a matched profile array: begin with `quota-axi`'s default TOON at that intake, using the skill's narrow TOON-then-`--json` fallback only for genuine ambiguity, evaluate every configured candidate against that current output, and choose under the skill's `preferred_provider` procedure with inspectable `spendPriority` as the one quota-perspective ranker after its eligibility, reasoning-class, and runway-feasibility gates.
Account for every candidate with the catalog evidence, provider relationship, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, and the spendPriority and runway evidence used in selection; never omit a candidate, guess, fall back silently, or call the result quota-informed without them.
Establish model support and provider family from that harness's own authoritative catalog, then apply the [account and scope matching rules in `quota-array-dispatch`](../../.agents/skills/quota-array-dispatch/SKILL.md#1-eligibility).
When the home's `config/crew-dispatch.json` declares `"shared_quota": true`, make no quota-axi call and apply no quota gate or ranking: choose by the matched rule's declared profile order and reasoning class (`preferred_provider` still narrows the pool; declared order then picks within it), accounting for every candidate with quota ranking off by home declaration (schema: `docs/configuration.md` "Crew dispatch profiles").
Missing model-level quota, a missing authentication source, unmeasurable headroom, or unmodeled authentication is disclosed uncertainty that keeps a candidate eligible, never a credential or login escalation.
Only concrete contradictory evidence blocks a candidate, such as an authoritative catalog proving the model unsupported or proof that the credential selected for that surface is unusable; never infer a credential store, provider family, or quota mapping from a harness, model, or source name, and never launch another harness's CLI to judge a candidate.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota; stop and report the tight choice if that class cannot proceed.
Break genuine evidence ties without array-order or harness bias.
`quota-axi` owns how model or product windows relate to bounding account windows and remains data-only.
Load `quota-array-dispatch` before choosing among a matched profile array or a Claude spawn's declared accounts; that skill is the single owner of the TOON-first spendPriority selection procedure.
Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pass its `profile:` line to `fm-spawn`, or pass your reason to override as `--dispatch-override <reason>`, because `fm-spawn` refuses other flags without it; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
The generic effort fallback and its precedence are owned by `harness-adapters`: explicit captain and standing configured effort win; otherwise use low for well-understood explicit work, xhigh for ambiguous investigation or design, intermediate levels proportionally, and never max without explicit captain preference.
Do not add model-specific versions of that policy.

`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
Dispatch only on a backend that `fm-spawn` validates as spawn-capable; pass an explicit per-spawn `--backend` only under that exact task's own authority, never as later-task precedent (selection contract: [`docs/configuration.md`](../configuration.md) "Runtime backend").
A missing dependency, authentication failure, unsupported backend, or version refusal is a blocker; never silently retry on another backend.
