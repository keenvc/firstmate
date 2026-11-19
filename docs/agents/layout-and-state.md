# Layout and state

Read this document when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths (`AGENTS.md` section 2).
It is an on-demand part of the `AGENTS.md` supervisor contract and carries the same authority as text written there; the hard rules and captain instruction precedence in `AGENTS.md` still govern it. Section numbers refer to `AGENTS.md` sections, each of which names the document that now holds its detail.

`docs/configuration.md` is the single owner of the top-level operational-home layout and configuration schemas; each producing script's header and help own exact child fields and mutation mechanics.
`FM_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`, while scripts continue to come from their tracked code root.
Each secondmate has a persistent isolated `FM_HOME`, including its own state, backlog, projects, and session lock.
`bin/fm-send.sh` fails closed unless `FM_HOME` is explicit, so a steer cannot silently resolve against another home.

Tracked files hold shared instructions and tooling; `data/` holds durable private fleet records; `state/` holds runtime records and append-only status events; `config/` holds local operating choices; and `projects/` contains clones that are read-only to firstmate except under hard rule 1's concrete captain-approved project operation exception.

Load `operational-home-layout` when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths.

A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconciliation.
Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the main-authoritative shared captain-preference file for secondmate inheritance, and `data/learnings.md` as curated home-local knowledge, regardless of harness memory, except for a knowledge class that a home-declared external memory tier under section 6 owns.
