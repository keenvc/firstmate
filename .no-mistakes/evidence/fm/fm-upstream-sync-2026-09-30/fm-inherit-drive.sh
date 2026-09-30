#!/usr/bin/env bash
# drive: primary lab home opts out of supervision host; push inherited config to a live secondmate home
set -u
TREE=$1   # tree whose bin/ to run
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); MATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bash "$PWD/bin/fm-lab-home.sh" create "$LAB" >/dev/null; bash "$PWD/bin/fm-lab-home.sh" create "$MATE" >/dev/null
: > "$LAB/config/supervision-host-off"
printf 'codex\n' > "$MATE/config/supervision-host"     # mate's own engine line
printf "sm-lab\n" > "$MATE/.fm-secondmate-home"; : > "$MATE/AGENTS.md"; mkdir -p "$MATE/bin"
printf 'kind=secondmate\nhome=%s\nwindow=sm-lab\n' "$MATE" > "$LAB/state/sm-lab.meta"
echo "== mate gate BEFORE push (claude primary): $(bash "$TREE/bin/fm-supervision-engine-lib.sh" enabled "$MATE/config" claude; echo exit=$?)"
echo "== FM_HOME=\$LAB fm-config-push.sh"
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMUX= bash "$TREE/bin/fm-config-push.sh" 2>&1 | sed 's/^/   /'
echo "   push exit=${PIPESTATUS[0]}"
echo "== mate config after push:"; ls -1 "$MATE/config" | sed 's/^/   /'
[ -f "$MATE/config/supervision-host-off" ] && echo "== inherited supervision-host-off: PRESENT" || echo "== inherited supervision-host-off: ABSENT"
echo "== mate own engine line preserved: $(cat "$MATE/config/supervision-host" 2>/dev/null)"
bash "$TREE/bin/fm-supervision-engine-lib.sh" enabled "$MATE/config" claude; echo "== mate gate AFTER push (claude primary): exit=$? (0=host runs, 1=off)"
echo "== control: remove primary opt-out and push again"
rm -f "$LAB/config/supervision-host-off"
env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMUX= bash "$TREE/bin/fm-config-push.sh" >/dev/null 2>&1
[ -f "$MATE/config/supervision-host-off" ] && echo "   mate opt-out after primary cleared: PRESENT" || echo "   mate opt-out after primary cleared: ABSENT"
bash "$TREE/bin/fm-supervision-engine-lib.sh" enabled "$MATE/config" claude; echo "   mate gate: exit=$?"
rm -rf "$LAB" "$MATE"
