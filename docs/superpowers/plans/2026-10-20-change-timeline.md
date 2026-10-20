# Change Timeline in the lab: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a `timeline` service records every change and alert in the lab as one normalised event, ranks likely causes for each firing alert, and feeds a "What changed" panel on hetops.dev/lab.

**Architecture:**

- **Sources:**
  - watchers on Kubernetes (namespaces clinic, clinic-data, chaos) and on Argo CD Applications;
  - three internal ingest endpoints: Alertmanager, chaos-api and Falco.
- **Every source** calls one `record(event)`. It dedupes, stores in SQLite and broadcasts to SSE.
- **GET endpoints** serve public events. The owner path serves everything.

**Tech stack:** Node 22, Fastify, `@kubernetes/client-node`, `better-sqlite3`, prom-client, node:test. The image is arm64 only, like every lab image.

**Spec:** `docs/superpowers/specs/2026-10-20-change-timeline-design.md`.

## Global constraints

**Events:**

- Shape: `{ id, at, source, kind, subject, summary, actor, severity, ref, public, dedupe }`.
  - `id` is a ULID.
  - `at` is ISO UTC.
  - `dedupe` is a string unique per real-world occurrence. Re-seeing it is a no-op.
- Values:
  - `source ∈ chaos|k8s|argo|alert|falco|budget`
  - `severity ∈ info|warn|crit`
- **`public` is decided by the source module, never by the caller.**
  - Falco is always `false`.
  - Nothing public carries an IP, an email or a person's name. Visitors are `a visitor`.

**Retention:** 14 days, pruned hourly.

**Read limits:**

- `GET /timeline`: at most 500 rows; `since` between 1 minute and 24 h, default 2 h.
- `GET /timeline/all`: same limits. Owner-only through Cloudflare Access; the service itself serves it only on a separate port, 8081, which the ingress routes behind Access.

**Ingest:**

- `POST /ingest/*` needs header `Authorization: Bearer $INGEST_TOKEN` (compared in constant time).
- Returns 202, or 400 on a bad body, or 401.
- Bodies are at most 64 KiB.

**Likely causes:** for a `firing` event, look in the 30 minutes before it.

- **Rank:**
  1. same namespace or subject first;
  2. then kind weight `experiment 5 > rollout 4 = sync 4 > scale 3 > restart 2 > warning 1`;
  3. then the most recent.
- Store the top 3 ids in `ref.suspects`. Only public events can be public suspects.

**Collapsing:**

- Kubernetes `Warning` Events: one per object and reason per 5 min. The `dedupe` key is `k8s:warn:<ns>/<obj>:<reason>:<5-min bucket>`.
- Restarts: one per pod per restart count.

**Repo rules** (as for every lab repo):

- Author `Het Patel <patel.x.het@gmail.com>`, no AI attribution.
- Conventional Commit subjects under 72 characters.
- Changes go through PRs on Het101, pushed with `GH_TOKEN=$(gh auth token --user Het101)` and `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.
- Actions are pinned by SHA with exact version comments.
- CI covers node:test, CodeQL, dependency review and Trivy (Track 1 pattern).

---

## T1 · Service skeleton (Het101/change-timeline)

**Files:**
- `package.json`
- `src/event.js` (validate + normalise)
- `src/store.js` (SQLite)
- `src/hub.js` (SSE fan-out)
- `src/causes.js`
- `src/app.js` (Fastify routes)
- `src/server.js`
- `src/metrics.js`
- `test/*.test.js`
- `Dockerfile`
- `.github/workflows/ci.yml`
- `README.md` (rewritten for the lab version)

- [ ] `event.js`: `normalise(input, now)` fills `id` and `at`. It rejects unknown sources and kinds, truncates `summary` to 200 characters, and forces `public:false` for falco.
- [ ] `store.js`: `openStore(file)`.
  - Table `events`, with a UNIQUE index on `dedupe` and an index on `at`.
  - `insert(e)` returns `true` if new.
  - `list({ since, publicOnly, limit })` returns newest first.
  - `prune(before)`.
  - `get(id)`.
- [ ] `hub.js`: `subscribe(send)` returns an unsubscribe function. `publish(e)` sends only public events to public subscribers. A heartbeat goes out every 20 s.
- [ ] `causes.js`: `suspects(firing, candidates)` implements the ranking above.
- [ ] `app.js`:
  - `record(e)`: normalise → insert → if `firing`, compute suspects → publish → count the metric.
  - Routes: `GET /timeline`, `GET /timeline/stream`, `GET /healthz`, `GET /metrics`.
  - The owner app on 8081 serves `GET /timeline/all`.
- [ ] Tests:
  - dedupe;
  - the public filter (falco never leaks through `/timeline` or SSE);
  - `since` bounds and the limit;
  - retention prune;
  - suspects ranking: same-namespace experiment beats an older sync in another namespace; nothing outside 30 min;
  - 401 / 400 / 202 on ingest.
- [ ] `Dockerfile`: `node:22-bookworm-slim`, then `npm ci --omit=dev`, `USER node`, `EXPOSE 8080 8081`. Built with buildx for linux/arm64 and pushed to `ghcr.io/het101/change-timeline:<sha7>` (owner makes the package public).

## T2 · Watchers

**Files:** `src/watch/k8s.js`, `src/watch/argo.js`, `src/github.js`, and tests with recorded watch events in `test/fixtures/`.

- [ ] **`k8s.js`:** uses `k8s.Watch` on each namespace for Deployments, StatefulSets, Pods and Events.
  - Reconnects with backoff from 1 s up to 30 s, and counts `timeline_watch_restarts_total{source}`.
  - On start, it lists objects to seed a state map and emits nothing for them. Only changes after start become events.
  - Deployment template image change → `rollout` with summary `clinic/api rolling out clinic-api:70f5b04`. When `updatedReplicas == replicas == availableReplicas` → `rollout` with `finished` in the summary.
  - `spec.replicas` change → `scale`. The actor is `hpa` if the managedFields manager is the HPA controller, else `chaos-api` or `argocd` by the manager name.
  - Pod `restartCount` increase → `restart`, with the last state's `reason`. Pod deleted → `delete`, with the actor taken from the deletion cause when known.
  - Event `type=Warning` → `warning` (collapsed).
- [ ] **`argo.js`:** watches `applications` in `argocd`.
  - `status.sync.revision` change → `sync`. The summary comes from `github.js`.
  - `status.health.status` change → `health`. Severity is `warn` for Degraded and Missing, else `info`.
- [ ] **`github.js`:** `commitSubject(repoUrl, sha)` calls GET `https://api.github.com/repos/<owner>/<repo>/commits/<sha>` without auth. Results are cached by sha (LRU of 200). On failure it returns the short sha.
- [ ] Tests feed the fixture watch events through the handlers and assert the exact events produced, including that a re-list after a reconnect produces none.

## T3 · Ingest and causes

**File:** `src/ingest.js`.

- [ ] **Alertmanager:** POST body = the v4 webhook payload.
  - For each alert: `firing` or `resolved`, with dedupe `alert:<fingerprint>:<status>:<startsAt>`.
  - The subject comes from labels `namespace`/`deployment|pod|service`, else `lab`.
  - The summary is `annotations.summary || labels.alertname`.
  - Severity comes from `labels.severity`.
  - Alerts are public (they are `team=lab` alerts already shown in Telegram).
- [ ] **Chaos:** body `{ phase: 'start'|'finish'|'freeze'|'reopen', experiment }`.
  - Start and finish → `experiment`. On finish, `ref` carries `{ experimentId, recoveryMs, cost }`.
  - Freeze and reopen → `budget` events.
  - The body carries `actor`, set by chaos-api: `a visitor`, or `owner` when the request used the bypass token (game days and the self-test both do). chaos-api never sends `ipHash`, and the ingest drops any field it does not know.
- [ ] **Falco:** body = Falco's JSON output → `detection`, with `public:false`.
  - Summary is `<rule>: <output_fields.k8s.ns.name>/<k8s.pod.name>`.
  - Only priority Warning or above.

## T4 · Lab deploy (owner, lab-style; Claude supplies complete files)

**`apps/timeline/`:**
- `namespace.yaml` (Linkerd inject, restricted PSA)
- `quota.yaml` (cpu 200m / memory 384Mi)
- `serviceaccount.yaml`
- `rbac.yaml` (ClusterRole `timeline-reader`; RoleBindings in clinic, clinic-data, chaos; read on `applications` in argocd)
- `pvc.yaml` (1Gi local-path)
- `deployment.yaml` (1 replica, `Recreate`, probes on `/healthz`, env `INGEST_TOKEN` from the sealed secret, `DB_FILE=/data/timeline.db`)
- `service.yaml` (8080 public, 8081 owner)
- `networkpolicy.yaml`
- `sealed-ingest-token.yaml`
- `kustomization.yaml`

**Elsewhere:**
- `argo/apps/timeline.yaml` (wave 3, project `lab`).
- Ingress: `lab.hetops.dev/timeline` → 8080 (Access Bypass, like `/chaos`), and `lab.hetops.dev/timeline/all` → 8081 (Access owner-only).
- `platform/monitoring/values.yaml`: the `timeline` webhook receiver, plus `continue: true` on the `team="lab"` route.
- Falco values: `http_output` to `http://timeline.timeline:8080/ingest/falco`, with the token header.

**Lab loop:**
- **Predict:** the first `kubectl get events -n timeline` shows the PVC binding and the image pull.
- **Apply.**
- **Verify:**
  - `curl -s lab.hetops.dev/timeline?since=10m` returns `[]` and then fills after a kill-pod;
  - the Alertmanager status page lists the `timeline` receiver;
  - `/timeline/all` without Access gets a 302 to Access.

## T5 · chaos-api

- [ ] `src/timeline.js`: `createTimeline({ url, token, fetchImpl })` returns `emit(body)`. It POSTs with `AbortSignal.timeout(1000)`, swallows every error, and counts `chaos_timeline_errors_total`.
- [ ] Calls go in the runner (start and finish) and in the Guard's policy transitions (freeze and reopen). The runner already has `bypass` in `start()`; it maps it to `actor`.
- [ ] The self-test gains step 16: after kill-pod, it polls `http://timeline.timeline:8080/timeline?since=5m` for up to 30 s. It expects the experiment, at least one `k8s` event in `clinic`, and, if the experiment caused an alert, the alert's `ref.suspects` containing the experiment.
- [ ] `apps/chaos`: env `TIMELINE_URL` and `TIMELINE_TOKEN` (same sealed token), an egress NetworkPolicy to namespace `timeline` on 8080, and the image tag bump.

## T6 · Lab page (hetops-portfolio)

- [ ] `lab/timeline.js`: fetch `/timeline?since=2h`, then SSE `/timeline/stream`.
- [ ] Rendering, `textContent` only:
  - **Rows:** time, source glyph, summary.
  - **Your own experiment** is marked by the experiment id the page already holds → "you".
  - **Collapsing:** consecutive events with the same kind and subject collapse in the UI ("3 restarts in clinic/api").
  - **A firing alert without a matching resolved** pins to the top with "Likely causes" rows that scroll to their events.
  - **Filters:** All · Changes · Alerts.
  - **Empty and unavailable states** as in the spec.
- [ ] The mock (`scripts/lab-mock.mjs`) serves `/timeline` and `/timeline/stream` with a scripted incident, so the panel works locally.
- [ ] Checks: works at 375 px, reduced motion, no ad-blocker class words. Update the Shipped recently line.

## T7 · Game day and journal

- [ ] **Run with the bypass token:** kill-pod, bad-release, spike, kill-postgres and scale-zero.
- [ ] **For each, record:** the events seen, the time from action to first event, and whether the alert's top suspect is the experiment.
- [ ] **Kill the timeline pod in the middle of a run.** The watchers resume, nothing is duplicated (dedupe), and the gap shows only as missing `warning` collapses.
- [ ] **Write the journal section** "Part 9: Change Timeline" (what we wanted → what we ran → what happened → what it means), plus the results table.
- [ ] **Update the ideas list** with candidate product connectors: GitHub webhook, Terraform runs, CloudTrail writes.
