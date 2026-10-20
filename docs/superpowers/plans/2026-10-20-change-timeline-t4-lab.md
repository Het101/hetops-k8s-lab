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

## 4b (next PR, preview): Alertmanager → timeline

1. **Generate one token** and seal it twice. Sealed Secrets are namespace-bound, and chaos gets its own copy in T5.

   ```bash
   TOKEN=$(openssl rand -hex 32)
   kubectl -n timeline create secret generic timeline-ingest --from-literal=token=$TOKEN --dry-run=client -o yaml \
     | kubeseal --format yaml > apps/timeline/sealed-timeline-ingest.yaml
   kubectl -n monitoring create secret generic alertmanager-timeline --from-literal=token=$TOKEN --dry-run=client -o yaml \
     | kubeseal --format yaml > platform/monitoring/extras/sealed-alertmanager-timeline.yaml
   ```

   Keep `$TOKEN` in the password manager (T5 seals it for chaos too). **Never paste it in chat.**
2. **Claude's PR** adds:
   - both files to their kustomizations;
   - `alertmanager-timeline` to `alertmanagerSpec.secrets`;
   - a `timeline` webhook receiver (`credentials_file`);
   - `continue: true` on the `team="lab"` route, so Telegram still gets every alert.
3. **Verify:**
   - the Alertmanager status page lists the receiver;
   - a forced test alert reaches both Telegram and `/timeline` as `firing`, then `resolved`.

## 4c (later): Falco through falcosidekick

The Falco chart's `falcosidekick.enabled: true`, with a webhook output to `/ingest/falco`. The `Authorization` header comes from a sealed secret in `falco`, delivered by a small `security`-project app. The result shows on the owner view only.
