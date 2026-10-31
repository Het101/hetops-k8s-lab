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

`kubectl get -w` watches one resource type at a time, so each watch below names a single type.

For each one: read the prediction question, write your answer, run it, then note the recovery time and anything that surprised you.

| # | id | Predict | Watch in terminal B | Target |
|---|---|---|---|---|
| 1 | `kill-pod` | How many requests fail while the pod is replaced? | `kubectl get pods -n clinic -l app=api -w` | 30 s |
| 2 | `crash` | Does the pod get a new name, or the same name with RESTARTS +1? | `kubectl get pods -n clinic -l app=api -w` | 30 s |
| 3 | `leak` | What reason will `Last State` show? | `kubectl -n clinic describe pod -l app=api \| grep -A3 "Last State"` | 60 s |
| 4 | `hang` | Which fails first, readiness or liveness, and how many seconds apart? | `kubectl -n clinic get events -w --field-selector reason=Unhealthy` | 60 s |
| 5 | `evict-api` | How many evictions succeed, and how many are refused? | `kubectl -n clinic get pdb api -w` | 90 s |
| 6 | `delete-api-pods` | Does the PodDisruptionBudget stop this one? How long do requests fail? | `kubectl get pods -n clinic -l app=api -w` | 60 s |
| 7 | `kill-postgres` | Is any data lost? Which other pods notice? | `kubectl -n clinic-data get pvc` once, then `kubectl -n clinic-data get pods -w` | 120 s |
| 8 | `scale-zero` | Who scales `web` back to 2: Kubernetes or Argo CD? How long until it notices? | `kubectl -n argocd get app clinic -w` | 120 s |
| 9 | `delete-web` | Same question, for a whole deleted Deployment. | `kubectl -n clinic get deploy -w` | 120 s |
| 10 | `delete-api-svc` | The api pods stay healthy. Does the site still work? | `kubectl -n clinic get endpointslices -w` | 120 s |
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

## The nightly self-test

After game day, the lab runs all 15 experiments by itself every night at 03:00 India time (`apps/chaos/selftest-cronjob.yaml`). The verdict goes to HetOps Status.

- **Needs owner mode:** `chaos-config` `enabled` must be `"owner"` (or `"true"` once public). With `"false"`, the run aborts and reports down.
- **Run it now:**
  ```bash
  kubectl -n chaos create job selftest-now --from=cronjob/chaos-selftest
  kubectl -n chaos logs -f job/selftest-now
  ```
- **Past nights:** `kubectl -n chaos get jobs`. Each one's log ends with its verdict line.
- **Go-public gate:** 3 green nights in a row. Then set `enabled` to `"true"`.

## Cluster settings that live outside git

Argo CD itself was installed by hand (Part 1), so these settings exist only on the cluster. Re-apply them after any reinstall.

- **Self-heal backoff** (found by the first self-test, 9 Oct). By default, Argo CD waits longer before each consecutive self-heal: 2 s, times 3 each time, capped at 300 s, and it resets only after 330 s of calm. That protects real clusters from two tools fighting over one object. In this lab, drift is deliberate, so back-to-back experiments hit the cap: `bad-release` took 296 s. Lab setting:
  ```bash
  kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"controller.self.heal.backoff.cap.seconds":"30","controller.self.heal.backoff.cooldown.seconds":"60"}}'
  kubectl -n argocd rollout restart statefulset argocd-application-controller
  ```
- **Reconciliation every 60 s** (L7): `timeout.reconciliation: 60s` in `argocd-cm`.
- **Gateway request metrics:** open-source NGINX Gateway Fabric counts requests but has no status code or path. The visitors dashboard reads the gateway's Linkerd proxy instead (`response_total`, `response_latency_ms_bucket` by `dst_deployment`), scraped by `platform/monitoring/extras/nginx-gateway-metrics.yaml`. (ingress-nginx, retired 22 Oct, needed `--enable-metrics` patched in by hand.)
- **Node inotify limit:** `fs.inotify.max_user_instances = 512` in `/etc/sysctl.d/99-inotify.conf`. The default of 128 ran out with Kubernetes and Coolify on one VM (`kubectl logs -f` failed with "too many open files").

## Error budget freeze (sub-project 3)

chaos-api freezes visitor chaos when the 7-day error budget is spent (`lab:slo_budget_remaining <= FREEZE_AT`) and reopens at `REOPEN_AT`. The defaults are 0 and 0.05, in code. The keys live in `chaos-config`, whose `/data` Argo CD ignores, so set them with kubectl, never in git.

- Test a freeze without spending budget:
  ```bash
  kubectl -n chaos patch cm chaos-config --type merge -p '{"data":{"FREEZE_AT":"0.99","REOPEN_AT":"0.995"}}'
  ```
- Restore the defaults:
  ```bash
  kubectl -n chaos patch cm chaos-config --type json -p '[{"op":"remove","path":"/data/FREEZE_AT"},{"op":"remove","path":"/data/REOPEN_AT"}]'
  ```
- While frozen, `CHAOS_BYPASS` requests (game day, the self-test) still run.
- If Prometheus is unreachable, the lab stays open (fail-open), and `SLIMissing` pages instead.

## Logging (ELK, on hetops-3 since 31 Oct)

The lab's logs live on hetops-3 (sub-project 2, `docs/superpowers/specs/2026-10-29-elk-move-design.md`), so they survive the lab going down. On the lab only `ops-filebeat` (`platform/logging`, Argo app `logging`, with the ECK operator that runs it) remains; it ships over Tailscale to `100.89.67.82:9200` as the write-only file-realm user `lab-shipper`. Everything else is `clusters/ops/logging` on hetops-3: Elasticsearch `ops-logs`, Kibana `ops-kibana`, hetops-3's own cloudflared, the setup Jobs.

- Kibana: https://kibana.hetops.dev (route on hetops-3's Cloudflare tunnel to `http://ops-kibana-kb-http.logging.svc:5601`, plus the Access app with `owner-only`, set in Cloudflare by hand). Log in as `elastic`; the password goes straight to the clipboard, never into chat:
  ```bash
  ssh ubuntu@130.210.37.122 'kubectl -n logging get secret ops-logs-es-elastic-user -o jsonpath="{.data.elastic}" | base64 -d' | clip
  ```
- Data: two data streams, `logs-lab-default` (container logs) and `logs-lab-security` (audit, Falco); data view `lab-logs` and the three detection rules are code in `clusters/ops/logging/kibana-objects/` (a change made by clicking is overwritten on the next sync).
- Retention: 7 days live (ILM `logs-lab-7d`, rollover daily). Snapshots: SLM `nightly-all` 01:30 UTC to repository `local` (hetops-3's disk), `nightly-security` 01:45 UTC to repository `r2` (bucket `hetops-logs-security`); kept 30 days (min 5, max 35). Disk guard: allocation stops under 30 GB free, writes block under 20 GB.
- Watched by Gatus on hetops-3 (group `logs`): cluster health, "Logs arriving from the lab" (documents in the last 10 minutes; an outage pages after about 25 minutes), and one check per snapshot policy.
- **Never put a secret in a command that crosses the API server** (`kubectl exec ... -u "elastic:$PW"` is recorded by the audit log, which Filebeat ships; found 29 Oct). Query from hetops-3's host, where the password stays in a curl config read from a file descriptor:
  ```bash
  # on hetops-3
  PW=$(kubectl -n logging get secret ops-logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
  es(){ curl -sk -K <(printf 'user = "elastic:%s"\n' "$PW") "$@"; echo; }
  es https://100.89.67.82:9200/_cluster/health
  es "https://100.89.67.82:9200/_slm/policy?filter_path=*.last_success,*.last_failure"
  es "https://100.89.67.82:9200/_cat/shards?h=index,prirep,state,unassigned.reason" | grep UNASSIGNED   # yellow: one node never places a replica; set that index's number_of_replicas to 0
  ```
- **Restore** (tested 29 Oct: local 2.6 s, R2 8.8 s). Restore beside the live data under a new name, search it in Kibana (an ad-hoc data view on `restored-*`), then delete it:
  ```bash
  S=$(es "https://100.89.67.82:9200/_cat/snapshots/local?h=id&s=end_epoch:desc" | head -1)      # or /r2 for the security stream
  es -H 'content-type: application/json' -X POST "https://100.89.67.82:9200/_snapshot/local/$S/_restore?wait_for_completion=true" \
    -d '{"indices":"logs-lab-default","rename_pattern":"(.+)","rename_replacement":"restored-$1","include_aliases":false,"include_global_state":false}'
  es -X DELETE "https://100.89.67.82:9200/_data_stream/restored-*"
  unset PW
  ```
- Host paths: the data volume under `/opt/local-path-provisioner/` on hetops-3, snapshots in `/var/lib/es-snapshots` (owned through Bedrock `group_vars/ops.yml`); on the lab, `ops-filebeat`'s read positions at `/var/lib/logging/ops-filebeat/`.
- The lab's own ELK (`lab-logs`, `lab-kibana`, `lab-filebeat`, 10 Oct to 31 Oct) was removed by the PR that added this section; its spec is `docs/superpowers/specs/2026-10-10-elk-design.md`.

## Kubernetes audit logging (SIEM track, T1)

The API server writes an audit log (policy: `platform/host/audit-policy.yaml`: every write including `pods/exec`, Secret/ConfigMap access at metadata level only, controller reads dropped). It is a static-pod change, so it lives outside Argo CD, in **Bedrock** (`bedrock/roles/audit`):
- the policy file is copied from git; a change restarts the API server through handlers;
- the flags and volumes are in kubeadm's ClusterConfiguration (`kube-system/kubeadm-config`), so `kubeadm upgrade` regenerates them;
- the manifest is checked flag by flag.

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock && ansible-playbook site.yml --check --diff   # then without --check
sudo kubeadm upgrade diff v1.31.14 2>&1 | grep -E '^[-+] +- --audit' | sed 's/^[-+]//' | sort | uniq -u   # empty: every audit flag is kept (at most moved)
```

`ops-filebeat` ships `/var/log/kubernetes/audit/audit.log` to Elasticsearch on hetops-3 (`logs-lab-security`) under `k8s_audit.*` (`log_source: k8s-audit`). (Until 21 Oct, `platform/host/enable-audit.sh` patched the manifest by hand, and the first upgrade would have dropped the flags.)

## Falco (SIEM track, T2)

- Runtime IDS on the node (modern eBPF). Alerts: `kubectl -n falco logs ds/falco -c falco`, and in Kibana `kubernetes.namespace : "falco"` (fields under `falco.*`).
- Tuning lives in `argo/apps/falco.yaml` (`customRules`). Exempt by the narrowest field that explains *why* a caller is legitimate; never disable a rule wholesale.
- **Manual Argo CD sync with kubectl:** a patched `operation` uses only the options inside it, not the app's `syncOptions`. Pass them: `kubectl -n argocd patch app falco --type merge -p '{"operation":{"initiatedBy":{"username":"owner"},"sync":{"revision":"9.2.0","syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'`

## Real visitor IPs at the gateway (SIEM track, T3)

All public traffic arrives through cloudflared, so nginx would see the tunnel pod's IP. NGINX Gateway Fabric takes the visitor's address from `X-Forwarded-For`, trusting it **only from the pod network** (where cloudflared runs) and recursively, so an address a visitor adds themselves is ignored: `rewriteClientIP` in `platform/gateway/values.yaml`, in git. The CI rehearsal (`.github/workflows/gateway.yml`) proves it on every change. Check live: `kubectl -n nginx-gateway logs deploy/lab-nginx -c nginx --tail=5` shows public addresses, not 192.168.x.

Every NodePort, the gateway's 30871 included, is filtered at the network edge: the gateway is reachable only through the tunnel, which is what makes chaos-api's trust in `CF-Connecting-IP` safe.

## Linkerd service mesh (mTLS track)

clinic, clinic-data, chaos, timeline and nginx-gateway are meshed: every hop between them is mTLS, and postgres accepts only the `api`, `worker`, `nightly-report` and `migrate` identities (`apps/clinic-data/mesh-policy.yaml`).

- **Health:** `linkerd check` and `linkerd check --proxy -n clinic`. CLI: `curl --proto '=https' -sSfL https://run.linkerd.io/install-edge | LINKERD2_VERSION=edge-26.9.3 sh` (keep it on the control plane's version).
- **Who talks to postgres:** `linkerd diagnostics proxy-metrics -n clinic-data sts/postgres | grep -oE 'client_id="[^"]+"' | sort | uniq -c`. Refusals: `kubectl -n clinic-data logs postgres-0 -c linkerd-proxy | grep "Connection denied"`.
- **The gateway is meshed by its namespace** (`managedNamespaceMetadata` in `argo/apps/gateway.yaml`): inbound port 80 skips the proxy, so nginx sees the visitor's address; nginx's calls to the apps go through it (mTLS).
- **New namespace or workload in the mesh:** its NetworkPolicies must allow DNS, egress to namespace `linkerd`, and port **4143** wherever the app port is allowed (meshed clients connect to the server's proxy port). A namespace with default-deny and no DNS rule leaves the proxy unable to start (`Init:1/2` loop).
- **PreSync hooks:** a hook runs before the sync phase. A hook that needs something new (a NetworkPolicy, a ServiceAccount) deadlocks the first sync. Ship the dependency in an earlier change.
- **Postgres probes are exec, not TCP:** a kubelet TCP probe has no mesh identity and the postgres Server refuses it.

### Certificates

| | Validity | Where |
|---|---|---|
| Trust anchor (root CA) | until Oct 2036 | public cert in `platform/linkerd/trust-anchor.yaml`; **private key only in the password manager** |
| Issuer (intermediate CA) | until **15 Oct 2027** | Sealed Secret `platform/linkerd/sealed-identity-issuer.yaml` |
| Workload certificates | 24 h, renewed automatically | issued by `linkerd-identity` |

**Yearly issuer rotation (before Oct 2027):** put the root key back in `~/linkerd-ca/ca.key`, run `bash platform/linkerd/make-certs.sh rotate-issuer`, commit the new sealed Secret, sync `linkerd`, then `kubectl -n linkerd rollout restart deploy/linkerd-identity` and `shred -u ~/linkerd-ca/ca.key`. Workloads pick up certificates from the new issuer within 24 h; the trust anchor does not change, so nothing else restarts.

**Never paste a CA private key into chat or a ticket.** If one leaks, regenerate it (as on 15 Oct 2026, before the first deploy).

**Roll back the mesh for one namespace:** remove `linkerd.io/inject: enabled` from it in git and restart its workloads. Delete `apps/clinic-data/mesh-policy.yaml` first, or postgres will refuse the unmeshed clients.
