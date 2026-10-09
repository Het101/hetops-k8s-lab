# Monitoring (sub-project 1) Implementation Plan

> **For agentic workers:** owner-run labs. Claude writes each lab's files and opens a PR. The owner merges it (or says "merge"), then runs the checks on the server. M4's code tasks use superpowers:subagent-driven-development.

**Goal:** Prometheus and Grafana, deployed by Argo CD, that see every tier of the chaos lab, plus a private Grafana with three dashboards. Spec: `docs/superpowers/specs/2026-10-09-monitoring-design.md`.

**Architecture:** kube-prometheus-stack 91.5.2 through a multi-source Argo CD Application (chart + our values + an `extras/` folder). The lab sources are exposed through ServiceMonitors, with one NetworkPolicy allow per namespace.

**Tech Stack:** kube-prometheus-stack 91.5.2 (Prometheus Operator v0.94.1), Grafana (chart 13.2.5), kube-state-metrics, node-exporter, postgres-exporter v0.20.1, prom-client 15.

## Global Constraints

- **Commits:** author `patel.x.het@gmail.com`; no Claude attribution lines; work through PRs. GitHub: `GH_TOKEN=$(gh auth token --user Het101)`; push with `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`.
- **Server commands:** run them on `ubuntu@my-workspace`. Check the prompt: it must not be a work VM.
- **Secrets:** they never appear in chat. Use `read -rs` plus `kubeseal`; for adding a key to an existing secret, `--merge-into`.
- **Shared VM:** every container has a memory limit. Prometheus retention is 7 days / 4 GB.
- **Never public:** Prometheus and Alertmanager UIs, and any `/metrics` path. Grafana is reachable only behind Cloudflare Access.
- **Argo CD:** the AppProject `monitoring` is separate from `lab`. The `lab` project keeps its narrow whitelist.

---

## M1: Install the stack

**Files (lab repo):**

- `argo/project-monitoring.yaml`
- `argo/apps/monitoring.yaml`
- `platform/monitoring/values.yaml`
- `platform/monitoring/extras/kustomization.yaml`
- `platform/monitoring/extras/sealed-grafana-admin.yaml`: the owner seals it in Step 1.

- [ ] **Step 1 (owner): seal the Grafana admin login.** On the server:

```bash
cd ~/hetops-k8s-lab && git pull -q && mkdir -p platform/monitoring/extras
read -rs -p "New Grafana admin password (save it in your password manager first): " GP; echo
kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-user=admin --from-file=admin-password=<(printf %s "$GP") --dry-run=client -o yaml | kubeseal --format yaml > platform/monitoring/extras/sealed-grafana-admin.yaml; unset GP
git add platform/monitoring/extras && git commit -qm "monitoring: sealed Grafana admin" && git push -q
```

(The `monitoring` namespace does not exist yet. kubeseal only needs the name; the controller decrypts once the namespace exists.)

- [ ] **Step 2 (Claude): the PR.**

`argo/project-monitoring.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject                  # the monitoring stack needs cluster-wide objects (CRDs, ClusterRoles, webhooks); "lab" must not
metadata:
  name: monitoring
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "-1" }   # the project must exist before the app that uses it
spec:
  description: Prometheus and Grafana for the chaos lab
  sourceRepos:
  - https://github.com/Het101/hetops-k8s-lab.git
  - https://prometheus-community.github.io/helm-charts
  destinations:
  - { server: https://kubernetes.default.svc, namespace: monitoring }
  - { server: https://kubernetes.default.svc, namespace: kube-system }     # the chart's CoreDNS / kubelet scrape Services
  - { server: https://kubernetes.default.svc, namespace: ingress-nginx }   # the controller's metrics Service (M3)
  clusterResourceWhitelist:
  - { group: '*', kind: '*' }
```

`argo/apps/monitoring.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "0" }
spec:
  project: monitoring
  sources:
  - repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 91.5.2                     # pinned; upgrades are a reviewed one-line PR
    helm:
      releaseName: kps                         # short prefix for every object name
      valueFiles: [$values/platform/monitoring/values.yaml]
  - repoURL: https://github.com/Het101/hetops-k8s-lab.git
    targetRevision: main
    ref: values                                # lets the chart above read our values file from git
  - repoURL: https://github.com/Het101/hetops-k8s-lab.git
    targetRevision: main
    path: platform/monitoring/extras           # our own objects: sealed secret, ServiceMonitors, dashboards
  destination: { server: https://kubernetes.default.svc, namespace: monitoring }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]   # the CRDs are too big for client-side apply
    managedNamespaceMetadata:
      labels:
        app.kubernetes.io/part-of: chaos-lab
        pod-security.kubernetes.io/enforce: privileged          # node-exporter reads the host (hostNetwork, hostPID)
        pod-security.kubernetes.io/warn: baseline
    retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 3m } }
```

`platform/monitoring/values.yaml`:

```yaml
# kube-prometheus-stack 91.5.2, sized for one shared VM. Defaults are kept unless there is a reason.
crds:
  enabled: true

# kubeadm binds these to 127.0.0.1, so Prometheus cannot scrape them: off, instead of permanently "down".
kubeControllerManager: { enabled: false }
kubeScheduler: { enabled: false }
kubeEtcd: { enabled: false }
kubeProxy: { enabled: false }
defaultRules:
  rules:
    etcd: false
    kubeControllerManager: false
    kubeProxy: false
    kubeSchedulerAlerting: false
    kubeSchedulerRecording: false

prometheus:
  prometheusSpec:
    scrapeInterval: 30s
    retention: 7d
    retentionSize: 4GB
    # pick up every ServiceMonitor/PodMonitor/rule in the cluster, not only ones labelled for this Helm release
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources:
      requests: { cpu: 200m, memory: 600Mi }
      limits: { memory: 1500Mi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources: { requests: { storage: 5Gi } }

alertmanager:
  alertmanagerSpec:
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits: { memory: 128Mi }

grafana:
  admin:
    existingSecret: grafana-admin
  persistence: { enabled: false }        # dashboards come from git; nothing to keep
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { memory: 384Mi }
  grafana.ini:
    analytics: { reporting_enabled: false, check_for_updates: false }
    auth.anonymous: { enabled: false }

prometheusOperator:
  resources:
    requests: { cpu: 20m, memory: 64Mi }
    limits: { memory: 192Mi }
kube-state-metrics:
  resources:
    requests: { cpu: 10m, memory: 48Mi }
    limits: { memory: 192Mi }
prometheus-node-exporter:
  resources:
    requests: { cpu: 10m, memory: 32Mi }
    limits: { memory: 96Mi }
```

`platform/monitoring/extras/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- sealed-grafana-admin.yaml
```

- [ ] **Step 3 (owner): predict, merge, watch.**
  - Predict how many pods appear in `monitoring`.
  - Then run: `kubectl -n argocd get app monitoring -w` until Synced/Healthy, and `kubectl -n monitoring get pods`.
  - `kubectl top node`: how much memory did it add?
- [ ] **Step 4 (owner): explore.**
  - `kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090` (a second SSH with `-L 9090:localhost:9090`), then open `localhost:9090` → Status → Targets.
  - Everything should be green, and the controller-manager, scheduler, etcd and kube-proxy entries should be absent.
  - Query `up` and `count by (job) (up)`.

---

## M2: PromQL on built-in metrics

No files: queries only. Run `scripts/gameday.sh crash`, then in Prometheus:

| # | Question | Query |
|---|---|---|
| 1 | Restarts per api pod | `kube_pod_container_status_restarts_total{namespace="clinic"}` |
| 2 | Restarts in the last 15 min | `increase(kube_pod_container_status_restarts_total{namespace="clinic"}[15m])` |
| 3 | Memory per api pod | `sum by (pod) (container_memory_working_set_bytes{namespace="clinic", container="api"})` |
| 4 | CPU per api pod (cores) | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="clinic", container="api"}[2m]))` |
| 5 | Was anything OOM-killed? Run `scripts/gameday.sh leak` first | `kube_pod_container_status_last_terminated_reason{namespace="clinic", reason="OOMKilled"}` |
| 6 | Node memory used % | `1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes` |

Learn: counter vs gauge, `rate` vs `increase`, label matchers, and `sum by`.

---

## M3: ingress-nginx RED

**Files:**

- `platform/monitoring/extras/ingress-nginx-metrics.yaml`, which is added to extras' kustomization.

- [ ] **Step 1 (owner):** confirm that metrics are on and see the labels.

  ```bash
  kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller --show-labels
  kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- curl -s localhost:10254/metrics | grep -c nginx_ingress_controller_requests
  ```

  The count should be greater than 0.

- [ ] **Step 2 (Claude) PR:**

```yaml
# The controller already serves metrics on :10254; this Service + ServiceMonitor let Prometheus find them.
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-metrics
  namespace: ingress-nginx
  labels: { app.kubernetes.io/name: ingress-nginx, app.kubernetes.io/component: controller-metrics }
spec:
  selector: { app.kubernetes.io/name: ingress-nginx, app.kubernetes.io/component: controller }
  ports: [{ name: metrics, port: 10254, targetPort: 10254 }]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: ingress-nginx, namespace: monitoring }
spec:
  namespaceSelector: { matchNames: [ingress-nginx] }
  selector: { matchLabels: { app.kubernetes.io/component: controller-metrics } }
  endpoints: [{ port: metrics, interval: 30s }]
```

- [ ] **Step 3 (owner) queries:**

| Question | Query |
|---|---|
| Requests/s per route | `sum by (ingress, path) (rate(nginx_ingress_controller_requests{host="lab.hetops.dev"}[2m]))` |
| Error % per route | `sum by (path) (rate(nginx_ingress_controller_requests{host="lab.hetops.dev",status=~"5.."}[2m])) / sum by (path) (rate(nginx_ingress_controller_requests{host="lab.hetops.dev"}[2m]))` |
| p95 latency per route (s) | `histogram_quantile(0.95, sum by (le, path) (rate(nginx_ingress_controller_request_duration_seconds_bucket{host="lab.hetops.dev"}[5m])))` |

Then run `gameday.sh kill-postgres` and watch `/api` error % jump.

---

## M4: App metrics (clinic api, chaos-api)

**Code: two subagent tasks (TDD).** Each one opens a PR that the controller merges.

- **hetops-clinic api:**
  - Add `prom-client` ^15 and `api/src/metrics.js`:
    - `collectDefaultMetrics()`;
    - a histogram `http_request_duration_seconds` with labels method, route (Fastify's `req.routeOptions.url`, or `unmatched`) and status, buckets `[0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5]`;
    - a gauge `clinic_db_pool_connections{state="total|idle|waiting"}`, read at scrape time from the admin pool's `totalCount`, `idleCount` and `waitingCount`.
  - Fastify `onResponse` hook observes the duration; `GET /metrics` returns `register.metrics()` with its content type.
  - **Tests:**
    - `/metrics` returns 200 and contains `http_request_duration_seconds_bucket{` after a request to `/api/whoami`;
    - the route label is the template, not the raw URL;
    - the pool gauge reflects a fake pool.
- **chaos-api:**
  - Add `prom-client` ^15 and `src/metrics.js` with:
    - `chaos_experiments_total{action,status}` (incremented in the Runner's `#finish`);
    - `chaos_recovery_seconds{action}` histogram, buckets `[5,10,20,30,60,90,120,180,300,600]`, observed when the status is `recovered`;
    - `chaos_probe_requests_total{tier="web|api",result="ok|fail"}` (incremented per visit in the Prober).
  - `GET /metrics` is added in `app.js`. It is not under `/chaos`, so the public ingress never routes it.
  - **Tests:** the counters move after a fake experiment and a fake visit; `/metrics` returns 200.

**Manifests (Claude PR, lab repo), after the new images exist:**

- api Service `metadata.labels: { app: api }`; chaos-api Service `metadata.labels: { app: chaos-api }`.
- ServiceMonitors in `platform/monitoring/extras/servicemonitors.yaml`:
  - `clinic-api`: namespace clinic, selector app=api, port `http`, path `/metrics`;
  - `chaos-api`: namespace chaos, selector app=chaos-api, port `http`, path `/metrics`.
- NetworkPolicies:
  - `apps/clinic/base/networkpolicies.yaml` gains `allow-monitoring`: podSelector app=api, ingress from namespace `monitoring`, TCP 8080;
  - `apps/chaos/networkpolicies.yaml`'s `chaos-api` policy gains a from-item for namespace `monitoring`.
- Image tag bumps.

**Owner checks:**

- The Targets page shows `clinic-api` (3–5 up) and `chaos-api` (1 up).
- p95 per api route: `histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{namespace="clinic"}[5m])))`.
- DB pool in use: `clinic_db_pool_connections{state="total"} - ignoring(state) clinic_db_pool_connections{state="idle"}`.
- Recovery times: `histogram_quantile(0.5, sum by (le, action) (rate(chaos_recovery_seconds_bucket[1d])))`.

---

## M5: postgres exporter

**Files (Claude PR):**

- `apps/clinic-data/postgres.yaml`: a sidecar container and a Service `metrics` port.
- `apps/clinic-data/networkpolicy.yaml`: allow from `monitoring` to TCP 9187.
- `platform/monitoring/extras/servicemonitors.yaml` gains `postgres`.

Sidecar:

```yaml
      - name: exporter
        image: quay.io/prometheuscommunity/postgres-exporter:v0.20.1
        ports: [{ name: metrics, containerPort: 9187 }]
        env:
        - { name: DATA_SOURCE_URI, value: "localhost:5432/postgres?sslmode=disable" }
        - { name: DATA_SOURCE_USER, value: postgres }
        - name: DATA_SOURCE_PASS
          valueFrom: { secretKeyRef: { name: postgres-auth, key: POSTGRES_PASSWORD } }
        resources: { requests: { cpu: 10m, memory: 32Mi }, limits: { memory: 64Mi } }
        securityContext: { runAsNonRoot: true, runAsUser: 65534, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
```

Service: add `metadata.labels: { app: postgres }` and port `{ name: metrics, port: 9187 }`.

ServiceMonitor `postgres`: namespace clinic-data, selector app=postgres, port `metrics`.

**Predict:** adding a container restarts `postgres-0` once. How long, and do api requests fail meanwhile? (Compare kill-postgres.)

**Owner checks:**

- `pg_up` should be 1.
- Run `gameday.sh kill-postgres` and watch `pg_up` drop to 0 and recover.
- `sum(pg_stat_activity_count)` shows connections.

---

## M6: Grafana

**Owner (dashboard):**

- Cloudflare Zero Trust → Networks → Tunnels → `hetops-lab` → Public hostname → add `grafana.hetops.dev`, service `HTTP`, `ingress-nginx-controller.ingress-nginx.svc.cluster.local:80`.
- Access: add `grafana.hetops.dev` to the existing owner-only application (or create one with the `owner-only` policy).

**Claude PR:**

- `values.yaml`:
  - `grafana.ingress`: enabled, `ingressClassName: nginx`, hosts `[grafana.hetops.dev]`, path `/`;
  - `grafana.ini.server.root_url: https://grafana.hetops.dev`.
- `platform/monitoring/extras/dashboards/*.yaml`: three ConfigMaps, labelled `grafana_dashboard: "1"`. Their JSON is built by a subagent from these panels:

| Dashboard | Panel | Query |
|---|---|---|
| Clinic lab: visitors | Requests/s by route | `sum by (path) (rate(nginx_ingress_controller_requests{host="lab.hetops.dev"}[2m]))` |
| | Error % by route | (M3 query) |
| | p95 by route | (M3 query) |
| | Probe visits ok/fail by tier | `sum by (tier, result) (rate(chaos_probe_requests_total[2m]))` |
| Clinic internals | p95 by api route | (M4 query) |
| | Requests by status | `sum by (status) (rate(http_request_duration_seconds_count{namespace="clinic"}[2m]))` |
| | DB pool in use and waiting | (M4) |
| | Postgres up, connections, commits/s | `pg_up`; `sum(pg_stat_activity_count)`; `rate(pg_stat_database_xact_commit{datname="clinic"}[2m])` |
| | Restarts | `increase(kube_pod_container_status_restarts_total{namespace="clinic"}[1h])` |
| | Memory per pod | (M2 #3) |
| Chaos experiments | Experiments by result | `sum by (action, status) (increase(chaos_experiments_total[1d]))` |
| | Median recovery by action, against target | (M4) |
| | Last self-test | `kube_job_status_succeeded{namespace="chaos", job_name=~"chaos-selftest.*"}` |

**Owner checks:**

- `grafana.hetops.dev` asks for the Cloudflare login, then the Grafana login.
- The three dashboards are listed. Run a few experiments and watch them.

**Journal:** Part 6 gets one section per lab.
