# Platform Labs Implementation Plan (L0 to L8)

> **For the owner, not for agentic workers.** This plan is executed **by hand**, by the owner, on the server, lab-style: read the goal and requirements, **write the manifest yourself**, predict the result, apply, verify, then compare with the answer key (folded under each lab). Claude reviews each lab's commit. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the clinic app on the HetOps cluster the way a bank would run a regulated workload. It must be quota-bounded, non-root and default-deny, deployed by Argo CD from this repo, and reachable at `lab.hetops.dev` behind Cloudflare Access.

**Architecture:** Four namespaces:
- `platform`: cloudflared
- `clinic-data`: Postgres StatefulSet
- `clinic`: api, worker, report CronJob, migrate Job and web
- `chaos`: empty until plan 3

You write raw manifests in their final folders (L1 to L5) and apply them with `kubectl`. In L6 you turn them into Kustomize, and in L7 you hand them to Argo CD (app-of-apps). L8 locks them down. Sealed Secrets keeps every credential in git encrypted. One Cloudflare Tunnel publishes the ingress without opening a port.

**Tech Stack:** Kubernetes 1.31 (kubeadm, one ARM64 node, Calico, ingress-nginx on NodePort 30870, local-path storage, metrics-server), Argo CD (installed), Sealed Secrets v0.40.0, cloudflared 2026.10.0, Postgres 17, images `ghcr.io/het101/clinic-api:66f54cc` and `ghcr.io/het101/clinic-web:66f54cc`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-08-chaos-lab-design.md`. Clinic app plan: `docs/superpowers/plans/2026-10-08-clinic-app.md`.
- **Shared VM:** the node also runs Coolify and every live hetops.dev site. Every container gets requests and limits, every app namespace a ResourceQuota and a LimitRange. Never bind host ports 80, 443 or 8080.
- **Quotas.** The spec's numbers are the requests; CPU limits may be higher because CPU is only throttled, never reserved:
  - `clinic`: requests 2 CPU and 3Gi, limits 4 CPU and 3Gi
  - `clinic-data`: requests 500m and 1Gi, limits 1 CPU and 1Gi
  - `chaos`: requests 250m and 256Mi, limits 500m and 256Mi
- **Pod Security `restricted` is enforced on `clinic`, `clinic-data` and `chaos`; `baseline` on `platform`.** Every pod needs:
  - `runAsNonRoot: true`
  - `seccompProfile: RuntimeDefault`
  - `allowPrivilegeEscalation: false`
  - `capabilities: drop [ALL]`
- **UIDs:** api, worker and jobs run as UID 1000; web as UID 101 (nginx-unprivileged); Postgres as UID 999.
- **api:** `maxSurge: 1, maxUnavailable: 0`, PDB `minAvailable: 2`, HPA 3 to 5 on CPU 70%.
- **Probes:** readiness `/readyz` with `timeoutSeconds: 3`; liveness `/healthz` generous (`timeoutSeconds: 5, failureThreshold: 6`); startup probe on `/healthz`.
- **`preStop` sleep 5 s on api and web**, with `terminationGracePeriodSeconds: 20`, so pods leave the Service before they stop listening (the clinic-app final review finding).
- **api memory limit 256Mi**, so the leak experiment OOMKills quickly. The api Deployment must **not** set `READINESS_ALWAYS_FAIL`.
- **Ingress:** host `lab.hetops.dev`, paths `/api` (to the `api` Service) and `/` (to the `web` Service) only. Never expose `/internal`.
- **Secrets** reach git only as SealedSecrets. The plain values are never written to a file, echoed into shell history or pasted into chat. Required Secrets:
  - `clinic/clinic-db`: `DB_HOST`, `DB_USER`, `DB_PASSWORD`
  - `clinic/clinic-internal`: `INTERNAL_TOKEN`
  - `clinic-data/postgres-auth`: `POSTGRES_PASSWORD`
  - `platform/cloudflared-token`: `token`
- **Image tag** for both images: `66f54cc`. From L6 on, change it only in `apps/clinic/overlays/lab/kustomization.yaml`.
- **`lab.hetops.dev` and `argocd.hetops.dev` stay behind Cloudflare Access (owner only)** until the go-public gate in the spec.
- **Argo CD:** `selfHeal: true`, `prune: true`, reconciliation 60 s, the migrate Job runs as a `PreSync` hook, and child apps retry.
- Commit after every lab from `~/hetops-k8s-lab` with message `lab Ln: <what>`. Push to `main` with the deploy key.

## File Structure (final, after L8)

```text
hetops-k8s-lab/
  platform/
    kustomization.yaml          (L6)
    namespaces.yaml             (L1) clinic, clinic-data, chaos, platform + Pod Security labels
    quotas.yaml                 (L1) ResourceQuota + LimitRange per app namespace
    cloudflared.yaml            (L5) Deployment, 2 replicas
    sealed-cloudflared-token.yaml (L5)
  apps/clinic-data/
    kustomization.yaml          (L6)
    postgres.yaml               (L2) headless Service + StatefulSet
    sealed-postgres-auth.yaml   (L2)
    networkpolicy.yaml          (L8)
  apps/clinic/base/
    kustomization.yaml          (L6)
    sealed-clinic-db.yaml       (L2)
    sealed-clinic-internal.yaml (L2)
    migrate-job.yaml            (L3, becomes a PreSync hook in L7)
    api.yaml                    (L3) Deployment + Service + PDB + HPA
    worker.yaml                 (L4)
    report-cronjob.yaml         (L4)
    web.yaml                    (L4) Deployment + Service
    ingress.yaml                (L5)
    networkpolicies.yaml        (L8)
    rbac-viewer.yaml            (L8)
  apps/clinic/overlays/lab/
    kustomization.yaml          (L6) image tags live here
  argo/
    root.yaml                   (L7) applied once by hand
    project.yaml                (L7) AppProject "lab"
    apps/platform.yaml          (L7) sync-wave 0
    apps/clinic-data.yaml       (L7) sync-wave 1
    apps/clinic.yaml            (L7) sync-wave 2
```

---

### L0: Preflight

**Goal:** confirm the node, the repo and the tools before writing anything.

- [ ] **Step 1: Check the node architecture and the repo**

```bash
uname -m                           # expect aarch64: images must be ARM64
kubectl get nodes -o wide
cd ~/hetops-k8s-lab && git pull && git log --oneline -3
mkdir -p platform apps/clinic-data apps/clinic/base apps/clinic/overlays/lab argo/apps
```

Expected: `aarch64`. The node is `Ready`, and the log shows the spec and both plans.

- [ ] **Step 2: Install kubeseal (the client side of Sealed Secrets)**

```bash
KS=0.40.0
curl -sL "https://github.com/bitnami/sealed-secrets/releases/download/v${KS}/kubeseal-${KS}-linux-arm64.tar.gz" | tar xz kubeseal
sudo install -m 0755 kubeseal /usr/local/bin/kubeseal && rm kubeseal
kubeseal --version
```

Expected: `kubeseal version: 0.40.0`.

Interview line: "Before touching a cluster I check architecture, versions and what's already running. An ARM node with amd64 images fails with `exec format error`."

---

### L1: Namespaces, Pod Security, quotas, LimitRanges

**Goal:** four namespaces that protect the shared VM. Nothing in them can run as root, and nothing can use more than its budget.

**Concepts:** a namespace as a tenant boundary; Pod Security Admission labels; ResourceQuota (the namespace ceiling) vs LimitRange (per-container defaults and maximums).

**Requirements:**

1. `platform/namespaces.yaml`: four Namespaces.
   - `clinic`, `clinic-data` and `chaos` get `pod-security.kubernetes.io/enforce: restricted` and `pod-security.kubernetes.io/warn: restricted`.
   - `platform` gets `enforce: baseline` and `warn: restricted`.
   - All four get the label `app.kubernetes.io/part-of: chaos-lab`.
2. `platform/quotas.yaml`: a ResourceQuota and a LimitRange in each of `clinic`, `clinic-data` and `chaos`, with the Global Constraints numbers, plus:
   - **Pod and storage caps:** `pods: "20"` and `persistentvolumeclaims: "0"` for `clinic`; `pods: "3"`, `persistentvolumeclaims: "1"` and `requests.storage: 2Gi` for `clinic-data`; `pods: "4"` for `chaos`.
   - **LimitRange `clinic`:** default `250m` / `256Mi`, defaultRequest `50m` / `64Mi`, max `1` / `1Gi`.
   - **LimitRange `clinic-data`:** default `250m` / `256Mi`, defaultRequest `50m` / `64Mi`, max `1` / `1Gi`.
   - **LimitRange `chaos`:** default `100m` / `128Mi`, defaultRequest `25m` / `64Mi`, max `500m` / `256Mi`.

- [ ] **Step 1: Write both files yourself**, then apply them:

```bash
kubectl apply -f platform/namespaces.yaml -f platform/quotas.yaml
kubectl get ns -L pod-security.kubernetes.io/enforce
kubectl describe quota -n clinic
```

- [ ] **Step 2: Predict, then prove each guardrail**

Predict before running each one: which are accepted, which are rejected, and with what message?

```bash
kubectl -n clinic run root-pod --image=nginx:1.27                       # 1: plain pod, runs as root
kubectl -n clinic run big --image=busybox:1.36 --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"big","image":"busybox:1.36","command":["sleep","60"],"resources":{"requests":{"memory":"2Gi"},"limits":{"memory":"2Gi"}},"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'   # 2: too big for the LimitRange max
kubectl -n clinic run ok --image=busybox:1.36 --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"ok","image":"busybox:1.36","command":["sleep","60"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'   # 3: compliant, no resources given
kubectl -n clinic get pod ok -o jsonpath='{.spec.containers[0].resources}'; echo
kubectl -n clinic delete pod ok
```

Expected:
1. Rejected: `violates PodSecurity "restricted:latest"`, listing the missing fields.
2. Rejected by the LimitRange: `maximum memory usage per Container is 1Gi`.
3. Accepted, and the jsonpath shows the LimitRange **defaults filled in**: `{"limits":{"cpu":"250m","memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}`.

- [ ] **Step 3: Commit**

```bash
git add platform && git commit -m "lab L1: namespaces, pod security, quotas" && git push
```

Interview line: "Each tenant namespace gets Pod Security restricted, a ResourceQuota as its ceiling and a LimitRange for defaults. On a shared node that's what stops one workload from starving another."

<details><summary>Answer key: L1</summary>

`platform/namespaces.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: clinic
  labels:
    app.kubernetes.io/part-of: chaos-lab
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: clinic-data
  labels:
    app.kubernetes.io/part-of: chaos-lab
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: chaos
  labels:
    app.kubernetes.io/part-of: chaos-lab
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform
  labels:
    app.kubernetes.io/part-of: chaos-lab
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
```

`platform/quotas.yaml`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: budget, namespace: clinic }
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 3Gi
    limits.cpu: "4"
    limits.memory: 3Gi
    pods: "20"
    persistentvolumeclaims: "0"
---
apiVersion: v1
kind: LimitRange
metadata: { name: defaults, namespace: clinic }
spec:
  limits:
  - type: Container
    default: { cpu: 250m, memory: 256Mi }
    defaultRequest: { cpu: 50m, memory: 64Mi }
    max: { cpu: "1", memory: 1Gi }
---
apiVersion: v1
kind: ResourceQuota
metadata: { name: budget, namespace: clinic-data }
spec:
  hard:
    requests.cpu: 500m
    requests.memory: 1Gi
    limits.cpu: "1"
    limits.memory: 1Gi
    pods: "3"
    persistentvolumeclaims: "1"
    requests.storage: 2Gi
---
apiVersion: v1
kind: LimitRange
metadata: { name: defaults, namespace: clinic-data }
spec:
  limits:
  - type: Container
    default: { cpu: 250m, memory: 256Mi }
    defaultRequest: { cpu: 50m, memory: 64Mi }
    max: { cpu: "1", memory: 1Gi }
---
apiVersion: v1
kind: ResourceQuota
metadata: { name: budget, namespace: chaos }
spec:
  hard:
    requests.cpu: 250m
    requests.memory: 256Mi
    limits.cpu: 500m
    limits.memory: 256Mi
    pods: "4"
---
apiVersion: v1
kind: LimitRange
metadata: { name: defaults, namespace: chaos }
spec:
  limits:
  - type: Container
    default: { cpu: 100m, memory: 128Mi }
    defaultRequest: { cpu: 25m, memory: 64Mi }
    max: { cpu: 500m, memory: 256Mi }
```

</details>

---

### L2: Sealed Secrets and Postgres

**Goal:** a Postgres that survives its pod being killed, with credentials that can live in a public git repo.

**Concepts:** asymmetric encryption for GitOps secrets; why a SealedSecret is bound to one namespace and name; StatefulSet identity and `volumeClaimTemplates`; why `PGDATA` points at a subdirectory.

- [ ] **Step 1: Install the Sealed Secrets controller**

```bash
kubectl apply -f https://github.com/bitnami/sealed-secrets/releases/download/v0.40.0/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller
```

- [ ] **Step 2: Create and seal the three secrets.** Do it in one shell session, so the generated values live only in shell variables. Store the password and the token in your password manager too; plan 3 needs the token again.

```bash
cd ~/hetops-k8s-lab
read -rs -p "Postgres password (or Enter to generate): " PGPASS; echo
[ -n "$PGPASS" ] || PGPASS=$(openssl rand -hex 24)
TOKEN=$(openssl rand -hex 24)

kubectl -n clinic-data create secret generic postgres-auth --from-literal=POSTGRES_PASSWORD="$PGPASS" \
  --dry-run=client -o yaml | kubeseal --format yaml > apps/clinic-data/sealed-postgres-auth.yaml
kubectl -n clinic create secret generic clinic-db \
  --from-literal=DB_HOST=postgres.clinic-data.svc.cluster.local --from-literal=DB_USER=postgres --from-literal=DB_PASSWORD="$PGPASS" \
  --dry-run=client -o yaml | kubeseal --format yaml > apps/clinic/base/sealed-clinic-db.yaml
kubectl -n clinic create secret generic clinic-internal --from-literal=INTERNAL_TOKEN="$TOKEN" \
  --dry-run=client -o yaml | kubeseal --format yaml > apps/clinic/base/sealed-clinic-internal.yaml
echo "Save these now (password manager), then clear them:"; echo "pg: $PGPASS"; echo "token: $TOKEN"
unset PGPASS TOKEN
```

**Predict:** open `apps/clinic/base/sealed-clinic-db.yaml`. Can you find the password in it? What would happen if you changed `namespace: clinic` to `namespace: lab` and applied it?

```bash
kubectl apply -f apps/clinic-data/sealed-postgres-auth.yaml -f apps/clinic/base/sealed-clinic-db.yaml -f apps/clinic/base/sealed-clinic-internal.yaml
kubectl get sealedsecrets,secrets -n clinic
```

Expected: each SealedSecret produces a Secret of the same name. The YAML contains only encrypted blobs. With a different namespace, the controller fails to decrypt (`no key could decrypt secret`), because strict scope binds a SealedSecret to its namespace and name.

- [ ] **Step 3: Write `apps/clinic-data/postgres.yaml` yourself.** It holds two objects:
   - A **headless** Service `postgres` (`clusterIP: None`) on port 5432.
   - A StatefulSet `postgres` with 1 replica and image `postgres:17`.
   - **Security:** pod `securityContext` with `runAsNonRoot`, `runAsUser`, `runAsGroup` and `fsGroup` all `999`, plus `seccompProfile: RuntimeDefault`. Container: `allowPrivilegeEscalation: false`, drop ALL.
   - **Env:** `PGDATA=/var/lib/postgresql/data/pgdata`; `POSTGRES_PASSWORD` from Secret `postgres-auth`.
   - **Probes:** readiness `exec: pg_isready -U postgres` every 5 s; liveness `tcpSocket` on 5432, every 10 s, `failureThreshold: 6`.
   - **Resources:** requests `250m` / `512Mi`, limits `500m` / `1Gi`.
   - **Storage:** `volumeClaimTemplates` named `data`, 2Gi `ReadWriteOnce`, mounted at `/var/lib/postgresql/data`.

```bash
kubectl apply -f apps/clinic-data/postgres.yaml
kubectl -n clinic-data rollout status statefulset/postgres
kubectl -n clinic-data get pods,pvc
```

- [ ] **Step 4: Prove the data survives**

**Predict first:** after deleting `postgres-0`, what's the new pod's name, and does the table still exist?

```bash
kubectl -n clinic-data exec postgres-0 -- psql -U postgres -c "create table survive(x int); insert into survive values (42);"
kubectl -n clinic-data delete pod postgres-0
kubectl -n clinic-data rollout status statefulset/postgres
kubectl -n clinic-data exec postgres-0 -- psql -U postgres -c "select * from survive;"
kubectl -n clinic-data exec postgres-0 -- psql -U postgres -c "drop table survive;"
```

Expected: the pod comes back as `postgres-0`, bound to the same PVC `data-postgres-0`, and the select returns 42. That's chaos action 13.

- [ ] **Step 5: Commit**

```bash
git add apps && git commit -m "lab L2: sealed secrets and postgres statefulset" && git push
```

Interview line: "Secrets go to git as SealedSecrets: encrypted with the cluster's public key, only the in-cluster controller can decrypt, and each one is bound to its namespace and name. Stateful services get a StatefulSet for stable identity and storage, but for a bank I'd still use managed Postgres."

<details><summary>Answer key: L2</summary>

`apps/clinic-data/postgres.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: clinic-data }
spec:
  clusterIP: None
  selector: { app: postgres }
  ports: [{ name: pg, port: 5432 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: postgres, namespace: clinic-data }
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: postgres
        image: postgres:17
        ports: [{ name: pg, containerPort: 5432 }]
        env:
        - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }   # initdb needs an empty dir it owns
        - name: POSTGRES_PASSWORD
          valueFrom: { secretKeyRef: { name: postgres-auth, key: POSTGRES_PASSWORD } }
        readinessProbe:
          exec: { command: [pg_isready, -U, postgres] }
          periodSeconds: 5
        livenessProbe:
          tcpSocket: { port: 5432 }
          periodSeconds: 10
          failureThreshold: 6
        resources:
          requests: { cpu: 250m, memory: 512Mi }
          limits: { cpu: 500m, memory: 1Gi }
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: [ALL] }
        volumeMounts: [{ name: data, mountPath: /var/lib/postgresql/data }]
  volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      resources: { requests: { storage: 2Gi } }
```

</details>

---

### L3: Migrations and the API Deployment

**Goal:** three API pods that survive rollouts, pod kills and a database outage without dropping a request.

**Concepts:** a Job for run-once work; why readiness fails before migrations; Service `port` vs `targetPort`; the three probes; `maxUnavailable: 0`; PDB vs eviction; HPA; `preStop` and endpoint removal racing SIGTERM.

- [ ] **Step 1: Start the API before the database is migrated**

Write `apps/clinic/base/api.yaml` first (requirements below), then predict: what READY value will the api pods show, and why?

**Requirements for `api.yaml`.** It holds four objects:
1. **Deployment `api`:**
   - 3 replicas, `revisionHistoryLimit: 5`, strategy `maxSurge: 1, maxUnavailable: 0`.
   - Pod labels `app: api`; image `ghcr.io/het101/clinic-api:66f54cc`; container port 8080.
   - Env `RUN_JOBS=false`; `envFrom` Secrets `clinic-db` and `clinic-internal`.
   - Probes from the Global Constraints, plus a startup probe on `/healthz` (period 2, `failureThreshold: 30`).
   - Resources: requests `100m` / `192Mi`, limits `500m` / `256Mi`.
   - Pod: `runAsNonRoot`, `runAsUser: 1000`, seccomp RuntimeDefault, `terminationGracePeriodSeconds: 20`.
   - Container: no privilege escalation, drop ALL, `readOnlyRootFilesystem: true`, an `emptyDir` mounted at `/tmp`.
   - `lifecycle.preStop.sleep.seconds: 5`.
2. **Service `api`:** port 80 to targetPort 8080.
3. **PDB `api`:** `minAvailable: 2`.
4. **HPA `api`:** 3 to 5 replicas, CPU 70%, `behavior.scaleDown.stabilizationWindowSeconds: 120`.

```bash
kubectl apply -f apps/clinic/base/api.yaml
kubectl -n clinic get pods -l app=api -w     # Ctrl+C after ~30 s
kubectl -n clinic logs deploy/api | grep -m1 readiness
```

Expected: `0/1 Running`. The logs say `readiness: admin database unreachable`. The admin database `clinic_admin` doesn't exist yet, so `/readyz` returns 503 and the pods get no traffic. They aren't restarted, because liveness (`/healthz`) passes.

- [ ] **Step 2: Run the migrations as a Job and watch readiness flip**

Write `apps/clinic/base/migrate-job.yaml` with these settings:
- **Job:** `backoffLimit: 0`, `activeDeadlineSeconds: 600`, `ttlSecondsAfterFinished: 3600`.
- **Pod:** label `app: migrate`, same image, `command: [node, api/src/migrate.js]`, `envFrom` `clinic-db`, `restartPolicy: Never`.
- **Security:** the same securityContext as the api, with `readOnlyRootFilesystem: true`.
- **Resources:** requests `100m` / `128Mi`, limits `250m` / `256Mi`.

```bash
kubectl apply -f apps/clinic/base/migrate-job.yaml
kubectl -n clinic wait --for=condition=complete job/migrate --timeout=120s
kubectl -n clinic logs job/migrate
kubectl -n clinic get pods -l app=api
```

Expected: the logs show `admin migrated` and three `tenant migrated` lines. Within about 5 s the api pods turn `1/1`. Running the Job again needs `kubectl delete job migrate` first, because a Job's pod template is immutable. In L7, Argo CD's hook recreates it on every sync.

- [ ] **Step 3: Call it from inside the cluster**

Your old `lab` namespace has no Pod Security labels, so a debug pod can run there:

```bash
kubectl -n lab run curl --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'for i in 1 2 3 4 5 6; do curl -s api.clinic/api/whoami; echo; done'
```

Expected: JSON lines naming **different** pods, showing the Service load-balancing across them. `api.clinic` resolves because of the `search` domains you learned in Lab 2.

- [ ] **Step 4: A zero-downtime rollout, proven**

Terminal 2: steady traffic.

```bash
kubectl -n lab run load --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'while true; do curl -s -o /dev/null -w "%{http_code}\n" --max-time 2 api.clinic/api/whoami; sleep 0.2; done'
```

Terminal 1:

```bash
kubectl -n clinic rollout restart deploy/api
kubectl -n clinic rollout status deploy/api
```

**Predict:** how many non-200 lines appear in terminal 2? Then remove `preStop` from your file, apply, run the restart again, and compare. (Put `preStop` back afterwards.)

Expected: with `preStop`, zero non-200s. Without it you'll usually see a few `000` or `502` lines: the pod stops listening while it is still in the Service endpoints.

- [ ] **Step 5: PDB vs delete**

**Predict:** you evict all three api pods at once with `kubectl drain`-style evictions. How many stay serving? What if you delete them instead?

```bash
for n in $(kubectl -n clinic get pods -l app=api -o jsonpath='{.items[*].metadata.name}'); do
  kubectl create --raw "/api/v1/namespaces/clinic/pods/${n}/eviction" -f - <<<"{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"${n}\",\"namespace\":\"clinic\"}}" >/dev/null \
    && echo "evicted $n" || echo "REFUSED $n"
done
kubectl -n clinic get pods -l app=api
```

Expected: one eviction succeeds and the next two are refused with `Cannot evict pod as it would violate the pod's disruption budget`. A plain `kubectl delete pod` ignores the PDB entirely; that's chaos actions 2 and 3.

- [ ] **Step 6: Commit**

```bash
git add apps && git commit -m "lab L3: api deployment, probes, pdb, hpa, migrate job" && git push
```

Interview line: "Readiness gates traffic, liveness restarts, startup protects slow boots. `maxUnavailable: 0` keeps capacity during rollouts. A `preStop` sleep covers the race between endpoint removal and SIGTERM. PDBs protect against evictions, not deletes. Migrations run once as a Job, never in the container's start command."

<details><summary>Answer key: L3</summary>

`apps/clinic/base/api.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: api, namespace: clinic }
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector: { matchLabels: { app: api } }
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  template:
    metadata: { labels: { app: api } }
    spec:
      terminationGracePeriodSeconds: 20
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: api
        image: ghcr.io/het101/clinic-api:66f54cc
        ports: [{ name: http, containerPort: 8080 }]
        env:
        - { name: RUN_JOBS, value: "false" }
        envFrom:
        - secretRef: { name: clinic-db }
        - secretRef: { name: clinic-internal }
        startupProbe:
          httpGet: { path: /healthz, port: http }
          periodSeconds: 2
          failureThreshold: 30
        readinessProbe:
          httpGet: { path: /readyz, port: http }
          periodSeconds: 5
          timeoutSeconds: 3
        livenessProbe:
          httpGet: { path: /healthz, port: http }
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 6
        lifecycle:
          preStop:
            sleep: { seconds: 5 }   # leave the Service endpoints before we stop listening
        resources:
          requests: { cpu: 100m, memory: 192Mi }
          limits: { cpu: 500m, memory: 256Mi }
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: [ALL] }
        volumeMounts: [{ name: tmp, mountPath: /tmp }]
      volumes: [{ name: tmp, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata: { name: api, namespace: clinic }
spec:
  selector: { app: api }
  ports: [{ name: http, port: 80, targetPort: http }]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: api, namespace: clinic }
spec:
  minAvailable: 2
  selector: { matchLabels: { app: api } }
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: api, namespace: clinic }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: api }
  minReplicas: 3
  maxReplicas: 5
  metrics:
  - type: Resource
    resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
  behavior:
    scaleDown: { stabilizationWindowSeconds: 120 }
```

`apps/clinic/base/migrate-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: migrate, namespace: clinic }
spec:
  backoffLimit: 0                 # a failed migration stops the release; a human looks
  activeDeadlineSeconds: 600      # never hang forever
  ttlSecondsAfterFinished: 3600
  template:
    metadata: { labels: { app: migrate } }
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: migrate
        image: ghcr.io/het101/clinic-api:66f54cc
        command: [node, api/src/migrate.js]
        envFrom: [{ secretRef: { name: clinic-db } }]
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits: { cpu: 250m, memory: 256Mi }
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: [ALL] }
```

</details>

---

### L4: Worker, CronJob, web

**Goal:** the scheduled jobs run exactly once, not once per replica; there's a nightly report; and a web front end runs as UID 101 on a read-only filesystem.

**Concepts:** splitting scheduled jobs out of a scaled service; `Recreate` strategy; CronJob `concurrencyPolicy`; running a CronJob on demand; image-specific UIDs.

**Requirements:**

1. **`worker.yaml`:** Deployment `worker`.
   - 1 replica, `strategy: Recreate`, label `app: worker`.
   - Same image, env `RUN_JOBS=true`, `envFrom` `clinic-db` and `clinic-internal`.
   - The api's readiness and liveness probes; resources requests `100m` / `128Mi`, limits `250m` / `256Mi`.
   - The api's securityContext, `/tmp` emptyDir. No Service.
2. **`report-cronjob.yaml`:** CronJob `nightly-report`.
   - Schedule `"0 2 * * *"`, `concurrencyPolicy: Forbid`, history limits 3 and 3.
   - Pod label `app: nightly-report`, `command: [node, api/src/jobs.js, report]`, `restartPolicy: Never`, `backoffLimit: 1`.
   - Same securityContext and resources as migrate.
3. **`web.yaml`:** Deployment `web` plus Service `web`.
   - 2 replicas, label `app: web`, image `ghcr.io/het101/clinic-web:66f54cc`, port 8080.
   - Pod `runAsNonRoot`, `runAsUser: 101`, seccomp RuntimeDefault; `readOnlyRootFilesystem: true` with an `emptyDir` at `/tmp` (nginx writes its pid and temp files there).
   - Readiness and liveness `httpGet /` on 8080; `preStop` sleep 5; `terminationGracePeriodSeconds: 20`.
   - Resources: requests `25m` / `32Mi`, limits `100m` / `64Mi`.
   - Service port 80 to 8080.

- [ ] **Step 1: Write and apply**

```bash
kubectl apply -f apps/clinic/base/worker.yaml -f apps/clinic/base/report-cronjob.yaml -f apps/clinic/base/web.yaml
kubectl -n clinic get deploy,cronjob,pods
```

- [ ] **Step 2: Prove the jobs run once**

```bash
kubectl -n clinic logs deploy/worker --since=5m | grep -c "reminders"   # the seeded 30-minute appointment gets reminded
kubectl -n clinic logs -l app=api --since=5m | grep -c "reminders"      # expect 0: api replicas never run jobs
kubectl -n clinic create job --from=cronjob/nightly-report report-now
kubectl -n clinic wait --for=condition=complete job/report-now --timeout=60s && kubectl -n clinic logs job/report-now
```

**Predict:** the API scales to 5. How many times does each reminder fire? (Once: only the worker runs jobs. That's the scheduled-jobs fix from your interview prep, now running for real.)

- [ ] **Step 3: Commit**

```bash
git add apps && git commit -m "lab L4: worker, nightly report cronjob, web" && git push
```

Interview line: "Scheduled work never runs inside a horizontally scaled service. It goes in a single-replica worker or a CronJob with `concurrencyPolicy: Forbid`, and the jobs are idempotent so a retry is safe."

<details><summary>Answer key: L4</summary>

`apps/clinic/base/worker.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: worker, namespace: clinic }
spec:
  replicas: 1
  selector: { matchLabels: { app: worker } }
  strategy: { type: Recreate }   # never two workers at once, even during a rollout
  template:
    metadata: { labels: { app: worker } }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: worker
        image: ghcr.io/het101/clinic-api:66f54cc
        ports: [{ name: http, containerPort: 8080 }]
        env:
        - { name: RUN_JOBS, value: "true" }
        envFrom:
        - secretRef: { name: clinic-db }
        - secretRef: { name: clinic-internal }
        readinessProbe:
          httpGet: { path: /readyz, port: http }
          periodSeconds: 5
          timeoutSeconds: 3
        livenessProbe:
          httpGet: { path: /healthz, port: http }
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 6
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits: { cpu: 250m, memory: 256Mi }
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: [ALL] }
        volumeMounts: [{ name: tmp, mountPath: /tmp }]
      volumes: [{ name: tmp, emptyDir: {} }]
```

`apps/clinic/base/report-cronjob.yaml`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: nightly-report, namespace: clinic }
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        metadata: { labels: { app: nightly-report } }
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            seccompProfile: { type: RuntimeDefault }
          containers:
          - name: report
            image: ghcr.io/het101/clinic-api:66f54cc
            command: [node, api/src/jobs.js, report]
            envFrom: [{ secretRef: { name: clinic-db } }]
            resources:
              requests: { cpu: 100m, memory: 128Mi }
              limits: { cpu: 250m, memory: 256Mi }
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: { drop: [ALL] }
```

`apps/clinic/base/web.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: web, namespace: clinic }
spec:
  replicas: 2
  selector: { matchLabels: { app: web } }
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  template:
    metadata: { labels: { app: web } }
    spec:
      terminationGracePeriodSeconds: 20
      securityContext:
        runAsNonRoot: true
        runAsUser: 101          # nginx-unprivileged's user
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: web
        image: ghcr.io/het101/clinic-web:66f54cc
        ports: [{ name: http, containerPort: 8080 }]
        readinessProbe: { httpGet: { path: /, port: http }, periodSeconds: 5 }
        livenessProbe: { httpGet: { path: /, port: http }, periodSeconds: 10 }
        lifecycle:
          preStop:
            sleep: { seconds: 5 }
        resources:
          requests: { cpu: 25m, memory: 32Mi }
          limits: { cpu: 100m, memory: 64Mi }
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: [ALL] }
        volumeMounts: [{ name: tmp, mountPath: /tmp }]
      volumes: [{ name: tmp, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata: { name: web, namespace: clinic }
spec:
  selector: { app: web }
  ports: [{ name: http, port: 80, targetPort: http }]
```

</details>

---

### L5: Ingress and the Cloudflare Tunnel

**Goal:** `https://lab.hetops.dev` serves the clinic app from the cluster, with no inbound port opened on the VM and only you allowed in.

**Concepts:** path routing; why `/internal` must never be routed; outbound-only tunnels; Cloudflare Access as an identity-aware gate; an explicit DNS record beats the `*.hetops.dev` wildcard that points at Coolify.

- [ ] **Step 1: Write `apps/clinic/base/ingress.yaml`.** It needs:
   - `ingressClassName: nginx` and host `lab.hetops.dev`.
   - Path `/api` (Prefix) to Service `api` port 80, and path `/` (Prefix) to Service `web` port 80.

```bash
kubectl apply -f apps/clinic/base/ingress.yaml
curl -s -H 'Host: lab.hetops.dev' localhost:30870/api/whoami; echo
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: lab.hetops.dev' -X POST localhost:30870/internal/crash
```

**Predict the second curl's status code.** Expected: whoami returns JSON. `/internal/crash` falls under the `/` rule, reaches **web** (nginx), and gets **405 or 404**. It never reaches the API. Path routing is your first line of defence; the token is the second.

- [ ] **Step 2: Create the tunnel in Cloudflare (browser).** In Zero Trust:
   1. Go to **Networks → Tunnels → Create a tunnel → Cloudflared**, and name it `hetops-lab`.
   2. Copy the **token** from the install command (the long string after `--token`). Don't run the install command itself.
   3. Under **Public hostname**, add `lab.hetops.dev` with service `HTTP` and URL `ingress-nginx-controller.ingress-nginx.svc.cluster.local:80`.

- [ ] **Step 3: Protect it before it's reachable.** In Zero Trust go to **Access → Applications → Add → Self-hosted**:
   - Application: `lab.hetops.dev`
   - Policy: Allow, Emails = your own address

- [ ] **Step 4: Seal the token and run cloudflared**

```bash
read -rs -p "Tunnel token: " TT; echo
kubectl -n platform create secret generic cloudflared-token --from-literal=token="$TT" \
  --dry-run=client -o yaml | kubeseal --format yaml > platform/sealed-cloudflared-token.yaml
unset TT
```

Write `platform/cloudflared.yaml` with these settings:
- Deployment `cloudflared` in `platform`, 2 replicas, image `cloudflare/cloudflared:2026.10.0`.
- `args: [tunnel, --no-autoupdate, --metrics, "0.0.0.0:2000", run]`, with env `TUNNEL_TOKEN` taken from Secret `cloudflared-token` key `token`.
- Liveness probe `httpGet /ready` on 2000.
- Resources: requests `25m` / `32Mi`, limits `100m` / `128Mi`.
- Security: `runAsNonRoot`, `runAsUser: 65532`, seccomp RuntimeDefault, no privilege escalation, drop ALL, read-only root filesystem.

```bash
kubectl apply -f platform/sealed-cloudflared-token.yaml -f platform/cloudflared.yaml
kubectl -n platform logs deploy/cloudflared | grep -m2 -i "registered tunnel connection"
```

Open `https://lab.hetops.dev`. Expected: the Cloudflare Access login first, then the clinic page saying "Served by api-…". Refresh a few times and watch the pod name change.

- [ ] **Step 5: Commit**

```bash
git add apps platform && git commit -m "lab L5: ingress and cloudflare tunnel behind access" && git push
```

Interview line: "Nothing listens publicly on the VM. cloudflared makes an outbound connection, Cloudflare Access checks identity per request, and the ingress only routes the public paths. Internal endpoints aren't reachable from outside at all."

<details><summary>Answer key: L5</summary>

`apps/clinic/base/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: clinic, namespace: clinic }
spec:
  ingressClassName: nginx
  rules:
  - host: lab.hetops.dev
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend: { service: { name: api, port: { number: 80 } } }
      - path: /
        pathType: Prefix
        backend: { service: { name: web, port: { number: 80 } } }
```

`platform/cloudflared.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: cloudflared, namespace: platform }
spec:
  replicas: 2
  selector: { matchLabels: { app: cloudflared } }
  template:
    metadata: { labels: { app: cloudflared } }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:2026.10.0
        args: [tunnel, --no-autoupdate, --metrics, "0.0.0.0:2000", run]
        env:
        - name: TUNNEL_TOKEN
          valueFrom: { secretKeyRef: { name: cloudflared-token, key: token } }
        livenessProbe:
          httpGet: { path: /ready, port: 2000 }
          periodSeconds: 10
          failureThreshold: 3
        resources:
          requests: { cpu: 25m, memory: 32Mi }
          limits: { cpu: 100m, memory: 128Mi }
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: [ALL] }
```

</details>

---

### L6: Kustomize

**Goal:** the same objects, described as a base plus an overlay, with the image tag in one place. This is a refactor, so the cluster must not change at all.

**Concepts:** `kustomization.yaml`; resources lists; the `images:` transformer; `kubectl kustomize` to render; `kubectl diff -k` to prove a refactor is a no-op.

- [ ] **Step 1: Write four `kustomization.yaml` files**
   - **`platform/kustomization.yaml`:** resources are `namespaces.yaml`, `quotas.yaml`, `sealed-cloudflared-token.yaml` and `cloudflared.yaml`.
   - **`apps/clinic-data/kustomization.yaml`:** `namespace: clinic-data`; resources are `sealed-postgres-auth.yaml` and `postgres.yaml`.
   - **`apps/clinic/base/kustomization.yaml`:** `namespace: clinic`; resources are all the YAML files in `base`.
   - **`apps/clinic/overlays/lab/kustomization.yaml`:** resources `[../../base]`, plus an `images:` list setting `newTag: 66f54cc` for both `ghcr.io/het101/clinic-api` and `ghcr.io/het101/clinic-web`.

- [ ] **Step 2: Render, then prove nothing changes**

```bash
kubectl kustomize apps/clinic/overlays/lab | grep -c '^kind:'
kubectl diff -k platform; echo "exit=$?"
kubectl diff -k apps/clinic-data; echo "exit=$?"
kubectl diff -k apps/clinic/overlays/lab; echo "exit=$?"
```

**Predict:** what should `kubectl diff` print, and what exit code means "identical"? Expected: no diff output and `exit=0` for all three. A non-empty diff means the refactor changed something; find it before moving on. If a Job shows a diff, that's expected (Job specs are immutable and gain server defaults). Note it and continue.

- [ ] **Step 3: Practise an image bump the GitOps way**

Change `newTag` to `bad` in the overlay, and run `kubectl diff -k apps/clinic/overlays/lab`. **Predict which objects change.** You should see api, worker, migrate and the report CronJob, but not web, because each `images:` entry only matches its own image name. Revert to `66f54cc` without applying.

- [ ] **Step 4: Commit**

```bash
git add platform apps && git commit -m "lab L6: kustomize base and lab overlay" && git push
```

Interview line: "Kustomize is a base plus overlays with no templating, built into kubectl. I prove a refactor is safe with `kubectl diff -k` before anything is applied. In GitOps the image tag lives in one overlay line that CI bumps."

<details><summary>Answer key: L6</summary>

`platform/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- namespaces.yaml
- quotas.yaml
- sealed-cloudflared-token.yaml
- cloudflared.yaml
```

`apps/clinic-data/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: clinic-data
resources:
- sealed-postgres-auth.yaml
- postgres.yaml
```

`apps/clinic/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: clinic
resources:
- sealed-clinic-db.yaml
- sealed-clinic-internal.yaml
- migrate-job.yaml
- api.yaml
- worker.yaml
- report-cronjob.yaml
- web.yaml
- ingress.yaml
```

`apps/clinic/overlays/lab/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
images:
- name: ghcr.io/het101/clinic-api
  newTag: 66f54cc
- name: ghcr.io/het101/clinic-web
  newTag: 66f54cc
```

</details>

---

### L7: Argo CD takes over

**Goal:** git becomes the only way to change the lab. Manual changes are reverted within about a minute, and a failing migration blocks a release while the old version keeps serving.

**Concepts:** app-of-apps; AppProject as a GitOps boundary; sync waves; PreSync hooks; `selfHeal` and `prune`; retry; adopting resources created by hand; reconciliation interval.

- [ ] **Step 1: Configure Argo CD**

```bash
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"60s"}}'
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart statefulset/argocd-application-controller deploy/argocd-repo-server deploy/argocd-server
```

`server.insecure` lets the Cloudflare Tunnel terminate TLS in front of Argo CD. Add the tunnel hostname `argocd.hetops.dev` → `HTTP` `argocd-server.argocd.svc.cluster.local:80`, plus an Access application for it (owner only), the same way as in L5.

- [ ] **Step 2: Make migrate a PreSync hook.** Add two annotations to `apps/clinic/base/migrate-job.yaml`:
   - `argocd.argoproj.io/hook: PreSync`
   - `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation`

- [ ] **Step 3: Write the Argo CD manifests yourself**

   1. **`argo/project.yaml`:** AppProject `lab` in `argocd`.
      - `sourceRepos`: `https://github.com/Het101/hetops-k8s-lab.git`.
      - Destinations: the in-cluster server for namespaces `clinic`, `clinic-data`, `chaos` and `platform`.
      - `clusterResourceWhitelist`: only `Namespace`.
   2. **Three child Applications in `argo/apps/`:** `platform` (path `platform`, wave `"0"`), `clinic-data` (path `apps/clinic-data`, wave `"1"`) and `clinic` (path `apps/clinic/overlays/lab`, wave `"2"`). For each:
      - project `lab`, `targetRevision: main`, destination namespace matching its path;
      - `syncPolicy.automated` with `prune: true` and `selfHeal: true`;
      - `retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 3m } }`;
      - **no** resources finalizer, so deleting an Application never deletes the workload.
   3. **`argo/root.yaml`:** Application `root` in project `default`.
      - Source: path `argo`, `directory: { recurse: true, exclude: root.yaml }`.
      - Destination: namespace `argocd`; automated prune and selfHeal.

```bash
git add argo apps && git commit -m "lab L7: argo cd app-of-apps, migrate as presync hook" && git push
kubectl apply -f argo/root.yaml
kubectl -n argocd get applications -w      # Ctrl+C when all four are Synced / Healthy
```

**Predict:** the workloads already exist from L1 to L6. Will Argo CD recreate them, causing a restart, or adopt them? Expected: it **adopts** them by adding its tracking label. Pods aren't restarted unless your files differ from what's running. The migrate hook runs once more, and that's harmless because migrations are idempotent.

- [ ] **Step 4: Drift: three manual changes, one minute each**

```bash
kubectl -n clinic scale deploy api --replicas=0         # chaos action 7
kubectl -n clinic delete deploy web                     # chaos action 8
kubectl -n clinic delete svc api                        # chaos action 9
kubectl -n argocd get app clinic -w                     # OutOfSync -> Synced, Healthy
```

**Predict the order of events** in the Argo CD UI, and how long each heal takes. Expected: each one returns to git's version within about 60–90 s.

- [ ] **Step 5: The private failing-migration lab.** In the migrate Job, add env `MIGRATE_FAIL` = `"true"`. Also bump a harmless field so the api changes too: a pod annotation `lab/release: "2"`. Commit and push.

**Predict:** what does Argo CD show, and are the api pods replaced? Expected:
- The sync **fails at PreSync**. The migrate pod exits 1 with `failing on purpose`.
- The api Deployment is **not** updated: the old pods keep serving, and `lab.hetops.dev` stays up.

Revert the commit with `git revert HEAD && git push`, and watch it sync green. Rollback in GitOps is a revert.

- [ ] **Step 6: Commit** (if anything is uncommitted)

```bash
git status --short && git add -A && git commit -m "lab L7: drift and failing migration drills" && git push
```

Interview line: "Argo CD pulls from git. selfHeal reverts manual changes, prune deletes what's gone from git, and a PreSync migration Job blocks a bad release before any pod changes. Rollback is a git revert, and the audit trail is the git log."

<details><summary>Answer key: L7</summary>

`apps/clinic/base/migrate-job.yaml`, metadata after the change:

```yaml
metadata:
  name: migrate
  namespace: clinic
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

`argo/project.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: { name: lab, namespace: argocd }
spec:
  description: HetOps chaos lab
  sourceRepos: [https://github.com/Het101/hetops-k8s-lab.git]
  destinations:
  - { server: https://kubernetes.default.svc, namespace: clinic }
  - { server: https://kubernetes.default.svc, namespace: clinic-data }
  - { server: https://kubernetes.default.svc, namespace: chaos }
  - { server: https://kubernetes.default.svc, namespace: platform }
  clusterResourceWhitelist:
  - { group: "", kind: Namespace }
```

`argo/apps/platform.yaml` (`clinic-data.yaml` and `clinic.yaml` are the same shape with their own name, wave, path and namespace):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
  annotations: { argocd.argoproj.io/sync-wave: "0" }
spec:
  project: lab
  source:
    repoURL: https://github.com/Het101/hetops-k8s-lab.git
    targetRevision: main
    path: platform
  destination: { server: https://kubernetes.default.svc, namespace: platform }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 3m } }
```

`argo/apps/clinic-data.yaml`: as above with `name: clinic-data`, wave `"1"`, `path: apps/clinic-data`, `namespace: clinic-data`.

`argo/apps/clinic.yaml`: as above with `name: clinic`, wave `"2"`, `path: apps/clinic/overlays/lab`, `namespace: clinic`.

`argo/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: root, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/Het101/hetops-k8s-lab.git
    targetRevision: main
    path: argo
    directory: { recurse: true, exclude: root.yaml }
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

Note: sync waves order the child Applications' creation. Argo CD doesn't wait for a child app to be *healthy* before the next wave unless a health check for `Application` is configured. The `retry` policy covers the case where `clinic`'s migrate hook starts before Postgres is ready.

</details>

---

### L8: Security: default-deny networking, Pod Security, RBAC

**Goal:** every flow in the lab is explicitly allowed; everything else is dropped; and a read-only identity can look but not touch.

**Concepts:** default-deny for ingress and egress; DNS egress (the drill you broke in Lab 6); namespace plus pod selectors; why kubelet probes keep working; Pod Security as an admission gate; Role, RoleBinding and `auth can-i`.

**Requirements:**

1. **`apps/clinic/base/networkpolicies.yaml`** (add it to the base kustomization), all in `clinic`:
   1. `default-deny`: every pod, both Ingress and Egress.
   2. `allow-dns`: every pod may reach `kube-dns` pods in `kube-system` on UDP and TCP 53.
   3. `api-ingress`: pods `app: api` accept port 8080 from namespaces `ingress-nginx` and `chaos`.
   4. `web-ingress`: pods `app: web` accept port 8080 from `ingress-nginx`.
   5. `db-egress`: pods with `app` in (`api`, `worker`, `migrate`, `nightly-report`) may reach pods `app: postgres` in namespace `clinic-data` on 5432. Use one `to` entry with both selectors, so they combine with AND.
2. **`apps/clinic-data/networkpolicy.yaml`** (add it to that kustomization):
   1. `default-deny`: all pods, Ingress and Egress.
   2. `postgres-ingress`: `app: postgres` accepts 5432 from namespace `clinic` only.
3. **`apps/clinic/base/rbac-viewer.yaml`:**
   - ServiceAccount `lab-viewer`.
   - Role `viewer`: get, list and watch on `pods`, `pods/log`, `services`, `endpoints`, `events`, `deployments` and `replicasets`.
   - RoleBinding binding the Role to the ServiceAccount.

- [ ] **Step 1: Write, commit, push.** Let Argo CD apply it; don't use `kubectl apply`.

```bash
git add apps && git commit -m "lab L8: default-deny network policies and a read-only viewer" && git push
kubectl -n argocd get app clinic clinic-data -w
```

- [ ] **Step 2: Prove each policy, predicting first**

```bash
curl -s -H 'Host: lab.hetops.dev' localhost:30870/api/whoami; echo                 # 1: via the ingress
kubectl -n lab run t --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s --max-time 3 api.clinic/api/whoami; echo "exit=$?"                        # 2: from the lab namespace
kubectl -n clinic exec deploy/api -- node -e "require('net').connect(80,'example.com').on('connect',()=>{console.log('OUT');process.exit()}).on('error',e=>{console.log('BLOCKED',e.code);process.exit()}); setTimeout(()=>{console.log('BLOCKED timeout');process.exit()},3000)"   # 3: egress to the internet
kubectl -n clinic get pods                                                          # 4: probes still pass
```

Expected:
1. Works: ingress-nginx is allowed.
2. Times out: `lab` is not an allowed source. Your old load-test pods are now outsiders.
3. `BLOCKED timeout`: no egress except DNS and Postgres. A compromised api pod can't call home.
4. All `1/1`: traffic from the node to its own pods (kubelet probes) is always allowed.

- [ ] **Step 3: RBAC and Pod Security**

```bash
SA=system:serviceaccount:clinic:lab-viewer
kubectl auth can-i list pods -n clinic --as=$SA          # yes
kubectl auth can-i get secrets -n clinic --as=$SA        # no
kubectl auth can-i delete pods -n clinic --as=$SA        # no
kubectl auth can-i list pods -n clinic-data --as=$SA     # no: a Role is namespaced
kubectl -n clinic run priv --image=nginx:1.27 --privileged   # rejected by Pod Security
```

- [ ] **Step 4: Final check of the whole lab**

```bash
kubectl -n argocd get applications            # all Synced / Healthy
for ns in clinic clinic-data platform; do echo "== $ns"; kubectl get pods -n "$ns"; done
kubectl describe quota -n clinic | sed -n '/Resource/,$p'
kubectl top pods -n clinic
```

Open `https://lab.hetops.dev`: the booking page works. This plan is done when every checkbox above is ticked and Argo CD shows all four Applications Synced and Healthy.

Interview line: "Default-deny ingress and egress per namespace, with explicit allows for DNS, the ingress and the database. Pod Security restricted at admission. Least-privilege Roles checked with `kubectl auth can-i`. The api can't reach the internet, so a compromised pod has nowhere to send data."

<details><summary>Answer key: L8</summary>

`apps/clinic/base/networkpolicies.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: clinic }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-dns, namespace: clinic }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
      podSelector: { matchLabels: { k8s-app: kube-dns } }
    ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: api-ingress, namespace: clinic }
spec:
  podSelector: { matchLabels: { app: api } }
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ingress-nginx } }
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: chaos } }
    ports: [{ protocol: TCP, port: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: web-ingress, namespace: clinic }
spec:
  podSelector: { matchLabels: { app: web } }
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ingress-nginx } }
    ports: [{ protocol: TCP, port: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: db-egress, namespace: clinic }
spec:
  podSelector:
    matchExpressions: [{ key: app, operator: In, values: [api, worker, migrate, nightly-report] }]
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: clinic-data } }
      podSelector: { matchLabels: { app: postgres } }      # same list item as the line above = AND
    ports: [{ protocol: TCP, port: 5432 }]
```

`apps/clinic-data/networkpolicy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: clinic-data }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: postgres-ingress, namespace: clinic-data }
spec:
  podSelector: { matchLabels: { app: postgres } }
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: clinic } }
    ports: [{ protocol: TCP, port: 5432 }]
```

`apps/clinic/base/rbac-viewer.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: lab-viewer, namespace: clinic }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: viewer, namespace: clinic }
rules:
- apiGroups: [""]
  resources: [pods, pods/log, services, endpoints, events]
  verbs: [get, list, watch]
- apiGroups: [apps]
  resources: [deployments, replicasets]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: lab-viewer, namespace: clinic }
subjects: [{ kind: ServiceAccount, name: lab-viewer, namespace: clinic }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: viewer }
```

Both kustomizations gain the new files: add `networkpolicies.yaml` and `rbac-viewer.yaml` to `apps/clinic/base/kustomization.yaml`, and `networkpolicy.yaml` to `apps/clinic-data/kustomization.yaml`.

</details>

---

## After this plan

- **Plan 3, chaos-api:** Claude writes the code. You write its RBAC and NetworkPolicy in `chaos`, using the RBAC table from the spec, and seal its copy of `INTERNAL_TOKEN`.
- **Plan 3 also adds** a CI step in `hetops-clinic` that bumps `newTag` in `apps/clinic/overlays/lab/kustomization.yaml` through a PR, so a merge to `main` deploys.
- **Plan 4:** the console page on hetops.dev. Then game day, then the go-public gate.
