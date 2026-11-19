#!/usr/bin/env bash
# fm-wait.sh - block in bash until an external condition changes, then print
# ONE compact line. The token-free replacement for sleep-then-check loops run
# by an agent: every agent turn re-sends its whole context (~110k tokens for a
# persistent mate in 2026-11), so 3,246 `sleep N` calls, 4,589 `gh pr
# view/checks` calls and ~3,500 Buildkite reads a week were each a full-context
# model call that learned "not yet". One fm-wait call replaces the whole loop.
#
# Usage:
#   fm-wait.sh pr <pr-url> [--until change|checks|merged|head]
#       change (default): state, head, merge state, review decision, or the
#                         pass/fail/pending check counts differ from the first read
#       checks:  no reported check is pending (at least one has reported), or
#                the PR closed/merged, or its head moved
#       merged:  the PR is no longer OPEN
#       head:    headRefOid differs from the first read
#   fm-wait.sh status <owner/repo> <sha> [--context <name>]
#       The commit's status for <name> (or the combined status) is terminal:
#       success, failure or error. Buildkite posts `buildkite/<pipeline>` on
#       every build, so this answers "did the build for this SHA finish" from
#       ONE GitHub read and spends no Buildkite request (the shared Buildkite
#       REST bucket is 50/min for the whole keenvc user).
#   fm-wait.sh buildkite <org> <pipeline> <build-number>
#       Build state is terminal (passed, failed, canceled, skipped, not_run,
#       blocked). Needs BUILDKITE_API_TOKEN; interval floor 60s. Prefer
#       `status` above whenever the build posts a commit status.
#   fm-wait.sh file <path> [--newer-than <epoch>] [--grep <ERE>]
#       The file exists (and is newer than <epoch>, and has a line matching).
#   fm-wait.sh pid <pid>
#       The process has exited.
#
# Common options:
#   --timeout <s>   give up after <s> seconds (default 540: under the 10-minute
#                   ceiling most agent shell tools allow one command; pass your
#                   shell tool its maximum timeout, and on exit 124 simply run
#                   the same fm-wait again with nothing in between)
#   --interval <s>  seconds between reads (default 60 for forge reads, 5 for
#                   file/pid). Forge reads are floored at 30s, Buildkite at 60s.
#
# Output: exactly one line, at most 400 characters:
#   fm-wait: <kind> <target> <outcome> <facts...> after <N>s
# Exit: 0 condition met; 124 timed out (the line carries the last state);
#       2 usage; 3 the read failed 5 times in a row (the line names the error).
#
# GitHub budget: before forge reads it consults `gh api rate_limit` (which
# itself costs no quota) every 10th read, and when the relevant bucket is
# under FM_WAIT_GH_FLOOR (default 500) it sleeps toward the reset instead of
# reading, so a fleet of waiters backs off together rather than draining the
# shared token.
set -u

GH=${FM_WAIT_GH:-gh}
CURL=${FM_WAIT_CURL:-curl}
FLOOR=${FM_WAIT_GH_FLOOR:-500}
MIN_FORGE=${FM_WAIT_MIN_INTERVAL:-30}
MIN_BK=${FM_WAIT_MIN_BK_INTERVAL:-60}

usage() {
  sed -n '/^# Usage:/,/^# GitHub budget:/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

START=$(date +%s)
elapsed() { echo $(( $(date +%s) - START )); }
emit() {  # <text>: the one output line
  local line
  line="fm-wait: $* after $(elapsed)s"
  printf '%s\n' "${line:0:400}"
}

KIND=${1:-}
[ -n "$KIND" ] || usage
shift
POS=()
TIMEOUT=540
INTERVAL=
UNTIL=change
CONTEXT=
NEWER=
GREP=
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --until) UNTIL=${2:-}; shift 2 ;;
    --context) CONTEXT=${2:-}; shift 2 ;;
    --newer-than) NEWER=${2:-}; shift 2 ;;
    --grep) GREP=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    --*) echo "fm-wait: unknown option $1" >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "fm-wait: --timeout needs seconds" >&2; exit 2 ;; esac
case "$INTERVAL" in *[!0-9]*) echo "fm-wait: --interval needs seconds" >&2; exit 2 ;; esac

case "$KIND" in
  pr|status) : "${INTERVAL:=60}"; [ "$INTERVAL" -ge "$MIN_FORGE" ] || INTERVAL=$MIN_FORGE ;;
  buildkite) : "${INTERVAL:=60}"; [ "$INTERVAL" -ge "$MIN_BK" ] || INTERVAL=$MIN_BK ;;
  file|pid) : "${INTERVAL:=5}"; [ "$INTERVAL" -ge 1 ] || INTERVAL=1 ;;
  *) usage ;;
esac
DEADLINE=$(( START + TIMEOUT ))

need_jq() { command -v jq >/dev/null 2>&1 || { emit "$KIND ${POS[*]:-} error jq-missing"; exit 3; }; }

# Sleep for the interval, but never past the deadline. Returns 1 at the deadline.
nap() {
  local now left
  now=$(date +%s)
  left=$(( DEADLINE - now ))
  [ "$left" -gt 0 ] || return 1
  if [ "$left" -lt "$1" ]; then sleep "$left"; else sleep "$1"; fi
  [ "$(date +%s)" -lt "$DEADLINE" ]
}

READS=0
# gh_budget <graphql|core>: back off while the bucket is under the floor.
gh_budget() {
  local bucket=$1 out remaining reset wait
  [ $(( READS % 10 )) -eq 0 ] || return 0
  out=$("$GH" api rate_limit 2>/dev/null) || return 0
  remaining=$(printf '%s' "$out" | jq -r ".resources.$bucket.remaining // empty" 2>/dev/null)
  reset=$(printf '%s' "$out" | jq -r ".resources.$bucket.reset // empty" 2>/dev/null)
  case "$remaining" in ''|*[!0-9]*) return 0 ;; esac
  [ "$remaining" -lt "$FLOOR" ] || return 0
  case "$reset" in ''|*[!0-9]*) reset=$(( $(date +%s) + 300 )) ;; esac
  wait=$(( reset - $(date +%s) + 5 ))
  [ "$wait" -gt 0 ] || return 0
  nap "$wait" || return 1
}

FAILS=0
LAST_ERR=
# A failed read counts toward the 5-in-a-row stop; a good one resets it.
read_failed() {
  LAST_ERR=$1
  FAILS=$((FAILS + 1))
  if [ "$FAILS" -ge 5 ]; then
    emit "$KIND ${POS[*]} error ${LAST_ERR}"
    exit 3
  fi
}

# --- pr ---------------------------------------------------------------------
# shellcheck disable=SC2016 # jq program, not shell.
PR_JQ='def cls:
  if (has("conclusion") or .__typename == "CheckRun") then
    (if (.status // "COMPLETED") != "COMPLETED" then "pending"
     elif ((.conclusion // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$")) then "pass"
     else "fail" end)
  else
    (if ((.state // "") | test("^(PENDING|EXPECTED)$")) then "pending"
     elif .state == "SUCCESS" then "pass" else "fail" end)
  end;
[.statusCheckRollup[]? | {n: ((.name // .context // "?") | gsub("[[:space:]]"; "_")), c: cls}] as $c
| def s: if . == null or . == "" then "-" else tostring end;
  [ (.state | s), (.headRefOid | s)[0:12], (.mergeStateStatus | s), (.reviewDecision | s),
    ($c | length), ([$c[] | select(.c == "pass")] | length),
    ([$c[] | select(.c == "fail")] | length), ([$c[] | select(.c == "pending")] | length),
    ([$c[] | select(.c == "fail") | .n] | .[0:4] | join(",") | s) ]
| map(tostring) | join(" ")'

PR_CUR=
pr_read() {  # sets PR_CUR="state head merge review total pass fail pending failing"
  local json
  READS=$((READS + 1))
  json=$("$GH" pr view "$1" --json state,headRefOid,mergeStateStatus,reviewDecision,statusCheckRollup 2>&1) \
    || { read_failed "gh:$(printf '%s' "$json" | head -1 | tr -s ' ' '_' | cut -c1-80)"; return 1; }
  PR_CUR=$(printf '%s' "$json" | jq -r "$PR_JQ" 2>/dev/null)
  [ -n "$PR_CUR" ] || { read_failed jq-parse; return 1; }
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

pr_line() {  # <outcome> <read>
  local state head merge review total pass fail pending failing
  read -r state head merge review total pass fail pending failing <<<"$2"
  [ "$failing" != - ] || failing=
  emit "pr ${POS[0]} $1 state=$state head=$head merge=$merge review=$review checks=$total pass=$pass fail=$fail pending=$pending${failing:+ failing=$failing}"
}

wait_pr() {
  local url=${POS[0]:-} first='' cur='' state head total pending fhead
  [ -n "$url" ] || usage
  case "$UNTIL" in change|checks|merged|head) ;; *) usage ;; esac
  need_jq
  while :; do
    gh_budget graphql || break
    if pr_read "$url"; then
      cur=$PR_CUR
      FAILS=0
      [ -n "$first" ] || first=$cur
      read -r state head _ _ total _ _ pending _ <<<"$cur"
      read -r _ fhead _ <<<"$first"
      case "$UNTIL" in
        merged) [ "$state" = OPEN ] || { pr_line "$(lower "$state")" "$cur"; exit 0; } ;;
        head) [ "$head" = "$fhead" ] || { pr_line head-moved "$cur"; exit 0; } ;;
        checks)
          [ "$state" = OPEN ] || { pr_line "$(lower "$state")" "$cur"; exit 0; }
          [ "$head" = "$fhead" ] || { pr_line head-moved "$cur"; exit 0; }
          if [ "$total" -gt 0 ] && [ "$pending" -eq 0 ]; then pr_line checks-done "$cur"; exit 0; fi
          ;;
        change) [ "$cur" = "$first" ] || { pr_line changed "$cur"; exit 0; } ;;
      esac
    fi
    nap "$INTERVAL" || break
  done
  if [ -n "$cur" ]; then pr_line timeout "$cur"; else emit "pr $url timeout ${LAST_ERR:-no-read}"; fi
  exit 124
}

# --- status -----------------------------------------------------------------
wait_status() {
  local repo=${POS[0]:-} sha=${POS[1]:-} json st desc
  [ -n "$repo" ] && [ -n "$sha" ] || usage
  need_jq
  st=
  while :; do
    gh_budget core || break
    READS=$((READS + 1))
    if json=$("$GH" api "repos/$repo/commits/$sha/status" 2>&1); then
      if [ -n "$CONTEXT" ]; then
        st=$(printf '%s' "$json" | jq -r --arg c "$CONTEXT" '[.statuses[]? | select(.context == $c)][0] | if . == null then "missing" else .state end' 2>/dev/null)
        desc=$(printf '%s' "$json" | jq -r --arg c "$CONTEXT" '[.statuses[]? | select(.context == $c)][0].target_url // ""' 2>/dev/null)
      else
        st=$(printf '%s' "$json" | jq -r 'if ((.statuses // []) | length) == 0 then "missing" else .state end' 2>/dev/null)
        desc=
      fi
      if [ -n "$st" ]; then
        FAILS=0
        case "$st" in
          success|failure|error) emit "status $repo@${sha:0:12} $st${CONTEXT:+ context=$CONTEXT}${desc:+ url=$desc}"; exit 0 ;;
        esac
      else
        read_failed jq-parse
      fi
    else
      read_failed "gh:$(printf '%s' "$json" | head -1 | tr -s ' ' '_' | cut -c1-80)"
    fi
    nap "$INTERVAL" || break
  done
  emit "status $repo@${sha:0:12} timeout last=${st:-unknown}${CONTEXT:+ context=$CONTEXT}"
  exit 124
}

# --- buildkite --------------------------------------------------------------
wait_buildkite() {
  local org=${POS[0]:-} pipe=${POS[1]:-} num=${POS[2]:-} json st='' url
  [ -n "$org" ] && [ -n "$pipe" ] && [ -n "$num" ] || usage
  [ -n "${BUILDKITE_API_TOKEN:-}" ] || { emit "buildkite $org/$pipe#$num error no-BUILDKITE_API_TOKEN"; exit 3; }
  need_jq
  url="https://api.buildkite.com/v2/organizations/$org/pipelines/$pipe/builds/$num"
  while :; do
    if json=$("$CURL" -fsS --max-time 30 -H "Authorization: Bearer $BUILDKITE_API_TOKEN" "$url" 2>&1); then
      st=$(printf '%s' "$json" | jq -r '.state // empty' 2>/dev/null)
      if [ -n "$st" ]; then
        FAILS=0
        case "$st" in
          passed|failed|canceled|skipped|not_run|blocked)
            emit "buildkite $org/$pipe#$num $st commit=$(printf '%s' "$json" | jq -r '(.commit // "-")[0:12]')"
            exit 0
            ;;
        esac
      else
        read_failed jq-parse
      fi
    else
      read_failed "curl:$(printf '%s' "$json" | head -1 | tr -s ' ' '_' | cut -c1-80)"
    fi
    nap "$INTERVAL" || break
  done
  emit "buildkite $org/$pipe#$num timeout last=${st:-unknown}"
  exit 124
}

# --- file / pid -------------------------------------------------------------
file_mtime() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -Lf %m "$1" 2>/dev/null; else stat -Lc %Y "$1" 2>/dev/null; fi
}

wait_file() {
  local path=${POS[0]:-} m hit
  [ -n "$path" ] || usage
  while :; do
    if [ -e "$path" ]; then
      m=$(file_mtime "$path")
      if [ -z "$NEWER" ] || [ "${m:-0}" -gt "$NEWER" ]; then
        if [ -z "$GREP" ]; then
          emit "file $path present mtime=${m:-?}"
          exit 0
        fi
        hit=$(grep -E -- "$GREP" "$path" 2>/dev/null | tail -1)
        if [ -n "$hit" ]; then
          emit "file $path matched: ${hit:0:200}"
          exit 0
        fi
      fi
    fi
    nap "$INTERVAL" || break
  done
  emit "file $path timeout"
  exit 124
}

wait_pid() {
  local pid=${POS[0]:-}
  case "$pid" in ''|*[!0-9]*) usage ;; esac
  while kill -0 "$pid" 2>/dev/null; do
    nap "$INTERVAL" || { emit "pid $pid timeout still-running"; exit 124; }
  done
  emit "pid $pid exited"
  exit 0
}

case "$KIND" in
  pr) wait_pr ;;
  status) wait_status ;;
  buildkite) wait_buildkite ;;
  file) wait_file ;;
  pid) wait_pid ;;
esac
