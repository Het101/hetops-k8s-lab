# Monitoring, sub-project 1: Prometheus and Grafana see the lab (design)

**Goal:** a GitOps-managed Prometheus and Grafana that see every tier of the chaos lab, and a private Grafana with three dashboards. It is built as six owner-run labs (M1 to M6) for interview learning.

**Not in this sub-project:**

- SLOs, burn-rate alerts and Alertmanager routing (sub-project 2).
- Public charts on hetops.dev/lab (sub-project 3).
- ELK.

## Install

- **Chart:** `kube-prometheus-stack` **91.5.2**, Helm release `kps`, namespace `monitoring`.
- **Argo CD:**
  - Application `monitoring`, in its own AppProject `monitoring`, which is allowed cluster-wide kinds plus the namespaces `monitoring`, `kube-system` (the chart's CoreDNS/kubelet Services) and `ingress-nginx`.
  - It has three sources: the chart; our values file `platform/monitoring/values.yaml` (via `$values`); and `platform/monitoring/extras/` (the sealed Grafana secret, ServiceMonitors, dashboards, the ingress-nginx metrics Service).
  - Sync options: `CreateNamespace`, `ServerSideApply` (the CRDs exceed the client-side annotation limit), automated prune and selfHeal.
- **Namespace `monitoring`:** Pod Security `privileged`, because node-exporter reads the host. Labels are set via `managedNamespaceMetadata`.
- **Off on kubeadm:** the scheduler, controller-manager, etcd and kube-proxy only listen on 127.0.0.1, so their scrapes and rules are disabled rather than left permanently down.

**Sizing** (shared VM):

| Component | Requests | Memory limit | Other |
|---|---|---|---|
| Prometheus | 200m CPU, 600Mi | 1500Mi | 7-day / 4 GB retention, 5Gi local-path PVC, 30 s scrape |
| Grafana | 50m, 128Mi | 384Mi | no persistence: dashboards come from git |
| Alertmanager | 10m, 32Mi | 128Mi | |
| operator, kube-state-metrics, node-exporter | about 64Mi each | 192Mi | |

## Sources

| Source | How |
|---|---|
| ingress-nginx | Service `ingress-nginx-controller-metrics` on port 10254 in `ingress-nginx`, plus a ServiceMonitor |
| clinic api | `prom-client` adds `/metrics`: `http_request_duration_seconds{method,route,status}` histogram, `clinic_db_pool_connections{state}` gauge, default process metrics. The api Service gains `labels: {app: api}` and a ServiceMonitor |
| chaos-api | `prom-client` adds `/metrics`: `chaos_experiments_total{action,status}`, `chaos_recovery_seconds{action}` histogram, `chaos_probe_requests_total{tier,result}`. Its Service gains labels and a ServiceMonitor |
| postgres | `postgres-exporter` v0.20.1 sidecar on port 9187, reading the existing `postgres-auth` secret. The headless Service gains a `metrics` port and labels, plus a ServiceMonitor |
| Kubernetes and node | from the chart |

**Network rules** (the lab namespaces are default-deny): allow ingress from namespace `monitoring` to:

- api:8080 (clinic)
- postgres:9187 (clinic-data)
- chaos-api:8080 (chaos)

**Privacy:** `/metrics` is never routed by the public ingress (only `/`, `/api` and `/chaos` are).

## Grafana

- **Access:** `grafana.hetops.dev`, through tunnel → ingress-nginx → `kps-grafana`, behind the Cloudflare Access `owner-only` policy.
- **Login:** admin via a sealed Secret `grafana-admin` (keys `admin-user`, `admin-password`). Anonymous access off; telemetry off.
- **Dashboards as code:** ConfigMaps labelled `grafana_dashboard: "1"`, loaded by the sidecar.
  - **Clinic lab: visitors**: RED per tier, from ingress-nginx and the probes.
  - **Clinic internals**: api routes and latency, the DB pool, postgres, restarts and OOMs.
  - **Chaos experiments**: recovery time against target, results, the self-test.

## Labs

| Lab | Content |
|---|---|
| M1 | Install, then explore Targets via port-forward |
| M2 | PromQL on built-in metrics |
| M3 | ingress-nginx RED |
| M4 | App metrics (clinic and chaos-api) |
| M5 | postgres exporter |
| M6 | Grafana hostname and dashboards |

Each lab ends with a check and a short journal entry (journal Part 6).
