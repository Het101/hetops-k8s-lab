# Change Timeline in the lab (design)

**Goal:** one feed that answers "what changed in the last two hours?". It puts every change and every alert in the lab on one line, and when an alert fires it shows the likely causes. On hetops.dev/lab a visitor sees their click, Kubernetes reacting, Argo CD healing, the alert and the recovery as one story.

**Why in the lab, and why now:** the lab already produces every kind of change on demand. The roadmap gate (two paying products) holds back the *SaaS*, not a lab feature. If the lab version proves useful, its event model and sources become the product's connectors.

**Decisions (owner, 2026-10-20):**

- **A small service of its own** (`timeline`), not Elasticsearch queries.
  - Elasticsearch keeps the raw logs for 3 days and stays owner-only.
  - The timeline keeps a curated, normalised change record for 14 days (owner confirmed).
- **Code lives in `Het101/change-timeline`**, the placeholder repo. Its README is rewritten to describe the lab version.
- **Public by default:** chaos experiments, Argo CD syncs and health, rollouts, scaling, restarts and lab alerts.
- **Owner-only:** Falco detections (owner confirmed: not even as a generic public line) and anything naming a person. Visitors are only ever "a visitor".

## Event model

Every source turns what it sees into one shape:

| Field | Example |
|---|---|
| `id` | ULID |
| `at` | `2026-10-20T14:02:11Z` |
| `source` | `chaos` · `k8s` · `argo` · `alert` · `falco` · `budget` |
| `kind` | `experiment` · `rollout` · `scale` · `restart` · `delete` · `warning` · `sync` · `health` · `firing` · `resolved` · `detection` · `freeze` · `reopen` |
| `subject` | `clinic/api` (namespace/name) |
| `summary` | `Argo CD synced clinic to 70f5b04: fix(api): one log line per request` |
| `actor` | `a visitor` · `chaos-api` · `argocd` · `hpa` · `kubelet` · `owner` |
| `severity` | `info` · `warn` · `crit` |
| `ref` | `{ revision, url, experimentId, alert }` (optional) |
| `public` | `true` / `false` |

**Rules:**
- Events are immutable.
- A source that re-sees the same thing (a watch reconnect, an alert re-send) produces the same `dedupe` key, and the duplicate is dropped.

## Sources (v1)

| Source | How | What becomes an event |
|---|---|---|
| **Kubernetes** | Watches over namespaces `clinic`, `clinic-data` and `chaos`, using `@kubernetes/client-node` (same pattern as chaos-api `k8s.js`). Read-only RBAC: get/list/watch only. | A Deployment or StatefulSet image change: a rollout, with start and finish taken from status. A replica count change: a scale, with the actor HPA or other. A pod deleted or restarted, with reason OOMKilled / Error. `Warning` Events (BackOff, FailedScheduling, Unhealthy), collapsed per object per 5 min. |
| **Argo CD** | Watch `applications.argoproj.io` in `argocd`, read-only. | `sync` when `status.sync.revision` changes. The commit subject is fetched once from the GitHub API (public repos) and cached. `health` when `status.health.status` changes, e.g. Degraded → Healthy. |
| **Alertmanager** | A second receiver, `timeline`, on the `team="lab"` route (`continue: true`, so Telegram still gets everything). It sends a webhook to `http://timeline.timeline:8080/ingest/alertmanager`. | `firing` and `resolved`, one per alert fingerprint. |
| **chaos-api** | chaos-api POSTs to `/ingest/chaos` when an experiment starts and when it finishes. Best effort: a timeline outage never blocks chaos. | `experiment`, with the action, the actor (a visitor, self-test or owner), and on finish the recovery time and budget cost. |
| **Error budget** | The same POST, from chaos-api's Guard. | `freeze` and `reopen`. |
| **Falco** | Falco `http_output` to `/ingest/falco`, priority Warning or above. | `detection`, owner-only. |

All `/ingest/*` paths are cluster-internal only. The ingress never routes them, NetworkPolicies allow only the namespaces that send, and a shared token is checked.

## Likely causes

When an alert fires, the timeline ranks the changes from the 30 minutes before it:

1. The same namespace as the alert, or the subject the alert names.
2. Most recent first.
3. Change kinds before noise: experiment > rollout or sync > scale > restart > warning.

**Output:** the top 3 are stored on the `firing` event as `ref.suspects`. The page shows them as "Likely causes".

**Honesty:** this is a ranking, not root-cause analysis, and the page says so ("changes just before this alert").

## Storage and retention

- **SQLite** (`better-sqlite3`) on a 1 Gi local-path PVC in namespace `timeline`.
- **Retention:** 14 days. Older rows are deleted hourly.
- **Size:** with dedupe and Warning collapsing, expected volume is a few thousand events a day, under 50 MiB.
- **Losing the volume** loses history, not function. Watchers rebuild current state on start.

## API

| Path | Who | Returns |
|---|---|---|
| `GET /timeline?since=2h` | public (Access bypass, like `/chaos`) | Public events, newest first. At most 500. `since` up to 24h. |
| `GET /timeline/stream` | public | SSE: each new public event, plus a heartbeat every 20 s. |
| `GET /timeline/all?since=…` | owner (behind Access) | Every event, including private ones. |
| `POST /ingest/{alertmanager,chaos,falco}` | in-cluster only | 202 |
| `GET /metrics` | Prometheus | `timeline_events_total{source,kind}`, `timeline_ingest_errors_total{source}`, `timeline_watch_restarts_total{source}` |

GET responses carry `Cache-Control: max-age=5`. The existing Cloudflare rate-limit rule covers POSTs, and GETs gain a looser rule of their own.

## hetops-k8s-lab

The owner types it lab-style, from complete manifest files.

- **Argo CD:** app `timeline` (wave 3) from `apps/timeline`.
- **Namespace and limits:** namespace `timeline`, a ResourceQuota, and requests/limits of 50m / 128Mi for the service.
- **RBAC:**
  - ClusterRole `timeline-reader`: get/list/watch on pods, events, deployments, statefulsets and replicasets, bound only in the three lab namespaces through RoleBindings;
  - get/list/watch on Argo CD `applications`.
- **NetworkPolicies:**
  - ingress from `ingress-nginx` (GET paths), `monitoring` (the Alertmanager webhook and scrapes), `chaos` and `falco`;
  - egress to DNS, the API server, `linkerd`, and api.github.com:443.
- **Linkerd:** meshed. A ServiceAccount of its own.
- **Alertmanager:** values gain the `timeline` receiver and `continue: true` on the lab route.
- **Falco:** values gain `http_output`.
- **Secrets:** a sealed `timeline-ingest` token, shared with chaos-api.

## chaos-api

- **`src/timeline.js`:** `emit(event)`. Fire-and-forget POST with a 1 s timeout. It is called from the runner (start and finish) and from the Guard (freeze and reopen).
- **Configuration:** env `TIMELINE_URL` and `TIMELINE_TOKEN`.
- **Self-test:** after each experiment it checks that the timeline shows the experiment and at least one Kubernetes reaction within 30 s.

## hetops-portfolio (lab page)

**"What changed" panel**, under the story feed:

- **The list:** a vertical timeline of the last 2 hours.
  - One row per event: time, source glyph, summary.
  - Your own experiment is marked "you".
  - Collapsed bursts read "3 restarts in clinic/api".
- **A firing alert** pins to the top with "Likely causes", up to 3 rows linking to their events.
- **Filters:** All · Changes · Alerts.
- **Live:** SSE adds rows. With reduced motion, rows appear without the slide.
- **Empty:** "Nothing changed in the last 2 hours. Break something."
- **Unavailable:** "Timeline unavailable right now". The rest of the page works.

**Page rules:** `textContent` only; no ad-blocker class words; works at 375 px; existing colour tokens.

## Out of scope for v1

- GitHub webhooks: Argo's sync revision already brings the commit.
- Terraform and CloudTrail: no cloud resources in the lab yet. They are the first connectors for the product.
- Search, a tracing correlation ID, and editing or annotating events.

## Plan outline (for the implementation plan)

1. **T1 · service skeleton:** event model, SQLite store with dedupe and retention, GET API and SSE, metrics, tests with a fake clock.
2. **T2 · watchers:** Kubernetes and Argo CD watchers with reconnect, plus the GitHub commit lookup with a cache. Tested against recorded watch events.
3. **T3 · ingest:** Alertmanager, chaos and Falco endpoints, the token check, likely-causes ranking.
4. **T4 · lab deploy** (owner, lab-style): namespace, quota, RBAC, NetworkPolicies, mesh, Argo app, Alertmanager and Falco values. Predict → apply → verify.
5. **T5 · chaos-api:** `emit`, env, self-test check.
6. **T6 · lab page:** the "What changed" panel.
7. **T7 · game day:** run 5 experiments. Check every one appears with its reactions, the alert pins its experiment as the top likely cause, and the timeline survives its own pod being killed. Then write the journal section.
