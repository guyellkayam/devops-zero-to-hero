# 07 — k3s Cluster Setup

## Why This Matters
k3s is a lightweight, certified Kubernetes distribution built for edge, IoT, and resource-constrained
environments. On our t3.large EC2 instance with only 8GB RAM, k3s uses ~500MB compared to full
kubeadm's 1.5GB+. That freed memory lets us run 35 tools on a single node for ~$25-45/month.

k3s gives you a real Kubernetes cluster with the full API, CRDs, RBAC, and everything you'd find
in EKS or GKE — just without the $75/month control plane fee.

---

## Prerequisites
- EC2 t3.large instance running (from guide 05/06)
- SSH access working: `ssh -i ~/.ssh/devops-key.pem ubuntu@<EC2_PUBLIC_IP>`
- Security group allows inbound: SSH (22), HTTP (80), HTTPS (443), K8s API (6443)
- Local tools installed: kubectl, helm, k9s (from guide 02)

---

## RAM Budget Overview

Before installing anything, understand how our 8GB is allocated:

| Component | RAM Usage | Notes |
|-----------|-----------|-------|
| **OS + system** | ~500MB | Ubuntu base processes |
| **k3s server** | ~500MB | API server, scheduler, controller, etcd |
| **MetalLB** | ~40MB | Load balancer (guide 08) |
| **Longhorn** | ~250MB | Storage (guide 09) |
| **Vault** | ~200MB | Secrets (guide 10) |
| **ESO** | ~80MB | External Secrets Operator (guide 11) |
| **ArgoCD** | ~400MB | GitOps (guide 12) |
| **Envoy Gateway** | ~100MB | Ingress (guide 13) |
| **Monitoring stack** | ~600MB | Prometheus + Grafana |
| **Your workloads** | ~1-2GB | Microservices, CI runners |
| **Buffer** | ~1-2GB | Headroom for spikes |
| **Total** | ~8GB | |

Every MB counts. That is why we disable built-in components we are replacing with better alternatives.

---

## Step 1: SSH Into Your EC2 Instance

```bash
# From your local machine
ssh -i ~/.ssh/devops-key.pem ubuntu@<EC2_PUBLIC_IP>

# Verify you're on the right box
hostname
uname -a
free -h   # Should show ~8GB total
```

> **TIP**: Add this to your `~/.ssh/config` for easier access:
> ```
> Host devops
>   HostName <EC2_PUBLIC_IP>
>   User ubuntu
>   IdentityFile ~/.ssh/devops-key.pem
> ```
> Then just: `ssh devops`

---

## Step 2: Install k3s

```bash
# Install k3s with custom flags
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --tls-san $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4) \
  " sh -
```

### What Each Flag Does:

| Flag | Why |
|------|-----|
| `--disable traefik` | We use Envoy Gateway instead (more features, Gateway API native) |
| `--disable servicelb` | We use MetalLB instead (more configurable, industry standard) |
| `--write-kubeconfig-mode 644` | Lets non-root users read kubeconfig |
| `--tls-san <public-ip>` | Adds your public IP to the API server TLS cert so kubectl works remotely |

### Verify k3s Is Running

```bash
# Check k3s service
sudo systemctl status k3s

# Should show: Active: active (running)

# Check node is Ready
sudo kubectl get nodes

# Expected output:
# NAME              STATUS   ROLES                  AGE   VERSION
# ip-10-0-1-xxx     Ready    control-plane,master   30s   v1.31.x+k3s1
```

---

## Step 3: Verify Core Components

```bash
# All system pods should be Running
sudo kubectl get pods -n kube-system

# Expected pods (traefik and svclb should NOT appear):
# NAME                                      READY   STATUS    RESTARTS   AGE
# coredns-xxxxxxxxx-xxxxx                   1/1     Running   0          1m
# local-path-provisioner-xxxxxxxxx-xxxxx    1/1     Running   0          1m
# metrics-server-xxxxxxxxx-xxxxx            1/1     Running   0          1m
```

Things to confirm:
- **coredns**: DNS resolution inside the cluster
- **local-path-provisioner**: Default storage (we replace with Longhorn in guide 09)
- **metrics-server**: Enables `kubectl top` commands
- **No traefik pods**: We disabled it (Envoy Gateway comes later)
- **No svclb pods**: We disabled it (MetalLB comes later)

---

## Step 4: Copy Kubeconfig to Your Local Machine

The kubeconfig file contains the credentials to talk to your cluster. You need it on your laptop.

### On the EC2 instance — get the kubeconfig:
```bash
# Print the kubeconfig
sudo cat /etc/rancher/k3s/k3s.yaml
```

### On your local machine — save it:
```bash
# Create the .kube directory if it doesn't exist
mkdir -p ~/.kube

# Copy kubeconfig from EC2 to local machine
scp -i ~/.ssh/devops-key.pem ubuntu@<EC2_PUBLIC_IP>:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config

# Replace the internal IP (127.0.0.1) with the EC2 public IP
sed -i '' "s/127.0.0.1/<EC2_PUBLIC_IP>/g" ~/.kube/k3s-config
# On Linux (no '' after -i):
# sed -i "s/127.0.0.1/<EC2_PUBLIC_IP>/g" ~/.kube/k3s-config
```

> **SECURITY**: This file contains full admin credentials to your cluster.
> Never commit it to Git. Never share it.

---

## Step 5: Set Up kubectl Context

```bash
# Option A: Use as your default config
export KUBECONFIG=~/.kube/k3s-config

# Add to your shell profile so it persists
echo 'export KUBECONFIG=~/.kube/k3s-config' >> ~/.zshrc  # or ~/.bashrc
source ~/.zshrc

# Option B: Merge with existing kubeconfig (if you have other clusters)
cp ~/.kube/config ~/.kube/config.backup  # backup first
KUBECONFIG=~/.kube/config:~/.kube/k3s-config kubectl config view --flatten > ~/.kube/config.merged
mv ~/.kube/config.merged ~/.kube/config

# Rename the context for clarity
kubectl config rename-context default devops-zero-to-hero

# Switch to it
kubectl config use-context devops-zero-to-hero
```

---

## Step 6: Test Remote Access

```bash
# From your LOCAL machine, verify cluster access
kubectl get nodes

# Expected:
# NAME              STATUS   ROLES                  AGE   VERSION
# ip-10-0-1-xxx     Ready    control-plane,master   5m    v1.31.x+k3s1

# Check cluster info
kubectl cluster-info

# Check all namespaces
kubectl get pods -A

# Check resource usage
kubectl top nodes
```

If `kubectl get nodes` works from your laptop, your cluster is fully operational.

---

## Step 7: Create Base Namespaces

Set up the namespace structure we will use throughout the project:

```bash
# On the EC2 instance or from your local machine (both work now)

# Infrastructure namespaces
kubectl create namespace metallb-system    # Guide 08
kubectl create namespace longhorn-system   # Guide 09
kubectl create namespace vault             # Guide 10
kubectl create namespace eso               # Guide 11
kubectl create namespace argocd            # Guide 12
kubectl create namespace envoy-gateway     # Guide 13
kubectl create namespace cert-manager      # TLS certificates
kubectl create namespace monitoring        # Prometheus + Grafana

# Application namespaces
kubectl create namespace apps-staging
kubectl create namespace apps-production

# Verify
kubectl get namespaces
```

---

## Step 8: Set Resource Limits (Protect the Node)

Create a default LimitRange so no single pod can eat all the RAM:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: default
spec:
  limits:
  - default:
      memory: "256Mi"
      cpu: "250m"
    defaultRequest:
      memory: "128Mi"
      cpu: "100m"
    type: Container
EOF
```

This means any pod in the `default` namespace without explicit resource requests
gets capped at 256Mi RAM and 0.25 CPU cores.

---

## Verify

Run this full verification from your **local machine**:

```bash
echo "=== Node Status ==="
kubectl get nodes -o wide

echo ""
echo "=== System Pods ==="
kubectl get pods -n kube-system

echo ""
echo "=== All Namespaces ==="
kubectl get namespaces

echo ""
echo "=== Resource Usage ==="
kubectl top nodes

echo ""
echo "=== k3s Version ==="
kubectl version --short 2>/dev/null || kubectl version

echo ""
echo "=== Cluster Info ==="
kubectl cluster-info
```

**All checks should pass**:
- Node shows `Ready`
- System pods are `Running`
- Namespaces are created
- kubectl works from your laptop

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `kubectl: connection refused` | Check EC2 security group allows port 6443 inbound from your IP |
| Node shows `NotReady` | SSH in, run `sudo systemctl status k3s` and check logs with `sudo journalctl -u k3s -f` |
| `x509: certificate is valid for...` | You forgot `--tls-san`. Reinstall: `curl -sfL https://get.k3s.io \| INSTALL_K3S_EXEC="--tls-san <PUBLIC_IP>" sh -` |
| `Unable to connect to the server` | Verify EC2 is running, check public IP hasn't changed (use Elastic IP!) |
| Traefik pods still running | k3s caches manifests. Run `sudo rm -rf /var/lib/rancher/k3s/server/manifests/traefik*` then restart k3s |
| `metrics-server` not working | Wait 2-3 minutes after install, it needs time to collect data |
| Permission denied on kubeconfig | Re-run install with `--write-kubeconfig-mode 644` or `sudo chmod 644 /etc/rancher/k3s/k3s.yaml` |

### Useful Debug Commands (on EC2):
```bash
# k3s logs
sudo journalctl -u k3s -f --no-pager | tail -50

# Check k3s config
sudo cat /etc/rancher/k3s/config.yaml

# Restart k3s
sudo systemctl restart k3s

# Full uninstall (nuclear option)
/usr/local/bin/k3s-uninstall.sh
```

---

## Checklist

- [ ] SSH into EC2 instance works
- [ ] k3s installed with `--disable traefik` and `--disable servicelb`
- [ ] `--tls-san` includes EC2 public IP
- [ ] Node shows `Ready` status
- [ ] coredns, local-path-provisioner, metrics-server pods Running
- [ ] No traefik or svclb pods exist
- [ ] Kubeconfig copied to local machine
- [ ] `127.0.0.1` replaced with EC2 public IP in kubeconfig
- [ ] `kubectl get nodes` works from local machine
- [ ] kubectl context named and set
- [ ] Base namespaces created
- [ ] Default LimitRange applied

---

## What's Next?
-> [08 -- MetalLB Setup](08-metallb-setup.md) — Give your cluster a load balancer so services can get external IPs.
