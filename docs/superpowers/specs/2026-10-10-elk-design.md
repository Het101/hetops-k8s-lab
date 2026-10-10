# Logging: ELK for the chaos lab (design)

**Goal:** the lab's logs searchable in one place, private. Metrics (sub-projects 1–3) say *that* something broke; logs say *why*. The payoff lab follows one failed visit from ingress-nginx to the api to postgres during a kill-postgres.

**Owner's decision (2026-10-10):** go ahead with these defaults. Before the install the node showed 8.2 GiB used and 15 GiB available; this stack adds about 3 GiB.

## Stack

| Piece | Choice |
|---|---|
| Operator | ECK (Elastic Cloud on Kubernetes) **3.5.0**, Helm chart `eck-operator` from `https://helm.elastic.co` |
| Version | Elastic Stack **9.5.5** (ARM64 images) |
| Elasticsearch | `lab-logs`: 1 node, 1 GiB heap, 2 GiB memory limit, 10 Gi `local-path` volume, `node.store.allow_mmap: false` |
| Kibana | `lab-kibana`: 1 GiB memory limit, plain HTTP inside the cluster |
| Shipper | Filebeat (ECK `Beat` resource) as a DaemonSet |
| Retention | 3 days, in git: Filebeat loads an ILM policy from a ConfigMap (roll over daily or at 2 GB, delete after 3 days) |
| Disk guard | `local-path` does not enforce the 10Gi request, so the volume is the host's root disk (shared with Coolify). Absolute watermarks stop Elasticsearch while the host still has free space: low 30gb, high 25gb, flood_stage 20gb |

**Notes on the choices:**

- `node.store.allow_mmap: false` avoids changing the node's `vm.max_map_count`. That is a host-level setting on a shared production VM, so it stays untouched.
- **Single node:** the Filebeat template sets `number_of_replicas: 0`, so cluster health is green, not yellow.
- **Operator scope:** `managedNamespaces: [logging]`, so the operator watches and acts only in `logging`.
- **Host writes:** only the Elasticsearch volume and ECK's `beat-data` hostPath (Filebeat's read positions) at `/var/lib/logging/lab-filebeat/`. Both are listed in `docs/gameday.md` for cleanup.
- **Mapping limit:** `app.*` is mapped from the first value it sees. All the apps are Fastify/pino today (numeric `level`, numeric `time`); an app that logged a string `level` would have those events rejected.

## Scope and safety

- **Which logs:** Filebeat reads container logs only from `clinic`, `clinic-data`, `chaos` and `ingress-nginx`, through a Kubernetes autodiscover condition. Coolify's containers and every other namespace are never read.
- **JSON parsing:** JSON log lines (the Fastify apps) are decoded into `app.*`. Plain-text lines (nginx) stay in `message`.
- **Kibana access:** `kibana.hetops.dev` goes through the tunnel and ingress-nginx, behind the Cloudflare Access `owner-only` policy, like Grafana. Login is the `elastic` user. Its password is in the Secret `lab-logs-es-elastic-user`: never pasted in chat, read straight into the clipboard or a password manager.
- **Pod Security:** Filebeat runs as root with read-only hostPath mounts of `/var/log/containers` and `/var/log/pods`, so namespace `logging` is labelled `privileged`, the same as `monitoring`.
- **Personal data:** ingress-nginx access logs contain visitor IP addresses. They are kept for 3 days, private behind Access, and used only for debugging.

## GitOps

- **AppProject `logging`:** cluster-scoped kinds allowed (CRDs, ClusterRoles, webhooks); destination namespace `logging` only.
- **Application `logging`**, with two sources:
  1. the `eck-operator` chart 3.5.0;
  2. `platform/logging/`: Elasticsearch, Kibana, the Filebeat Beat and its RBAC, and the Kibana ingress.
- **Sync options:** `CreateNamespace`, `ServerSideApply` (the CRDs are large), and `SkipDryRunOnMissingResource` on the Elastic resources (their CRDs arrive in the same sync). The Elastic resources are at sync-wave 1, after the operator, with retries for the first webhook start.

## Labs

| Lab | What the owner does and learns |
|---|---|
| E1 | ECK and Elasticsearch: predict pod count and memory; check health green; read the `elastic` password straight into a variable; `_cat/nodes` and `_cluster/health` through a port-forward |
| E2 | Filebeat: check the DaemonSet; see the `filebeat-9.5.5` data stream grow (`_cat/indices`); confirm no Coolify logs (`kubernetes.namespace` terms) |
| E3 | Kibana: tunnel hostname plus Access app; log in; a data view on `filebeat-*`; first KQL searches (`kubernetes.namespace : "clinic" and app.level >= 40`) |
| E4 | The payoff: kill-postgres, then follow the failure from ingress (503s) to api errors (`app.err`) to the postgres restart, all on one time axis |
| E5 | Retention and the disk guard: read the ILM policy and the watermarks back through the API; predict when the first index is deleted; a saved search "lab incidents" |

## Out of scope

- Logstash: Filebeat writes straight to Elasticsearch.
- Alerting from logs: the alerts stay in Prometheus.
- Shipping node or system logs.
- More than one Elasticsearch node.
