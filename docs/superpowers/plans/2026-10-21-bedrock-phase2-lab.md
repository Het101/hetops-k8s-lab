# Bedrock Phase 2: real roles (lab sheet)

Phase 1 proved the playbook describes the server: `changed=0`. Phase 2 makes its first real changes, each with predict → apply → verify. Every step leaves the playbook back at `changed=0`.

## Step 1: SSH hardening (your first real apply)

**What changes:** one new file, `/etc/ssh/sshd_config.d/10-bedrock.conf`, rendered from `roles/base/templates/10-bedrock.conf.j2`:

| Setting | Before (discovery) | After |
|---|---|---|
| `X11Forwarding` | yes | no |
| `MaxAuthTries` | 6 | 3 |
| `ClientAliveInterval` / `ClientAliveCountMax` | 0 / 3 (off) | 300 / 3: a client that stops answering for 15 min is dropped |
| `PasswordAuthentication`, `PermitRootLogin` | no, prohibit-password | the same, now written down |

**The Ansible ideas in it:**
- **Template:** a Jinja2 file filled from variables.
- **Role defaults:** `roles/base/defaults/main.yml`, the lowest-precedence variables; `group_vars` can override them.
- **`validate:`:** `sshd -t -f` tests the new file before it is put in place.
- **Handlers:** `Check the whole SSH config` then `Reload SSH`, run only if the file changed.
- **`meta: flush_handlers`:** runs the handlers now, so the next task reads the new settings.
- **`register` plus `is changed`:** in check mode, the final check waits for the real run.

### 1a. Open your safety net

Open a **second** SSH session to the server and leave it alone. A reload keeps existing sessions, so if the new settings broke logins, this one still works and can undo it.

### 1b. Predict, then check

**Predict:**
- Which task will check mode call `changed`?
- Will either handler run in check mode?
- Will the final SSH check run or skip?

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock
ansible-playbook site.yml --check --diff
```

**Expected:**
- `SSH uses Bedrock's settings` is `changed`, and the diff shows the whole new file.
- Both handlers show `RUNNING HANDLER`, but in check mode they change nothing: the command is skipped and the reload is only reported.
- The final check is `skipping`, because sshd still runs the old settings.
- Recap: `changed=1` or more (handlers count), `failed=0`.

### 1c. Apply

For the first time without `--check`. Everything else in the playbook already matches the server (Phase 1 proved it), so only SSH changes.

```bash
ansible-playbook site.yml --diff
```

**Expected:**
- the template is `changed`;
- the handlers run, `sshd -t` passes and SSH reloads;
- the final check is `ok` for all six settings;
- recap `failed=0`.

### 1d. Verify from outside

From your **laptop**, open a **third**, new connection. This is the real test: only new connections use the new settings.

```bash
ssh ubuntu@<server> 'sudo sshd -T | grep -E "^(x11forwarding|maxauthtries|clientaliveinterval) "'
```

**Expected:** `x11forwarding no`, `maxauthtries 3`, `clientaliveinterval 300`.

**If the new connection is refused**, use the second session to undo it:

```bash
sudo rm /etc/ssh/sshd_config.d/10-bedrock.conf && sudo systemctl reload ssh
```

Then paste the error to Claude.

### 1e. Idempotence

```bash
ansible-playbook site.yml --check --diff
```

**Expected:** `changed=0` again. Nothing is notified, so no handler runs and nothing reloads.

**Then try drift:** add a line by hand, then run check mode.

```bash
echo 'X11Forwarding yes' | sudo tee -a /etc/ssh/sshd_config.d/10-bedrock.conf
ansible-playbook site.yml --check --diff
```

**Expected:** `changed`, with a diff showing the extra line. This is exactly what Phase 4's nightly run will report.

Put it back the Ansible way:

```bash
ansible-playbook site.yml --diff
```

Close the second session when done.

## Step 2: hold the shared containerd

**Why:** discovery found that one containerd, Docker's `containerd.io`, runs both Coolify's sites and the lab, and it is **not held**. A routine `sudo apt upgrade` would upgrade it and restart it under everything at once.

**What changes:** apt's selection for `containerd.io` becomes `hold`. Nothing restarts; it is apt bookkeeping only.

**The Ansible idea:** a module, not a command.
- `ansible.builtin.dpkg_selections` knows the current state, so it reports `ok` when the package is already held, supports check mode and is idempotent.
- `shell: apt-mark hold containerd.io` would run every time, report `changed` every time, and do nothing in check mode.
- Rule of thumb: reach for `command` or `shell` only when no module exists, and then only for reads.

**Side effect, on purpose:** a `docker-ce` upgrade that needs a newer `containerd.io` is now "kept back" too. Upgrading the runtime becomes a decision: unhold, upgrade at a quiet time, check the sites and the lab, hold again. That becomes a Bedrock step later.

### 2a. Predict, then check

**Predict:**
- Which task says `changed`?
- What does the new "held too" check do in check mode?

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock
ansible-playbook site.yml --check --diff
```

**Expected:**
- `Apt will not upgrade the shared containerd on its own` is `changed`;
- `The shared containerd is held too` is `skipping`;
- recap `changed=1`, `failed=0`.

### 2b. Apply, then verify

```bash
ansible-playbook site.yml --diff
apt-mark showhold
apt-cache policy containerd.io | head -3
```

**Expected:**
- the recap shows `changed=1`, and the "held too" check is `ok`;
- `showhold` lists `containerd.io` beside the kube packages.

### 2c. Idempotence

```bash
ansible-playbook site.yml --check --diff
```

**Expected:** `changed=0`.

## Step 3: the audit flags, owned by kubeadm's config

**The problem:** `platform/host/enable-audit.sh` added the audit flags straight into `/etc/kubernetes/manifests/kube-apiserver.yaml`. kubeadm owns that file. `kubeadm upgrade` regenerates it from the cluster's **ClusterConfiguration** (ConfigMap `kube-system/kubeadm-config`) and drops anything added by hand. So the first 1.31 → 1.32 upgrade would quietly switch audit logging off, and the SIEM rules from track 2 would go blind.

**The fix:** put the flags and their two volumes into the ClusterConfiguration, so kubeadm generates them itself. Bedrock then checks that config. The manifest already has the flags, so no API server restart is needed to adopt this.

### 3a. Discovery (read-only)

**Predict before you run:**
- Does the ClusterConfiguration mention audit at all?
- What will `kubeadm upgrade diff` show for the audit flags?

```bash
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'; echo
sudo grep -n -E 'audit|kubernetesVersion' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo kubeadm upgrade diff v1.31.14 2>&1 | tail -n 60
```

`kubeadm upgrade diff` changes nothing: it prints the diff between today's static pod manifests and what an upgrade would write. Lines starting with `-` would be removed.

Paste all three outputs to Claude. Step 3b, the role, is written from what they show.

**Result of 3a (21 Oct):**
- The ClusterConfiguration is `v1beta4` with `apiServer: {}`: no audit settings at all.
- `kubeadm upgrade diff` removed all five `--audit-*` flags and both volumes, and **nothing else**. So the stored config already reproduces the rest of the manifest exactly; only the audit part is missing.

### 3b. Kubeadm's config carries the audit settings

**What the role does now (`roles/audit`):**
1. **Policy file:** the same as before, but a change to it now notifies two handlers. `Restart the API server` stops its container, because the API server reads the policy only at start; the kubelet starts it again from the unchanged manifest. `Wait for the API server` polls `/readyz`.
2. **kubeadm's config:**
   - read the `kubeadm-config` ConfigMap with `kubernetes.core.k8s_info`;
   - parse the stored YAML with `from_yaml`;
   - merge in the audit `extraArgs` and `extraVolumes`, keeping any others;
   - write it back with `kubernetes.core.k8s`, **only if the parsed config differs**. A text compare would report a change every run, because kubeadm's formatting never matches Ansible's byte for byte. This is the documented kubeadm way to reconfigure a cluster.
3. **Manifest check:** read `kube-apiserver.yaml` and check each flag is there.

**No restart in this step:** the API server already runs with the flags. Only kubeadm's record of them changes, and the policy file is unchanged, so no handler is notified.

**One-time setup:** the `kubernetes.core` modules need the Python `kubernetes` client inside Ansible's environment.

```bash
pipx inject ansible kubernetes
```

**Predict:**
- Which task is `changed`?
- Does the API server restart?
- What will `kubeadm upgrade diff` show *after* the apply?

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock
ansible-playbook site.yml --check --diff
```

**Expected:**
- `Kubeadm's configuration carries the audit settings` is `changed`, and the diff shows the ClusterConfiguration gaining `extraArgs` and `extraVolumes`;
- no handler runs;
- recap `changed=1`, `failed=0`.

### 3c. Apply and prove it

```bash
ansible-playbook site.yml --diff
sudo kubeadm upgrade diff v1.31.14 2>&1 | tail -n 40
ansible-playbook site.yml --check --diff
```

**Expected:**
- the apply: `changed=1`, and every audit flag check `ok`;
- `kubeadm upgrade diff` no longer **removes** any `--audit-*` line. It may still show some lines moving, because kubeadm writes flags in alphabetical order and the script had put them first. They are the same lines, just reordered;
- the second check: `changed=0`.

After this, `platform/host/enable-audit.sh` is retired in the next PR. Bedrock owns the policy and the flags, and a kubeadm upgrade keeps them.

## Step 4: reboot awareness

**Why:** discovery found kernel `7.0.0-1013-oracle` installed while `6.17.0-1014-oracle` runs. Unattended upgrades install kernels but never reboot, so the new kernel's fixes are not active yet.

**What changes:** nothing on the server. Three read tasks:
- `stat` checks for the flag Ubuntu drops (`/var/run/reboot-required`);
- `slurp` reads which packages asked for the reboot;
- `debug` prints it.

**The Ansible idea:** report, don't act.
- Ansible *could* reboot (`ansible.builtin.reboot` waits for the host to come back), but the server also runs every live site, so when to reboot is the owner's decision.
- `debug` shows as `ok`, not `changed`: a report is not a change. Phase 4's nightly run picks up the same message.

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock
ansible-playbook site.yml --check --diff
```

**Expected:**
- `Say so if a reboot is pending` prints the running kernel and the packages, for example `linux-image-7.0.0-1013-oracle`;
- recap `changed=0`.

**The reboot itself (your call, at a quiet time):**
- `sudo reboot`;
- 2 to 3 minutes later: `uname -r` shows 7.0, every site is up on status.hetops.dev, `kubectl get nodes` is `Ready`, and the Argo CD apps are `Healthy`;
- run Bedrock again: the reboot message is gone and `changed=0`.
