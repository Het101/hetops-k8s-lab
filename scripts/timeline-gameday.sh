#!/usr/bin/env bash
# Change Timeline game day (T7): run one experiment, fire a test alert right after it, and print what the
# timeline saw, how fast, and what it ranks as the alert's likely cause.
#   read -rs -p "BYPASS_TOKEN: " CHAOS_BYPASS; echo; export CHAOS_BYPASS
#   scripts/timeline-gameday.sh kill-pod
set -euo pipefail
id=${1:?usage: scripts/timeline-gameday.sh <action-id>}
case $id in kill-postgres) ns=clinic-data ;; *) ns=clinic ;; esac
since=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

"$(dirname "$0")/gameday.sh" "$id"

# A stand-in for the alert this experiment could cause, in the namespace it hits.
AM=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=alertmanager -o name | head -1)
kubectl -n monitoring exec "$AM" -c alertmanager -- amtool alert add GameDay team=lab severity=warning \
  namespace="$ns" experiment="$id" --annotation="summary=\"Game day: after $id\"" \
  --start="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --end="$(date -u -d '+2 min' +%Y-%m-%dT%H:%M:%SZ)" \
  --alertmanager.url=http://localhost:9093
echo "  test alert sent; waiting 20 s for it to arrive..."
sleep 20

curl -s "https://lab.hetops.dev/timeline?since=30m" | jq -r --arg since "$since" '
  def ms: (.[0:19] + "Z" | fromdateiso8601) * 1000 + ((.[20:23] | tonumber?) // 0);
  INDEX(.id) as $by    # every event of the last 30 min: a likely cause can predate this run
  | ([.[] | select(.at >= $since)] | sort_by(.at)) as $ev
  | ($ev | map(select(.source == "chaos" and (.summary | test(" ran ")))) | first) as $start
  | ($ev | map(select(.source != "chaos" and .source != "alert" and .at >= ($start.at // "")))) | first) as $first
  | ($ev | map(select(.kind == "firing" and .ref.alertname == "GameDay")) | last) as $alert
  | "events:", ($ev[] | "  \(.at[11:23])  \(.source)/\(.kind)  \(.summary)"),
    "first non-chaos event: " + (if $start and $first then "\((($first.at | ms) - ($start.at | ms)) / 1000) s after the start (\($first.source)/\($first.kind))" else "none" end),
    "likely causes of the GameDay alert:",
    (if $alert then ($alert.ref.suspects // [] | to_entries[] | "  \(.key + 1). \($by[.value].source)/\($by[.value].kind)  \($by[.value].summary)") else "  (the alert has not arrived)" end)'
