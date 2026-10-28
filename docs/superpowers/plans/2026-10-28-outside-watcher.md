# The outside watcher: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gatus on hetops-3 checks every public HetOps site from outside and alerts on its own Telegram bot; the lab's Alertmanager and Kuma watch it back, so either side going silent is noticed.

**Architecture:** One Gatus pod (namespace `watch`) deployed by hetops-3's Argo CD from `clusters/ops/gatus/`, its config a ConfigMap, its secrets a SealedSecret sealed with hetops-3's key, its port reachable only on hetops-3's Tailscale address. The lab's Alertmanager sends its always-firing `Watchdog` alert to a Gatus heartbeat endpoint every 5 minutes (one PR to `platform/monitoring/`); Kuma on the lab gets one monitor on Gatus's health.

**Tech Stack:** Gatus v5.37.0 (`ghcr.io/twin/gatus:v5.37.0`, arm64), Argo CD v3.5.4, sealed-secrets 0.40.0 (`kubeseal` 0.40.0 on the lab), kube-prometheus-stack Alertmanager, Uptime Kuma 2.5.5, Tailscale 1.104.2.

**Spec:** [`docs/superpowers/specs/2026-10-28-outside-watcher-design.md`](../specs/2026-10-28-outside-watcher-design.md)

## Global Constraints

- Gatus image `ghcr.io/twin/gatus:v5.37.0`; namespace `watch`; port 8080 as `hostPort` with `hostIP: 100.89.67.82` only. Nothing listens for it on 130.210.37.122.
- Storage `memory`. Resources: requests 20m CPU / 32Mi, limit 128Mi.
- Every check runs every 60 s; alerts after 3 failures in a row (`failure-threshold: 3`), resolves after 2 successes, `send-on-resolved: true`.
- Every HTTPS check also has `[CERTIFICATE_EXPIRATION] > 336h`.
- Telegram: a NEW bot only hetops-3 knows; chat ID `718892351`.
- Heartbeat: external endpoint `lab-alerting`, group `watchers` (key `watchers_lab-alerting`), `heartbeat.interval: 15m`; the lab's Alertmanager sends `Watchdog` every 5 minutes (`repeat_interval: 5m`).
- Secrets only as SealedSecrets: `gatus-secrets` (namespace `watch`) sealed with hetops-3's key; `alertmanager-watchdog` (namespace `monitoring`) sealed with the lab's key. No token is ever printed, pasted in chat, or committed in plain text.
- The lab changes only through a merged PR, except: a throwaway test pod in Task 1 (deleted the same step), and one Kuma monitor added in its UI by the owner (Task 6).
- Commits: `Het Patel <patel.x.het@gmail.com>`, GPG-signed, subject under 72 characters, no Claude attribution. PRs to `main` on Het101/hetops-k8s-lab; merge only after `gh pr checks <n> --watch` exits 0.
- Non-interactive SSH to the lab needs `export PATH=$HOME/.local/bin:$PATH;` before `ansible*` (not needed for `kubectl`/`kubeseal`, which are in `/usr/local/bin`).
- Every server change goes into the journal's Part 13 the same session, with exact commands; every mistake gets a Part 11 row.

## Who runs what

| Where | Who | How |
|---|---|---|
| Telegram (@BotFather, the new bot) | owner | phone or desktop app |
| Uptime Kuma UI (status.hetops.dev) | owner | browser, logged in |
| hetops-3 | Claude | `ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122` |
| The lab | Claude | `ssh ubuntu@140.245.13.138` |
| Code and PRs | Claude | laptop checkout `C:\Users\HetPatel\Personal\HetOps\hetops-k8s-lab` |

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `clusters/ops/sealed-secrets/ops-cert.pem` | create | hetops-3's sealed-secrets PUBLIC certificate, for sealing without cluster access |
| `clusters/ops/apps/gatus.yaml` | create | Argo CD Application for Gatus |
| `clusters/ops/gatus/kustomization.yaml` | create | lists the manifests below |
| `clusters/ops/gatus/namespace.yaml` | create | namespace `watch` |
| `clusters/ops/gatus/config.yaml` | create | ConfigMap `gatus-config`: every check, the heartbeat, Telegram |
| `clusters/ops/gatus/deployment.yaml` | create | the Gatus pod, hostPort on the Tailscale IP |
| `clusters/ops/gatus/sealed-gatus-secrets.yaml` | create | SealedSecret `gatus-secrets` |
| `platform/monitoring/values.yaml` | modify | `watchdog` route and receiver; `alertmanager-watchdog` in `secrets:` |
| `platform/monitoring/extras/sealed-alertmanager-watchdog.yaml` | create | SealedSecret `alertmanager-watchdog` |
| `platform/monitoring/extras/kustomization.yaml` | modify | lists the new SealedSecret |

---

### Task 1: Can the lab reach hetops-3 over Tailscale? (decides the heartbeat sender)

**Files:** none. Changes: a throwaway listener on hetops-3 and a throwaway pod on the lab, both removed in this task.

**Interfaces:**
- Produces: `HEARTBEAT_SENDER` = `alertmanager` (pods on the lab reach `100.89.67.82`) or `hostnetwork-cronjob` (only the lab host does). Task 5 uses it. Also whether Kuma's container reaches `100.89.67.82` (Task 6).

- [ ] **Step 1: A temporary listener on hetops-3's Tailscale address, 10 minutes at most**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'sudo systemd-run --unit=ts-probe --collect timeout 600 python3 -m http.server 8080 --bind 100.89.67.82 && sleep 1 && ss -tlnp | grep 8080'
```

Expected: a `LISTEN … 100.89.67.82:8080` line.

- [ ] **Step 2: From the lab host**

```bash
ssh ubuntu@140.245.13.138 'curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://100.89.67.82:8080/'
```

Expected: `200`.

- [ ] **Step 3: From a pod on the lab, in `monitoring` (where Alertmanager runs)**

```bash
ssh ubuntu@140.245.13.138 'kubectl -n monitoring run ts-probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://100.89.67.82:8080/'
```

Expected `200` → `HEARTBEAT_SENDER=alertmanager`. Anything else (timeout, `000`) → `HEARTBEAT_SENDER=hostnetwork-cronjob`. The pod deletes itself (`--rm`); confirm with `kubectl -n monitoring get pod ts-probe` → `NotFound`.

- [ ] **Step 4: From Kuma's container on the lab**

```bash
ssh ubuntu@140.245.13.138 'sudo docker exec uptime-kuma-xss888w8404kkwkw4cskcgow curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://100.89.67.82:8080/'
```

Expected: `200`. If not, Task 6's reverse check uses the lab host instead (written there).

- [ ] **Step 5: From the public internet, the same port must not answer**

```bash
curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://130.210.37.122:8080/ || true
```

Expected: `000` (timeout). Then stop the listener: `ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'sudo systemctl stop ts-probe 2>/dev/null; ss -tlnp | grep -c 8080'` → `0`.

- [ ] **Step 6: Journal** — Part 13: the four results and the `HEARTBEAT_SENDER` decision.

---

### Task 2 (owner): The Telegram bot

**Files:** none in git. Produces: a file on the owner's laptop holding only the bot token.

- [ ] **Step 1:** In Telegram, open **@BotFather**, send `/newbot`, name it `HetOps outside watcher`, username e.g. `hetops_watch_bot`. BotFather replies with a token.
- [ ] **Step 2:** Open the new bot's chat and press **Start** (a bot can only message someone who started it).
- [ ] **Step 3:** Save the token, and nothing else, to `C:\Users\HetPatel\.secrets\gatus-bot-token` (one line, no quotes). Do not paste it into chat.
- [ ] **Step 4 (Claude): Check the file without printing the token**

```bash
f=~/.secrets/gatus-bot-token; test -s "$f" && wc -c < "$f" && grep -cE '^[0-9]+:[A-Za-z0-9_-]{30,}$' "$f"
```

Expected: a length around 46 and `1`.

---

### Task 3: Gatus on hetops-3 (PR C)

**Files:** create everything under `clusters/ops/` in the File Structure table.

**Interfaces:**
- Consumes: Task 2's token file; hetops-3's sealing key.
- Produces: Gatus at `http://100.89.67.82:8080` (dashboard, `/health`, `/api/v1/endpoints/watchers_lab-alerting/external`). The heartbeat token value lives only in the lab's `/tmp/lab-alerting-token` (mode 0600) until Task 5 seals it again for the lab, then is deleted.

- [ ] **Step 1: Branch**

```bash
cd /c/Users/HetPatel/Personal/HetOps/hetops-k8s-lab && git checkout main && git pull --ff-only && git checkout -b feat/outside-watcher
```

- [ ] **Step 2: hetops-3's public sealing certificate into git** (public: it can only seal, never open)

```bash
mkdir -p clusters/ops/sealed-secrets
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 "kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d" > clusters/ops/sealed-secrets/ops-cert.pem
openssl x509 -in clusters/ops/sealed-secrets/ops-cert.pem -noout -subject -enddate
```

Expected: a subject and an end date about 10 years out. The file starts with `-----BEGIN CERTIFICATE-----` and contains no `PRIVATE KEY`.

- [ ] **Step 3: Seal `gatus-secrets` on the lab with that certificate** (the token goes from the file into the pipe; nothing is printed)

```bash
scp clusters/ops/sealed-secrets/ops-cert.pem ubuntu@140.245.13.138:/tmp/ops-cert.pem
tr -d '\r\n' < ~/.secrets/gatus-bot-token | ssh ubuntu@140.245.13.138 'umask 077; openssl rand -hex 32 | tr -d "\n" > /tmp/lab-alerting-token; kubectl create secret generic gatus-secrets -n watch --from-file=TELEGRAM_TOKEN=/dev/stdin --from-literal=TELEGRAM_CHAT_ID=718892351 --from-file=LAB_ALERTING_TOKEN=/tmp/lab-alerting-token --dry-run=client -o yaml | kubeseal --cert /tmp/ops-cert.pem --format yaml' > clusters/ops/gatus/sealed-gatus-secrets.yaml
grep -cE 'kind: SealedSecret|namespace: watch|TELEGRAM_TOKEN:|TELEGRAM_CHAT_ID:|LAB_ALERTING_TOKEN:' clusters/ops/gatus/sealed-gatus-secrets.yaml
```

Expected: `5` or more (kind, namespace, three encrypted keys). Neither token passes through a command line (`ps` never shows it) and neither carries a newline: `tr -d` strips the file's line ending, and the heartbeat token is written without one, so the bearer token compares exactly on both sides. `/tmp/lab-alerting-token` stays on the lab (mode 0600) for Task 5.

- [ ] **Step 4: The manifests**

`clusters/ops/gatus/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: watch
resources:
  - namespace.yaml
  - config.yaml
  - sealed-gatus-secrets.yaml
  - deployment.yaml
```

`clusters/ops/gatus/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: watch
```

`clusters/ops/gatus/config.yaml`:

```yaml
# The outside watcher's checks (sub-project 1, 28 Oct). Translated from Uptime Kuma's monitors on the lab;
# Kuma keeps the backup and self-test checks, which report job results rather than whether something is up.
# Gatus reloads this file when it changes. ${VARS} come from the SealedSecret gatus-secrets.
apiVersion: v1
kind: ConfigMap
metadata:
  name: gatus-config
data:
  config.yaml: |
    storage:
      type: memory
    web:
      port: 8080
    ui:
      title: HetOps outside watcher
      header: Outside watcher (hetops-3)
    alerting:
      telegram:
        token: "${TELEGRAM_TOKEN}"
        id: "${TELEGRAM_CHAT_ID}"
        default-alert:
          failure-threshold: 3
          success-threshold: 2
          send-on-resolved: true

    default-endpoint: &check
      interval: 60s
      alerts:
        - type: telegram

    endpoints:
      - <<: *check
        name: Portfolio
        group: sites
        url: https://hetops.dev
        conditions: ["[STATUS] < 300", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Tools
        group: sites
        url: https://tools.hetops.dev/
        conditions: ["[STATUS] < 300", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Hub
        group: sites
        url: https://hub.hetops.dev/login
        conditions: ["[STATUS] < 300", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Dashboard
        group: sites
        url: https://dash.hetops.dev
        conditions: ["[STATUS] < 300", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Tallybank
        group: sites
        url: https://tally.hetops.dev
        conditions: ["[STATUS] < 300", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: DNS Intelligence
        group: products
        url: https://dns.hetops.dev/api/health
        conditions: ["[STATUS] < 300", "[BODY].status == ok", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Radar Cloud
        group: products
        url: https://radar.hetops.dev/api/health
        conditions: ["[STATUS] < 300", "[BODY].ok == true", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Analytics
        group: products
        url: https://analytics.hetops.dev/api/heartbeat
        conditions: ["[STATUS] < 300", "[BODY].ok == true", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: n8n
        group: products
        url: https://n8n.hetops.dev/healthz
        conditions: ["[STATUS] < 300", "[BODY].status == ok", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Restore Drill
        group: products
        url: https://drill.hetops.dev/api/health
        conditions: ["[STATUS] < 300", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Status page
        group: watchers
        url: https://status.hetops.dev/api/status-page/deck
        conditions: ["[STATUS] < 300", "len([BODY].publicGroupList) > 0", "[CERTIFICATE_EXPIRATION] > 336h"]
      - <<: *check
        name: Lab gateway
        group: watchers
        url: https://lab.hetops.dev/timeline
        conditions: ["[STATUS] < 300", "[CERTIFICATE_EXPIRATION] > 336h"]

    # The lab's Alertmanager pushes its always-firing Watchdog alert here every 5 minutes. No push for 15 minutes
    # means the lab's alerting (or the lab) is down. Key: watchers_lab-alerting.
    external-endpoints:
      - name: lab-alerting
        group: watchers
        token: "${LAB_ALERTING_TOKEN}"
        heartbeat:
          interval: 15m
        alerts:
          - type: telegram
            failure-threshold: 1
            description: "No heartbeat from the lab's Alertmanager for 15 minutes"
```

`clusters/ops/gatus/deployment.yaml`:

```yaml
# Gatus, reachable only over Tailscale: the hostPort is bound to hetops-3's Tailscale address, so the CNI forwards
# 8080 only for traffic to 100.89.67.82; the public IP gets nothing.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gatus
spec:
  replicas: 1
  strategy: { type: Recreate }          # one hostPort, one pod: never two at once
  selector:
    matchLabels: { app: gatus }
  template:
    metadata:
      labels: { app: gatus }
      annotations:
        hetops.dev/config-version: "1"  # bump to restart Gatus on a config change it does not pick up itself
    spec:
      containers:
        - name: gatus
          image: ghcr.io/twin/gatus:v5.37.0
          ports:
            - containerPort: 8080
              hostPort: 8080
              hostIP: 100.89.67.82
          envFrom:
            - secretRef: { name: gatus-secrets }
          volumeMounts:
            - { name: config, mountPath: /config }
          readinessProbe:
            httpGet: { path: /health, port: 8080 }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health, port: 8080 }
            periodSeconds: 30
            failureThreshold: 4
          resources:
            requests: { cpu: 20m, memory: 32Mi }
            limits: { memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
      volumes:
        - name: config
          configMap: { name: gatus-config }
```

`clusters/ops/apps/gatus.yaml`:

```yaml
# The outside watcher (sub-project 1): Gatus checks the public HetOps sites from outside the lab.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gatus
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Het101/hetops-k8s-lab.git
    targetRevision: main
    path: clusters/ops/gatus
  destination: { server: https://kubernetes.default.svc, namespace: watch }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

- [ ] **Step 5: Render and validate before pushing** (on hetops-3, where kubectl has kustomize; server-side dry run against the real cluster)

```bash
tar -C clusters/ops -cf - gatus | ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'rm -rf /tmp/gatus && mkdir /tmp/gatus && tar -C /tmp -xf - && kubectl kustomize /tmp/gatus > /tmp/gatus.yaml && kubectl apply --dry-run=server -f /tmp/gatus.yaml 2>&1 | tail -n 6; rm -rf /tmp/gatus /tmp/gatus.yaml'
```

Expected: `namespace/watch created (server dry run)` and the other objects `created (server dry run)`, except possibly a "namespaces watch not found" for namespaced objects (the namespace doesn't exist yet in a dry run) — that line alone is acceptable. Any schema error is not: fix and re-run.

- [ ] **Step 6: Commit, PR, merge after checks**

```bash
git add clusters/ops && git commit -m "feat(ops): the outside watcher, Gatus on hetops-3"
export GH_TOKEN=$(gh auth token --user Het101)
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin feat/outside-watcher
gh pr create --repo Het101/hetops-k8s-lab --base main --head feat/outside-watcher --title "feat(ops): the outside watcher, Gatus on hetops-3" --body "Sub-project 1, Task 3: Gatus v5.37.0 in namespace watch on hetops-3, 12 checks + the lab-alerting heartbeat, Telegram alerts, hostPort on the Tailscale IP only. hetops-3's public sealing certificate goes into clusters/ops/sealed-secrets/."
gh pr checks <n> --repo Het101/hetops-k8s-lab --watch && gh pr merge <n> --repo Het101/hetops-k8s-lab --squash --delete-branch
```

- [ ] **Step 7: Argo CD syncs it; Gatus answers over Tailscale only**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n argocd get application gatus; kubectl -n watch rollout status deploy/gatus --timeout=180s; kubectl -n watch get pods -o wide; curl -s --max-time 5 http://100.89.67.82:8080/health; echo'
ssh ubuntu@140.245.13.138 'curl -s --max-time 5 http://100.89.67.82:8080/health; echo'
curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://130.210.37.122:8080/health || true
```

Expected: application `Synced Healthy`; pod Running; `{"status":"UP"}` from hetops-3 and from the lab; `000` from the laptop's public path. If the Argo app is not created within 3 minutes, `kubectl -n argocd get application root` and its events say why.

- [ ] **Step 8: Every check green, and no alert storm**

```bash
ssh ubuntu@140.245.13.138 'curl -s http://100.89.67.82:8080/api/v1/endpoints/statuses | python3 -c "import sys,json; [print(e[\"group\"], e[\"name\"], (e[\"results\"] or [{}])[-1].get(\"success\")) for e in json.load(sys.stdin)]"'
```

Expected after 2 minutes: 12 endpoints `True`, and `watchers lab-alerting` present (no result yet: Task 5 starts its pushes). Telegram has received no failure alert. If a check is `False`, read its `conditionResults` (same URL, full JSON) and fix the condition in a follow-up PR before going on.

- [ ] **Step 9: Journal** — Part 13: every command, the sealing (never the values), the outputs.

Note: the `lab-alerting` heartbeat will alert 15 minutes after Gatus starts if Task 5 is not done by then. Do Task 5 immediately after this task, or expect (and record) one Telegram "no heartbeat" alert.

---

### Task 4: Every check is proven to fail and recover

**Files:** none in git (a temporary, reverted in-cluster change).

- [ ] **Step 1: Stop Argo CD reverting the test change, for this test only**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n argocd patch application gatus --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":null}}}" && kubectl -n argocd get application gatus -o jsonpath="{.spec.syncPolicy}"; echo'
```

Expected: `{}` (no automated sync).

- [ ] **Step 2: Break every check at once** (each URL gets a path that does not exist)

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n watch get configmap gatus-config -o yaml | sed -E "s#(url: https://[^ ]+)#\1/__gatus-fail-test#" | kubectl apply -f - && kubectl -n watch rollout restart deploy/gatus && kubectl -n watch rollout status deploy/gatus --timeout=120s'
```

- [ ] **Step 3: Within about 4 minutes, Telegram shows a failure alert for each of the 12 checks.** Count them with the owner, and in Gatus:

```bash
ssh ubuntu@140.245.13.138 'curl -s http://100.89.67.82:8080/api/v1/endpoints/statuses | python3 -c "import sys,json; print(sum(1 for e in json.load(sys.stdin) if e[\"results\"] and not e[\"results\"][-1][\"success\"]))"'
```

Expected: `12`. A check that does not fail on a wrong path (a site returning 200 for any path, e.g. a single-page app) is a finding: write it down, and give that check a body condition that a wrong path cannot meet, in a follow-up PR.

- [ ] **Step 4: Put it back, and let Argo CD own it again**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n argocd patch application gatus --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":true,\"selfHeal\":true}}}}" && sleep 60 && kubectl -n argocd get application gatus && kubectl -n watch get configmap gatus-config -o yaml | grep -c __gatus-fail-test; kubectl -n watch rollout restart deploy/gatus'
```

Expected: application `Synced`; `0` test paths left. Within about 3 minutes, Telegram shows 12 "resolved" messages.

- [ ] **Step 5: Journal** — Part 13: the count of alerts and recoveries, any check that did not fail.

---

### Task 5: The lab's Alertmanager heartbeats into Gatus (PR D)

**Files:**
- Modify: `platform/monitoring/values.yaml`, `platform/monitoring/extras/kustomization.yaml`
- Create: `platform/monitoring/extras/sealed-alertmanager-watchdog.yaml`

**Interfaces:**
- Consumes: Task 1's `HEARTBEAT_SENDER`; `/tmp/lab-alerting-token` on the lab (Task 3).
- Produces: a push to `watchers_lab-alerting` every 5 minutes.

- [ ] **Step 1: Branch, and seal the same token for the lab** (the lab's own controller; the file is then deleted)

```bash
cd /c/Users/HetPatel/Personal/HetOps/hetops-k8s-lab && git checkout main && git pull --ff-only && git checkout -b feat/watchdog-heartbeat
ssh ubuntu@140.245.13.138 'kubectl create secret generic alertmanager-watchdog -n monitoring --from-file=token=/tmp/lab-alerting-token --dry-run=client -o yaml | kubeseal --format yaml' > platform/monitoring/extras/sealed-alertmanager-watchdog.yaml
ssh ubuntu@140.245.13.138 'shred -u /tmp/lab-alerting-token /tmp/ops-cert.pem; ls /tmp/lab-alerting-token 2>&1'
```

Expected: a SealedSecret `alertmanager-watchdog` in `monitoring` with one key `token`; then `No such file or directory`.

- [ ] **Step 2 (if `HEARTBEAT_SENDER=alertmanager`): route and receiver**

In `platform/monitoring/extras/kustomization.yaml`, after `- sealed-alertmanager-timeline.yaml` add:

```yaml
- sealed-alertmanager-watchdog.yaml
```

In `platform/monitoring/values.yaml`:
- the `secrets:` line becomes
  `secrets: [alertmanager-telegram, alertmanager-timeline, alertmanager-watchdog]   # mounted at /etc/alertmanager/secrets/<name>/`
- under `routes:`, FIRST in the list, add:

```yaml
      # The dead-man's switch (sub-project 1, 28 Oct): the always-firing Watchdog alert goes to the outside watcher
      # on hetops-3 every 5 minutes. If it stops, Gatus alerts on its own Telegram bot.
      - receiver: watchdog
        matchers: ['alertname="Watchdog"']
        group_wait: 0s
        group_interval: 1m
        repeat_interval: 5m
```

- under `receivers:`, after `- name: "null"`, add:

```yaml
    - name: watchdog                       # Gatus external endpoint on hetops-3, over Tailscale
      webhook_configs:
      - url: http://100.89.67.82:8080/api/v1/endpoints/watchers_lab-alerting/external?success=true
        send_resolved: false
        http_config:
          authorization:
            type: Bearer
            credentials_file: /etc/alertmanager/secrets/alertmanager-watchdog/token
```

- [ ] **Step 2b (only if `HEARTBEAT_SENDER=hostnetwork-cronjob`): a CronJob on the lab host's network instead**

Keep the `extras/kustomization.yaml` line and the `secrets:` line out; create `platform/monitoring/extras/watchdog-heartbeat.yaml` and list it in `extras/kustomization.yaml`:

```yaml
# The dead-man's switch (sub-project 1): pods on the lab cannot reach the tailnet, so this runs on the host's
# network and pushes the heartbeat to the outside watcher on hetops-3 every 5 minutes.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: watchdog-heartbeat
  namespace: monitoring
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 3600
      backoffLimit: 0
      template:
        spec:
          hostNetwork: true
          restartPolicy: Never
          containers:
            - name: push
              image: curlimages/curl:8.11.1
              command: ["sh", "-c"]
              args:
                - curl -sf --max-time 10 -X POST -H "Authorization: Bearer $(cat /token/token)" "http://100.89.67.82:8080/api/v1/endpoints/watchers_lab-alerting/external?success=true"
              volumeMounts: [{ name: token, mountPath: /token, readOnly: true }]
          volumes:
            - name: token
              secret: { secretName: alertmanager-watchdog }
```

(This heartbeat proves the lab's cluster and network are alive, not Alertmanager itself; record that difference in the journal.)

- [ ] **Step 3: Render the chart change before pushing** (the Helm inside argocd-repo-server, as the lab does)

```bash
ssh ubuntu@140.245.13.138 'kubectl -n argocd get application monitoring -o jsonpath="{.status.sync.status} {.status.health.status}"; echo'
```

Expected now: `Synced Healthy` (baseline). After merging, the same command must return to `Synced Healthy`.

- [ ] **Step 4: Commit, PR, merge after checks**

```bash
git add platform/monitoring && git commit -m "feat(monitoring): Watchdog heartbeats the outside watcher"
export GH_TOKEN=$(gh auth token --user Het101)
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin feat/watchdog-heartbeat
gh pr create --repo Het101/hetops-k8s-lab --base main --head feat/watchdog-heartbeat --title "feat(monitoring): Watchdog heartbeats the outside watcher" --body "Sub-project 1, Task 5: the lab's always-firing Watchdog goes to Gatus on hetops-3 every 5 minutes over Tailscale (dead-man's switch). No other route changes."
gh pr checks <n> --repo Het101/hetops-k8s-lab --watch && gh pr merge <n> --repo Het101/hetops-k8s-lab --squash --delete-branch
```

- [ ] **Step 5: The heartbeat arrives**

```bash
ssh ubuntu@140.245.13.138 'kubectl -n argocd get application monitoring -o jsonpath="{.status.sync.status} {.status.health.status}"; echo; kubectl -n monitoring get secret alertmanager-watchdog -o jsonpath="{.data.token}" | wc -c'
```

Wait up to 6 minutes, then:

```bash
ssh ubuntu@140.245.13.138 'curl -s http://100.89.67.82:8080/api/v1/endpoints/watchers_lab-alerting/statuses | python3 -c "import sys,json; r=json.load(sys.stdin)[\"results\"]; print(len(r), r[-1][\"success\"] if r else None)"'
```

Expected: `Synced Healthy`; a non-zero token length; then at least 1 result, `True`. If Alertmanager's log shows `401`, the two sealed tokens differ: both must come from the same `/tmp/lab-alerting-token` (Task 3 Step 3, Task 5 Step 1). Logs: `kubectl -n monitoring logs alertmanager-kps-kube-prometheus-stack-alertmanager-0 -c alertmanager --since 10m | grep -i watchdog`.

- [ ] **Step 6: Journal** — Part 13: commands, the first heartbeat, the route added.

---

### Task 6: Both directions of the dead-man's switch fire and recover

**Files:** none in git. Changes: an Alertmanager silence (expires by itself), one Kuma monitor (owner), Gatus scaled to 0 and back.

- [ ] **Step 1: Lab to hetops-3 — silence the Watchdog for 20 minutes**

```bash
ssh ubuntu@140.245.13.138 'kubectl -n monitoring exec alertmanager-kps-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool silence add alertname=Watchdog --duration=20m --comment="sub-project 1 dead-mans-switch test" --author=claude --alertmanager.url=http://localhost:9093'
```

Expected: a silence ID. Within 15 to 20 minutes, Telegram shows the `lab-alerting` failure ("No heartbeat from the lab's Alertmanager for 15 minutes"). After the silence expires (20 min), the next heartbeat (within 5 min) resolves it on Telegram. Record both times. (With the CronJob sender, test instead with `kubectl -n monitoring patch cronjob watchdog-heartbeat -p '{"spec":{"suspend":true}}'` for 20 minutes, then `false`.)

- [ ] **Step 2 (owner): Kuma watches Gatus**

In status.hetops.dev (logged in): **Add New Monitor** → type **HTTP(s)** → Friendly name `Ops watcher (hetops-3)` → URL `http://100.89.67.82:8080/health` → Heartbeat interval `60` → Retries `2` → Notifications: tick **My Brevo Alert (1)** → **Save**. Not on any public status page. (If Task 1 Step 4 failed, the URL cannot be reached from Kuma's container: skip this step and record that the reverse direction is not yet covered.)

- [ ] **Step 3: hetops-3 to the lab — stop Gatus, Kuma must email**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n argocd patch application gatus --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":null}}}" && kubectl -n watch scale deploy/gatus --replicas=0'
```

Expected: within about 3 minutes, an email from Kuma that "Ops watcher (hetops-3)" is down. Then:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n argocd patch application gatus --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":true,\"selfHeal\":true}}}}" && sleep 60 && kubectl -n watch get deploy gatus'
```

Expected: `1/1` again (Argo CD restored the replica count); Kuma emails "up". Gatus restarting with empty history may send a Telegram "lab-alerting" alert if no push arrives in 15 minutes; the next Watchdog push (5 min) arrives first, so none is expected.

- [ ] **Step 4: Journal** — Part 13: both directions with times.

---

### Task 7: Prove it holds, and close

- [ ] **Step 1: Resource use and exposure, the next day**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n watch top pod 2>/dev/null || kubectl -n watch exec deploy/gatus -- cat /sys/fs/cgroup/memory.current'
curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://130.210.37.122:8080/health || true
ssh ubuntu@140.245.13.138 'curl -s http://100.89.67.82:8080/api/v1/endpoints/watchers_lab-alerting/statuses | python3 -c "import sys,json; r=json.load(sys.stdin)[\"results\"]; print(len(r), all(x[\"success\"] for x in r[-12:]))"'
```

Expected: under 100 MiB (no metrics-server on hetops-3, so the cgroup value in bytes is the fallback: under 104857600); `000` publicly; recent heartbeats all `True`.

- [ ] **Step 2: Close out** — the spec's five "Done when" checks with their evidence in Part 13; a Start here progress item; memory `oci-hetops-3.md` notes sub-project 1 done.
