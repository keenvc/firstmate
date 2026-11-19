#!/usr/bin/env bash
# fm-hold-sla.sh - a deadline and a default action for every open captain hold.
#
# A captain hold that nobody answers is the slowest thing in the pipeline: the
# answered ones take minutes, the unanswered ones sit for days. This command
# gives every open hold a deadline (FM_HOLD_SLA_HOURS, default 24h, per class
# FM_HOLD_SLA_HOURS_<CLASS>) and the default action recorded when it was first
# seen - the recommendation the raising agent already wrote. At expiry:
#
#   routine classes resolve to their default automatically:
#     duplicate   - another open hold has the same task, PR, or key; the older
#                   copies close as superseded, the newest stays.
#     moot        - the subject already resolved: a mirrored secondmate task is
#                   closed or no longer held, or (routine only) the PR the hold
#                   is about is merged or closed.
#     pr-merge    - a routine hold on a PR: merged (Mergify queue by default)
#                   only when CI is green AND the newest review VERDICT on the
#                   current head is CLEAN; otherwise it stays and is listed.
#     ask         - any other routine question with a recorded default: closed
#                   with that default and the default delivered to its owner.
#     parked      - a backlog hold the captain already parked ("deferred under
#                   captain-approved triage", "keep paused"): not a question, so
#                   it is re-held with --until today+FM_HOLD_SLA_PARK_DAYS (30)
#                   and leaves Captain's Call until that date.
#   captain-only classes never auto-resolve, whatever their age: production
#   writes, PHI, credentials/security, spending money, destructive data changes,
#   incidents (FM_HOLD_SLA_PROTECTED_* patterns, matched over the hold text and,
#   for a PR, its title, labels, and changed paths). A routine-looking hold with
#   no recorded default and a held WORK item (freeing work is attended-only) are
#   treated the same way. They stay held and are escalated in ONE daily digest.
#
# Usage:
#   fm-hold-sla.sh scan                       TSV of open holds (read-only)
#   fm-hold-sla.sh sweep [--live]             record SLAs, act on expired, write digest
#   fm-hold-sla.sh report [--out <path>]      one-off read-only backlog classification
#   fm-hold-sla.sh set <key> [--class <c>] [--default <text>] [--hours <n>]
#   fm-hold-sla.sh classify <text>            print the class a text would get
#
# Sources: every open keyed needs-decision/blocked record in this home's
# state/*.status (the status fold of bin/fm-classify-lib.sh, read-only) and
# every task held for the captain in this home's backlog. A
# `captain-hold-<task>-<n>` key is the parent-channel mirror of task <task> in
# the secondmate home recorded in state/<owner>.meta.
#
# sweep is a dry run unless --live or FM_HOLD_SLA_LIVE=1. A dry run writes only
# under state/hold-sla/ (records, log, digest) and never closes, merges, sends,
# or wakes. Live actions: a status-log close is one guarded self-announced
# `resolved [key=...]: hold-sla ...` append (bin/fm-wake-lib.sh); a task-backed
# hold closes through `fm-captain-hold.sh sla-close`, whose record says
# "SLA default applied", never "Captain decision"; an ask's default is delivered
# to its owner fire-and-forget through bin/fm-send.sh; the digest raises one
# `check` wake per UTC day. Config: optional config/hold-sla.env (KEY=VALUE).
#
# State: state/hold-sla/records/<id>.sla (first_seen, deadline, class, default),
# state/hold-sla/overrides/<key>.set, state/hold-sla/hold-sla.log,
# state/hold-sla/digest-YYYY-MM-DD.md and digest-latest.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SLA_DIR="$STATE/hold-sla"

die() { printf 'fm-hold-sla: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

if [ -f "$CONFIG/hold-sla.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k=${line%%=*} v=${line#*=}
    case "$k" in FM_HOLD_SLA_*) [ -n "${!k+x}" ] || export "$k=$v" ;; esac
  done < "$CONFIG/hold-sla.env"
fi

HOURS_DEFAULT=${FM_HOLD_SLA_HOURS:-24}
GH=${FM_HOLD_SLA_GH:-gh}
TASKS_AXI=${FM_HOLD_SLA_TASKS_AXI:-$FM_ROOT/bin/fm-tasks-axi.sh}
CAPTAIN_HOLD=${FM_HOLD_SLA_CAPTAIN_HOLD:-$FM_ROOT/bin/fm-captain-hold.sh}
SEND=${FM_HOLD_SLA_SEND:-$FM_ROOT/bin/fm-send.sh}

# Run a command against another home: its own state and data, never this one's
# overrides.
in_home() {  # <home> <command...>
  local h=$1; shift
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$h" "$@"
}
MERGE_MODE=${FM_HOLD_SLA_MERGE_MODE:-mergify-queue}
PR_HOLD_LABELS=${FM_HOLD_SLA_PR_HOLD_LABELS:-captain-hold do-not-auto-ready}
NOTIFY_OWNER=${FM_HOLD_SLA_NOTIFY_OWNER:-1}
NOW=${FM_HOLD_SLA_NOW:-$(date +%s)}
TODAY=$(date -u -d "@$NOW" +%F 2>/dev/null || date -u -r "$NOW" +%F)

# Captain-only patterns (extended regex, matched case-insensitively on word
# boundaries). Each is overridable; the class name is what the digest prints.
P_INCIDENT=${FM_HOLD_SLA_PROTECTED_INCIDENT:-incident|outage|sev[0-9]|p0|breach|leak|leaked|leaking|urgent}
P_PHI=${FM_HOLD_SLA_PROTECTED_PHI:-phi|hipaa|baa|pii|patient|patients}
P_SECURITY=${FM_HOLD_SLA_PROTECTED_SECURITY:-security|credential|credentials|secret|secrets|token|tokens|password|passwords|api[ -]?key|keys|pat|oauth|sso|rls|auth|vuln|vulnerability|cve|permission|permissions|access}
P_SPEND=${FM_HOLD_SLA_PROTECTED_SPEND:-spend|spending|budget|billing|invoice|payment|payments|paid|purchase|buy|subscription|top-?up|credit|credits|cost|money|refund|stripe|usd|price|pricing}
P_PROD=${FM_HOLD_SLA_PROTECTED_PROD:-prod|production|deploy|deployment|go-live|cutover|rollout|migration|migrations|migrate|dns|live}
P_DESTRUCTIVE=${FM_HOLD_SLA_PROTECTED_DESTRUCTIVE:-delete|deletion|deleting|drop|truncate|purge|wipe|destroy|discard|force-push|backfill|reset}
P_PARKED=${FM_HOLD_SLA_PARKED:-[Dd]eferred under captain-approved triage|[Kk]eep paused|parked list|[Pp]ark until}
PARK_DAYS=${FM_HOLD_SLA_PARK_DAYS:-30}
P_PATHS=${FM_HOLD_SLA_PROTECTED_PATHS:-(^|/)(infra|migrations?|db|auth|billing|payments?|secrets?)(/|$)|\.github/workflows/|\.buildkite/|\.env|deploy}

# Prints the captain-only class for <text>, or nothing when it is routine.
protected_class() {  # <text>
  local t c pat
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for c in incident phi security spend prod destructive; do
    case "$c" in
      incident) pat=$P_INCIDENT ;; phi) pat=$P_PHI ;; security) pat=$P_SECURITY ;;
      spend) pat=$P_SPEND ;; prod) pat=$P_PROD ;; destructive) pat=$P_DESTRUCTIVE ;;
    esac
    if printf '%s' "$t" | grep -Eq "(^|[^a-z0-9])($pat)([^a-z0-9]|$)"; then
      printf '%s\n' "$c"; return 0
    fi
  done
  return 0
}

# The agent's own recommendation, if it wrote one.
extract_default() {  # <text>
  printf '%s' "$1" | sed -nE '
    s/.*[Rr]ecommend(ation|ed|s)?[[:space:]]*[:=-]?[[:space:]]*([^.;]{3,160}).*/\2/p; t
    s/.*([Ss]uggest(ion|ed)?|[Mm]y pick|[Pp]ropos(e|ed|al))[[:space:]]*[:=-][[:space:]]*([^.;]{3,160}).*/\4/p; t
    s/.*[Dd]efault( action)?[[:space:]]*[:=-][[:space:]]*([^.;]{3,160}).*/\2/p' | head -1
}

extract_pr() {  # <text> -> "owner/repo N" or nothing
  printf '%s' "$1" | grep -Eo 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | head -1 \
    | sed -E 's#github\.com/([^/]+/[^/]+)/pull/([0-9]+)#\1 \2#'
}

one_line() { printf '%s' "$1" | tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\010\013-\037\177' | cut -c1-"${2:-600}"; }
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-180; }
meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# Raise epoch of each key in one status file: the [at=] of its first opening
# line. Lines written without a stamp take the nearest earlier stamp in the log
# (the log is append-only, so that bounds the raise from below), else the next.
status_raise_times() {  # <status-file> -> "key epoch" lines
  awk '
    { at = ""; if (match($0, /\[at=[0-9]+\]/)) at = substr($0, RSTART + 4, RLENGTH - 5) }
    at != "" { for (k in pend) { print k, at; delete pend[k] } last = at }
    /^(needs-decision|blocked)/ {
      if (match($0, /\[key=[A-Za-z0-9._-]+\]/)) {
        k = substr($0, RSTART + 5, RLENGTH - 6)
        if (k in seen) next
        seen[k] = 1
        if (at != "") print k, at
        else if (last != "") print k, last
        else pend[k] = 1
      }
    }' "$1"
}

# scan: one TSV row per open hold:
#   rid  source  owner  key  task  verb  raised  text
# An empty task is written as "-". rid is the dedupe identity: pr:<repo>#<n>, else task:<owner>:<task>, else
# status:<owner>:<key>.
scan() {
  local f owner open_rows times key verb note raised task pr rid
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    owner=${f##*/}; owner=${owner%.status}
    open_rows=$(status_open_decisions "$f" 2>/dev/null) || continue
    [ -n "$open_rows" ] || continue
    times=$(status_raise_times "$f")
    while IFS=$'\t' read -r key verb note; do
      [ -n "$key" ] || continue
      case "$key" in pending-reply-*|default) continue ;; esac
      case "$verb" in needs-decision|blocked) ;; *) continue ;; esac
      raised=$(printf '%s\n' "$times" | awk -v k="$key" '$1 == k { print $2; exit }')
      [ -n "$raised" ] || raised=$(stat -c %Y "$f" 2>/dev/null || echo "$NOW")
      task=''
      case "$key" in captain-hold-*-[0-9]*) task=$(printf '%s' "$key" | sed -E 's/^captain-hold-(.+)-[0-9]+$/\1/') ;; esac
      pr=$(extract_pr "$note")
      if [ -n "$pr" ]; then rid="pr:${pr% *}#${pr#* }"
      elif [ -n "$task" ]; then rid="task:$owner:$task"
      else rid="status:$owner:$key"; fi
      printf '%s\tstatus\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rid" "$owner" "$key" "${task:--}" "$verb" "$raised" "$(one_line "$note")"
    done <<< "$open_rows"
  done
  scan_tasks
}

scan_tasks() {
  local axi=$TASKS_AXI id show hk title reason stamp raised created text pr rid
  [ -x "$axi" ] || return 0
  "$axi" list --state held --limit 5000 --fields hold_kind 2>/dev/null \
    | sed -n 's/^  \([A-Za-z0-9._-]*\),.*,captain$/\1/p' | while read -r id; do
      [ -n "$id" ] || continue
      show=$("$axi" show "$id" --full 2>/dev/null) || continue
      hk=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)
      [ "$hk" = captain ] || continue
      title=$(printf '%s\n' "$show" | sed -n 's/^  title: //p' | head -1)
      reason=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: //p' | head -1)
      created=$(printf '%s\n' "$show" | sed -n 's/^  created: //p' | head -1)
      stamp=$(printf '%s\n' "$show" | grep -Eo 'Captain hold set: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1 | sed 's/^Captain hold set: //')
      raised=$(date -u -d "${stamp:-$created}" +%s 2>/dev/null || echo "$NOW")
      text="$title - $reason"
      pr=$(extract_pr "$text")
      if [ -n "$pr" ]; then rid="pr:${pr% *}#${pr#* }"; else rid="task:main:$id"; fi
      printf '%s\ttask\tmain\t%s\t%s\tcaptain-held\t%s\t%s\n' "$rid" "$id" "$id" "$raised" "$(one_line "$text")"
    done
}

# Mirror task state in its owning home: prints "state held hold_kind kind" or nothing.
mirror_task_state() {  # <owner> <task>
  local meta="$STATE/$1.meta" home show
  home=$(meta_get "$meta" home); [ -n "$home" ] || home=$(meta_get "$meta" worktree)
  [ -n "$home" ] && [ -d "$home" ] || return 0
  if ! show=$(in_home "$home" "$TASKS_AXI" show "$2" 2>&1); then
    # Only an explicit NOT_FOUND is absence; any other failure is unknown.
    case "$show" in *'code: NOT_FOUND'*) echo absent ;; *) echo unknown ;; esac
    return 0
  fi
  printf '%s %s %s %s\n' \
    "$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)" \
    "$(printf '%s\n' "$show" | sed -n 's/^  held: //p' | head -1)" \
    "$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)" \
    "$(printf '%s\n' "$show" | sed -n 's/^  kind: //p' | head -1)"
}

owner_home() {  # <owner>
  local h
  [ "$1" = main ] && { printf '%s\n' "$FM_HOME"; return; }
  h=$(meta_get "$STATE/$1.meta" home); [ -n "$h" ] || h=$(meta_get "$STATE/$1.meta" worktree)
  printf '%s\n' "$h"
}

# PR facts: sets PR_STATE PR_GREEN PR_CLEAN PR_PROTECT PR_WHY
pr_facts() {  # <repo> <n>
  local json head
  PR_STATE='' PR_GREEN=0 PR_CLEAN=0 PR_PROTECT='' PR_WHY=''
  json=$("$GH" pr view "$2" -R "$1" --json state,isDraft,mergeable,headRefOid,title,labels,files,statusCheckRollup,comments 2>/dev/null) \
    || { PR_WHY='PR unreadable'; return 1; }
  PR_STATE=$(printf '%s' "$json" | jq -r '.state')
  head=$(printf '%s' "$json" | jq -r '.headRefOid // ""')
  if printf '%s' "$json" | jq -e '[.statusCheckRollup[]? | select((.name // .context) != "Mergify Merge Protections")
        | select(((.conclusion // .state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$") | not))] | length == 0' >/dev/null 2>&1 \
     && [ "$(printf '%s' "$json" | jq -r '.mergeable')" != CONFLICTING ] \
     && [ "$(printf '%s' "$json" | jq -r '.isDraft')" != true ]; then
    PR_GREEN=1
  fi
  # Newest comment carrying a VERDICT that names the current head.
  if [ -n "$head" ] && printf '%s' "$json" | jq -e --arg h "$head" '
        [.comments[]? | .body | select(test("VERDICT"))
          | select((capture("(?i)(head|reviewed-commit)\\W*:?\\W*(?<s>[0-9a-f]{7,40})").s // "") as $s
                   | ($s | length) >= 7 and ($h | startswith($s)))]
        | last // "" | test("VERDICT\\W*:?\\W*(CLEAN|PASS|APPROVE)"; "i")' >/dev/null 2>&1; then
    PR_CLEAN=1
  fi
  PR_PROTECT=$(protected_class "$(printf '%s' "$json" | jq -r '.title + " " + ([.labels[]?.name] | join(" "))')")
  if [ -z "$PR_PROTECT" ] && printf '%s' "$json" | jq -r '.files[]?.path' | grep -Eiq "$P_PATHS"; then
    PR_PROTECT=paths
  fi
  [ "$PR_GREEN" = 1 ] || PR_WHY="CI not green, draft, or conflicting"
  [ "$PR_CLEAN" = 1 ] || PR_WHY="${PR_WHY:+$PR_WHY; }no CLEAN verdict on head ${head:0:8}"
  return 0
}

# classify one row -> sets CLS (routine class or captain-only:<why>), DEFAULT
classify_row() {  # <rid> <source> <owner> <key> <task> <text> <is_dup>
  local rid=$1 source=$2 owner=$3 key=$4 task=$5 text=$6 dup=$7 prot ts ov
  DEFAULT=$(extract_default "$text") HOURS=$HOURS_DEFAULT MOOT=''
  ov="$SLA_DIR/overrides/$(safe_name "$key").set"
  prot=$(protected_class "$text")
  if [ "$dup" = 1 ]; then CLS=duplicate
  elif [ "$source" = task ] && printf '%s' "$text" | grep -Eiq "$P_PARKED"; then
    # Already answered: the captain parked it. It is not an open question, only
    # an undated hold; the default re-dates it so it leaves Captain's Call.
    CLS=parked DEFAULT="re-hold with --until $(date -u -d "@$((NOW + PARK_DAYS * 86400))" +%F 2>/dev/null) (captain already parked it)"
  elif [ "$source" = status ] && [ -n "$task" ]; then
    ts=$(mirror_task_state "$owner" "$task")
    case "$ts" in
      unknown|'') CLS="captain-only:unverifiable-mirror" ;;
      absent) CLS=moot MOOT="mirrored task $task is absent from $owner's backlog" ;;
      done\ *) CLS=moot MOOT="mirrored task $task is closed in $owner's home" ;;
      *\ no\ *) CLS=moot MOOT="mirrored task $task is no longer held in $owner's home" ;;
      *) CLS='' ;;
    esac
    if [ -z "$CLS" ]; then
      if [ -n "$prot" ]; then CLS="captain-only:$prot"
      elif [ "${ts##* }" != captain ]; then CLS="captain-only:held-work"
      elif [ -z "$DEFAULT" ]; then CLS="captain-only:no-default"
      else CLS=ask; fi
    fi
  elif [ "${rid%%:*}" = pr ]; then
    if [ -n "$prot" ]; then CLS="captain-only:$prot"; else CLS="pr-merge"; fi
  elif [ -n "$prot" ]; then CLS="captain-only:$prot"
  elif [ "$source" = task ] && [ -z "$DEFAULT" ]; then CLS="captain-only:no-default"
  elif [ -z "$DEFAULT" ]; then CLS="captain-only:no-default"
  else CLS=ask; fi
  if [ -f "$ov" ]; then
    local oc od oh
    oc=$(meta_get "$ov" class); od=$(meta_get "$ov" default); oh=$(meta_get "$ov" hours)
    # An override may tighten a routine hold to captain-only, or record the
    # default; it can never turn a protected hold routine.
    if [ -n "$oc" ] && { [ "${CLS%%:*}" != captain-only ] || [ "${oc%%:*}" = captain-only ]; }; then CLS=$oc; fi
    [ -z "$od" ] || DEFAULT=$od
    [ -z "$oh" ] || HOURS=$oh
    if [ "$CLS" = captain-only:no-default ] && [ -n "$DEFAULT" ] && [ -z "$prot" ]; then CLS=ask; fi
  fi
  local ck
  ck=$(printf '%s' "${CLS%%:*}" | tr 'a-z-' 'A-Z_')
  ck="FM_HOLD_SLA_HOURS_$ck"
  [ -f "$ov" ] && [ -n "$(meta_get "$ov" hours)" ] || HOURS=${!ck:-$HOURS}
}

dedupe() {  # rows on stdin -> rows with a trailing is_dup column (newest per rid is 0)
  sort -t $'\t' -k1,1 -k7,7nr | awk -F '\t' -v OFS='\t' '{ d = ($1 == last) ? 1 : 0; last = $1; print $0, d }'
}

slog() { mkdir -p "$SLA_DIR" && printf '%s %s%s\n' "$(date -u -d "@$NOW" +%FT%TZ 2>/dev/null)" "$([ "$LIVE" = 1 ] || echo 'DRY ')" "$*" >> "$SLA_DIR/hold-sla.log"; }

record_sla() {  # <rid> <key> <raised> <deadline> <class> <default>
  local f
  f="$SLA_DIR/records/$(safe_name "$1")__$(safe_name "$2").sla"
  mkdir -p "$SLA_DIR/records"
  [ -f "$f" ] && return 0
  printf 'rid=%s\nkey=%s\nraised=%s\nfirst_seen=%s\ndeadline=%s\nclass=%s\ndefault=%s\n' \
    "$1" "$2" "$3" "$NOW" "$4" "$5" "$(one_line "$6" 200)" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

answer_cmd() {  # <source> <owner> <key> <task>
  if [ "$1" = status ]; then
    printf 'bin/fm-send.sh %s --resolve-key %s "<answer>"' "$2" "$3"
  else
    printf "printf '%%s\\\\n' '<answer>' > /tmp/a && bin/fm-captain-hold.sh answer %s --decision-file /tmp/a" "$4"
  fi
}

status_close() {  # <owner> <key> <note>
  local f="$STATE/$1.status" rc=0
  load_wake_lib || return 2
  fm_cap_line_var "resolved [key=$2]: hold-sla $(one_line "$3" 400)" $((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))
  [ "$(_fm_decision_key "$FM_LINE_CAP_LINE" 2>/dev/null)" = "$2" ] || return 2
  fm_wake_status_append_self_announced "$STATE" "$f" "$FM_LINE_CAP_LINE" || rc=$?
  [ "$rc" -ne 2 ]
}

deliver_default() {  # <owner> <key> <default> <hours>
  [ "$NOTIFY_OWNER" = 1 ] || return 0
  local id
  id=$(printf '%s %s %s' "$1" "$2" "$TODAY" | sha256sum | cut -c1-16)
  "$SEND" "$1" --fire-and-forget "$id" \
    "hold-sla: your captain call [key=$2] passed its ${4}h deadline unanswered and was closed with your recorded default. Apply it now: $3. (The captain can still override.)" >/dev/null 2>&1
}

pr_merge() {  # <repo> <n>
  local l
  for l in $PR_HOLD_LABELS; do "$GH" pr edit "$2" -R "$1" --remove-label "$l" >/dev/null 2>&1 || true; done
  case "$MERGE_MODE" in
    gh-auto) "$GH" pr merge "$2" -R "$1" --squash --auto >/dev/null 2>&1 ;;
    *) "$GH" pr comment "$2" -R "$1" --body "hold-sla: routine captain hold passed its deadline; CI green and the review verdict on this head is CLEAN, so it takes its default action (merge).

@mergifyio queue" >/dev/null 2>&1 ;;
  esac
}

# Evaluate every row. mode=report prints a classification table only.
evaluate() {  # <mode: sweep|report>
  local mode=$1 rid source owner key task verb raised text dup deadline age expired outcome cmd ev pr repo num park_until reason
  [ "$mode" = report ] || mkdir -p "$SLA_DIR"
  DIGEST_ROWS='' REPORT_ROWS=''
  while IFS=$'\t' read -r rid source owner key task verb raised text dup; do
    [ -n "$rid" ] || continue
    # scan writes "-" for an empty field: bash read collapses adjacent tabs.
    [ "$task" != - ] || task=''
    classify_row "$rid" "$source" "$owner" "$key" "$task" "$text" "$dup"
    pr=''
    if [ "$CLS" = pr-merge ]; then
      repo=${rid#pr:}; num=${repo##*#}; repo=${repo%#*}
      if pr_facts "$repo" "$num"; then
        pr="$repo#$num"
        if [ "$PR_STATE" = MERGED ] || [ "$PR_STATE" = CLOSED ]; then
          [ "${CLS%%:*}" = captain-only ] || { CLS=moot; MOOT="PR $pr is $PR_STATE"; }
        elif [ -n "$PR_PROTECT" ]; then CLS="captain-only:pr-$PR_PROTECT"
        else DEFAULT="merge once CI is green and the head verdict is CLEAN (now: green=$PR_GREEN clean=$PR_CLEAN)"
        fi
      else
        DEFAULT="merge once CI is green and the head verdict is CLEAN (PR unreadable now)"
      fi
    fi
    deadline=$((raised + HOURS * 3600))
    age=$(( (NOW - raised) / 3600 ))
    expired=0; [ "$NOW" -lt "$deadline" ] || expired=1
    cmd=$(answer_cmd "$source" "$owner" "$key" "$task")
    if [ "$mode" = report ]; then
      REPORT_ROWS+="$CLS"$'\t'"$age"$'\t'"$owner"$'\t'"$key"$'\t'"$source:$verb$([ "$source" = status ] && [ -n "$task" ] && echo :mirror)"$'\t'"$(one_line "${MOOT:-$DEFAULT}" 160)"$'\t'"$cmd"$'\t'"$(one_line "$text" 220)"$'\n'
      continue
    fi
    record_sla "$rid" "$key" "$raised" "$deadline" "$CLS" "$DEFAULT"
    if [ "${CLS%%:*}" = captain-only ] || [ "$expired" = 0 ]; then
      if [ "${CLS%%:*}" = captain-only ] && [ "$expired" = 1 ]; then
        DIGEST_ROWS+="$age"$'\t'"| ${age}h | ${CLS#captain-only:} | $owner | \`$key\` | $(one_line "${DEFAULT:-none recorded}" 120 | tr '|' '/') | \`$cmd\` |"$'\n'
      fi
      continue
    fi
    outcome=''
    case "$CLS" in
      duplicate) outcome="superseded by a newer open hold on $rid" ;;
      moot) outcome="moot: $MOOT" ;;
      ask) outcome="default applied after ${HOURS}h unanswered: $DEFAULT" ;;
      parked) outcome="captain-parked hold re-dated: $DEFAULT" ;;
      pr-merge)
        if [ "$PR_STATE" = OPEN ] && [ "$PR_GREEN" = 1 ] && [ "$PR_CLEAN" = 1 ]; then
          outcome="default applied after ${HOURS}h: merge $pr (CI green, verdict CLEAN)"
        else
          DIGEST_ROWS+="$age"$'\t'"| ${age}h | pr-merge blocked: ${PR_WHY:-PR unreadable} | $owner | \`$key\` | merge when green+CLEAN | \`$cmd\` |"$'\n'
          continue
        fi ;;
    esac
    slog "expire $CLS rid=$rid key=$key owner=$owner age=${age}h -> $outcome"
    [ "$LIVE" = 1 ] || continue
    if [ "$CLS" = pr-merge ]; then pr_merge "${pr%#*}" "${pr##*#}" || { slog "merge failed $pr"; continue; }; fi
    if [ "$CLS" = parked ]; then
      park_until=$(date -u -d "@$((NOW + PARK_DAYS * 86400))" +%F 2>/dev/null)
      reason=$("$TASKS_AXI" show "$key" --full 2>/dev/null | sed -n 's/^  hold_reason: //p' | head -1 | sed 's/^"//; s/"$//')
      if [ -n "$reason" ] && [ -n "$park_until" ] \
        && "$CAPTAIN_HOLD" hold "$key" --reason "$reason" --until "$park_until" >/dev/null 2>>"$SLA_DIR/hold-sla.log"; then
        slog "re-dated parked hold $key until $park_until"
      else
        slog "re-date refused for $key; left for the captain"
      fi
      continue
    fi
    if [ "$source" = task ] || { [ -n "$task" ] && [ "$CLS" = ask ]; }; then
      ev=$(mktemp "${TMPDIR:-/tmp}/fm-hold-sla.XXXXXX") || continue
      printf 'hold-sla %s: %s\nRaised: %s; deadline %sh; class %s.\n' "$TODAY" "$outcome" \
        "$(date -u -d "@$raised" +%FT%TZ 2>/dev/null)" "$HOURS" "$CLS" > "$ev"
      if [ "$source" = task ]; then set -- "$CAPTAIN_HOLD"; else set -- in_home "$(owner_home "$owner")" "$CAPTAIN_HOLD"; fi
      if "$@" sla-close "${task:-$key}" --evidence-file "$ev" >/dev/null 2>>"$SLA_DIR/hold-sla.log"; then
        slog "sla-closed ${task:-$key} in $(owner_home "$owner")"
      else
        slog "sla-close refused for ${task:-$key}; left for the captain"
        rm -f "$ev"; continue
      fi
      rm -f "$ev"
      [ "$source" = task ] && continue
    fi
    if status_close "$owner" "$key" "$outcome"; then
      slog "closed status key $key in $owner.status"
      [ "$CLS" = ask ] && deliver_default "$owner" "$key" "$DEFAULT" "$HOURS"
    else
      slog "status close failed for $key in $owner.status"
    fi
  done
}

write_digest() {
  local f="$SLA_DIR/digest-$TODAY.md" n
  n=$(printf '%s' "$DIGEST_ROWS" | grep -c . || true)
  {
    printf '# Captain hold digest %s\n\n' "$TODAY"
    printf '%s open captain-only holds are past their SLA (%s). Routine holds were resolved to their defaults; see state/hold-sla/hold-sla.log.\n\n' \
      "$n" "$([ "$LIVE" = 1 ] && echo live || echo 'dry run: nothing was changed')"
    printf '| age | class | owner | key | recommendation | answer with |\n| --- | --- | --- | --- | --- | --- |\n'
    printf '%s' "$DIGEST_ROWS" | sort -t $'\t' -k1,1nr | cut -f2-
  } > "$f.tmp" && mv -f "$f.tmp" "$f" && cp -f "$f" "$SLA_DIR/digest-latest.md"
  # One captain-facing wake per UTC day, only when something is waiting.
  if [ "$LIVE" = 1 ] && [ "$n" -gt 0 ] && [ ! -e "$SLA_DIR/.notified-$TODAY" ]; then
    if load_wake_lib && fm_wake_append check "hold-sla-digest-$TODAY" "check: hold SLA digest: $n captain-only holds are past their deadline and wait on you; one answer command each in $f"; then
      : > "$SLA_DIR/.notified-$TODAY"
    fi
  fi
  printf 'digest: %s (%s captain-only past SLA)\n' "$f" "$n"
}

WAKE_LIB_LOADED=0
load_wake_lib() {
  [ "$WAKE_LIB_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  FM_ROOT_OVERRIDE=${FM_ROOT_OVERRIDE:-$FM_ROOT} FM_STATE_OVERRIDE=$STATE . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  # shellcheck source=bin/fm-line-cap-lib.sh
  . "$SCRIPT_DIR/fm-line-cap-lib.sh" || return 1
  WAKE_LIB_LOADED=1
}

cmd=${1:-}; [ "$#" -gt 0 ] && shift
case "$cmd" in
  scan|sweep|report)
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh" || die "cannot load fm-classify-lib.sh" ;;
esac
LIVE=${FM_HOLD_SLA_LIVE:-0}
case "$cmd" in
  scan) scan ;;
  classify)
    c=$(protected_class "${1:-}"); d=$(extract_default "${1:-}")
    printf 'class=%s\ndefault=%s\n' "${c:+captain-only:$c}${c:-routine}" "$d" ;;
  sweep)
    [ "${1:-}" = --live ] && LIVE=1
    mkdir -p "$STATE" || die "cannot create $STATE"
    exec 8>"$STATE/.hold-sla.lock" || die "cannot open the sweep lock"
    flock -n 8 || { echo "fm-hold-sla: another sweep is running"; exit 0; }
    evaluate sweep < <(scan | dedupe)
    write_digest ;;
  report)
    out=''; [ "${1:-}" = --out ] && out=${2:-}
    LIVE=0
    evaluate report < <(scan | dedupe)
    {
      total=$(printf '%s' "$REPORT_ROWS" | grep -c . || true)
      auto=$(printf '%s' "$REPORT_ROWS" | grep -cv '^captain-only' || true)
      printf '# Captain hold backlog %s\n\nRead-only classification of every open captain hold in %s (nothing was changed).\n\n' "$TODAY" "$FM_HOME"
      printf -- '- open holds: %s\n- auto-resolvable at SLA expiry: %s\n- captain-only: %s\n\n' "$total" "$auto" "$((total - auto))"
      printf '## Counts by record type\n\n'; printf '%s' "$REPORT_ROWS" | cut -f5 | sort | uniq -c | sort -rn | awk '{printf "- %s: %s\n", $2, $1}'
      printf '\n(status = an open keyed record in state/<owner>.status; :mirror = the parent copy of a secondmate captain-held task; task = a captain-held task in this home'"'"'s backlog.)\n\n'
      printf '## Counts by class\n\n'; printf '%s' "$REPORT_ROWS" | cut -f1 | sort | uniq -c | sort -rn | awk '{printf "- %s: %s\n", $2, $1}'
      printf '\n## Age (hours since raised)\n\n'
      printf '%s' "$REPORT_ROWS" | awk -F '\t' '{ if ($2>=168) a++; else if ($2>=72) b++; else if ($2>=24) c++; else d++ } END { printf "- over 7 days: %d\n- 3-7 days: %d\n- 1-3 days: %d\n- under 1 day: %d\n", a, b, c, d }'
      for sect in auto captain; do
        if [ "$sect" = auto ]; then printf '\n## Auto-resolvable (would resolve to the default at expiry)\n\n'; sel='^captain-only'; inv=-v
        else printf '\n## Captain-only (answer these)\n\n'; sel='^captain-only'; inv=''; fi
        printf '| age h | class | owner | key | default / why moot | answer with | hold |\n| --- | --- | --- | --- | --- | --- | --- |\n'
        printf '%s' "$REPORT_ROWS" | grep -E $inv "$sel" | sort -t $'\t' -k2,2nr \
          | awk -F '\t' '{ for (i=1;i<=NF;i++) gsub(/\|/, "/", $i); printf "| %s | %s | %s | `%s` | %s | `%s` | %s |\n", $2, $1, $3, $4, $6, $7, $8 }'
      done
    } > "${out:-/dev/stdout}"
    [ -z "$out" ] || printf 'report: %s\n' "$out" ;;
  set)
    key=${1:-}; [ -n "$key" ] || die "set needs a key"; shift
    class='' default='' hours=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --class) class=${2:-}; shift 2 ;;
        --default) default=${2:-}; shift 2 ;;
        --hours) hours=${2:-}; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    case "$hours" in ''|*[!0-9]*) [ -z "$hours" ] || die "--hours must be a whole number" ;; esac
    mkdir -p "$SLA_DIR/overrides"
    f="$SLA_DIR/overrides/$(safe_name "$key").set"
    printf 'class=%s\ndefault=%s\nhours=%s\nset_at=%s\n' "$class" "$(one_line "$default" 200)" "$hours" "$NOW" > "$f"
    echo "set: $key" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
