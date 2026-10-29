# ELK moves to the ops cluster

**Status:** design, 29 Oct 2026. Sub-project 2 of 5 of the ops cluster ([design](2026-10-27-ops-cluster-design.md)). Builds on sub-project 1 ([outside watcher](2026-10-28-outside-watcher-design.md)) and the tailnet policy (`tailscale/policy.hujson`, PR #151).

## Why

Elasticsearch and Kibana are the heaviest lab tooling on the lab server, which also runs every live HetOps site: measured 29 Oct, Elasticsearch 1.8 GiB, Kibana 1.0 GiB, plus an operator; limits 2 GiB each. Its disk guard (stop allocating below 30 GB free, block writes below 20 GB) sits on the server the sites share. And when the lab server dies, the logs that would explain why die with it.

hetops-3 (4 OCPU, 24 GB, 185 GB free disk, ops cluster using under 2 GiB) has the room, and is a separate Oracle account and machine.

## Today (the lab, measured 27 to 29 Oct)

- ECK operator 3.5.0, Elasticsearch 9.5.5 `lab-logs` (one node, 1 GiB heap, 10 Gi `local-path`), Kibana 9.5.5 `lab-kibana`, Filebeat as an ECK `Beat` (`elasticsearchRef: lab-logs`), all in namespace `logging` (Argo app `logging`, `platform/logging/`).
- About 1.1 GB and 2.1 million documents a day into one data stream `filebeat-9.5.5`; ILM rolls over daily and deletes after 3 days (about 5 GB live).
- Per day: clinic app logs 1.03 M (48%), gateway access logs with visitor IPs 0.88 M (41%), Kubernetes audit log 0.16 M (7%), CrowdSec, chaos, Falco and the rest 0.09 M (4%).
- Kibana: `kibana.hetops.dev` through the lab's Cloudflare tunnel and gateway, behind Cloudflare Access (owner only), login as `elastic`. Its data view, Security detection rules (430 alerts so far) and saved searches exist only inside Elasticsearch, not in git.

## Decisions (owner, 29 Oct)

1. **Kibana is reached through hetops-3's own Cloudflare tunnel**, so it stays usable when the lab is down. Same hostname and Access policy in the end.
2. **Fresh logs; Kibana's setup as code.** No snapshot migration. Both clusters run in parallel for one retention window. Data views, detection rules and saved searches are exported once, committed, and imported by a Job on every sync.
3. **7 days of live logs.**
4. **Nightly backups kept 30 days:** all logs on hetops-3's disk; the security stream also off-site in the owner's Cloudflare R2 (inside the free 10 GB).

## Design

### On hetops-3: `clusters/ops/logging/` (Argo app `logging`)

- **ECK operator 3.5.0** (Helm chart, `managedNamespaces: [logging]`, telemetry off), as on the lab.
- **Elasticsearch 9.5.5** `ops-logs`: one node, `-Xms2g -Xmx2g`, requests 500m CPU / 4 GiB, limit 4 GiB; `node.store.allow_mmap: false`; the lab's disk watermarks (30 / 25 / 20 GB free); a 40 Gi `local-path` volume. ECK's own TLS stays on.
  - **Reachable only over Tailscale:** the pod's 9200 is a `hostPort` with `hostIP: 100.89.67.82`, like Gatus. Nothing listens on the public IP; Oracle's security list still allows SSH only.
  - Every index template sets `number_of_replicas: 0` (one node).
- **Kibana 9.5.5** `ops-kibana`: limit 2 GiB, `NODE_OPTIONS=--max-old-space-size=1280` (the lab's tuning), `server.publicBaseUrl: https://kibana.hetops.dev`, telemetry off, plain HTTP inside the cluster.
- **cloudflared** (pinned image), one Deployment, its tunnel token from a SealedSecret, routing the Kibana hostname to `ops-kibana-kb-http:5601`.
- **Data streams and retention:** index templates and one ILM policy (rollover at 1 day or 2 GB primary shard, delete after 7 days) for `logs-lab-default` and `logs-lab-security`, created by a Job from JSON in git (the Elasticsearch API, idempotent PUTs).
- **Backups (SLM):**
  - repository `local`: type `fs`, a hostPath `/var/lib/es-snapshots` owned by Elasticsearch's UID (Bedrock creates it, as with Gatus); `path.repo` set accordingly. Policy `nightly-all` at 01:30 UTC: all `logs-lab-*`, retention 30 days (min 5, max 35 snapshots).
  - repository `r2`: type `s3`, endpoint `https://{account-id}.r2.cloudflarestorage.com` (the owner's Cloudflare account ID, not secret, in the repository's config), bucket `hetops-logs-security`, path-style access; access key and secret go into Elasticsearch's keystore through ECK `secureSettings` from a SealedSecret. Policy `nightly-security` at 01:45 UTC: `logs-lab-security` and `.internal.alerts-security.alerts-*`, retention 30 days.
- **Kibana as code:** `clusters/ops/logging/kibana-objects/` holds the exported NDJSON (data views, saved searches) and the detection rules (export format). An Argo PostSync Job imports them through Kibana's saved-objects and detection-rules import APIs with overwrite. A change made only by clicking is reset on the next sync; changes go through a PR (export, commit).
- **The write-only key:** a Job creates a role `lab-shipper` (index privileges `create_doc`, `auto_configure` on `logs-lab-*`, nothing else) and an API key for it. That key, with ECK's CA certificate, is sealed with the **lab's** controller for the lab.

### On the lab

- **`ops-filebeat`:** a second ECK `Beat` in `logging` with the same inputs and processors as `lab-filebeat`, but `output.elasticsearch` to `https://100.89.67.82:9200` with the API key and ECK's CA (SealedSecrets `ops-shipper-key`, `ops-es-ca`). It routes by event: audit log, `falco` and `crowdsec` namespaces → `logs-lab-security`; everything else → `logs-lab-default`. Its own read-positions path, so the two Filebeats do not share state.
- After the parallel week: `lab-logs`, `lab-kibana`, `lab-filebeat`, the Kibana HTTPRoute and the ECK operator (if nothing else uses it) are removed in one PR; the local-path volume and `/var/lib/logging/lab-filebeat/` are cleaned up through Bedrock (check, then apply). `.github/workflows/gateway.yml` loses its Kibana route checks.

### The network

- `tailscale/policy.hujson`: grant `tag:lab → tag:ops tcp:9200`, with a test that accepts it and keeps 22 and 6443 denied.

### Watching it

- **Gatus (hetops-3):** a check on `https://100.89.67.82:9200/_cluster/health` (status not `red`; a read-only monitoring API key), and a check that reads `_slm/stats` and alerts when either policy has had no success for 26 hours. Telegram, as for the other checks.
- **Lab Prometheus:** an alert when `ops-filebeat` reports output errors for 10 minutes (Filebeat's monitoring metrics).

## When things go wrong

- **hetops-3 or the link down:** Filebeat keeps its place and retries. Nothing is lost while the outage is shorter than the files' rotation: 3 days for the audit log; for container logs kubelet's default 10 MiB per file, about 1 to 2 hours for the busiest pod. A longer outage can lose the busiest pods' oldest lines: **accepted**; a local buffer would cost memory on the server being unloaded.
- **Disk:** the watermarks block writes before the disk is full. Planned use about 45 GB of 185 GB free (8 GB live, about 35 GB of local snapshots).
- **A backup stops:** the Gatus `_slm/stats` check alerts after 26 hours without a success.
- **Kibana drift:** git wins on the next sync (above).
- **Credentials:** rotating the shipper key = new key from the Job, reseal for the lab, delete the old key; the R2 token = new token, reseal, restart Elasticsearch to reload the keystore. hetops-3's sealing-key backup (owner's laptop) covers the new SealedSecrets.
- **Rebuild of hetops-3:** restore the sealing key, Bedrock, Argo; the Jobs recreate templates, policies, role and Kibana setup. Live logs and local snapshots are lost; the security snapshots in R2 survive and can be restored.

## Rollout (one PR per step, each checked before the next)

1. Tailnet grant for 9200 (CI tests and applies it).
2. Bedrock: `/var/lib/es-snapshots` on `ops`. Then on hetops-3: operator, Elasticsearch, Kibana, cloudflared, the setup Jobs. Kibana first on a temporary hostname `kibana-ops.hetops.dev` behind the same Access policy.
3. Kibana as code: export from the lab, commit, import; the same rules enabled on both sides.
4. `ops-filebeat` on the lab.
5. Both snapshot repositories and policies; each run once by hand.
6. Seven days in parallel. Then `kibana.hetops.dev` moves to hetops-3's tunnel (the temporary hostname is removed), and the lab's ELK is removed (above).

## Testing

1. **Arrival:** documents in both streams; a `kubectl create configmap` on the lab shows in `logs-lab-security` within a minute; a search with the shipper key returns 403.
2. **Outage:** Elasticsearch on hetops-3 stopped for 10 minutes: the Filebeat error alert fires; after recovery the gap is filled, the audit log complete.
3. **Restore:** last night's local snapshot restored under a temporary name, searched in Kibana, deleted; the same from R2 for the security stream; both timed and recorded.
4. **A failing backup:** the R2 policy pointed once at a wrong bucket; with the check's window lowered for the test, Gatus alerts.
5. **Exposure:** `130.210.37.122:9200` does not answer from outside; the lab reaches 9200; hetops-3 still cannot reach the lab's SSH; Kibana without the Access login shows Cloudflare's login page.
6. **Rules:** a detection rule fires on hetops-3 for an event that fires it on the lab today (a `kubectl exec` into a pod).

## Done when

1. Seven days of lab logs are searchable in hetops-3's Kibana, both streams filled.
2. The detection rules run on hetops-3 and raise the same alerts as before.
3. Both snapshot policies succeed nightly, and both restores were tested.
4. The lab runs no Elasticsearch or Kibana; its memory use is down by about 3 GiB.
5. Every step and mistake is in the journal (via `journal-pending.md`).

## Owner steps

- **Cloudflare tunnel** for hetops-3; its token handed over in a file, never in chat. `kibana-ops.hetops.dev`, later `kibana.hetops.dev`, in the existing owner-only Access application.
- **Cloudflare R2:** bucket `hetops-logs-security`, an API token limited to that bucket (object read and write), handed over in a file.

## Cost

Nothing new: the tunnel is free; R2 holds about 3 GB, inside the free 10 GB; no Oracle resource is added (hetops-3's existing disk).
