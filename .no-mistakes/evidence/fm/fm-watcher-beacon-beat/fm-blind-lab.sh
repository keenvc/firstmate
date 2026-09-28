#!/usr/bin/env bash
# Live: a home with in-flight work and NO watcher at all - the real turn-end
# guard must block and name what it observed about the beacon.
set -u
REPO=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
git init -q "$LAB"
git -C "$LAB" -c user.name=lab -c user.email=lab@invalid commit -q --allow-empty -m init
: > "$LAB/AGENTS.md"
mkdir -p "$LAB/bin" "$LAB/docs"
cp "$REPO"/bin/*.sh "$LAB/bin/"
cp -R "$REPO/docs/supervision-protocols" "$LAB/docs/supervision-protocols"
chmod +x "$LAB"/bin/*.sh
printf 'window=fleet:w1\nproject=%s/projects/demo\nharness=claude\nkind=ship\nbackend=tmux\n' "$LAB" > "$LAB/state/t1.meta"
mkdir -p "$LAB/fakebin"; ln -sf /bin/bash "$LAB/fakebin/claude"
echo "in-flight task records: $(ls "$LAB"/state/*.meta | wc -l); watcher lock present: $( [ -e "$LAB/state/.watch.lock" ] && echo yes || echo no); beacon present: $( [ -e "$LAB/state/.last-watcher-beat" ] && echo yes || echo no)"
echo "--- bin/fm-turnend-guard.sh --claude on a blind home ---"
set +e
printf '%s\n' '{"session_id":"sess-blind","stop_hook_active":false}' \
  | CLAUDECODE=1 FM_HOME="$LAB" "$LAB/fakebin/claude" -c '"$FM_HOME/bin/fm-turnend-guard.sh" --claude' 2>&1
echo "exit=$?"
