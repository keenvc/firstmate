#!/usr/bin/env bash
# fm-credit-preflight.sh - refuse a launch onto a prepaid provider whose real
# balance is exhausted, so firstmate fails over instead of losing the worker to
# "Insufficient credits" at launch.
#
# Usage: fm-credit-preflight.sh <model>
#
# The provider comes from the model id's leading segment, the way opencode
# names it: `openrouter/...` reads OpenRouter's credit (total_credits -
# total_usage, which quota-axi reports as "unlimited"), and `deepseek/...` reads
# DeepSeek direct's USD balance. Any other provider exposes no balance this
# script reads, so it says so on stderr and allows the launch.
#
# Exit 0: launch allowed (balance above the floor, no balance exposed, or the
#         read failed - an unreadable balance never blocks, it is reported).
# Exit 1: refused, with the exhausted balance and the remedy on stderr.
#
# Environment: FM_CREDIT_PREFLIGHT=off skips the check; FM_CREDIT_MIN_USD is the
# floor (default 0, refuse at or below it). FM_CREDIT_OPENROUTER_AUTH,
# FM_CREDIT_DEEPSEEK_ENV, FM_CREDIT_OPENROUTER_URL and FM_CREDIT_DEEPSEEK_URL
# relocate the credential files and endpoints (tests).
set -u

model=${1:-}
[ -n "$model" ] || { echo "usage: fm-credit-preflight.sh <model>" >&2; exit 2; }
[ "${FM_CREDIT_PREFLIGHT:-on}" != off ] || exit 0

floor=${FM_CREDIT_MIN_USD:-0}
provider=${model%%/*}

fetch() { # <url> <bearer-token> -> body on stdout
  curl -fsS -m 12 -H "Authorization: Bearer $2" "$1"
}

case "$provider" in
openrouter)
  auth=${FM_CREDIT_OPENROUTER_AUTH:-$HOME/.local/share/opencode/auth.json}
  key=$(jq -r '.openrouter | (.key // .access // empty)' "$auth" 2>/dev/null)
  url=${FM_CREDIT_OPENROUTER_URL:-https://openrouter.ai/api/v1/credits}
  filter='.data | (.total_credits - .total_usage)'
  remedy="top up OpenRouter or dispatch on a route that is not OpenRouter"
  ;;
deepseek)
  envf=${FM_CREDIT_DEEPSEEK_ENV:-$HOME/.config/firstmate/deepseek.env}
  key=$(sed -n 's/^DEEPSEEK_API_KEY=//p' "$envf" 2>/dev/null | head -n1 | tr -d "\"' ")
  url=${FM_CREDIT_DEEPSEEK_URL:-https://api.deepseek.com/user/balance}
  filter='[.balance_infos[] | select(.currency == "USD") | .total_balance | tonumber] | add // 0'
  remedy="top up DeepSeek direct or dispatch on a route that is not DeepSeek direct"
  ;;
*)
  echo "credit-preflight: provider '$provider' exposes no balance to read; not blocking" >&2
  exit 0
  ;;
esac

if [ -z "${key:-}" ]; then
  echo "credit-preflight: no $provider credential readable; balance unchecked, not blocking" >&2
  exit 0
fi
body=$(fetch "$url" "$key" 2>/dev/null) || body=
left=$(printf '%s' "$body" | jq -r "$filter" 2>/dev/null)
case "$left" in
'' | null | *[!0-9.-]*)
  echo "credit-preflight: could not read the $provider balance; not blocking" >&2
  exit 0
  ;;
esac
if awk -v l="$left" -v f="$floor" 'BEGIN { exit !(l <= f) }'; then
  echo "error: $provider credit is exhausted (balance $left USD, floor $floor); workers launched on it die with 'Insufficient credits' - $remedy" >&2
  exit 1
fi
echo "credit-preflight: $provider balance $left USD" >&2
exit 0
