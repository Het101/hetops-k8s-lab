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

Argo CD itself was installed by hand (Part 1). Its settings are no longer among these: since 31 Oct they live in Bedrock (`bedrock/roles/argocd`, keys in `defaults/main.yml` and `group_vars/lab.yml`), which applies them and restarts the controller when they change. Never `kubectl patch` them: the nightly drift check reports it.

- **Self-heal backoff** (found by the first self-test, 9 Oct), now `argocd_cmd_params` in `bedrock/group_vars/lab.yml`. By default, Argo CD waits longer before each consecutive self-heal: 2 s, times 3 each time, capped at 300 s, and it resets only after 330 s of calm. That protects real clusters from two tools fighting over one object. In this lab, drift is deliberate, so back-to-back experiments hit the cap: `bad-release` took 296 s. The lab caps it at 30 s, cooldown 60 s.
- **Reconciliation: 180 s**, Argo CD's default (was 60 s from L7 until 31 Oct). Self-heal does not depend on it: a change to a live object triggers a comparison at once.
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

## Logging (ELK)

- Kibana: https://kibana.hetops.dev (Cloudflare tunnel hostname plus an Access app with `owner-only`, set by hand like Grafana). Log in as `elastic`; read the password straight into the clipboard or a password manager, never into chat:
  ```bash
  kubectl -n logging get secret lab-logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d
  ```
- **Yellow after a restart, `logging` stuck in Progressing:** look for replica shards (`r UNASSIGNED`). One node can never place a replica. Kibana's detection engine creates `.lists-default` and `.items-default` with 1 replica; set them to 0 (done 22 Oct). A new backing index after a rollover needs it again:
  ```bash
  PW=$(kubectl -n logging get secret lab-logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
  kubectl -n logging exec lab-logs-es-default-0 -c elasticsearch -- curl -sk -u "elastic:$PW" "https://localhost:9200/_cat/shards?h=index,prirep,state,unassigned.reason" | grep UNASSIGNED
  kubectl -n logging exec lab-logs-es-default-0 -c elasticsearch -- curl -sk -u "elastic:$PW" -X PUT "https://localhost:9200/<index>/_settings" -H 'content-type: application/json' -d '{"index":{"number_of_replicas":0}}'
  unset PW
  ```
- Retention: 3 days (ILM policy from the `filebeat-ilm-policy` ConfigMap). Disk guard: Elasticsearch stops allocating with less than 30 GB free on the host, and blocks writes below 20 GB.
- Host paths written by the stack (clean up only after removing the `logging` app): the local-path volume under `/opt/local-path-provisioner/`, and Filebeat's read positions at `/var/lib/logging/lab-filebeat/`.

## Kubernetes audit logging (SIEM track, T1)

The API server writes an audit log (policy: `platform/host/audit-policy.yaml`: every write including `pods/exec`, Secret/ConfigMap access at metadata level only, controller reads dropped). It is a static-pod change, so it lives outside Argo CD, in **Bedrock** (`bedrock/roles/audit`):
- the policy file is copied from git; a change restarts the API server through handlers;
- the flags and volumes are in kubeadm's ClusterConfiguration (`kube-system/kubeadm-config`), so `kubeadm upgrade` regenerates them;
- the manifest is checked flag by flag.

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock && ansible-playbook site.yml --check --diff   # then without --check
sudo kubeadm upgrade diff v1.31.14 2>&1 | grep -E '^[-+] +- --audit' | sed 's/^[-+]//' | sort | uniq -u   # empty: every audit flag is kept (at most moved)
```

Filebeat ships `/var/log/kubernetes/audit/audit.log` to Elasticsearch under `k8s_audit.*` (`log_source: k8s-audit`). (Until 21 Oct, `platform/host/enable-audit.sh` patched the manifest by hand, and the first upgrade would have dropped the flags.)

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
