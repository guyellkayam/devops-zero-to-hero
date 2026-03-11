# 08 — MetalLB Setup

## Why This Matters
On AWS EKS, when you create a Service of type `LoadBalancer`, AWS automatically provisions
an Elastic Load Balancer (ALB/NLB) — at $16+/month each. On our bare-metal-like k3s setup,
there is no cloud provider to do this. Without MetalLB, any `LoadBalancer` service stays stuck
in `Pending` forever.

MetalLB acts as your own load balancer controller. It assigns real IPs from a pool you define
and announces them using Layer 2 (ARP). This lets services get external IPs just like they
would on a cloud-managed cluster — at zero extra cost and only ~40MB of RAM.

---

## Prerequisites
- k3s cluster running with `--disable servicelb` (from guide 07)
- kubectl working from your local machine
- Helm installed (from guide 02)
- Know your EC2 instance's **private IP** (e.g., `10.0.1.50`)

```bash
# Get your EC2 private IP (run on EC2 instance)
curl -s http://169.254.169.254/latest/meta-data/local-ipv4
# Example: 10.0.1.50

# Or from your local machine
kubectl get nodes -o wide
# Look at the INTERNAL-IP column
```

---

## Step 1: Add the MetalLB Helm Repository

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
```

---

## Step 2: Install MetalLB

```bash
helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait
```

### Wait for Pods to Be Ready:
```bash
# Watch pods start up
kubectl get pods -n metallb-system -w

# Expected (wait until all show Running):
# NAME                                  READY   STATUS    RESTARTS   AGE
# metallb-controller-xxxxxxxxx-xxxxx    1/1     Running   0          30s
# metallb-speaker-xxxxx                 1/1     Running   0          30s
```

- **controller**: Handles IP assignment decisions
- **speaker**: Announces IPs using ARP (Layer 2)

---

## Step 3: Configure IP Address Pool

MetalLB needs to know which IPs it can assign. On EC2, we use the instance's private IP
(since all traffic comes through the instance anyway via Envoy Gateway).

```bash
# Replace 10.0.1.50 with YOUR EC2 private IP
export EC2_PRIVATE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Using IP: $EC2_PRIVATE_IP"

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - ${EC2_PRIVATE_IP}/32
  autoAssign: true
EOF
```

> **Why `/32`?** We only have one IP (single node). On a multi-node setup or bare-metal
> with a real IP range, you would use something like `192.168.1.200-192.168.1.250`.

### Alternative: Hardcoded version
If the dynamic approach does not work, create the file manually:

```yaml
# metallb-ipaddresspool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.1.50/32      # <-- Replace with your EC2 private IP
  autoAssign: true
```

```bash
kubectl apply -f metallb-ipaddresspool.yaml
```

---

## Step 4: Configure L2 Advertisement

This tells MetalLB to respond to ARP requests for the IPs in the pool:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
```

---

## Step 5: Test with a Sample LoadBalancer Service

Deploy a simple nginx pod and expose it as a LoadBalancer:

```bash
# Create a test deployment
kubectl create deployment nginx-test --image=nginx:alpine --port=80

# Expose it as LoadBalancer
kubectl expose deployment nginx-test --type=LoadBalancer --port=80

# Check the service — it should get an EXTERNAL-IP (not Pending!)
kubectl get svc nginx-test -w
```

**Expected output:**
```
NAME         TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
nginx-test   LoadBalancer   10.43.200.50   10.0.1.50     80:31234/TCP   10s
```

The key thing: `EXTERNAL-IP` shows your EC2 private IP instead of `<pending>`.

### Verify it works:
```bash
# From EC2 instance
curl http://$(kubectl get svc nginx-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Should return the nginx welcome page HTML
```

### Clean up the test:
```bash
kubectl delete deployment nginx-test
kubectl delete svc nginx-test
```

---

## Step 6: Verify MetalLB Resource Usage

```bash
# Check actual RAM usage
kubectl top pods -n metallb-system

# Expected: ~20-40MB total across both pods
```

---

## Verify

```bash
echo "=== MetalLB Pods ==="
kubectl get pods -n metallb-system

echo ""
echo "=== IPAddressPool ==="
kubectl get ipaddresspool -n metallb-system

echo ""
echo "=== L2Advertisement ==="
kubectl get l2advertisement -n metallb-system

echo ""
echo "=== MetalLB Resource Usage ==="
kubectl top pods -n metallb-system 2>/dev/null || echo "Wait a minute for metrics to be available"
```

All pods should be `Running`, IPAddressPool and L2Advertisement should exist.

---

## How MetalLB Works (Conceptual)

```
[Pod] --> [ClusterIP Service] --> [MetalLB assigns External IP]
                                         |
                                   [Speaker announces via ARP]
                                         |
                                   [Traffic reaches the node]
                                         |
                                   [kube-proxy routes to pod]
```

1. You create a `type: LoadBalancer` service
2. MetalLB controller picks an IP from the pool
3. MetalLB speaker announces that IP via ARP on the network
4. Traffic to that IP reaches the node
5. kube-proxy forwards it to the correct pod

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| EXTERNAL-IP stuck on `<pending>` | Check IPAddressPool exists: `kubectl get ipaddresspool -n metallb-system` |
| Speaker pod CrashLoopBackOff | Check if k3s servicelb is still running: `kubectl get ds -n kube-system \| grep svclb`. If yes, reinstall k3s with `--disable servicelb` |
| "no available IPs" in events | Your pool is exhausted. With `/32` you only get 1 IP — shared across all LoadBalancer services (which is fine for single node + Envoy Gateway) |
| ARP not working | On EC2, L2 works within the same subnet. Verify node and pool are on the same subnet |
| Helm install fails | Ensure namespace exists: `kubectl create namespace metallb-system` |
| Multiple services need LB | With single IP, use Envoy Gateway (guide 13) as the single LoadBalancer entry point, then route by hostname/path |

### Debug Commands:
```bash
# Check MetalLB controller logs
kubectl logs -n metallb-system -l app.kubernetes.io/component=controller

# Check speaker logs
kubectl logs -n metallb-system -l app.kubernetes.io/component=speaker

# Check events
kubectl get events -n metallb-system --sort-by='.lastTimestamp'

# Describe the IPAddressPool
kubectl describe ipaddresspool -n metallb-system
```

---

## Checklist

- [ ] MetalLB Helm repo added
- [ ] MetalLB installed in `metallb-system` namespace
- [ ] Controller pod is Running
- [ ] Speaker pod is Running
- [ ] IPAddressPool created with EC2 private IP
- [ ] L2Advertisement created and references the pool
- [ ] Test LoadBalancer service gets an EXTERNAL-IP (not Pending)
- [ ] Test service responds to curl
- [ ] Test deployment and service cleaned up
- [ ] RAM usage is ~40MB or less

---

## What's Next?
-> [09 -- Longhorn Setup](09-longhorn-setup.md) — Add persistent storage so your databases and stateful apps survive pod restarts.
