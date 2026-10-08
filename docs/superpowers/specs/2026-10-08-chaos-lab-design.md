# HetOps Chaos Lab: design

Date: 2026-10-08. Status: approved in brainstorming, awaiting spec review.

## Goal

A real Kubernetes cluster that the public can break from a web page, and that heals itself through Kubernetes controllers and Argo CD. It replaces the simulated "Break production" section on hetops.dev with live data. It also has to teach the owner Kubernetes and Argo CD properly, so the platform layer is typed by hand, lab-style.

Success means:

- Every one of the 15 chaos actions recovers on its own within its target time, proven by a nightly self-test.
- No visitor action can affect anything outside the `clinic`, `clinic-data` and `chaos` namespaces, or take CPU or memory from the Coolify sites on the same VM.
- The owner can explain every manifest in an interview.

## Constraints

- **One Oracle ARM VM**, 4 CPU and 24 GiB, shared with Coolify and every live hetops.dev site. Kubernetes is kubeadm on one node, with Calico, ingress-nginx (NodePort 30870) and local-path storage already installed. The FORWARD-chain REJECT rule was removed on 2026-10-07; pod networking works.
- **ARM64 images only.**
- **Coolify's Traefik owns ports 80 and 443.** Kubernetes must not bind them.
- **No client code.** The app is a look-alike of the healthcare platform's shape, written from scratch.

## Repositories

| Repo | Visibility | Contents | Who writes it |
| --- | --- | --- | --- |
| `Het101/hetops-k8s-lab` | Public | Kustomize bases and overlays, Argo CD Applications (app-of-apps), SealedSecrets, platform add-ons | Owner, by hand; CI only bumps image tags |
| `Het101/hetops-clinic` | Public | API, worker and web code, Dockerfiles, GitHub Actions to GHCR | Claude, owner reviews |
| `Het101/chaos-api` | Public | Chaos service code, tests, Dockerfile | Claude; owner writes its RBAC and NetworkPolicy in the lab repo |
| `Het101/hetops-portfolio` | Public (existing) | The `/lab` console page and the homepage teaser | Claude, by PR |

## Architecture

```text
                     Cloudflare (DNS, WAF, Turnstile, Access)
                                    |  outbound-only tunnel
+-------------- Oracle ARM VM (shared with Coolify) -----------------+
|  Coolify / Traefik :80/:443 -- hetops.dev sites (untouched)        |
|                                                                    |
|  Kubernetes (kubeadm, Calico)                                      |
|   ns platform    cloudflared --> ingress-nginx                     |
|                  sealed-secrets controller                         |
|   ns argocd      Argo CD (app-of-apps, selfHeal, prune)            |
|   ns clinic      api x3, worker x1, web x2, migrate Job, CronJob   |  <- visitors break this
|   ns clinic-data postgres StatefulSet (PVC on local-path)          |  <- only "kill the pod"
|   ns chaos       chaos-api (fixed action menu, scoped RBAC)        |
+--------------------------------------------------------------------+
        ^ git pull                                  ^ images
   GitHub: hetops-k8s-lab (config)        GHCR <- hetops-clinic and chaos-api CI
```

Hostnames, all through one Cloudflare Tunnel to ingress-nginx:

- `lab.hetops.dev`: the clinic web app at `/`, the clinic API at `/api`, chaos-api at `/chaos`.
- `argocd.hetops.dev`: the Argo CD UI, behind Cloudflare Access (owner only).

The console page lives at `hetops.dev/lab`, served by Coolify, outside the cluster, so it survives a namespace nuke.

### Resource budget

| Namespace | ResourceQuota (requests and limits) |
| --- | --- |
| `clinic` | 2 CPU, 3 GiB |
| `clinic-data` | 0.5 CPU, 1 GiB |
| `chaos` | 0.25 CPU, 256 MiB |
| `argocd`, `platform` | Not quota'd; measured after install, expected about 1.5 GiB together |

Every container has requests and limits (enforced by a LimitRange in each app namespace). The API HPA's maximum (5 replicas) fits inside the `clinic` quota.

## The clinic app

A multi-tenant clinic booking app: one admin database and one database per clinic, three demo clinics. The API resolves each tenant's database from the admin database, the same pattern as the healthcare platform.

| Component | Kind | Replicas | Details |
| --- | --- | --- | --- |
| `api` | Deployment, Node 22 + Fastify | 3, HPA to 5 on CPU 70% | Probes: startup and liveness on `/healthz`, readiness on `/readyz` (admin DB ping only). Strategy `maxSurge: 1, maxUnavailable: 0`. PDB `minAvailable: 2`. `RUN_JOBS=false` |
| `worker` | Deployment, same image | 1, `Recreate` | `RUN_JOBS=true`; runs a reminders job every minute against each tenant DB |
| `nightly-report` | CronJob, same image | - | Daily summary row per tenant |
| `migrate` | Job, same image | per sync | Argo CD `PreSync` hook, `hook-delete-policy: BeforeHookCreation`, `backoffLimit: 0`, `activeDeadlineSeconds: 600`; migrates admin then each tenant |
| `web` | Deployment, `nginxinc/nginx-unprivileged` + static app | 2 | Calls `/api` |
| `postgres` | StatefulSet in `clinic-data` | 1 | `postgres:17`, 2 GiB PVC on local-path, credentials from a SealedSecret |

API endpoints:

- Public: `GET /api/whoami` (pod name, image version, tenant count), `GET /api/clinics/:id/appointments`, `POST /api/clinics/:id/appointments`, `GET /api/work` (CPU-heavy, for the load test).
- Internal: `POST /internal/crash`, `/internal/leak`, `/internal/hang`. Require header `X-Chaos-Token` (from a Secret) and are reachable only from the `chaos` namespace (NetworkPolicy).

Images:

- Tagged with the commit SHA. A separate tag `bad` is built from the same code with `READINESS_ALWAYS_FAIL=true` baked in, for action 10.
- Multi-stage, non-root, ARM64, running under Pod Security `restricted` (read-only root filesystem, `emptyDir` for `/tmp`).

## Chaos actions

| # | Action | Implementation | Healer | Recovery target |
| --- | --- | --- | --- | --- |
| 1 | Kill a pod | Delete one random `api` pod | ReplicaSet | 30 s |
| 2 | Evict every API pod | Eviction API on each `api` pod | PDB holds 2 serving; ReplicaSet | 90 s |
| 3 | Delete every API pod | Delete all `api` pods | ReplicaSet (PDB does not block deletes) | 60 s |
| 4 | Crash the process | `POST /internal/crash` on one pod | kubelet restart | 30 s |
| 5 | Memory leak | `POST /internal/leak` until the 256 MiB limit | OOMKilled, kubelet restart | 60 s |
| 6 | Hang the app | `POST /internal/hang` blocks the event loop | Liveness probe restart | 60 s |
| 7 | Scale API to 0 | Patch `deployments/scale` to 0 | Argo CD selfHeal | 120 s |
| 8 | Delete `web` Deployment | Delete it | Argo CD selfHeal | 120 s |
| 9 | Delete `api` Service | Delete it | Argo CD selfHeal | 120 s |
| 10 | Bad release by hand | Patch `api` image to tag `bad` | `maxUnavailable: 0` keeps old pods; Argo CD reverts image | 180 s |
| 11 | Delete DB Secret | Delete Secret `clinic-db` in `clinic` | Sealed Secrets controller and Argo CD | 120 s |
| 12 | Rogue deny-all NetworkPolicy | Create `chaos-deny-all` with Argo CD's tracking label | Argo CD prune | 180 s |
| 13 | Kill Postgres | Delete pod `postgres-0` | StatefulSet, same PVC | 120 s |
| 14 | Traffic spike | 90 s of concurrent requests to `/api/work` from chaos-api | HPA 3 to 5, then scale-down | 8 min for scale-down |
| 15 | Nuke the namespace | Delete namespace `clinic` | Argo CD `CreateNamespace=true` and full resync | 300 s |

Argo CD must run with `selfHeal: true`, `prune: true` and a reconciliation timeout short enough to meet these targets. The default is 180 s; the lab sets 60 s. Before the targets are final they get measured during game day and adjusted.

## chaos-api

Node 22, one replica, `Recreate` strategy. Responsibilities:

1. **Actions:** `POST /chaos/actions/:id` with a Turnstile token. It runs the pre-written action and returns an experiment ID.
2. **Stream:** `GET /chaos/stream` (Server-Sent Events). It sends snapshots and changes from Kubernetes watches on:
   - pods, Deployments, EndpointSlices, events and HPA in `clinic` and `clinic-data`;
   - Argo CD `Application` status in `argocd`;
   - the results of a built-in prober.
3. **Prober:** five requests per second to `http://api.clinic/api/whoami`. Each result (pod, status, latency) goes into the stream, so viewers never generate load.
4. **Incident log:** the last 50 experiments, with action, start time, recovery time, outcome and hashed IP. Kept in memory and in a ConfigMap, so it survives restarts.

### Guardrails

1. A global lock: one experiment at a time. An experiment ends when the app is healthy again, or after 10 minutes, which marks it failed and alerts the owner.
2. A new experiment may start only when every Deployment in `clinic` is fully available and the Argo CD app is Synced and Healthy.
3. Cloudflare Turnstile is verified on the server for every action. A Cloudflare rate-limit rule covers `/chaos/actions`.
4. A per-IP cooldown of 60 s (from `CF-Connecting-IP`). Actions 14 and 15 are limited to 3 per hour each, across all visitors.
5. A kill switch: ConfigMap `chaos-config` key `enabled`. Actions are also refused when node memory working set is above 80%, read from metrics-server.
6. If an experiment fails, or chaos-api itself is down, HetOps Status (Uptime Kuma) alerts the owner. Uptime Kuma monitors `lab.hetops.dev/chaos/health`.

### RBAC (ServiceAccount `chaos-api`)

| Scope | Resources | Verbs |
| --- | --- | --- |
| Role in `clinic` | pods, events, endpointslices, deployments, horizontalpodautoscalers, services, networkpolicies | get, list, watch |
| Role in `clinic` | pods | delete |
| Role in `clinic` | pods/eviction | create |
| Role in `clinic` | deployments, deployments/scale | patch |
| Role in `clinic` | services (resourceNames: api), deployments (resourceNames: web) | delete |
| Role in `clinic` | secrets (resourceNames: clinic-db) | delete |
| Role in `clinic` | networkpolicies | create |
| Role in `clinic-data` | pods | get, list, watch |
| Role in `clinic-data` | pods (resourceNames: postgres-0) | delete |
| Role in `argocd` | applications.argoproj.io | get, list, watch |
| Role in `chaos` | configmaps (resourceNames: chaos-config, chaos-incidents) | get, watch, update |
| ClusterRole | namespaces (resourceNames: clinic) | get, delete |
| ClusterRole | nodes.metrics.k8s.io | get, list |

Explicitly absent: reading Secrets, `pods/exec`, creating pods, anything on nodes, any other namespace.

The `clinic` Roles and RoleBindings live in the `clinic` namespace, so action 15 deletes them along with everything else. Until Argo CD restores them, chaos-api's watches on `clinic` fail with 403 or 404. chaos-api must treat that as an expected state: keep retrying with backoff, and tell viewers "namespace gone, waiting for Argo CD", instead of crashing or showing stale pods. The cluster-scoped namespace permission and the `argocd` watch are unaffected, so the stream still shows the rebuild.

## Console page (`hetops.dev/lab`)

- A cluster map: namespaces as zones, pods coloured by true state, request dots from the prober going to the pod that answered.
- Argo CD status (sync and health), with a visible "drift detected, reverting" moment.
- The action buttons, Turnstile, a recovery timer, and target times per action.
- "What just happened" narration per event, with a kubectl toggle showing the command an engineer would run.
- The incident log.
- If the stream is unreachable or chaos is disabled, it falls back to the existing simulation, labelled "simulation".
- Reduced motion replaces the dots with a status line.
- Class names avoid ad-blocker trigger words ("ad", "banner", "cookie", "policy").
- The homepage's "Break production" section links to it.

## Testing

- **chaos-api unit tests:** lock, cooldowns, hourly caps, kill switch, refusing to start while unhealthy, Turnstile failure handling.
- **Clinic app tests:** readiness reflects admin DB availability; `/internal/*` rejects calls without the token.
- **Lab checks:** each platform lab has a pass condition. For example, a rollout with a bad image gives zero failed prober requests.
- **Nightly self-test CronJob** in `chaos`: runs every action in turn with a bypass token (not exposed publicly) and records recovery time against the target. It alerts through HetOps Status on regression, and skips if a public experiment is running.
- **Go-public gate:** game day passed, and the self-test green for 3 consecutive nights.

## Build order

| Phase | Owner | Work |
| --- | --- | --- |
| 0 | Owner | Push `hetops-k8s-lab` to GitHub; install Argo CD; reach the UI by port-forward |
| 1 | Claude | `hetops-clinic` code, Dockerfiles, CI to GHCR (ARM64) |
| 2 | Owner, labs L1 to L8 | L1 namespaces, quotas, LimitRanges. L2 Postgres StatefulSet and Sealed Secrets. L3 API Deployment with probes, PDB, HPA. L4 worker, CronJob, PreSync migrate Job. L5 Services, Ingress, Cloudflare Tunnel. L6 Kustomize base and overlay. L7 Argo CD app-of-apps, selfHeal, prune, sync waves, the private failing-migration lab. L8 RBAC, default-deny NetworkPolicy, Pod Security restricted |
| 3 | Claude code, owner RBAC | chaos-api |
| 4 | Claude | Console page on hetops.dev |
| 5 | Owner | Game day: all 15 actions privately, predictions, runbook |
| 6 | Both | Go public after the gate |
| Later | Both | Prometheus and Grafana (kube-prometheus-stack), then ELK via ECK |

## Out of scope

- Multiple nodes, node-level chaos (drain, disk fill, kubelet), and anything touching CoreDNS or `kube-system`.
- Visitor accounts or persistence beyond the incident log.
- Chaos Mesh or LitmusChaos (possible private lab later).
- Running any of the healthcare client's code.
