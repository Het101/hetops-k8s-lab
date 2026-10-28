# The outside watcher

**Status:** design, 28 Oct 2026. Sub-project 1 of 5 of the ops cluster ([design](2026-10-27-ops-cluster-design.md)). Lives in `clusters/ops/` (hetops-3) and one change to `platform/monitoring/values.yaml` (the lab).

## Why

Everything that watches HetOps runs on the lab server (140.245.13.138): Uptime Kuma (status.hetops.dev, 13 monitors, email through Brevo) and the lab's Prometheus and Alertmanager (Telegram and the Change Timeline). If the lab server dies, the watcher and the alarm die with it, and nobody is told.

The outside watcher runs on hetops-3, a separate Oracle account and machine. It checks the public sites from outside, and the two sides watch each other, so either one going silent is noticed.

## Decisions (owner, 28 Oct)

- **Scope:** every public site and health endpoint Kuma checks today, plus the watchers themselves (status.hetops.dev, the lab's alerting via a dead-man's switch).
- **Alerts:** Telegram, through a **new bot** only hetops-3 knows, to the same chat as today (`718892351`).
- **No public page.** status.hetops.dev stays the one public status page; the watcher's own page is reachable only over Tailscale.
- **Gatus** (not a second Kuma, not a Prometheus blackbox stack): one small process whose checks are one YAML file in git, with Telegram alerts and heartbeat endpoints built in.
- **vm2 does not join Tailscale** for this; nothing here talks to it. Moving all fleet SSH onto Tailscale is a possible later hardening step of its own.

## Design

### Gatus on hetops-3

- Argo CD app `clusters/ops/apps/gatus.yaml`, manifests in `clusters/ops/gatus/`: namespace `watch`, one Deployment of `ghcr.io/twin/gatus:v5.37.0` (released 24 Sep 2026), a ConfigMap with `config.yaml`, a SealedSecret.
- Storage: SQLite at `/data/gatus.db`, a hostPath `/var/lib/gatus` on hetops-3 (see Addendum 2).
- **Reachable only over Tailscale:** the pod's port 8080 is a `hostPort` with `hostIP: 100.89.67.82` (hetops-3's Tailscale address), so kube-proxy/CNI forward it only for traffic to that address. Nothing listens for it on the public IP, and Oracle's security list still allows only SSH inbound.
- Resources: requests 20m CPU / 32Mi, limit 128Mi.

### The checks (every 60 s; alert after 3 failures in a row, again on recovery)

Translated from Kuma's monitors as they stand on 28 Oct:

| Check | URL | Condition |
|---|---|---|
| Portfolio | `https://hetops.dev` | status 200 |
| Tools | `https://tools.hetops.dev/` | status 200 |
| Hub | `https://hub.hetops.dev/login` | status 200 (the root redirects to `/login`) |
| Dashboard | `https://dash.hetops.dev` | status 200 |
| Tallybank | `https://tally.hetops.dev` | status 200 |
| DNS Intelligence | `https://dns.hetops.dev/api/health` | status 200, `[BODY].status == ok` |
| Radar Cloud | `https://radar.hetops.dev/api/health` | status 200, `[BODY].ok == true` |
| Analytics | `https://analytics.hetops.dev/api/heartbeat` | status 200, `[BODY].ok == true` |
| n8n | `https://n8n.hetops.dev/healthz` | status 200, `[BODY].status == ok` |
| Restore Drill (site up) | `https://drill.hetops.dev/api/health` | status 200 |
| The status page | `https://status.hetops.dev/api/status-page/deck` | status 200, `len([BODY].publicGroupList) > 0` |
| The lab's gateway | `https://lab.hetops.dev/timeline` | status 200 (the public timeline: tunnel, gateway and cluster all answered) |

Every HTTPS check also alerts when its certificate has under 14 days left (`[CERTIFICATE_EXPIRATION] > 336h`).

Left in Kuma, not here: the two backup checks (DNS and Radar `backup.*` fields), Restore Drill's `ok` (drills passing), and the chaos self-test heartbeat. Those report job results, not whether something is up.

### The dead-man's switch, both ways

- **Lab to hetops-3.** The lab's Alertmanager has an always-firing `Watchdog` alert (kube-prometheus-stack), routed nowhere today. A new route sends `alertname="Watchdog"` to a new receiver `watchdog`, a webhook to Gatus's external endpoint `http://100.89.67.82:8080/api/v1/endpoints/watchers_lab-alerting/external?success=true` with a bearer token, `repeat_interval: 5m`. In Gatus, external endpoint `lab-alerting` (group `watchers`) has `heartbeat.interval: 15m`: no heartbeat for 15 minutes means a Telegram alert that the lab's alerting is silent. The route sits before the others with `continue: true`; nothing else in the routing changes.
- **hetops-3 to the lab.** The lab's Uptime Kuma gets one HTTP monitor, "Ops watcher", on `http://100.89.67.82:8080/health` every 60 s, notifying through the existing Brevo email. Kuma is configured in its UI, so this is a click, written into the journal.
- **Risk decided before building:** the lab's Alertmanager pod must reach `100.89.67.82` over the lab's Tailscale (pod, node, `tailscale0`). This is tested first from a throwaway pod in `monitoring` on the lab. If it fails, the heartbeat comes from a CronJob on the lab instead (`curl` every 5 minutes, same URL and token); the Gatus side is unchanged.

### Secrets

- **hetops-3:** SealedSecret `gatus-secrets` in `watch`, sealed with hetops-3's controller (`kubeseal --controller-namespace kube-system`, run against hetops-3's cluster): the new bot's token, the chat ID, the heartbeat token. Gatus reads them as `${TELEGRAM_TOKEN}`, `${TELEGRAM_CHAT_ID}`, `${LAB_ALERTING_TOKEN}`.
- **Lab:** SealedSecret `alertmanager-watchdog` in `monitoring`, sealed with the lab's controller: the same heartbeat token, mounted like `alertmanager-telegram` (the chart's `secrets:` list) and read with `credentials_file`.
- The owner creates the bot with @BotFather and hands its token over in a file, never in chat. The heartbeat token is random (`openssl rand -hex 32`), generated on the machine that seals it.

## Testing

1. **Every check green** on first sync. Each one is then proven to fail: for a few minutes a copy of the config points every check at a wrong path; each failure must arrive on Telegram, then the config goes back and each recovery arrives.
2. **Lab to hetops-3:** a 20-minute Alertmanager silence on `alertname="Watchdog"` must produce Gatus's "lab-alerting" alert after 15 minutes, and a recovery once the silence ends.
3. **hetops-3 to the lab:** scaling Gatus to 0 must make Kuma's "Ops watcher" email; scaling back must recover it.
4. **Exposure:** from the laptop, `130.210.37.122:8080` must not answer; from the lab, `100.89.67.82:8080/health` must.

## Done when

1. All twelve checks are green, and each was seen failing and recovering on Telegram.
2. Both directions of the dead-man's switch fired and recovered.
3. Port 8080 answers over Tailscale only.
4. Gatus uses under 100 MiB on hetops-3.
5. The journal (Part 13) has every step; Part 11 has any mistake.

## Before it ships (owner)

- Disable key expiry for hetops-3 in the Tailscale admin console, or the link drops around April 2027.
- A tailnet ACL is still open from sub-project 0. This sub-project works without one; it should exist before sub-project 2 sends logs over the link.

## Cost

Nothing new in Oracle: no disk, IP or service. Telegram bots are free. Gatus is open source (Apache 2.0).

## Addendum, 28 Oct: Calico's packet marks clash with Tailscale's

**Found while deploying.** Gatus answered on hetops-3 itself, but not from the lab over Tailscale. A packet capture on hetops-3 showed the lab's request arrive on `tailscale0`, reach the pod through the hostPort, and the pod's reply leave through `enp0s6` (the public card), where it is lost.

**Root cause, proven.** Calico's `raw` table marks every packet coming out of a pod: `cali-PREROUTING -i cali+ -j MARK --set-xmark 0x80000/0x80000`. Tailscale reserves the same bit: its routing rule `5210: from all fwmark 0x80000/0xff0000 lookup main` means "never through the tunnel" (how Tailscale keeps its own traffic from looping). So any pod packet bound for a `100.x` address is routed by the main table, out of the public card. `ip route get 100.93.151.22` on hetops-3 shows it: no mark goes via `tailscale0`; mark `0x80000` goes via `enp0s6`; mark `0x1000000` goes via `tailscale0`. The lab has the same rules, which is why Task 1's pod probe timed out.

**Why the bit is there.** Felix (Calico's agent) picks its mark bits from `iptablesMarkMask`, default `0xffff0000`, which includes Tailscale's whole range `0xff0000`. Neither FelixConfiguration (lab, vm2, hetops-3) sets a mask today.

**Decision (owner: the best solution, no workaround).**
- Every Kubernetes node sets Felix's `iptablesMarkMask` to **`0xff000000`**: 8 bits (Calico's minimum), clear of Tailscale (`0x00ff0000`), kube-proxy (`0x4000`, `0x8000`) and the CNI port mapper (`0x2000`).
- **Bedrock owns it** (`group_vars/k8s.yml` value, `roles/cluster` patches FelixConfiguration `default`), so every rebuild has it and the nightly drift check guards it. CI tests first that no Calico rule sets a bit inside `0xff0000`.
- **Rollout order:** CI, staging (vm2), ops (hetops-3), then the lab only with the owner's go-ahead at a quiet time. Felix restarts itself to apply a new mask.
- **The heartbeat goes back to the original design:** with pods able to reach the tailnet, the lab's Alertmanager sends `Watchdog` to Gatus itself, proving the lab's alerting path, not only its network. The host-network CronJob (PR #143) is closed unmerged; its SealedSecret `alertmanager-watchdog` is reused.
- Gatus keeps its hostPort bound to the Tailscale address; nothing in it changes.

## Addendum 2, 28 Oct: Gatus keeps its state on disk

Task 4 broke all 12 checks and restored them; Gatus was restarted after the restore, and the new process, holding no memory of the alerts, sent no "resolved" messages. The same would happen after any restart during a real outage. Gatus persists triggered alerts across restarts only with SQLite or Postgres storage, so storage is now SQLite at `/data/gatus.db`, on a hostPath `/var/lib/gatus` (hetops-3 is one node). It costs no Oracle resource. Lost only if hetops-3 is rebuilt, which loses history, not configuration. Proven by Task 4b's test: alerts fire, Gatus restarts while they are open, and the "resolved" messages still arrive.
