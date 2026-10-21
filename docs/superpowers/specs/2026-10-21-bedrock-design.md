# Bedrock: the server under the lab, as code

**Status:** design, 21 Oct 2026. Lives in `bedrock/` in this repo.

## Why

Everything inside Kubernetes is in git, and Argo CD puts it back. The server underneath is not. It is one Oracle ARM VM (4 CPU, 24 GiB, Ubuntu, arm64), shared with Coolify and every live hetops.dev site. kubeadm, containerd, kernel modules, sysctls, SSH, updates and the API server audit policy (`platform/host/enable-audit.sh`) were all set up by hand. If the VM died, the repo could rebuild the cluster's contents but not the machine.

Bedrock is an Ansible playbook for that layer. Three claims, each with proof:

1. **It describes the real server.** A check-mode run against the live VM reports zero changes.
2. **It can rebuild from nothing.** CI runs it on a fresh arm64 Ubuntu machine, brings up a one-node cluster and records the time.
3. **It notices hand changes.** A nightly check-mode run on the VM reports drift to the Change Timeline (new source `ansible`) and to status.hetops.dev.

Restore Drill proves the data comes back. Bedrock proves the machine comes back.

## Scope

**In:**
- the OS baseline (packages, unattended upgrades, kernel modules, sysctls, swap, SSH hardening, journald);
- containerd and the kube packages at pinned versions;
- the audit policy and its API server flags.

**Out:**
- **Coolify and the sites it runs.** Coolify installs and manages its own Docker; Bedrock only checks that it does not break it.
- **Anything Argo CD owns.**
- **Secrets.** The SSH keys and the Cloudflare tunnel token stay where they are; Ansible Vault is used only when a role needs one.

## Rules

- **Adopt, don't rebuild.** On the live VM, a role is done when `--check --diff` reports `changed=0`. A role that would change the server is either wrong about the server, or the change is deliberate and gets its own predict → apply → verify step.
- **Commands are read-only or don't exist.** `command`/`shell` tasks run in check mode only when they are pure reads (`check_mode: false`, `changed_when: false`). Everything that changes state uses a module that supports check mode.
- **SSH changes need a second open session.** A bad `sshd_config` must not lock the owner out.
- **One host, localhost.** The VM runs Ansible against itself (`ansible_connection=local`). CI uses the same playbook against its own machine. No laptop, no WSL.

## Phases

| Phase | Result |
|---|---|
| 1 Adopt | Ansible installed on the VM; ad-hoc discovery writes down what the server really is; roles `base`, `kubernetes` and `audit` describe it; check mode reports `changed=0` |
| 2 Roles | Real roles: templates, handlers (the API server restarts only when the audit policy changes), tags, variables; SSH hardening applied for real (two-session rule); `enable-audit.sh` retired |
| 3 Rebuild in CI | GitHub Actions `ubuntu-24.04-arm`: playbook, `kubeadm init`, a test pod Running, a second run with `changed=0` (idempotence), time recorded; `ansible-lint` |
| 4 Drift watch | systemd timer, nightly check mode; changed tasks posted to the Change Timeline (`source: ansible`, owner and public view) and a Kuma push monitor |
| 5 Portfolio | Lab page "Below Kubernetes" panel: last drift check, last rebuild time |

## Risks

- **A shared host.** A wrong apply could take every site down, not just the lab. Hence check mode first, and applies only with a stated prediction.
- **kubeadm in CI.** It may need more than a fresh runner gives (cgroup, swap, ports). If so, Phase 3 proves the OS and containerd layers and records the gap.
