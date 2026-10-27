# hetops-3, the ops cluster: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bedrock builds hetops-3 (130.210.37.122) into a second one-node Kubernetes cluster, the ops cluster, joined to the lab over Tailscale and deployed by its own Argo CD from `clusters/ops/`.

**Architecture:** hetops-3 joins Bedrock's inventory as group `ops` (a child of `k8s`), so `site.yml` builds it at the lab's versions from the lab (the control node) with `--limit hetops-3`. A new play, *The ops cluster*, adds two roles: `tailscale` (package and daemon; the owner joins the tailnet by hand) and `argocd` (Argo CD v3.5.4, then the app-of-apps `clusters/ops/root.yaml`). CI rehearses both roles by making its runner a member of `ops`.

**Tech Stack:** Ansible 14.5.0 (core 2.21), ansible-lint 26.10.1, kubernetes.core, kubeadm 1.35.9, Calico v3.31.7, Argo CD v3.5.4, sealed-secrets 0.40.0, Tailscale 1.104.2, GitHub Actions `ubuntu-24.04-arm`.

**Spec:** [`docs/superpowers/specs/2026-10-27-ops-cluster-design.md`](../specs/2026-10-27-ops-cluster-design.md)

## Global Constraints

- Nothing on the lab server changes except through a merged PR, plus one line in `~/.ssh/known_hosts`.
- Every `ansible-playbook` run that targets hetops-3 carries `--limit hetops-3`.
- Versions: Kubernetes 1.35.9, containerd 2.2.3, Calico v3.31.7 (all from `group_vars/k8s.yml`, unchanged); Argo CD **v3.5.4**; sealed-secrets **0.40.0**; Tailscale **1.104.2**.
- `clusters/ops/` lives outside `argo/`, so the lab's root app (path `argo`, recursive) never reads it.
- No login key, token or private key goes into git. The owner runs `sudo tailscale up` by hand.
- No new Oracle resource (disk, IP, paid service): the account is Pay As You Go at exactly the Always Free limit.
- ansible-lint rules in force: FQCN modules, task names start with a capital, registers carry the role's prefix (`tailscale_`, `argocd_`, `reboot_`), `command`/`shell` tasks that only read set `changed_when: false` and `check_mode: false`.
- Commits: `Het Patel <patel.x.het@gmail.com>`, signed, subject under 72 characters, no Claude attribution. PRs to `main` on Het101/hetops-k8s-lab; merge only after `gh pr checks <n> --watch` exits 0.
- Every step that changes a server is written into the lab journal's Part 13 the same session, with the exact commands; every mistake gets a Part 11 row.

## Who runs what

| Where | Who | How |
|---|---|---|
| OCI console | owner | browser |
| hetops-3 | Claude | `ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122` from the laptop |
| The lab (control node) | Claude | `ssh ubuntu@140.245.13.138`, then `cd ~/hetops-k8s-lab/bedrock` |
| Code and PRs | Claude | laptop checkout `C:\Users\HetPatel\Personal\HetOps\hetops-k8s-lab` |
| `sudo tailscale up` login | owner | opens the printed URL and approves |

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `bedrock/roles/tailscale/defaults/main.yml` | create | the pinned Tailscale version |
| `bedrock/roles/tailscale/tasks/main.yml` | create | Tailscale's apt source, package, daemon |
| `bedrock/roles/argocd/defaults/main.yml` | create | the pinned Argo CD version |
| `bedrock/roles/argocd/tasks/main.yml` | create | install Argo CD where missing; apply `clusters/ops/root.yaml` |
| `bedrock/site.yml` | modify | new play *The ops cluster* (`hosts: ops`) |
| `bedrock/tests/ci-inventory.ini` | modify | the runner is also in `ops` |
| `.github/workflows/bedrock.yml` | modify | rebuild job checks Tailscale and Argo CD |
| `clusters/ops/root.yaml` | create | the ops cluster's app-of-apps |
| `clusters/ops/apps/sealed-secrets.yaml` | create | Argo CD Application for sealed-secrets |
| `clusters/ops/sealed-secrets/kustomization.yaml` | create | sealed-secrets 0.40.0's release manifest |
| `bedrock/inventory.ini` | modify | group `[ops]` with hetops-3, `ops` under `k8s` |
| `bedrock/group_vars/ops.yml` | create | how the lab reaches hetops-3 and its API |
| `bedrock/patch.yml`, `upgrade.yml`, `reboot.yml` | modify | the canary play covers `staging:ops` |
| `bedrock/tasks/reboot-one.yml` | modify | skip the container snapshot on a server without Docker |
| `bedrock/README.md` | modify | fleet table, roles, order |

Two PRs: **PR A** (Tasks 2 and 3: roles, `clusters/ops`, CI) can merge any time, because the real inventory has no `ops` group yet and the new play matches no host. **PR B** (Task 4: inventory and playbooks) merges only after Task 1, right before Task 5, because from its merge on the nightly drift check (02:30 UTC) reaches hetops-3.

---

### Task 1: Name hetops-3 and give the lab access

**Files:** none in git. Changes: hetops-3's hostname and `authorized_keys`; one line in the lab's `~/.ssh/known_hosts`.

**Interfaces:**
- Produces: a host named `hetops-3`, reachable from the lab as `ubuntu@130.210.37.122` with `~/.ssh/bedrock_fleet`, host key pinned. Tasks 4 and 5 rely on it.

- [ ] **Step 1 (owner): Set the VNIC hostname in OCI**

Compute → Instances → hetops-3 → Networking → Attached VNICs → hetops-vnic → IP administration → ⋮ **Edit** on 10.0.0.164 → Hostname `hetops-3` → **Update**. The FQDN line should then start with `hetops-3.`.

- [ ] **Step 2: Set the hostname on the box**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'sudo hostnamectl set-hostname hetops-3 && hostname'
```

Expected: `hetops-3`

- [ ] **Step 3: Reboot once and check the name stuck**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'sudo systemctl reboot'
```

About a minute later, once SSH answers again:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'hostname; uptime'
```

Expected: `hetops-3`, uptime about a minute. If it says `hetops-vnic`, Step 1 did not save: redo it, then Steps 2 and 3.

- [ ] **Step 4: Put the fleet key on hetops-3, accepted only from the lab**

```bash
FLEET=$(ssh ubuntu@140.245.13.138 'cat ~/.ssh/bedrock_fleet.pub')
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 "grep -qF '${FLEET#* }' ~/.ssh/authorized_keys || echo 'from=\"140.245.13.138\" $FLEET' >> ~/.ssh/authorized_keys; tail -n 1 ~/.ssh/authorized_keys | cut -c1-60"
```

Expected: a line starting `from="140.245.13.138" ssh-ed25519 AAAA`.

- [ ] **Step 5: Pin hetops-3's host key on the lab, after checking it**

The fingerprint read from the laptop on 26 Oct, before any change: ED25519 `SHA256:BP9GIiDvha8a9+X1ZZt5rn/bxYLiEWCIsAnSNxxnYCY`.

```bash
ssh-keygen -lf <(ssh-keygen -F 130.210.37.122 -f ~/.ssh/known_hosts | grep -v '^#')
ssh ubuntu@140.245.13.138 'ssh-keyscan -t ed25519 130.210.37.122 2>/dev/null > /tmp/hetops-3.key; ssh-keygen -lf /tmp/hetops-3.key'
```

Expected: both print `SHA256:BP9GIiDvha8a9+X1ZZt5rn/bxYLiEWCIsAnSNxxnYCY`. Only if they match:

```bash
ssh ubuntu@140.245.13.138 'cat /tmp/hetops-3.key >> ~/.ssh/known_hosts && rm /tmp/hetops-3.key'
```

- [ ] **Step 6: The lab reaches hetops-3 with the fleet key**

```bash
ssh ubuntu@140.245.13.138 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -i ~/.ssh/bedrock_fleet ubuntu@130.210.37.122 hostname'
```

Expected: `hetops-3`

- [ ] **Step 7: Journal**

Part 13: a section "Building the ops cluster", step 1, with the commands above and their output.

---

### Task 2: The `tailscale` role, rehearsed in CI

**Files:**
- Create: `bedrock/roles/tailscale/defaults/main.yml`, `bedrock/roles/tailscale/tasks/main.yml`
- Modify: `bedrock/site.yml`, `bedrock/tests/ci-inventory.ini`, `.github/workflows/bedrock.yml`

**Interfaces:**
- Consumes: `ansible_facts['distribution_release']` (`noble`).
- Produces: play *The ops cluster* (`hosts: ops`) in `site.yml`, which Task 3 adds a role to; variable `tailscale_version`.

- [ ] **Step 1: Branch**

```bash
cd /c/Users/HetPatel/Personal/HetOps/hetops-k8s-lab && git checkout main && git pull --ff-only && git checkout -b feat/ops-roles
```

- [ ] **Step 2: Write the failing CI check first**

In `.github/workflows/bedrock.yml`, job `rebuild`, after the step `The cluster runs a pod, and the audit log is being written`, add:

```yaml
      # The ops cluster's roles (27 Oct): the runner is also in group ops (tests/ci-inventory.ini).
      - name: Tailscale is installed at the pinned version and its daemon runs (never joined in CI)
        run: |
          want=$(sed -n 's/^tailscale_version: "\(.*\)"/\1/p' roles/tailscale/defaults/main.yml)
          tailscale version | head -n 1 | grep -qx "$want"
          systemctl is-active tailscaled
```

And in `bedrock/tests/ci-inventory.ini`, after the `[k8s:children]` block, add:

```ini

# The ops cluster's roles (tailscale, argocd) are rehearsed on the same runner.
[ops:children]
lab
```

- [ ] **Step 3: Check it fails**

```bash
git add -A && git commit -qm "test(bedrock): CI expects Tailscale on the ops group" && git push -u origin feat/ops-roles
```

Open a draft PR (`gh pr create --draft`, with `GH_TOKEN=$(gh auth token --user Het101)`), then `gh pr checks --watch`. Expected: `rebuild` FAILS at the new step (`sed` finds no defaults file, so `grep -qx ""` fails).

- [ ] **Step 4: Write the role**

`bedrock/roles/tailscale/defaults/main.yml`:

```yaml
# The lab's Tailscale on 27 Oct, so both ends of the link run the same version. Not held: patch.yml can move it,
# and the nightly drift check then names the version to write down here.
tailscale_version: "1.104.2"
```

`bedrock/roles/tailscale/tasks/main.yml`:

```yaml
# Tailscale: the private link between the lab and the ops cluster (27 Oct). Bedrock installs it and keeps the
# daemon running. Joining the tailnet is the owner's step (sudo tailscale up): a login key never goes into git.

- name: Tailscale's signing key
  ansible.builtin.get_url:
    url: "https://pkgs.tailscale.com/stable/ubuntu/{{ ansible_facts['distribution_release'] }}.noarmor.gpg"
    dest: /usr/share/keyrings/tailscale-archive-keyring.gpg
    mode: "0644"
    force: false

- name: Tailscale's apt source
  ansible.builtin.copy:
    dest: /etc/apt/sources.list.d/tailscale.list
    content: |
      deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu {{ ansible_facts['distribution_release'] }} main
    mode: "0644"
  register: tailscale_source

- name: The apt cache knows Tailscale's packages
  ansible.builtin.apt:
    update_cache: true
  when: tailscale_source is changed

# Check mode on a machine without the source yet: apt cannot know the package, so skip rather than fail.
- name: Tailscale, at the written-down version
  ansible.builtin.apt:
    name: "tailscale={{ tailscale_version }}"
    state: present
  when: not (ansible_check_mode and tailscale_source is changed)

- name: The Tailscale daemon runs, and starts on boot
  ansible.builtin.systemd_service:
    name: tailscaled
    state: started
    enabled: true
  when: not (ansible_check_mode and tailscale_source is changed)
```

In `bedrock/site.yml`, between the play *Kubernetes nodes* and the play *The control node*, add:

```yaml
# The ops cluster (hetops-3, 27 Oct): its private link to the lab, and its own Argo CD, which deploys clusters/ops/.
- name: The ops cluster
  hosts: ops
  become: true
  roles:
    - tailscale
```

- [ ] **Step 5: Check it passes**

```bash
git add -A && git commit -qm "feat(bedrock): tailscale role for the ops cluster" && git push
```

`gh pr checks --watch`. Expected: `lint` passes; `rebuild` passes every step, including "Second run changes nothing", the drift check (`my-workspace: 0 changed, 0 failed`), and the new Tailscale step.

---

### Task 3: The `argocd` role and `clusters/ops/`

**Files:**
- Create: `bedrock/roles/argocd/defaults/main.yml`, `bedrock/roles/argocd/tasks/main.yml`, `clusters/ops/root.yaml`, `clusters/ops/apps/sealed-secrets.yaml`, `clusters/ops/sealed-secrets/kustomization.yaml`
- Modify: `bedrock/site.yml`, `.github/workflows/bedrock.yml`

**Interfaces:**
- Consumes: `cluster_ready` (fact set by `roles/cluster`, true on a node with a cluster or in a real run), `bedrock_api_python`, `audit_kubeconfig` (`{{ bedrock_kube_home }}/.kube/config`, `roles/audit/defaults`), the play from Task 2.
- Produces: Argo CD in namespace `argocd`; Application `root` (path `clusters/ops/apps`); Application `sealed-secrets` (namespace `kube-system`). Sub-projects 1 to 4 add Applications under `clusters/ops/apps/`.

- [ ] **Step 1: Write the failing CI check**

In `.github/workflows/bedrock.yml`, after the Tailscale step from Task 2, add:

```yaml
      # Argo CD is installed and has its app-of-apps. No wait for a sync: Argo CD reads main, CI tests a branch.
      - name: Argo CD runs and follows clusters/ops
        run: |
          kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
          kubectl -n argocd get application root -o jsonpath='{.spec.source.path}' | grep -qx clusters/ops/apps
```

```bash
git add -A && git commit -qm "test(bedrock): CI expects Argo CD on the ops group" && git push
```

`gh pr checks --watch`. Expected: `rebuild` FAILS at "Argo CD runs" (`deployments.apps "argocd-server" not found`).

- [ ] **Step 2: Write `clusters/ops/`**

`clusters/ops/root.yaml`:

```yaml
# The ops cluster's app-of-apps (hetops-3, 27 Oct). Outside argo/ on purpose: the lab's root app reads argo/
# only, so it never sees this folder, and this cluster's Argo CD reads only this one. Applied by Bedrock
# (roles/argocd); everything under apps/ is then git's.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Het101/hetops-k8s-lab.git
    targetRevision: main
    path: clusters/ops/apps
    directory: { recurse: true }
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

`clusters/ops/apps/sealed-secrets.yaml`:

```yaml
# Sealed secrets on the ops cluster, at the lab's version. Its controller makes its own key: a secret sealed
# for this cluster cannot be opened on the lab, and the reverse. Seal with: kubeseal --controller-namespace kube-system
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Het101/hetops-k8s-lab.git
    targetRevision: main
    path: clusters/ops/sealed-secrets
  destination: { server: https://kubernetes.default.svc, namespace: kube-system }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

`clusters/ops/sealed-secrets/kustomization.yaml`:

```yaml
# The release manifest the lab's controller came from (docker.io/bitnami/sealed-secrets-controller:0.40.0).
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/bitnami/sealed-secrets/releases/download/v0.40.0/controller.yaml
```

- [ ] **Step 3: Write the role**

`bedrock/roles/argocd/defaults/main.yml`:

```yaml
# The lab's Argo CD on 27 Oct (quay.io/argoproj/argocd:v3.5.4). This role installs it where it is missing and
# never moves an installed one: an Argo CD upgrade is a step of its own, like Calico's.
argocd_version: v3.5.4
```

`bedrock/roles/argocd/tasks/main.yml`:

```yaml
# Argo CD on the ops cluster (27 Oct), installed the way roles/cluster installs Calico: only where missing,
# from the release manifest at the written-down version. Then pointed at clusters/ops/ in this repo; from there
# git owns what runs on the cluster. API tasks run on the node, with the node's kubeconfig (option A).

- name: Read whether Argo CD is installed
  vars:
    ansible_python_interpreter: "{{ bedrock_api_python }}"
  kubernetes.core.k8s_info:
    kind: Deployment
    name: argocd-server
    namespace: argocd
    kubeconfig: "{{ audit_kubeconfig }}"
  register: argocd_server
  when: cluster_ready

- name: Install Argo CD (only where it is missing)
  when: cluster_ready and argocd_server.resources | length == 0
  vars:
    ansible_python_interpreter: "{{ bedrock_api_python }}"
  block:
    - name: Argo CD's namespace
      kubernetes.core.k8s:
        kind: Namespace
        name: argocd
        state: present
        kubeconfig: "{{ audit_kubeconfig }}"

    - name: Argo CD's release manifest, at the written-down version
      ansible.builtin.get_url:
        url: "https://raw.githubusercontent.com/argoproj/argo-cd/{{ argocd_version }}/manifests/install.yaml"
        dest: "/etc/kubernetes/bedrock-argocd-{{ argocd_version }}.yaml"
        mode: "0644"

    # Server-side apply: Argo CD's CRDs are too big for client-side apply's last-applied annotation
    # (the lab's own install, 8 Oct, needed the same).
    - name: Argo CD runs
      kubernetes.core.k8s:
        state: present
        src: "/etc/kubernetes/bedrock-argocd-{{ argocd_version }}.yaml"
        namespace: argocd
        apply: true
        server_side_apply:
          field_manager: bedrock
        kubeconfig: "{{ audit_kubeconfig }}"

- name: Argo CD's server is available
  vars:
    ansible_python_interpreter: "{{ bedrock_api_python }}"
  kubernetes.core.k8s_info:
    kind: Deployment
    name: argocd-server
    namespace: argocd
    kubeconfig: "{{ audit_kubeconfig }}"
    wait: true
    wait_condition:
      type: Available
      status: "True"
    wait_timeout: 300
  when: cluster_ready

# lookup() runs on the controller (the lab, or the CI runner): this repo's file, never a file on the node.
- name: Argo CD follows clusters/ops in git
  vars:
    ansible_python_interpreter: "{{ bedrock_api_python }}"
  kubernetes.core.k8s:
    state: present
    definition: "{{ lookup('ansible.builtin.file', playbook_dir ~ '/../clusters/ops/root.yaml') | from_yaml }}"
    kubeconfig: "{{ audit_kubeconfig }}"
  when: cluster_ready
```

In `bedrock/site.yml`, play *The ops cluster*, add `argocd` after `tailscale`:

```yaml
  roles:
    - tailscale
    - argocd
```

- [ ] **Step 4: Check it passes**

```bash
git add -A && git commit -qm "feat(bedrock): argocd role and the ops app-of-apps" && git push
```

`gh pr checks --watch`. Expected: every job passes, including "Second run changes nothing" (the root Application applied twice reports no change), the drift step (`my-workspace: 0 changed, 0 failed`) and "Argo CD runs and follows clusters/ops".

If "Second run changes nothing" fails on the root Application, read the diff (`ansible-playbook site.yml --diff` output in the log): Argo CD may default a field the file leaves out. Write that field into `clusters/ops/root.yaml` as the server returns it, push, re-check.

- [ ] **Step 5: Merge PR A**

Mark the PR ready (`gh pr ready`), then:

```bash
gh pr checks <n> --repo Het101/hetops-k8s-lab --watch && gh pr merge <n> --repo Het101/hetops-k8s-lab --squash --delete-branch
```

Nothing in the fleet changes: the real inventory has no `ops` group, so the new play matches no host. The next drift run is still lab and vm2 only.

---

### Task 4: hetops-3 joins the fleet (PR B)

**Files:**
- Modify: `bedrock/inventory.ini`, `bedrock/patch.yml`, `bedrock/upgrade.yml`, `bedrock/reboot.yml`, `bedrock/tasks/reboot-one.yml`, `bedrock/README.md`
- Create: `bedrock/group_vars/ops.yml`

**Interfaces:**
- Consumes: Task 1 (hostname, key, pinned host key), Task 3's merged roles.
- Produces: inventory host `hetops-3` in groups `ops` and `k8s`, which Task 5 targets with `--limit hetops-3`.

- [ ] **Step 1: Branch**

```bash
git checkout main && git pull --ff-only && git checkout -b feat/ops-joins-fleet
```

- [ ] **Step 2: Inventory and connection settings**

`bedrock/inventory.ini`: in the header comment's group list add, after the `staging` line:

```ini
#   ops      the ops cluster (hetops-3, 27 Oct): tools the lab relies on, its own Argo CD (clusters/ops/)
```

After the `[staging]` block add:

```ini

[ops]
hetops-3 ansible_host=130.210.37.122
```

And `[k8s:children]` becomes:

```ini
[k8s:children]
lab
staging
ops
```

`bedrock/group_vars/ops.yml`:

```yaml
# The ops cluster (hetops-3, 27 Oct): reached from the control node over SSH, like staging. These five settings
# repeat staging.yml's on purpose, so staging's files stay untouched; precedence is the same (k8s < ops).

# How Ansible connects. The host key is pinned in the control node's known_hosts (checked against the
# fingerprint seen from the owner's laptop on 26 Oct before it was added), so an unknown key is refused.
ansible_user: ubuntu
ansible_ssh_private_key_file: ~/.ssh/bedrock_fleet

# Where kubernetes.core modules run, and as whom (option A): ON the ops node, never on the controller.
# NEVER controller lookups here (lookup() always runs on the controller): they would name the lab's files.
bedrock_api_python: /opt/bedrock/venv/bin/python3     # made by roles/kubernetes, with the pinned client
bedrock_kube_user: ubuntu
bedrock_kube_home: /home/ubuntu
```

- [ ] **Step 3: The canary plays cover ops**

In each of `patch.yml`, `upgrade.yml` and `reboot.yml`, the first play changes `hosts: staging` to `hosts: staging:ops` and its name gains "and ops":

| File | Play name before | Play name after |
|---|---|---|
| `patch.yml` | `Patch staging` | `Patch staging and ops` |
| `upgrade.yml` | `Upgrade staging` | `Upgrade staging and ops` |
| `reboot.yml` | `Reboot staging` | `Reboot staging and ops` |

`serial: 1` runs them one at a time in inventory order (vm2, then hetops-3); `any_errors_fatal` still ends the run before the lab play. The spec describes this as "an ops play between staging and the lab"; widening the canary play gives the same order and the same stop-before-the-lab rule with less code. In each file's header comment, `staging first` / `staging, then the lab` become `staging and ops first` / `staging and ops, then the lab`.

- [ ] **Step 4: Reboot works on a server without Docker**

hetops-3 has no Docker (the lab and vm2 do). In `bedrock/tasks/reboot-one.yml`, inside block *The reboot*, directly before `Save the running containers, for verify to compare against after the boot`, add:

```yaml
    - name: Is Docker on this server?
      ansible.builtin.stat:
        path: /usr/bin/docker
      register: reboot_docker
```

and give the save task:

```yaml
      when: reboot_docker.stat.exists
```

The verify side needs no change: `Read the container list saved before the reboot` has `failed_when: false`, and the compare runs only `when: reboot_saved.content is defined`.

- [ ] **Step 5: README**

In `bedrock/README.md`:
- the fleet table gains the row `| `hetops-3` (130.210.37.122) | `ops` | SSH as `ubuntu` with `~/.ssh/bedrock_fleet`, pinned host key | the ops cluster: tools the lab relies on, its own Argo CD (`clusters/ops/`) |`, and the sentence under it says `k8s` is the parent of all three groups;
- the playbook table's Hosts column reads `all → k8s → ops → lab` for `site.yml`, and `staging and ops, then the lab with -e …` for the other three;
- the Roles line gains `tailscale`, `argocd` (the ops cluster: the private link, and its own Argo CD);
- "Staging first" becomes "Staging and ops first", and its first sentence names both.

- [ ] **Step 6: CI passes, then hold**

```bash
git add -A && git commit -qm "feat(bedrock): hetops-3 joins the fleet as the ops cluster" && git push -u origin feat/ops-joins-fleet
```

Open the PR; `gh pr checks <n> --watch` must exit 0 (lint and syntax over all four playbooks; CI never reads `inventory.ini`). **Do not merge yet**: it merges at the start of Task 5, on a day the build can finish before 02:30 UTC.

---

### Task 5: Build hetops-3

**Files:** none in git (`bedrock/README.md` "Today" line in Step 7).

**Interfaces:**
- Consumes: PR B merged, Task 1 done.
- Produces: node `hetops-3` Ready on v1.35.9, Argo CD running with `root` applied.

- [ ] **Step 1: Merge PR B and pull on the lab**

```bash
gh pr checks <n> --repo Het101/hetops-k8s-lab --watch && gh pr merge <n> --repo Het101/hetops-k8s-lab --squash --delete-branch
ssh ubuntu@140.245.13.138 'cd ~/hetops-k8s-lab && git pull --ff-only && git log --oneline -1'
```

- [ ] **Step 2: Ansible reaches it**

```bash
ssh ubuntu@140.245.13.138 'cd ~/hetops-k8s-lab/bedrock && ansible hetops-3 -m ansible.builtin.ping && ansible hetops-3 -m ansible.builtin.setup -a "filter=ansible_hostname,ansible_architecture,ansible_distribution_version"'
```

Expected: `pong`; `hetops-3`, `aarch64`, `24.04`.

- [ ] **Step 3: Check mode on the blank machine**

```bash
ssh ubuntu@140.245.13.138 'cd ~/hetops-k8s-lab/bedrock && ansible-playbook site.yml --check --limit hetops-3 2>&1 | tail -n 25'
```

Expected: no `fatal` in roles `common`, `base` or `tailscale`; `kubernetes`, `cluster`, `audit` and `argocd` mostly skipped or changed (no cluster yet). Write down every `fatal` with its task name in the journal; a `fatal` is a finding, not something to fix here.

- [ ] **Step 4: The real build, timed and detached**

```bash
ssh ubuntu@140.245.13.138 'cd ~/hetops-k8s-lab/bedrock && systemd-run --user --unit=bedrock-ops-build --working-directory=$PWD -E PATH=$PATH -E HOME=$HOME -E USER=$USER bash -c "start=\$(date +%s); ansible-playbook site.yml --limit hetops-3 > /tmp/bedrock-ops-build.log 2>&1; rc=\$?; echo BUILD_SECONDS=\$(( \$(date +%s) - start )) rc=\$rc >> /tmp/bedrock-ops-build.log"'
```

Wait for the unit to finish (`systemctl --user is-active bedrock-ops-build` says `inactive`), then:

```bash
ssh ubuntu@140.245.13.138 'tail -n 6 /tmp/bedrock-ops-build.log'
```

Expected: `hetops-3 : ok=… changed=… unreachable=0 failed=0`, then `BUILD_SECONDS=… rc=0`. Record the seconds.

- [ ] **Step 5: The second run changes nothing**

```bash
ssh ubuntu@140.245.13.138 'cd ~/hetops-k8s-lab/bedrock && ansible-playbook site.yml --limit hetops-3 2>&1 | tail -n 3'
```

Expected: `hetops-3 : ok=… changed=0 unreachable=0 failed=0`

- [ ] **Step 6: The checks**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 '
  kubectl get nodes -o wide
  kubectl -n kube-system get pods -l k8s-app=calico-node
  sudo grep -c -- "--audit-" /etc/kubernetes/manifests/kube-apiserver.yaml
  sudo iptables -S FORWARD | grep -c "REJECT" || true
  kubectl -n argocd get deploy argocd-server
  kubectl -n argocd get applications'
```

Expected: one node `hetops-3`, Ready, `v1.35.9`; calico-node Running; the audit flag count matches the lab's (`sudo grep -c -- "--audit-" /etc/kubernetes/manifests/kube-apiserver.yaml` on the lab); `0` REJECT rules in FORWARD; argocd-server `1/1`; applications `root` and `sealed-secrets`.

- [ ] **Step 7: Journal and README**

Part 13 gets the build: every command above, the check-mode findings, `BUILD_SECONDS`, the `changed=0` line, the checks' output. In `bedrock/README.md`, the line "Today (25 Oct) both servers run…" becomes "Today (<date>) all three servers run Kubernetes 1.35.9, etcd 3.6.6, Calico 3.31.7." (small PR, after the checks pass).

---

### Task 6: Join the tailnet

**Files:** none.

**Interfaces:**
- Produces: hetops-3 on the tailnet as `hetops-3`, reachable from the lab. Sub-projects 2 and 3 rely on it.

- [ ] **Step 1 (owner): Log hetops-3 into the tailnet**

The tailnet is the lab's (`my-workspace` shows `hetpatidar09@`). On hetops-3:

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'sudo tailscale up --hostname=hetops-3'
```

It prints a login URL. The owner opens it, signs in with the same account as the lab, and approves the device.

- [ ] **Step 2: The lab reaches hetops-3 over Tailscale**

```bash
ssh ubuntu@140.245.13.138 'tailscale status | grep hetops-3; tailscale ping -c 3 hetops-3'
```

Expected: a `100.x` address for `hetops-3`; `pong from hetops-3 (100.x…) via …`. A `via DERP` reply works but is slower; a direct address is better and usually appears after a few pings.

- [ ] **Step 3: Journal**

Part 13: the commands, the 100.x address, whether the path is direct or DERP.

---

### Task 7: Prove it holds

**Files:** none (journal, memory).

- [ ] **Step 1: Argo CD has synced from main**

```bash
ssh -i ~/.ssh/id_rsa ubuntu@130.210.37.122 'kubectl -n argocd get applications; kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=120s'
```

Expected: `root` and `sealed-secrets` both `Synced` and `Healthy`; the controller rolled out.

- [ ] **Step 2: The nightly drift check covers hetops-3**

The morning after Task 5, on the lab:

```bash
ssh ubuntu@140.245.13.138 'journalctl -u bedrock-drift.service --since "today 02:00" --no-pager -o cat | tail -n 6'
```

Expected: a line `hetops-3: 0 changed, 0 failed`, beside the lab's and vm2's.

- [ ] **Step 3: Close out**

- Journal Part 13: the spec's six "Done when" checks, each with its evidence; Start here's progress list gains a ticked item for the ops cluster.
- Memory `oci-hetops-3.md`: sub-project 0 done, the build time, the tailnet address.
- Cost Analysis on hetops-3's account still shows 0.00.
