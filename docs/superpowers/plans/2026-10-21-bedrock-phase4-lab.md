# Bedrock Phase 4: drift watch (lab sheet)

**Goal:** every night the server checks itself against Bedrock. A hand change shows up on the Change Timeline as `ansible/drift`:
- public but coarse, a count and the roles: `2 hand changes on the host (base, kubernetes)`;
- task names stay on the server, in `journalctl -u bedrock-drift`;
- once the host matches again, the timeline says so, once.

**What it is:**
- **The `drift` role** installs:
  - `/usr/local/bin/bedrock-drift`, which runs `ansible-playbook site.yml --check` with the JSON callback and posts to the timeline's Service IP;
  - `bedrock-drift.service` and `bedrock-drift.timer`, nightly at 02:30 UTC (08:00 IST).
- **The ingest token** is read from the cluster's `timeline-ingest` secret (`no_log`) into `/etc/bedrock/timeline-token`, mode 0600, readable only by you.
- **It runs on the host because it checks the host.** It reaches the timeline pod through its Service IP: a node may always reach the pods on it, which is how kubelet probes pass the default-deny policies.

**New Ansible ideas:**
- **`no_log`:** secrets out of output and diffs.
- **Callback plugins:** `ansible.posix.json` turns a run into data.
- **Installing systemd units:** templates, a `daemon_reload` handler, `enabled` + `started`.
- **Defaults built from facts and lookups:** `ansible_playbook_python | dirname`, `lookup('env', 'USER')`.

## Step 1: check, then apply

**Predict:**
- Which tasks are `changed`?
- Will `--diff` show the token?

```bash
cd ~/hetops-k8s-lab && git pull && cd bedrock
ansible-playbook site.yml --check --diff 2>&1 | grep -E -A3 '^TASK \[drift|^changed|no_log'
```

**Expected:**
- the drift role's tasks are `changed`: the script, `/etc/bedrock`, the token, both units, the reload and the timer;
- the token task prints `the output has been hidden due to the fact that 'no_log: true'`;
- everything else is `ok`.

```bash
ansible-playbook site.yml --diff | tail -2
systemctl list-timers bedrock-drift.timer --no-pager
ansible-playbook site.yml --check | tail -2
```

**Expected:**
- the apply ends with `failed=0`;
- the timer shows the next run at 02:30 UTC;
- the check that follows says `changed=0`.

## Step 2: run it now, clean

```bash
sudo systemctl start bedrock-drift.service
journalctl -u bedrock-drift.service --no-pager -o cat | tail -n 5
```

**Expected:** `0 changed, 0 failed, at <commit>; last time: clean`, and nothing posted (a clean host has nothing to say).

## Step 3: a hand change, caught by the timer's own run

**Predict:** what appears on the public timeline, and what stays on the server?

```bash
echo 'X11Forwarding yes' | sudo tee -a /etc/ssh/sshd_config.d/10-bedrock.conf
sudo systemctl start bedrock-drift.service
journalctl -u bedrock-drift.service --no-pager -o cat | tail -n 5
curl -s "https://lab.hetops.dev/timeline?since=10m" | jq -r '.[] | select(.source=="ansible") | "\(.at[11:19])  \(.severity)  \(.summary)"'
```

**Expected:**
- the journal: `would change: base : SSH uses Bedrock's settings`, `1 changed`, `timeline answered 202`;
- the timeline: `warn  1 hand change on the host (base)`.

## Step 4: put it back, and the timeline says so

```bash
ansible-playbook site.yml --diff | tail -2
sudo systemctl start bedrock-drift.service
curl -s "https://lab.hetops.dev/timeline?since=10m" | jq -r '.[] | select(.source=="ansible") | "\(.at[11:19])  \(.severity)  \(.summary)"'
```

**Expected:** a second line, `info  The host matches Bedrock again`.
