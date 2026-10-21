# Bedrock Phase 1: adopt the server (lab sheet)

**Goal:** Ansible describes the lab server as it really is. Done when this prints `changed=0 failed=0`:

```bash
ansible-playbook site.yml --check --diff
```

**Nothing on the server changes in this phase.** `--check` asks every module what it *would* do. The only commands that really run are reads (`sshd -T`, `apt-mark showhold`).

**The server is shared with Coolify and every live hetops.dev site.** Never run the playbook without `--check` in Phase 1.

Design: `docs/superpowers/specs/2026-10-21-bedrock-design.md`. Files: `bedrock/`.

## Step 0: where you are

Your prompt says `my-workspace`, not a work VM.

```bash
cd ~/hetops-k8s-lab && git checkout main && git pull
```

## Step 1: install Ansible

**Predict:** what does Ansible need on the machine it manages? (Compare Puppet or Chef, which need an agent.)

```bash
python3 --version
sudo apt-get update && sudo apt-get install -y pipx
pipx install --include-deps ansible==14.5.0
pipx ensurepath && exec bash -l
ansible --version
```

**If Python is older than 3.12** (Ubuntu 22.04 has 3.10), Ansible 14 will not install. Use `pipx install --include-deps 'ansible==10.*'` (ansible-core 2.17) and tell Claude, so the CI pin matches.

**Expected:** `ansible [core 2.21.x]`, with `python version = 3.12…`.

**Answer to the prediction:** Python and a way in (SSH, or here `ansible_connection=local`). There is no agent. Ansible copies a small Python program for each task, runs it, reads its JSON answer and deletes it.

## Step 2: your first ad-hoc commands

An ad-hoc command is one module, run once, without a playbook.

```bash
cd ~/hetops-k8s-lab/bedrock
ansible lab -m ansible.builtin.ping
ansible lab -m ansible.builtin.setup -a 'filter=ansible_distribution*'
ansible lab -m ansible.builtin.setup -a 'filter=ansible_architecture'
ansible lab -m ansible.builtin.setup -a 'filter=ansible_memtotal_mb'
```

**Expected:**
- `ping` answers `"ping": "pong"`. It is not ICMP: it proves Ansible can run Python there.
- The other three are **facts**: what Ansible learns about a host before every play, used as variables (`ansible_architecture` is checked in `roles/base`).

Try `ansible lab -m ansible.builtin.setup | less` once, to see how much it knows.

## Step 3: discovery (write down what the server really is)

Nobody has written this down before. Run each command, then paste all the output to Claude.

```bash
ansible lab -b -m ansible.builtin.shell -a 'dpkg-query -W kubeadm kubelet kubectl containerd containerd.io docker-ce 2>&1; echo ---; apt-mark showhold'
ansible lab -b -m ansible.builtin.shell -a 'ls /etc/modules-load.d /etc/sysctl.d; echo ---; tail -n +1 /etc/modules-load.d/*.conf; echo ---; sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables'
ansible lab -b -m ansible.builtin.shell -a "sshd -T | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication|x11forwarding|maxauthtries) '"
ansible lab -b -m ansible.builtin.shell -a 'swapon --show; echo ---; grep -n SystemdCgroup /etc/containerd/config.toml; echo ---; ls -l /etc/kubernetes/audit/'
```

`-b` is *become*: the module runs as root through sudo.

**Predict before you look:**
- Which minor version are the kube packages?
- Are they held?
- Is `br_netfilter` loaded from a file called `k8s.conf`, or something else?
- Is Docker (Coolify's) sharing containerd with Kubernetes?

## Step 4: the first check-mode run

Claude fills `group_vars/lab.yml` and fixes the roles from your step 3 output first.

**Predict:** which tasks will say `changed` or `failed`, and why? Each task describes the server as the kubeadm install guide would set it up.

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock
ansible-playbook site.yml --check --diff
```

**Reading the output:**

| Status | Meaning in check mode |
|---|---|
| `ok` | The server already matches the task |
| `changed` | The task *would* change the server; `--diff` shows the difference |
| `skipping` | A condition said no |
| `failed` | An `assert` found the server is not what we believed, or a module could not run |

**Every `changed` or `failed` is a finding.** For each one, decide:
- **the role is wrong:** the server was set up differently, so change the role to match the server; or
- **the server is wrong:** a real gap, such as SSH allowing passwords. Write it down for Phase 2; do not fix it now.

Paste the recap to Claude. Repeat until the recap says `changed=0 failed=0`.

## Step 5: idempotence

Run it again, unchanged. **Predict:** what changes?

```bash
ansible-playbook site.yml --check --diff
```

**Expected:** exactly the same recap. A role that describes the server gives the same answer every time; that is idempotence. In Phase 3 the CI rebuild runs the playbook twice for real, and the second run must report `changed=0`.

## What you have learned

- **Inventory, groups and connections:** `inventory.ini`, `[lab]`, `ansible_connection=local`.
- **Ad-hoc commands and modules.**
- **Facts.**
- **become (sudo).**
- **Playbooks and roles:** `site.yml`, `roles/*/tasks/main.yml`.
- **group_vars.**
- **Check and diff mode.**
- **Why `command`/`shell` tasks carry `check_mode: false` and `changed_when: false`:** they are reads, so they run even in check mode and never count as a change.
- **Assertions as tests.**
