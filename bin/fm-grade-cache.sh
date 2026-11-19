#!/usr/bin/env bash
# fm-grade-cache.sh - a head-SHA grade cache for PR review/verdict lanes.
#
# Why: the standing PR-flow steward re-graded PR heads it had already graded
# - 1,977 gh calls and 1.54B prompt tokens in seven days (2026-11-12..19) -
# because nothing durable told it "this exact head already has my verdict".
# A grade is a fact about one (repo, PR, head SHA); a new push is a new head
# and the only thing that needs a new grade.
#
# Usage:
#   fm-grade-cache.sh todo <owner/repo> [--exclude-author <login>]...
#       ONE `gh pr list` for the repo; prints one line per open, non-draft PR
#       whose current head has no cached grade, oldest first:
#         <number> <head-sha> <age-minutes>m <author> <title...>
#       Nothing printed = nothing to grade. Merge-queue drafts are skipped.
#   fm-grade-cache.sh get <owner/repo> <pr> <sha>
#       Prints the cached grade line and exits 0, or exits 1 when this head
#       has no grade.
#   fm-grade-cache.sh put <owner/repo> <pr> <sha> <verdict> [note...]
#       Records the grade for that head (verdict e.g. CLEAN, BLOCK, SKIP-LOW-RISK,
#       HUMAN-HOLD). Re-recording the same head replaces nothing; the newest
#       line for a head wins on get.
#   fm-grade-cache.sh list [<owner/repo>]
#       The newest grade per (repo, PR, head), tab-separated.
#
# Store: FM_GRADE_CACHE, default <home>/state/pr-grade-cache.tsv, lines
#   <repo>\t<pr>\t<sha>\t<verdict>\t<epoch>\t<note>
# appended under flock, so concurrent lanes never interleave a line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CACHE=${FM_GRADE_CACHE:-$FM_HOME/state/pr-grade-cache.tsv}
GH=${FM_GRADE_CACHE_GH:-gh}

usage() {
  sed -n '/^# Usage:/,/^# Store:/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

valid_sha() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" -ge 7 ]; }
valid_pr() { case "$1" in *[!0-9]*|'') return 1 ;; esac; }
valid_repo() { case "$1" in */*/*|/*|*/|*[!A-Za-z0-9._/-]*|'') return 1 ;; */*) return 0 ;; esac; return 1; }

# A short and a full SHA name the same head: compare on the shorter prefix.
lookup() {  # <repo> <pr> <sha>
  [ -f "$CACHE" ] || return 1
  awk -F '\t' -v r="$1" -v p="$2" -v s="$3" '
    $1 == r && $2 == p {
      n = length($3) < length(s) ? length($3) : length(s)
      if (substr($3, 1, n) == substr(s, 1, n)) hit = $0
    }
    END { if (hit == "") exit 1; print hit }' "$CACHE"
}

cmd_put() {
  local repo=$1 pr=$2 sha=$3 verdict=$4 note
  shift 4
  note=$(printf '%s' "$*" | tr '\t\n' '  ')
  if ! { valid_repo "$repo" && valid_pr "$pr" && valid_sha "$sha" && [ -n "$verdict" ]; }; then usage; fi
  verdict=$(printf '%s' "$verdict" | tr -c 'A-Za-z0-9_.-' '-')
  mkdir -p "$(dirname "$CACHE")" || exit 1
  (
    if command -v flock >/dev/null 2>&1; then
      exec 9>>"$CACHE.lock"
      flock -w 10 9 || exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$pr" "$sha" "$verdict" "$(date +%s)" "$note" >> "$CACHE"
  ) || { echo "fm-grade-cache: could not record" >&2; exit 1; }
}

cmd_todo() {
  local repo=$1 json now
  shift
  valid_repo "$repo" || usage
  local -a excl=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclude-author) excl+=("${2:-}"); shift 2 ;;
      *) usage ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { echo "fm-grade-cache: jq is required" >&2; exit 1; }
  json=$("$GH" pr list --repo "$repo" --state open --limit 200 \
    --json number,headRefOid,isDraft,author,title,createdAt 2>/dev/null) \
    || { echo "fm-grade-cache: gh pr list failed for $repo" >&2; exit 1; }
  now=$(date +%s)
  printf '%s' "$json" | jq -r --argjson now "$now" --arg ex "$(printf '%s\n' "${excl[@]:-}")" '
    ($ex | split("\n") | map(select(length > 0))) as $ex
    | sort_by(.createdAt)[]
    | select(.isDraft | not)
    | select((.title // "") | startswith("merge queue:") | not)
    | select(((.author.login // "") as $a | $ex | index($a)) | not)
    | [ (.number | tostring), .headRefOid,
        ((($now - (.createdAt | fromdateiso8601)) / 60 | floor | tostring) + "m"),
        (.author.login // "-"), (.title // "" | gsub("[\t\n]"; " ")) ]
    | @tsv' | while IFS=$'\t' read -r num sha age author title; do
      lookup "$repo" "$num" "$sha" >/dev/null && continue
      printf '%s %s %s %s %s\n' "$num" "$sha" "$age" "$author" "${title:0:100}"
    done
}

cmd_list() {
  [ -f "$CACHE" ] || return 0
  awk -F '\t' -v r="${1:-}" '(r == "" || $1 == r) { k = $1 FS $2 FS $3; last[k] = $0; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
    END { for (i = 1; i <= n; i++) print last[order[i]] }' "$CACHE"
}

case "${1:-}" in
  todo) [ $# -ge 2 ] || usage; shift; cmd_todo "$@" ;;
  get)
    [ $# -eq 4 ] || usage
    if ! { valid_repo "$2" && valid_pr "$3" && valid_sha "$4"; }; then usage; fi
    lookup "$2" "$3" "$4"
    ;;
  put) [ $# -ge 5 ] || usage; shift; cmd_put "$@" ;;
  list) cmd_list "${2:-}" ;;
  *) usage ;;
esac
