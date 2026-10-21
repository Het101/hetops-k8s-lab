#!/usr/bin/env bash
# Change Timeline game day (T7), the rest in one go: four experiments 240 s apart (so each test alert resolves
# and the lab settles), then Part 2, the timeline killed mid-run. Everything is also saved to a log file.
#   read -rs -p "BYPASS_TOKEN: " CHAOS_BYPASS; echo; export CHAOS_BYPASS
#   scripts/timeline-gameday-all.sh
set -uo pipefail     # no -e: one failed experiment must not stop the rest
: "${CHAOS_BYPASS:?set your token first: read -rs -p 'BYPASS_TOKEN: ' CHAOS_BYPASS; echo; export CHAOS_BYPASS}"
cd "$(dirname "$0")/.."
log="$HOME/gameday-$(date -u +%Y%m%d-%H%M).log"
exec > >(tee "$log") 2>&1

for id in bad-release scale-zero kill-postgres traffic-spike; do
  echo; echo "===== $id  $(date -u +%H:%M:%S) UTC ====="
  scripts/timeline-gameday.sh "$id" || echo "  ($id exited $?)"
  echo "  next in 240 s..."; sleep 240
done

echo; echo "===== Part 2: the timeline killed during delete-web  $(date -u +%H:%M:%S) UTC ====="
since=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
scripts/gameday.sh delete-web & run=$!
sleep 3
kubectl delete pod -n timeline -l app=timeline
wait $run || echo "  (delete-web exited $?)"
kubectl rollout status deploy/timeline -n timeline --timeout=180s
sleep 10
feed=$(curl -s "https://lab.hetops.dev/timeline?since=10m")
echo "events since the kill:"
jq -r --arg since "$since" '[.[] | select(.at >= $since)] | sort_by(.at) | .[] | "  \(.at[11:23])  \(.source)/\(.kind)  \(.summary)"' <<<"$feed"
echo "duplicates (expect none):"
jq -r 'group_by(.source, .kind, .subject, .summary, .at) | map(select(length > 1)) | .[] | "  \(length)x  \(.[0].summary)"' <<<"$feed"

echo; echo "done. Log: $log"
