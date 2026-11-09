#!/usr/bin/env bash
# Build the copper lane index: every local firstmate home and every lane
# record (state/*.meta) it holds, read-only. Output is a TSV the sweep reads:
#   <home>\t<task-id>\t<worktree>\t<pane-id>\t<last-turn-event>@<epoch>
# Refuses to write through a symlink and keeps the file private to this home.
set -u

OUT=${1:-/mnt/workdisk/tmp/copper-homes.tsv}
TMP=$(mktemp "${OUT}.XXXXXX") || exit 1
trap 'rm -f -- "$TMP"' EXIT HUP INT TERM

for home in /home/azureuser/firstmate /home/azureuser/fm-homes/*/; do
  home=${home%/}
  [ -d "$home/state" ] || continue
  for meta in "$home"/state/*.meta; do
    [ -f "$meta" ] || continue
    [ -L "$meta" ] && continue
    id=$(basename "$meta" .meta)
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -n 1)
    pane=$(sed -n 's/^herdr_pane_id=//p' "$meta" | head -n 1)
    [ -n "$pane" ] || pane=$(sed -n 's/^window=default://p' "$meta" | head -n 1)
    bfile="$home/state/$id.busy-state"
    busy=""
    if [ -f "$bfile" ]; then
      busy=$(sed -n 's/.*event=\([a-z-]*\).*/\1/p' "$bfile" 2>/dev/null | head -n 1)
      bts=$(sed -n 's/.* ts=\([0-9]*\).*/\1/p' "$bfile" 2>/dev/null | head -n 1)
      busy="${busy:-}@${bts:-}"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$home" "$id" "$wt" "$pane" "$busy"
  done
done | sort -u > "$TMP" || exit 1

chmod 0600 "$TMP"
cp -f -- "$TMP" "$OUT" || exit 1
exit 0
