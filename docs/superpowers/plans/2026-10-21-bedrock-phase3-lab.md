# Bedrock Phase 3: rebuild from nothing, proven in CI (lab sheet)

**Goal:** a GitHub Actions job takes a blank arm64 Ubuntu 24.04 machine and runs the playbook. It ends with a one-node cluster, a test pod `Running` and the audit log being written. A second run must report `changed=0`. The job records how long it took.

**The constraint:** the roles that *create* things must create **exactly what the live server already has**: the same file names, the same contents. Then the live `--check` stays at `changed=0`, and "rebuilt from nothing" means "rebuilt into *this* server".

**Who does what:**
- Claude builds and debugs the rebuild in CI, on GitHub's throwaway machines; nothing there touches the server.
- The owner runs the discovery below, and at the end one live `--check --diff`.

## Step 1: discovery (read-only)

**Predict:**
- Is the Kubernetes apt repo a `.list` or a `.sources` file?
- Which Calico version is it, and was it installed with the Tigera operator?

```bash
ls -l /etc/apt/sources.list.d/ /etc/apt/keyrings/ /usr/share/keyrings/ 2>&1 | grep -v '^total'
grep -h -v '^#' /etc/apt/sources.list.d/*kube* /etc/apt/sources.list.d/*docker* 2>/dev/null
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.containers[*].image}{"\n"}{end}' | grep -i -E 'calico|tigera' | sort -u
kubectl get installation default -o jsonpath='{.spec.calicoNetwork.ipPools}' 2>&1; echo
kubectl describe node | grep -i -A2 taints
sudo cat /var/lib/kubelet/kubeadm-flags.env; echo; containerd --version
sudo head -5 /etc/containerd/config.toml; sudo grep -n -E 'disabled_plugins|sandbox|SystemdCgroup' /etc/containerd/config.toml
kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' | grep -E 'cgroupDriver|containerRuntimeEndpoint|failSwapOn'
```

Paste all of it to Claude.
