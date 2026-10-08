#!/usr/bin/env bash
# Game day: run one chaos experiment with your bypass token and time the recovery.
#   read -rs -p "BYPASS_TOKEN: " CHAOS_BYPASS; echo; export CHAOS_BYPASS
#   scripts/gameday.sh kill-pod
# Talks to chaos-api through the ingress on this server, so Cloudflare (and its rate limit) is not in the way.
set -euo pipefail
id=${1:?usage: scripts/gameday.sh <action-id>   (ids: curl -s -H "Host: lab.hetops.dev" localhost:30870/chaos/actions)}
: "${CHAOS_BYPASS:?set your token first: read -rs -p 'BYPASS_TOKEN: ' CHAOS_BYPASS; echo; export CHAOS_BYPASS}"
url=http://localhost:30870/chaos
get() { curl -s -H 'Host: lab.hetops.dev' "$url/$1"; }

start=$(date +%s)
res=$(curl -s -w '\n%{http_code}' -H 'Host: lab.hetops.dev' -H "X-Chaos-Bypass: $CHAOS_BYPASS" \
  -H 'content-type: application/json' -d '{}' -X POST "$url/actions/$id")
code=${res##*$'\n'}
echo "${res%$'\n'*}"
[ "$code" = 202 ] || { echo "refused: HTTP $code"; exit 1; }

# The experiment is over when chaos-api reports nothing running.
until get status | grep -q '"experiment":null'; do
  printf '\r  watching the lab heal... %ss ' "$(( $(date +%s) - start ))"
  sleep 2
done
echo

get incidents | python3 -c '
import json, sys
e = json.load(sys.stdin)[0]
line = e["action"] + ": " + e["status"]
if "recoveryMs" in e: line += " in %.1f s" % (e["recoveryMs"] / 1000)
if e.get("error"): line += "   (the action itself failed: " + e["error"] + ")"
if e.get("reasons"): line += "   still unhealthy: " + ", ".join(e["reasons"])
print(line)'
