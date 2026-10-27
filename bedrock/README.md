# Bedrock: the fleet as code

Ansible for everything under Kubernetes, on every server: the OS, SSH, packages, containerd, the kubeadm cluster and its audit logging. Run from this folder on the **lab server** (the control node); `ansible.cfg` here picks the inventory and roles.

## The fleet

| Host | Group | Reached by | Role |
|---|---|---|---|
| `my-workspace` (140.245.13.138) | `lab` | local connection | production + the control node |
| `vm2` (140.238.224.158) | `staging` | SSH as `ubuntu` with `~/.ssh/bedrock_fleet`, pinned host key | gets every change first |
| `hetops-3` (130.210.37.122) | `ops` | SSH as `ubuntu` with `~/.ssh/bedrock_fleet`, pinned host key | the ops cluster: tools the lab relies on, its own Argo CD (`clusters/ops/`) |

`k8s` is the parent of all three groups: [`group_vars/k8s.yml`](group_vars/k8s.yml) holds the versions every Kubernetes node shares. The fleet key is accepted only from the lab's IP (`from="140.245.13.138"` in vm2's `authorized_keys`).

Variable precedence, lowest first: role defaults < `group_vars/all` < `group_vars/k8s.yml` < `group_vars/lab.yml` / `staging.yml` / `ops.yml` < `host_vars/` < `-e`.

## Playbooks

| Playbook | What | Hosts |
|---|---|---|
| [`site.yml`](site.yml) | the whole fleet, from the OS up. `--check --diff` describes the live servers (`changed=0`); on a blank machine it builds one | all → `k8s` → `ops` → `lab` |
| [`patch.yml`](patch.yml) | every apt update (held packages stay held) | staging and ops, then the lab with `-e patch_lab=true` |
| [`upgrade.yml`](upgrade.yml) | one Calico or Kubernetes step, values from `upgrades/<minor>.yml` | staging and ops, then the lab with `-e upgrade_lab=true` |
| [`reboot.yml`](reboot.yml) | reboots a server with a reboot pending (or any, with `-e reboot_force=true`), then waits until every pod is Ready | staging and ops, then the lab with `-e reboot_lab=true` |

Roles: `common` (every server: SSH hardening, unattended-upgrades, reboot report) · `base`, `kubernetes`, `cluster`, `audit` (every Kubernetes node) · `drift` (the control node: the nightly check) · `tailscale`, `argocd` (the ops cluster: the private link, and its own Argo CD).

## Staging and ops first

`patch.yml`, `upgrade.yml` and `reboot.yml` run staging and ops as a canary: one server at a time, and any failure there (`any_errors_fatal`) ends the run before the lab play starts. The lab play skips itself unless its opt-in is passed. So the safe default of every command is "staging and ops only".

```bash
ansible-playbook site.yml --check --diff                                   # both servers: is anything different from git?
ansible-playbook site.yml --limit staging                                  # apply to staging only
ansible-playbook patch.yml                                                 # patch staging
ansible-playbook patch.yml -e patch_lab=true                               # staging, then the lab
ansible-playbook upgrade.yml -e @upgrades/1.34.yml --tags kubernetes       # staging
ansible-playbook upgrade.yml -e @upgrades/1.34.yml --tags kubernetes -e upgrade_lab=true   # then the lab
```

Long runs (upgrades, patches): start them detached so a dropped SSH session cannot stop them halfway, and read the log:

```bash
systemd-run --user --unit=bedrock-run --working-directory=$PWD -E PATH=$PATH -E HOME=$HOME -E USER=$USER \
  bash -c 'ansible-playbook upgrade.yml -e @upgrades/1.34.yml --tags kubernetes > /tmp/bedrock-run.log 2>&1'
```

## Upgrading Kubernetes

One minor at a time (kubeadm's rule), each one in its own `upgrades/<minor>.yml`:

1. CI rehearses every pending step on a throwaway cluster built at the step's starting version (`upgrade_from_vars`).
2. Run it on staging (Calico tag first if Calico moves, then `kubernetes`). Pin staging's new versions in `group_vars/staging.yml`, so the drift check describes it as it now is.
3. Run it on the lab in a window the owner picks (the lab runs every live site), with `-e upgrade_lab=true`.
   A server already past a step skips it, so staging (ahead) never blocks the lab catching up.
4. Move the values into `group_vars/k8s.yml` and take the pins out of `staging.yml`.

Calico only ever moves up: a step never pulls a newer Calico back down. Today (25 Oct) both servers run
Kubernetes 1.35.9, etcd 3.6.6, Calico 3.31.7. 1.35 is supported until 28 Feb 2027; 1.36 will need Calico 3.32.

Before applying, each run snapshots etcd to `/var/lib/etcd/bedrock-before-<version>.db`, refuses while a chaos job is running, and afterwards checks the node is Ready on the new version and the API server still has every audit flag.

## Drift

`bedrock-drift.timer` on the lab runs `site.yml --check` against the whole fleet at 02:30 UTC and posts one result per server to the Change Timeline. A server it cannot reach counts as a failure, not as "no drift".

## Adding a server

1. On the new server: an `ubuntu` user with passwordless sudo, Ubuntu 24.04, arm64.
2. Put the fleet public key in its `authorized_keys` with `from="140.245.13.138"`, and add its host key to the lab's `~/.ssh/known_hosts` after checking the fingerprint out of band.
3. Add it to `inventory.ini` under the group that says what it is for (`[staging]`, or a new group with its own `group_vars`).
4. `ansible-playbook site.yml --check --limit <host>`, then without `--check`, then once more: `changed=0`.

CI ([`.github/workflows/bedrock.yml`](../.github/workflows/bedrock.yml)) uses [`tests/ci-inventory.ini`](tests/ci-inventory.ini): the runner builds itself as the lab and never reaches the real fleet.
