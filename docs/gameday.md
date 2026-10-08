# Game day

Run all 15 experiments privately, one at a time. Before each one, **write down what you think will happen**, then run it and compare.

The surprises are the point. They become the runbook, and they show where a recovery target or the lab itself needs fixing before the public gets the buttons.

## Before you start

**1. Owner mode.** Only requests carrying your bypass token can run experiments; the public buttons stay paused.

```bash
kubectl -n chaos patch configmap chaos-config --type merge -p '{"data":{"enabled":"owner"}}'
```

**2. Your token,** once per terminal session (it never appears on screen):

```bash
read -rs -p "BYPASS_TOKEN: " CHAOS_BYPASS; echo; export CHAOS_BYPASS
```

**3. Two terminals and a browser.**
- **Terminal A** runs the experiments: `cd ~/hetops-k8s-lab && git pull`, then `scripts/gameday.sh <id>`.
- **Terminal B** watches: `kubectl get pods -n clinic -w` (swap in each experiment's "watch" command from the table below).
- **Browser:** https://hetops.dev/lab. Owner mode still shows the live scene, so you will see the pods change there too.

**4. Health check.** Every experiment refuses to start while the lab is unhealthy (HTTP 409 `healing`). If that happens, wait and look at `kubectl -n argocd get app clinic`.

## The 15 experiments, easiest first

For each one: read the prediction question, write your answer, run it, then note the recovery time and anything that surprised you.

| # | id | Predict | Watch in terminal B | Target |
|---|---|---|---|---|
| 1 | `kill-pod` | How many requests fail while the pod is replaced? | `kubectl get pods -n clinic -l app=api -w` | 30 s |
| 2 | `crash` | Does the pod get a new name, or the same name with RESTARTS +1? | `kubectl get pods -n clinic -l app=api -w` | 30 s |
| 3 | `leak` | What reason will `Last State` show? | `kubectl -n clinic describe pod -l app=api \| grep -A3 "Last State"` | 60 s |
| 4 | `hang` | Which fails first, readiness or liveness, and how many seconds apart? | `kubectl -n clinic get events -w --field-selector reason=Unhealthy` | 60 s |
| 5 | `evict-api` | How many evictions succeed, and how many are refused? | `kubectl -n clinic get pdb api -w` | 90 s |
| 6 | `delete-api-pods` | Does the PodDisruptionBudget stop this one? How long do requests fail? | `kubectl get pods -n clinic -l app=api -w` | 60 s |
| 7 | `kill-postgres` | Is any data lost? Which other pods notice? | `kubectl -n clinic-data get pod,pvc -w` | 120 s |
| 8 | `scale-zero` | Who scales `web` back to 2: Kubernetes or Argo CD? How long until it notices? | `kubectl -n argocd get app clinic -w` | 120 s |
| 9 | `delete-web` | Same question, for a whole deleted Deployment. | `kubectl -n clinic get deploy -w` | 120 s |
| 10 | `delete-api-svc` | The api pods stay healthy. Does the site still work? | `kubectl -n clinic get svc,endpointslices -w` | 120 s |
| 11 | `delete-secret` | Does the Secret come back? Who would bring it back? Do the running pods care? | `kubectl -n clinic get secret clinic-db -w` | 120 s |
| 12 | `rogue-netpol` | What breaks first? How does Argo CD know this policy is not in git? | `kubectl -n clinic get networkpolicy -w` | 180 s |
| 13 | `bad-release` | Do users see errors? What stops the broken version from replacing the good pods? | `kubectl -n clinic rollout status deploy/api -w` | 180 s |
| 14 | `traffic-spike` | How many api pods will the autoscaler add, and how long until it scales back down? | `kubectl -n clinic get hpa api -w` | 8 min |
| 15 | `nuke-namespace` | What comes back first? What happens to the database's data? | `kubectl get ns clinic -w` | 300 s |

Two notes:
- **Heavy actions (14 and 15)** are capped at 3 per hour, but your bypass skips that cap. Do them last.
- **For 15, keep `kubectl -n argocd get app -w` open** as well. That is where the rebuild is visible.

## After each experiment

Paste Claude the script's last line (for example `kill-pod: recovered in 4.1 s`), your prediction, and what surprised you. It all goes into the journal (Part 5).

## When you are done

```bash
kubectl -n chaos patch configmap chaos-config --type merge -p '{"data":{"enabled":"false"}}'
unset CHAOS_BYPASS
```
