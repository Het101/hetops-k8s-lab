# Change Timeline, T4: deploy it in the lab (lab sheet)

**Parent plan:** `2026-10-20-change-timeline.md` (T4).
**Spec:** `../specs/2026-10-20-change-timeline-design.md`.

T4 is split in two, so each part can be proven on its own:

- **4a (this PR):** the timeline runs, watches the cluster and serves the public feed.
  - Kubernetes and Argo CD changes appear.
  - Ingest is refused for now: the token is optional and not set yet.
- **4b (next PR):** you seal the ingest token, and Alertmanager starts sending alerts to the timeline.
  - Why it waits: Alertmanager's `credentials_file` setting needs the secret to exist first. Adding the setting before the secret exists would break Alertmanager.

**Deviations from the plan, found while preparing T4:**

1. **Owner view path:** it is `/owner/timeline`, not `/timeline/all`. That way, lab.hetops.dev's default owner-only Access policy covers it, and no second Access app is needed.
2. **Falco is not wired in T4:**
   - Falco's `http_output` cannot send an `Authorization` header (its options are TLS and the user agent only).
   - The fix is falcosidekick (which can), but its sealed token needs a home in namespace `falco`, which no app manages today.
   - Falco detections are owner-only and already in Kibana, so this becomes a small follow-up (T4c).
3. **Falco tuning:** the rule `Contact K8S API Server From Container` now also exempts namespace `timeline`. Calling the API all day is the timeline's job, and without the exemption it would alert constantly.

---

## 4a: what this PR changes

| File | What it does |
|---|---|
| `platform/namespaces.yaml` | New namespace `timeline`: Linkerd injection, Pod Security `restricted` |
| `platform/quotas.yaml` | Its ResourceQuota (200m / 256Mi requests, 1 / 512Mi limits, 2 pods, 1 PVC of at most 1Gi) and LimitRange |
| `argo/project.yaml` | Project `lab` may deploy to `timeline` |
| `argo/apps/timeline.yaml` | Argo CD app `timeline`, wave 3, from `apps/timeline` |
| `apps/timeline/rbac.yaml` | ServiceAccount `timeline`; ClusterRole `timeline-reader` (get/list/watch on pods, events, deployments, statefulsets); ClusterRole + binding `timeline-argo` (get/list/watch on Applications) |
| `apps/{clinic/base,clinic-data,chaos}/rbac-timeline.yaml` | A RoleBinding to `timeline-reader` in each lab namespace. The clinic one lives with the clinic app, so a nuke brings it back. |
| `apps/timeline/pvc.yaml` | 1Gi disk for the SQLite file |
| `apps/timeline/deployment.yaml` | One replica, `Recreate` (one writer), read-only root filesystem, `/data` on the PVC, the optional `INGEST_TOKEN` |
| `apps/timeline/ingress.yaml` | `lab.hetops.dev/timeline` → 8080 (public) and `/owner/timeline` → 8081 (owner) |
| `apps/timeline/networkpolicies.yaml` | Default deny, DNS and Linkerd. **In:** ingress-nginx, monitoring, chaos. **Out:** the Kubernetes API and HTTPS to the internet (api.github.com). |
| `argo/apps/falco.yaml` | `timeline` added to the API-contact exemption |

### Step 0: make the image public (browser, once)

GitHub → **Het101** → **Packages** → `change-timeline` → **Package settings** → **Change visibility** → **Public**.

Check from the server. Predict first: does an anonymous pull work now?

```bash
sudo crictl pull ghcr.io/het101/change-timeline:7d06768
```

### Step 1: predict, then merge

**Predict before merging**, and write the answers down:

1. Which Argo CD apps change? Name all of them.
2. In what order do the namespace, the RoleBindings and the timeline pod appear? Use the sync waves.
3. How many containers does the timeline pod have, and why?
4. What status does the PVC show before the pod is scheduled? (Hint: local-path uses `WaitForFirstConsumer`.)

**Then merge this PR.** Argo CD applies it within its 60 s reconcile.

### Step 2: verify

```bash
kubectl -n argocd get applications platform timeline clinic clinic-data chaos falco
kubectl -n timeline get pods,pvc
kubectl -n timeline logs deploy/timeline -c timeline | head
```

**Expected:**
- All apps are `Synced` / `Healthy`.
- The pod is `2/2` (timeline + linkerd-proxy).
- The PVC is `Bound`.
- The log says `watching clinic, clinic-data, chaos and Argo CD applications`.
- The log also says `INGEST_TOKEN is not set: every ingest request will be rejected`. That is correct in 4a: the token arrives in 4b.

**Least privilege.** Predict each answer first:

```bash
SA=system:serviceaccount:timeline:timeline
kubectl auth can-i watch pods -n clinic --as=$SA          # ?
kubectl auth can-i delete pods -n clinic --as=$SA         # ?
kubectl auth can-i watch pods -n default --as=$SA         # ?
kubectl auth can-i list applications.argoproj.io -n argocd --as=$SA   # ?
kubectl auth can-i get secrets -n clinic --as=$SA         # ?
```

Expected: yes, no, no, yes, no.

### Step 3: open the public door (Cloudflare dashboard)

Zero Trust → **Access** → **Applications** → **Add** → **Self-hosted**:
- **Name:** `lab timeline (public)`
- **Domain:** `lab.hetops.dev`, path `timeline`
- **Policy:** **Bypass**, **Everyone**. This is the same as the `/chaos` app.

Check both doors:

```bash
curl -s "https://lab.hetops.dev/timeline?since=10m"; echo                          # public: a JSON array
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://lab.hetops.dev/owner/timeline   # owner: 302 to Access
curl -s -H 'Origin: https://hetops.dev' -D - -o /dev/null "https://lab.hetops.dev/timeline" | grep -i access-control
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://lab.hetops.dev/ingest/chaos   # ingest is not routed: 404
```

### Step 4: watch it see a change

**Predict:** which timeline events will a kill-pod produce now, before T5 wires up chaos-api? Which source, which kind, which subject?

```bash
scripts/gameday.sh kill-pod
sleep 20; curl -s "https://lab.hetops.dev/timeline?since=5m" | jq -r '.[] | "\(.at)  \(.source)/\(.kind)  \(.summary)"'
```

**Expected:**
- `k8s/delete  pod api-… deleted` for the killed pod.
- Possibly `k8s/warning  Unhealthy: …` while its replacement starts.
- **No `chaos/experiment` yet.** That is T5.

**Then a GitOps change.** Merge any small commit to this repo and watch for `argo/sync  Argo CD synced <app> to <sha>: <your commit subject>`.

### Step 5: Falco stays quiet

After an hour, Kibana's saved search `lab incidents` should show no `Contact K8S API Server From Container` hits with `k8s.ns.name: timeline`.

---

## 4b: turn on every pushed source (one token, three sealed copies)

**Result of 4a (2026-10-20):**
- All apps `Synced` / `Healthy`, the pod `2/2`, the PVC `Bound`, and `can-i` gave `yes no no yes no`.
- **The first kill-pod** recovered in 8.2 s, and the timeline showed `argo/health Progressing` → `k8s/delete` → `argo/health Healthy`.
- **Two surprises:**
  1. `POST /ingest/chaos` from outside got **302**, not 404. Cloudflare Access stops it at the edge, before the cluster's own "no route".
  2. The pod deletion was timed 6 s late, when shutdown finished. Fixed in change-timeline `7748ad1`: a deletion is now timed when the pod is stamped for deletion.

**What this branch changes:**

| File | Change |
|---|---|
| `platform/monitoring/values.yaml` | The secret `alertmanager-timeline` is mounted. The `team="lab"` route goes to receiver `timeline` first with `continue: true`, so Telegram still gets everything. The new `timeline` webhook receiver (`send_resolved`, Bearer from `credentials_file`). |
| `platform/monitoring/extras/kustomization.yaml` | + `sealed-alertmanager-timeline.yaml` (**you add the file**) |
| `apps/timeline/kustomization.yaml` | + `sealed-timeline-ingest.yaml` (**you add the file**); image `7748ad1` |
| `apps/chaos/kustomization.yaml` | chaos-api `6dc0b46` (reports experiments and budget freezes). It reads `TIMELINE_TOKEN` from `chaos-secrets` (**you add the key**) through its existing `envFrom`. |
| `apps/chaos/networkpolicies.yaml` | chaos-api egress to namespace `timeline`, ports 8080 and 4143 |
| `apps/chaos/selftest-cronjob.yaml` | `TIMELINE_CHECK_URL=https://lab.hetops.dev/timeline`: the self-test checks that every experiment reached the timeline |

### Step 1: seal one token three times (on the server)

```bash
cd ~/hetops-k8s-lab && git fetch && git checkout lab/timeline-t4b && git pull
TOKEN=$(openssl rand -hex 32)
printf %s "$TOKEN" | kubectl -n timeline create secret generic timeline-ingest --from-file=token=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --format yaml > apps/timeline/sealed-timeline-ingest.yaml
printf %s "$TOKEN" | kubectl -n monitoring create secret generic alertmanager-timeline --from-file=token=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --format yaml > platform/monitoring/extras/sealed-alertmanager-timeline.yaml
printf %s "$TOKEN" | kubectl -n chaos create secret generic chaos-secrets --from-file=TIMELINE_TOKEN=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --format yaml --merge-into apps/chaos/sealed-chaos-secrets.yaml
unset TOKEN
```

**Store the token?** You do not need it again. To rotate it, generate a new one and run the three commands again. **Never paste it in chat.**

**Check it before committing.** Predict first: what should each check show?

```bash
grep -c "encryptedData" apps/timeline/sealed-timeline-ingest.yaml platform/monitoring/extras/sealed-alertmanager-timeline.yaml
grep -n "TIMELINE_TOKEN\|BYPASS_TOKEN" apps/chaos/sealed-chaos-secrets.yaml | cut -c1-60
for d in apps/timeline platform/monitoring/extras apps/chaos; do kubectl kustomize $d > /dev/null && echo "$d renders"; done
git add -A && git commit -m "lab 4b: seal the timeline ingest token" && git push
```

**Expected:**
- 1 and 1;
- both keys are present (the merge kept `BYPASS_TOKEN`);
- all three render.

### Step 2: predict, then merge PR

**Predict:**
1. In what order do the four apps re-sync? Which pods restart?
2. Will Telegram still get lab alerts? Why?
3. After a kill-pod, which new event kinds appear that 4a did not have?

**Then merge the PR.**

### Step 3: verify

```bash
kubectl -n argocd get applications monitoring timeline chaos
kubectl -n timeline logs deploy/timeline -c timeline | head -3     # no "INGEST_TOKEN is not set" now
kubectl -n chaos get pods
```

**A test alert to both receivers:**

```bash
AM=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=alertmanager -o name | head -1)
kubectl -n monitoring exec $AM -c alertmanager -- amtool alert add TimelineTest team=lab severity=warning \
  --annotation='summary="Test alert for the Change Timeline"' --start=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --end=$(date -u -d '+3 min' +%Y-%m-%dT%H:%M:%SZ) \
  --alertmanager.url=http://localhost:9093
sleep 30; curl -s "https://lab.hetops.dev/timeline?since=5m" | jq -r '.[] | "\(.at)  \(.source)/\(.kind)  \(.summary)"'
```

**Expected:**
- `alert/firing  Test alert for the Change Timeline` on the timeline, plus the same alert in Telegram. Quote the annotation value and pass `--start`: on 20 Oct, without `--start`, this amtool sent the end time as the start;
- after about 3 to 8 minutes, `alert/resolved` in both.

**A kill-pod with the bypass** (`read -rsp` as in 4a). Expected now:
- `chaos/experiment  The owner ran "Kill a pod"`;
- `k8s/delete` (timed before Argo's `Progressing`);
- `chaos/experiment  "Kill a pod" recovered in … · cost …`.

**Tonight's self-test** gains a 16th line, `timeline`. Expect `16/16 healed inside target` on the status page.

## 4c: Falco through falcosidekick (owner view only)

**Result of 4b (2026-10-20):** the test alert reached Telegram and the timeline (firing, then resolved); a kill-pod on `0702813` logged, in true order, the chaos start, `k8s/delete` 0.2 s later, Progressing, Healthy, and "recovered in 8.6 s · no error budget spent"; each lab commit recorded one sync, for the app whose files changed.

**Why a relay:** Falco's own `http_output` cannot send an `Authorization` header, and the timeline refuses ingest without one. falcosidekick (part of the Falco chart) receives every Falco alert and posts warning-and-above to `/ingest/falco` with the header. The timeline marks every Falco event `public: false`, so it shows only on the owner view.

**What this branch changes:**

| File | Change |
|---|---|
| `argo/apps/falco.yaml` | Two sources. The chart gains `falcosidekick` (1 replica, webhook to the timeline, `minimumpriority: warning`, `existingSecret: falcosidekick-timeline`). The second source, `security/falco`, carries the sealed header. |
| `security/falco/kustomization.yaml` | + `sealed-falcosidekick-timeline.yaml` (**you add the file**) |
| `apps/timeline/networkpolicies.yaml` | ingress from namespace `falco` (falcosidekick is not meshed, so it reaches port 8080 directly) |

The header is the same ingest token as 4b, read back from the cluster: no new token, nothing to rotate in three places.

### Step 1: seal the header (on the server)

```bash
cd ~/hetops-k8s-lab && git fetch && git checkout lab/timeline-t4c && git pull
TOKEN=$(kubectl get secret timeline-ingest -n timeline -o jsonpath='{.data.token}' | base64 -d)
printf 'Authorization:Bearer %s' "$TOKEN" | kubectl -n falco create secret generic falcosidekick-timeline \
  --from-file=WEBHOOK_CUSTOMHEADERS=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --format yaml > security/falco/sealed-falcosidekick-timeline.yaml
unset TOKEN
```

**Check it before committing.** Predict first: how many encrypted keys, and does the folder render?

```bash
grep -c "WEBHOOK_CUSTOMHEADERS" security/falco/sealed-falcosidekick-timeline.yaml
kubectl kustomize security/falco > /dev/null && echo "security/falco renders"
kubectl kustomize apps/timeline > /dev/null && echo "apps/timeline renders"
git add -A && git commit -m "lab 4c: seal the falcosidekick header" && git push
```

**Expected:** `1`, then both render.

### Step 2: predict, then merge the PR

**Predict:**
1. Which pods restart in `falco`, and which pod is new?
2. A pod in namespace `falco` reads `/etc/shadow` as root. Which Falco rule fires, at which priority, and where does it show: the public timeline, the owner view, or both?
3. A `kubectl exec` shell into a pod fires "Terminal shell in container". Why will it **not** reach the timeline?

**Then merge the PR** (or tell Claude to).

### Step 3: verify

```bash
kubectl get pods -n falco
```

**Expected:** the Falco DaemonSet pod restarted (its config now has `http_output`) and `falco-falcosidekick-…` is `1/1 Running`.

Fire a warning-level rule from a throwaway pod (Predict 2):

```bash
kubectl run falco-test -n falco --rm -i --restart=Never --image=busybox:1.36 -- sh -c 'cat /etc/shadow > /dev/null; echo done'
kubectl logs -n falco ds/falco -c falco --since=2m | grep -o '"rule":"[^"]*"' | sort | uniq -c
kubectl logs -n falco deploy/falco-falcosidekick --since=2m | grep -i webhook
```

**Expected:**
- Falco logged `Read sensitive file untrusted` (priority Warning);
- falcosidekick logged `Webhook - POST OK (202)`.

The owner view (port 8081 is not routed from outside, so forward it):

```bash
kubectl port-forward -n timeline svc/timeline 8081:8081 >/dev/null & PF=$!; sleep 2
curl -s "localhost:8081/owner/timeline?since=5m" | jq -r '.[] | select(.source=="falco") | "\(.at)  \(.severity)  \(.summary)"'
kill $PF
curl -s "https://lab.hetops.dev/timeline?since=5m" | jq '[.[] | select(.source=="falco")] | length'
```

**Expected:**
- the owner view: `warn  Read sensitive file untrusted: falco/falco-test`;
- the public timeline: `0`.

**If it does not arrive:**

| falcosidekick log says | Meaning |
|---|---|
| `POST OK (202)` but nothing on the owner view | below Warning, so the timeline dropped it: check the rule's priority |
| `401` | the header is wrong: re-run step 1 |
| `connection refused` / timeout | the network policy is not synced yet: `kubectl get netpol timeline -n timeline -o yaml \| grep falco` |
| the pod is `CreateContainerConfigError` | the sealed secret is not unsealed yet: `kubectl get secret falcosidekick-timeline -n falco` |
