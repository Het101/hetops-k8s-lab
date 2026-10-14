#!/usr/bin/env bash
# Turns on Kubernetes API audit logging on this kubeadm node (SIEM track, lab T1).
#   sudo platform/host/enable-audit.sh            apply
#   sudo platform/host/enable-audit.sh reload     re-install the policy and restart the API server
#   sudo platform/host/enable-audit.sh rollback   restore the backed-up manifest
# The kubelet watches /etc/kubernetes/manifests and restarts kube-apiserver about 30-60 s after
# the file changes. Running workloads are not affected; kubectl is unavailable meanwhile.
set -euo pipefail

MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
BACKUP=/root/kube-apiserver.yaml.before-audit   # outside manifests/: the kubelet would run any copy left there
POLICY_SRC="$(dirname "$0")/audit-policy.yaml"

if [[ "${1:-}" == reload ]]; then
  # kube-apiserver reads its audit policy only at start. Re-install the policy, then move the
  # manifest out and back so the kubelet recreates the static pod.
  install -m 0644 "$POLICY_SRC" /etc/kubernetes/audit/policy.yaml
  mv "$MANIFEST" /root/kube-apiserver.yaml.reloading && sleep 20 && mv /root/kube-apiserver.yaml.reloading "$MANIFEST"
  echo "policy reloaded; the API server is back in about a minute"
  exit 0
fi

if [[ "${1:-}" == rollback ]]; then
  cp "$BACKUP" "$MANIFEST" && echo "restored $MANIFEST from $BACKUP; the API server restarts in about a minute"
  exit 0
fi

if grep -q -- '--audit-policy-file' "$MANIFEST"; then echo "audit logging is already enabled"; exit 0; fi

install -d -m 0755 /etc/kubernetes/audit /var/log/kubernetes/audit
install -m 0644 "$POLICY_SRC" /etc/kubernetes/audit/policy.yaml
cp "$MANIFEST" "$BACKUP"

python3 - "$MANIFEST" <<'PY'
import sys
path = sys.argv[1]
s = open(path).read()

def insert_after(text, anchor, block):
    assert text.count(anchor) == 1, f"expected exactly one {anchor!r}"
    return text.replace(anchor, anchor + block, 1)

# Flags: rotate at 50 MB, keep 3 files for 3 days (Filebeat ships them to Elasticsearch anyway).
s = insert_after(s, "    - kube-apiserver\n",
    "    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml\n"
    "    - --audit-log-path=/var/log/kubernetes/audit/audit.log\n"
    "    - --audit-log-maxsize=50\n"
    "    - --audit-log-maxbackup=3\n"
    "    - --audit-log-maxage=3\n")
s = insert_after(s, "    volumeMounts:\n",
    "    - mountPath: /etc/kubernetes/audit\n      name: audit-policy\n      readOnly: true\n"
    "    - mountPath: /var/log/kubernetes/audit\n      name: audit-log\n")
s = insert_after(s, "  volumes:\n",
    "  - hostPath:\n      path: /etc/kubernetes/audit\n      type: DirectoryOrCreate\n    name: audit-policy\n"
    "  - hostPath:\n      path: /var/log/kubernetes/audit\n      type: DirectoryOrCreate\n    name: audit-log\n")
open(path, "w").write(s)
PY

echo "backup:  $BACKUP"
echo "applied: the API server restarts in about a minute. Check with:"
echo "  sudo tail -n 2 /var/log/kubernetes/audit/audit.log"
echo "rollback if kubectl is not back within 3 minutes:"
echo "  sudo $0 rollback"
