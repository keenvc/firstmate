# Maintaining AGENTS.md and its documents

Read this document before editing `AGENTS.md` or any `docs/agents/` document.
It is an on-demand part of the `AGENTS.md` supervisor contract and carries the same authority as text written there; the hard rules and captain instruction precedence in `AGENTS.md` still govern it. Section numbers refer to `AGENTS.md` sections, each of which names the document that now holds its detail.

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file, skill, command, or doc.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve every safety boundary and keep the always-loaded contract concise.

## The core and its on-demand documents

`AGENTS.md` is sent on every model call of every firstmate and secondmate session, so it holds only the always-needed core: identity and prime directives, safety and authority rules, session start, the supervision essentials and wake handling, the captain etiquette that applies to every message, captain instruction precedence, and the index of on-demand documents with their load triggers.
Situation-specific procedures belong in a `docs/agents/` document or the skill that owns them, named from `AGENTS.md` by exact path and trigger.
Move procedures rather than deleting them, keep every `AGENTS.md` section heading and number stable because scripts, skills, and tests cite them, and classify every new document in `docs/documentation-audiences.json`.
Keep `AGENTS.md` under 15,000 characters.

## Self-update reach

Firstmate's shared instruction surface reaches running homes only after it lands on the default branch and those homes fast-forward.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are loaded by a running firstmate; public `skills/` is an installer-facing surface.
A `docs/agents/` document is read from disk at its trigger, so a landed change reaches a running home at its next read after the fast-forward.
