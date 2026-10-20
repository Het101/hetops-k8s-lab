# Change Timeline T7: game day

**Goal:** prove the timeline on real failures, not one kill-pod. For five experiments, record:
- what the timeline saw;
- how fast its first event came;
- whether a fresh alert's top likely cause is the experiment.

Then kill the timeline in the middle of a run and see what survives.

**Before you start:**
- Tonight's self-test reported `16/16` (sheet T4, 4b).
- Your prompt shows `my-workspace`.
- The error budget is open: the lab page does not say "frozen".

**The helper:** `scripts/timeline-gameday.sh <id>` does four things:
1. runs the experiment with your bypass (`gameday.sh`);
2. fires a test alert, `GameDay`, in the namespace the experiment hits;
3. waits 20 s;
4. prints the run's events, the time to the first non-chaos event, and the alert's top three likely causes.

The timeline ranks likely causes in this order:
1. changes in the alert's namespace come first;
2. then by kind: experiment 5, rollout/sync 4, scale 3, restart 2, warning 1;
3. then the nearest in time.

```bash
cd ~/hetops-k8s-lab && git checkout main && git pull
read -rs -p "BYPASS_TOKEN: " CHAOS_BYPASS; echo; export CHAOS_BYPASS
```

## Part 1: five experiments

Run them one at a time, at least 2 minutes apart so each test alert resolves. **Before each one, write your prediction in the table:**
- the events you expect;
- the first non-chaos event and how soon it comes;
- the top likely cause.

```bash
scripts/timeline-gameday.sh kill-pod
scripts/timeline-gameday.sh bad-release
scripts/timeline-gameday.sh scale-zero
scripts/timeline-gameday.sh kill-postgres
scripts/timeline-gameday.sh traffic-spike     # heavy: about 2 minutes
```

| Experiment | Predicted events | Seen events | First event (s) | Top likely cause | Right? |
|---|---|---|---|---|---|
| kill-pod | | | | | |
| bad-release | | | | | |
| scale-zero | | | | | |
| kill-postgres | | | | | |
| traffic-spike | | | | | |

**Hints, not answers:**
- `bad-release` changes a Deployment by hand. Who does the timeline name as the actor, and does Argo CD's self-heal show up?
- `scale-zero` should produce two `scale` events. Which actor is named on each?
- `kill-postgres` hits `clinic-data`. The alert is sent there too, so a nearby change in `clinic` should rank below it.
- `traffic-spike` may set off an HPA scale-up. Which comes first: the scale event or the chaos finish?

## Part 2: kill the timeline mid-run

**Predict:** the timeline is down for about 50 s while chaos-api pushes its events and the watchers miss pod changes. Which of these survive the restart, and why?
1. the `delete-web` chaos **start**;
2. the chaos **finish**;
3. the web pod's `k8s/delete`;
4. Argo CD's `Progressing` → `Healthy`.

```bash
scripts/gameday.sh delete-web & sleep 3
kubectl delete pod -n timeline -l app=timeline
wait
kubectl rollout status deploy/timeline -n timeline
sleep 10
curl -s "https://lab.hetops.dev/timeline?since=10m" | jq -r 'sort_by(.at) | .[] | "\(.at[11:23])  \(.source)/\(.kind)  \(.summary)"'
```

Then check for duplicates. **Expected:** nothing printed.

```bash
curl -s "https://lab.hetops.dev/timeline?since=10m" | jq -r 'group_by(.source, .kind, .subject, .summary, .at) | map(select(length > 1)) | .[] | "\(length)x  \(.[0].summary)"'
```

**Write down what was lost.** Each gap is a design finding for the journal, not a failure of this test. A lost chaos event would mean chaos-api's fire-and-forget needs a retry.

## Part 3: hand back

Paste me:
- the five helper outputs;
- the Part 2 output and the duplicate check.

Claude will:
- fill the results table in the journal (Part 9);
- write "What game day showed";
- add the product-connector ideas (GitHub webhook, Terraform runs, CloudTrail writes).
