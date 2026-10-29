#!/usr/bin/env bash
# Live drift guard for the Factory Droid adapter's vendor-controlled surface:
# process name, folder trust, rendered composer/busy signals, the interrupt key,
# and the exit command.
# Opt-in because it submits real prompts (droid has no echo provider).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DROID_BIN=$(command -v droid 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-droid-signals-$$"
SESSION=droid-signals
TARGET="$SESSION:droid"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_DROID_SIGNALS_LIVE droid tmux
[ -n "$DROID_BIN" ] || fail "droid is not installed"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-droid-signals.XXXXXX") || fail "could not create the isolated droid lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated droid workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated droid workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated droid workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated droid workspace"
printf 'guard-id\n' >"$LAB/workspace/.fm-secondmate-home"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated droid workspace"

# The worker runs under a throwaway HOME holding a copy of ~/.factory, so its
# trust answer, sessions, and every other droid write land in the lab store
# rather than the operator's real one. The copy carries the account credential.
DROID_HOME="$LAB/home"
mkdir -p "$DROID_HOME" || fail "could not create the throwaway droid HOME"
[ -d "$HOME/.factory" ] || fail "no ~/.factory to stage for the throwaway droid HOME"
cp -R "$HOME/.factory" "$DROID_HOME/.factory" || fail "could not stage the throwaway droid credential copy"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# bin/fm-droid-trust.sh's secondmate-home mode is the shape this lab can prove:
# a marked home is what a droid secondmate launches into, and it needs no linked
# worktree. It must write the throwaway store, never the operator's.
HOME="$DROID_HOME" "$ROOT/bin/fm-droid-trust.sh" --secondmate-home "$WORKSPACE" guard-id >/dev/null \
  || fail "bin/fm-droid-trust.sh refused the marked lab home"
DROID_STORE="$DROID_HOME/.factory/settings.json"
node -e 'const fs=require("node:fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const p=process.argv[2];process.exit(j.trustedFolders&&Object.prototype.hasOwnProperty.call(j.trustedFolders,p)?0:1);' \
  "$DROID_STORE" "$WORKSPACE" \
  || fail "the pre-registered home is not recorded in the throwaway trustedFolders store"
pass "bin/fm-droid-trust.sh records the marked home in droid's own store"

cat >"$LAB/runtime-settings.json" <<'JSON'
{"model":"deepseek-v4.1-flash-1017","reasoningEffort":"low","sessionDefaultSettings":{"autonomyLevel":"high","interactionMode":"auto"}}
JSON

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n droid -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -e -t "$TARGET" -S 0 -E - 2>/dev/null || true
}

# The launch asks for a computed answer (12345+67890=80235) so the awaited token
# never appears in the echoed launch line itself.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$DROID_HOME\" $DROID_BIN --settings \"$LAB/runtime-settings.json\" --auto high \"Add 12345 and 67890. Reply with exactly the sum and nothing else\"" \
  || fail "could not type the droid launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit the droid launch line"

# Pre-registration must have removed the folder-trust dialog. If it renders
# anyway, answer the preselected trust row once so the rest of the guard can run,
# and report the drift rather than silently passing.
dialog_seen=0
screen=
for _ in $(seq 1 150); do
  screen=$(capture)
  case "$screen" in
    *"Trust this folder?"*|*80235*|*80,235*) break ;;
  esac
  sleep 0.5
done
case "$screen" in
  *"Trust this folder?"*)
    dialog_seen=1
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not answer the droid trust dialog"
    ;;
esac
[ "$dialog_seen" -eq 0 ] \
  || fail "the pre-registered home still parked on droid's folder-trust dialog"

# The busy row must render while the turn is in flight so the portable matcher
# has live text to prove. It is observed in the SAME poll that waits for the
# answer: a fast model can finish inside one interval, and a second loop that
# starts after the answer arrives would only ever see the settled composer.
busy_live=
answer_live=
for _ in $(seq 1 480); do
  screen=$(capture)
  if printf '%s\n' "$screen" | fm_busy_lines_match droid; then busy_live=1; fi
  case "$screen" in *80235*|*80,235*) answer_live=1; break ;; esac
  sleep 0.5
done
[ -n "$busy_live" ] || fail "the droid busy signature never matched a real turn in flight"
pass "the real droid busy row matches the droid delivery signature"

[ -n "$answer_live" ] || fail "the real droid worker never answered its launch prompt"
pass "the real droid worker processed its launch prompt"

# Wait for the settled idle composer, then prove the shared classifier reads it
# with droid's proved identity and refuses without one. droid shows the rotating
# `Try "..."` ghost on a FRESH session only; after the first turn the empty
# composer is a bare `>` row inside the box, so settle on the busy row leaving
# rather than on any placeholder text.
idle_settled=0
quiet=0
for _ in $(seq 1 180); do
  screen=$(capture)
  if printf '%s\n' "$screen" | fm_busy_lines_match droid; then
    quiet=0
  else
    quiet=$((quiet + 1))
    if [ "$quiet" -ge 2 ]; then idle_settled=1; break; fi
  fi
  sleep 0.5
done
[ "$idle_settled" -eq 1 ] || fail "the droid composer never settled out of its busy row"
verdict=$(fm_composer_classify_screen "$(printf 'styled=1\ncursor=1\nidentity=1\ndroid=1')" "$screen" '')
[ "$verdict" = empty ] || fail "the settled real droid composer must read empty with a proved identity, got '$verdict'"
probed=$(fm_composer_classify_screen "$(printf 'styled=1\ncursor=1\nidentity=1')" "$screen" '')
[ "$probed" = unknown ] || fail "the same screen without a droid identity must stay unknown, got '$probed'"
pass "the real droid idle composer reads empty only with its proved identity"

# One Escape cancels a running turn and prints droid's own cancellation row.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Write a 3000-word essay on the history of glass" || fail "could not type the long droid prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit the long droid prompt"
# The working composer's `Enter to steer` placeholder appears a moment before the
# model request starts, so gate the Escape on droid's spinner row instead: a
# press in that window would land on an idle composer and cancel nothing.
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"(Press ESC to stop)"*) break ;; esac
  sleep 0.5
done
case "$screen" in
  *"(Press ESC to stop)"*) : ;;
  *) fail "the long droid turn never showed its spinner row" ;;
esac
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape || fail "could not send Escape to the real droid turn"
# The rendered cancellation row is the strongest signal, but droid repaints the
# composer right after it and a capture can miss the row. Accept either that row
# or the spinner leaving within a few seconds of the press, which a 3000-word
# turn cannot reach by finishing on its own. A press that landed on an idle
# composer leaves the spinner up and fails both.
cancelled=
for _ in $(seq 1 60); do
  screen=$(capture)
  case "$screen" in *"Request cancelled by user"*) cancelled=row; break ;; esac
  case "$screen" in
    *"(Press ESC to stop)"*) : ;;
    *) cancelled=stopped; break ;;
  esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "a single Escape never cancelled the real droid turn; last screen:"$'\n'"$(capture | tail -20)"
if [ "$cancelled" = row ]; then
  pass "a single Escape cancels the real droid turn and prints its cancellation row"
else
  pass "a single Escape stops the real droid turn (spinner gone within the poll)"
fi

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/quit" || fail "could not type the droid exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit the droid exit command"
gone=
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in *droid*) sleep 0.5 ;; *) gone=1; break ;; esac
done
[ -n "$gone" ] || fail "/quit never stopped the real droid process"
pass "/quit stops the real droid process"

cleanup
trap - EXIT
