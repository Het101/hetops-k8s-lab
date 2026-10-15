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
- **ingress-nginx request metrics** (monitoring M3, 9 Oct): v1.12.1 was installed without `--enable-metrics`, and exported only Go/process metrics. Prometheus showed the target UP with no request data. Fix:
  ```bash
  kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-metrics=true"}]'
  ```
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
- Retention: 3 days (ILM policy from the `filebeat-ilm-policy` ConfigMap). Disk guard: Elasticsearch stops allocating with less than 30 GB free on the host, and blocks writes below 20 GB.
- Host paths written by the stack (clean up only after removing the `logging` app): the local-path volume under `/opt/local-path-provisioner/`, and Filebeat's read positions at `/var/lib/logging/lab-filebeat/`.

## Kubernetes audit logging (SIEM track, T1)

The API server writes an audit log (policy: `platform/host/audit-policy.yaml`: every write including `pods/exec`, Secret/ConfigMap access at metadata level only, controller reads dropped). It is a static-pod change, so it lives outside Argo CD:

```bash
cd ~/hetops-k8s-lab && git pull && sudo platform/host/enable-audit.sh          # backup + apply
sudo platform/host/enable-audit.sh rollback                                     # if kubectl is not back in 3 minutes
```

Filebeat ships `/var/log/kubernetes/audit/audit.log` to Elasticsearch under `k8s_audit.*` (`log_source: k8s-audit`). After a kubeadm upgrade, check the flags survived: kubeadm regenerates the manifest.

## Falco (SIEM track, T2)

- Runtime IDS on the node (modern eBPF). Alerts: `kubectl -n falco logs ds/falco -c falco`, and in Kibana `kubernetes.namespace : "falco"` (fields under `falco.*`).
- Tuning lives in `argo/apps/falco.yaml` (`customRules`). Exempt by the narrowest field that explains *why* a caller is legitimate; never disable a rule wholesale.
- **Manual Argo CD sync with kubectl:** a patched `operation` uses only the options inside it, not the app's `syncOptions`. Pass them: `kubectl -n argocd patch app falco --type merge -p '{"operation":{"initiatedBy":{"username":"owner"},"sync":{"revision":"9.2.0","syncOptions":["CreateNamespace=true","ServerSideApply=true"]}}}'`

## Real visitor IPs in ingress-nginx (SIEM track, T3)

All public traffic arrives through cloudflared, so nginx saw the tunnel pod's IP. Trust Cloudflare's `CF-Connecting-IP` header, but **only from the pod network** (where cloudflared runs); anything else claiming that header is ignored, so it cannot be spoofed from outside:

```bash
kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type merge -p '{"data":{"use-forwarded-headers":"true","forwarded-for-header":"CF-Connecting-IP","proxy-real-ip-cidr":"192.168.0.0/16"}}'
```

Set outside git (ingress-nginx was installed by hand). Re-apply after any reinstall.

## Linkerd service mesh (mTLS track)

clinic, clinic-data, chaos and ingress-nginx are meshed: every hop between them is mTLS, and postgres accepts only the `api`, `worker`, `nightly-report` and `migrate` identities (`apps/clinic-data/mesh-policy.yaml`).

- **Health:** `linkerd check` and `linkerd check --proxy -n clinic`. CLI: `curl --proto '=https' -sSfL https://run.linkerd.io/install-edge | LINKERD2_VERSION=edge-26.9.3 sh` (keep it on the control plane's version).
- **Who talks to postgres:** `linkerd diagnostics proxy-metrics -n clinic-data sts/postgres | grep -oE 'client_id="[^"]+"' | sort | uniq -c`. Refusals: `kubectl -n clinic-data logs postgres-0 -c linkerd-proxy | grep "Connection denied"`.
- **ingress-nginx is meshed by hand** (installed outside git). Re-apply after any reinstall:
  ```bash
  kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type merge -p '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"enabled","config.linkerd.io/skip-inbound-ports":"80,443,8443"}}}}}'
  ```
  Inbound 80/443 (visitors) and 8443 (admission webhook) skip the proxy, so real client IPs and CrowdSec are unchanged; nginx's calls to the apps go through it.
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
