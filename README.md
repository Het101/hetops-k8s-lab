# HetOps Kubernetes lab

A real cluster you can break at [lab.hetops.dev](https://lab.hetops.dev): pick a failure, and Kubernetes and Argo CD put it back. Everything in it is declared in this repo: the servers (Ansible), the cluster (kubeadm), and every workload (Argo CD).

## Architecture

Two Oracle Cloud A1 servers in Mumbai (Arm, Ubuntu 24.04, Always Free). Each runs its own single-node cluster.

```
                    git (this repo)
        ┌─────────────────┴──────────────────┐
        │ Argo CD syncs argo/ (lab only)     │ Bedrock: ansible-playbook, run from the lab
        ▼                                    ▼
┌──────────── lab (production) ────────────┐        SSH, key accepted only        ┌──── vm2 (staging) ────┐
│ 140.245.13.138 · my-workspace            │──────── from the lab's IP ──────────▶│ 140.238.224.158       │
│                                          │                                      │                       │
│ Kubernetes (kubeadm), Calico             │                                      │ Kubernetes (kubeadm)  │
│  ├ apps: clinic, clinic-data, chaos,     │                                      │ Calico, audit log     │
│  │       timeline                        │                                      │ nothing else: a place │
│  ├ platform: Gateway (NGINX), Linkerd,   │                                      │ for changes to land   │
│  │   cloudflared, CrowdSec, Falco,       │                                      │ first                 │
│  │   Prometheus/Grafana, ELK             │                                      └───────────────────────┘
│ Docker + Coolify: every live HetOps site │
│ (one containerd shared by both, held)    │
└──────────────────▲───────────────────────┘
                   │ Cloudflare Tunnel (two cloudflared replicas)
           visitors: lab.hetops.dev
```

- **Production is one server.** The lab cluster *and* every live HetOps site (Coolify) share it, so anything that restarts the runtime or the node restarts everything. That is why changes are rehearsed twice before they reach it: on a throwaway cluster in CI, then on staging.
- **Staging (vm2) mirrors the lab's host layer** (same roles, same versions, from one file: `bedrock/group_vars/k8s.yml`) but not its workloads. It runs ahead of the lab during an upgrade (pinned in `bedrock/group_vars/staging.yml`).
- **Each node manages its own cluster.** Ansible's Kubernetes tasks run on the node, against that node's kubeconfig; a guard refuses to run if a kubeconfig points at another server's API.

## The layers, and who owns each

| Layer | Owner | Where |
|---|---|---|
| OS, SSH, packages, containerd, kubelet, kubeadm cluster, audit policy | Bedrock (Ansible) | [`bedrock/`](bedrock/README.md) |
| Workloads, platform services, dashboards | Argo CD (app of apps) | [`argo/`](argo), [`platform/`](platform), [`apps/`](apps), [`security/`](security) |
| Secrets | Sealed Secrets: only the encrypted form is in git | `*/sealed-*.yaml` |
| Failure drills | chaos-api, nightly self-test 21:30 UTC | [`docs/gameday.md`](docs/gameday.md), [`scripts/`](scripts) |
| What changed, when, by whom | Change Timeline (lab.hetops.dev/timeline): Argo syncs, chaos runs, Bedrock drift | [`apps/timeline`](apps/timeline) |

## Daily rhythm (UTC)

| When | What |
|---|---|
| 21:30 | chaos self-test: every experiment runs and must heal |
| 02:30 | Bedrock drift check: `site.yml --check` against both servers, reported to the timeline |
| daily | unattended-upgrades installs security updates on both servers (reboots are reported, never done) |

## Changing things

Every change is a pull request. CI lints it, rebuilds a server from a blank machine with Bedrock, and rehearses the next Kubernetes upgrade. After merge, Argo CD syncs workloads within minutes. Host changes go out with Bedrock, staging first: see [`bedrock/README.md`](bedrock/README.md).
