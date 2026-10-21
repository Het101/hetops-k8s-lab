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
