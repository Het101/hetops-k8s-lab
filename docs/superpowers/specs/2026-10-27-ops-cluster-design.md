# hetops-3: the ops cluster

**Status:** design, 27 Oct 2026. Sub-project 0 of 5. Lives in `bedrock/` and a new `clusters/ops/` in this repo.

## Why

The lab server (140.245.13.138) runs everything: the public chaos lab, its tooling, and every live hetops.dev site through Coolify. Measured 27 Oct: load about 2 on 4 cores, 10 of 23 GiB used. The heaviest parts are lab tooling, not sites: Elasticsearch and Kibana (~2.9 GiB, Kibana the busiest pod), and Coolify's image builds (CPU spikes, a 5.2 GB build cache). And if the server dies, the status page and its alerts die with it.

hetops-3 is a second Oracle A1 VM (4 OCPU, 24 GB, 200 GB) in its own Oracle account, created 26 Oct. It becomes the **ops cluster**: a second one-node Kubernetes cluster, built by Bedrock and deployed by its own Argo CD, that hosts the tools the lab relies on. The live sites do not move.

## The five sub-projects

Each gets its own spec, plan and PRs. This spec is sub-project 0.

| # | Sub-project | Depends on |
|---|---|---|
| 0 | **Bedrock builds hetops-3 as the ops cluster** (this spec) | none |
| 1 | Outside watcher: a second Uptime Kuma and probes, alerting even when the lab is down | 0 |
| 2 | ELK moves: Elasticsearch and Kibana on hetops-3; Filebeat on the lab ships over Tailscale | 0 |
| 3 | Coolify build server: Coolify builds images on hetops-3, apps still run on the lab | 0 |
| 4 | Keycloak: SSO and MFA for Grafana and Argo CD | 0, and 2 proven stable |

## Decisions (owner, 26 to 27 Oct)

- **Nothing on the lab server changes** except through a PR, plus one `known_hosts` line. No live site moves.
- **Bedrock builds the whole thing** (both plays of `site.yml`): proof that git alone rebuilds a Kubernetes server.
- **The lab stays the control node.** Every run that targets hetops-3 uses `--limit hetops-3`.
- **hetops-3 runs its own Argo CD**, so it keeps deploying and healing when the lab is down. The lab's Argo CD never sees it.
- **The link between the servers is Tailscale.** The lab is already on the tailnet. No new public ports.

## Design

### Place in the fleet

- `inventory.ini` gets a group `[ops]` with `hetops-3 ansible_host=130.210.37.122`, and `ops` joins `[k8s:children]`. hetops-3 therefore builds at the versions in `group_vars/k8s.yml` (Kubernetes 1.35.9, containerd 2.2.3, Calico v3.31.7).
- `group_vars/ops.yml` holds the same five connection and API settings as `staging.yml` (user `ubuntu`, `~/.ssh/bedrock_fleet`, the node's own venv and kubeconfig). It duplicates five lines rather than moving staging's into a shared parent, so staging's files stay untouched.

### Access

Follows the README's "Adding a server":

1. The fleet public key goes into hetops-3's `authorized_keys` with `from="140.245.13.138"`.
2. hetops-3's host key (ED25519 `SHA256:BP9GIiDvha8a9+X1ZZt5rn/bxYLiEWCIsAnSNxxnYCY`, read 27 Oct) is checked against the owner's laptop `known_hosts` and pinned in the lab's `known_hosts`.

### The name, before anything else

kubeadm names the node after the hostname, permanently. The machine is `hetops-vnic` (taken from the VNIC), and cloud-init on Oracle images can set it back from the VNIC on boot. So, by hand, before the first Bedrock run:

1. OCI console: the VNIC's private IP, **Edit**, Hostname `hetops-3`.
2. On the box: `sudo hostnamectl set-hostname hetops-3`.
3. Reboot once; `hostname` must still say `hetops-3`.

### The build

From the lab, in `~/hetops-k8s-lab/bedrock`:

1. `ansible-playbook site.yml --check --limit hetops-3`. On a blank machine some tasks fail in check mode (packages not yet installed); the failures are written down, not fixed.
2. `ansible-playbook site.yml --limit hetops-3`, timed. The time is the rebuild number.
3. The same command again: `changed=0`.
4. Checks: `kubectl get nodes` shows `hetops-3` Ready on v1.35.9; Calico pods Running; the API server carries every audit flag; Oracle's FORWARD REJECT is gone (the `base` role already removes it).

### New Bedrock parts

- **`tailscale` role** (group `ops`): Tailscale's apt source and the package pinned at 1.104.2, the lab's version. Joining the tailnet is the owner's step (`sudo tailscale up`, their own login): a login key never goes into git. After that the lab reaches hetops-3 on its `100.x` address.
- **`argocd` role** (group `ops` only): installs Argo CD **v3.5.4** (the lab's version) from its release manifest with server-side apply, only where it is missing, the same way `cluster` installs Calico. Then it applies `clusters/ops/root.yaml`.
- `site.yml` gets a fourth play, **The ops cluster**: `hosts: ops`, roles `tailscale` and `argocd`, after the Kubernetes play.

### clusters/ops/ in git

- `clusters/ops/root.yaml`: an app-of-apps, the same shape as `argo/root.yaml`, path `clusters/ops/apps`. It lives outside `argo/`, so the lab's root app (path `argo`, recursive) never picks it up.
- `clusters/ops/apps/sealed-secrets.yaml`: the sealed-secrets controller **0.40.0** (the lab's version). hetops-3's controller makes its own key, so a secret is sealed for one cluster and cannot be opened on the other. Sub-projects 1 to 4 add their apps next to it.

### Keeping in step

- `patch.yml`, `upgrade.yml` and `reboot.yml` get an `ops` play between staging and the lab: one server at a time, `any_errors_fatal`, no opt-in. The order becomes **staging, then ops, then the lab** (the lab still only with its `-e ..._lab=true`). A failure on staging or ops stops the run before the lab.
- The nightly drift check already covers every host (`hosts: all`), so hetops-3 is checked from the first night after it joins and reported to the Change Timeline.
- CI: `tests/ci-inventory.ini` adds `[ops:children] lab`, so the runner also installs Tailscale's package and Argo CD, rehearsing the new roles on every PR. It checks that Argo CD's pods are Ready but does not wait for a sync: Argo CD reads `main`, and CI is testing a branch. The runner never runs `tailscale up`.
- README: the fleet table, group list and playbook order gain `ops`.

### Cost

hetops-3 already uses its account's whole Always Free allowance (4 OCPU, 24 GB, 200 GB). This sub-project adds no disk, IP or paid service. A budget (`free-tier-guard`) emails on any actual spend over 0.01 and a forecast over 10%.

## Done when

1. `kubectl get nodes` on hetops-3 shows one node, `hetops-3`, Ready on v1.35.9.
2. A second `site.yml --limit hetops-3` run reports `changed=0`.
3. The lab reaches hetops-3 over Tailscale (`tailscale ping hetops-3`).
4. hetops-3's Argo CD shows `root` and `sealed-secrets` Synced and Healthy.
5. The next nightly drift run reports hetops-3 with no drift.
6. The journal's Part 13 has every step and command; Part 11 has any mistake.

## Risks

| Risk | Guard |
|---|---|
| A run without `--limit` also touches the lab | The README and every plan step spell `--limit hetops-3`; `site.yml` on the lab is idempotent (its drift is `changed=0`), and patch/upgrade/reboot keep their lab opt-ins |
| hetops-3's account is closed (Oracle allows one free tier per person) | Nothing lives only there: its state is git, and sub-projects keep data the lab can rebuild |
| Pay As You Go bills anything past the free allowance | No new resources in this sub-project; the budget alerts on 0.01 |
| The hostname changes back on a reboot | Fixed at the VNIC first, checked by a reboot before kubeadm runs |

## Addendum, 28 Oct: two steps when rebuilding hetops-3

1. Restore the sealing key BEFORE Argo starts: `kubectl apply -f ~/.secrets/hetops-3-sealed-secrets-key.yaml` into `kube-system`, ahead of Bedrock's `argocd` role, so the sealed-secrets controller adopts it and existing SealedSecrets (e.g. `gatus-secrets`) still unseal.
2. Re-pin the Tailscale address: after re-joining, set it back to `100.89.67.82` in the Tailscale admin console (Machines, the machine, Edit IP address); git names that address.
