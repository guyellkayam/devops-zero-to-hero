# 09 — Longhorn Storage Setup

## Why This Matters
Kubernetes pods are ephemeral — when a pod dies, its data dies with it. If you run PostgreSQL,
Redis, Vault, or any stateful workload, you need **persistent storage** that survives pod restarts,
rescheduling, and crashes.

k3s ships with `local-path-provisioner` which stores data on the host filesystem. That works, but
it has zero redundancy, no snapshots, no backup, and no dashboard. Longhorn gives you:

- **Persistent Volumes** that survive pod deletion
- **Snapshots and backups** (to S3)
- **A web dashboard** to visualize storage usage
- **Automatic replica management** (on multi-node setups)
- All of this at ~250MB RAM on a single node

---

## Prerequisites
- k3s cluster running (from guide 07)
- kubectl and Helm working from local machine
- `longhorn-system` namespace exists (created in guide 07)

---

## Step 1: Install Prerequisites on EC2

Longhorn requires `open-iscsi` and `util-linux` on the node. SSH into your EC2 instance:

```bash
ssh devops  # or ssh -i ~/.ssh/devops-key.pem ubuntu@<EC2_PUBLIC_IP>

# Install required packages
sudo apt-get update
sudo apt-get install -y open-iscsi util-linux

# Enable and start iscsid
sudo systemctl enable iscsid
sudo systemctl start iscsid

# Verify iscsid is running
sudo systemctl status iscsid
# Should show: Active: active (running)
```

### Run Longhorn's Environment Check (optional but recommended):
```bash
# This script checks all requirements
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/master/scripts/environment_check.sh | bash
```

All checks should pass. Minor warnings about NFS are safe to ignore (we are not using NFS).

---

## Step 2: Add the Longhorn Helm Repository

```bash
# From your local machine
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

---

## Step 3: Install Longhorn

```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultReplicaCount=1 \
  --set defaultSettings.defaultDataPath="/var/lib/longhorn" \
  --set defaultSettings.storageMinimalAvailablePercentage=15 \
  --set defaultSettings.guaranteedInstanceManagerCPU=5 \
  --set persistence.defaultClassReplicaCount=1 \
  --set csi.attacherReplicaCount=1 \
  --set csi.provisionerReplicaCount=1 \
  --set csi.resizerReplicaCount=1 \
  --set csi.snapshotterReplicaCount=1 \
  --set longhornUI.replicas=1 \
  --wait \
  --timeout 5m
```

### What These Settings Do:

| Setting | Value | Why |
|---------|-------|-----|
| `defaultReplicaCount=1` | 1 replica | Single node — no point replicating to itself |
| `defaultDataPath` | `/var/lib/longhorn` | Where Longhorn stores volume data on disk |
| `storageMinimalAvailablePercentage=15` | 15% | Alert when disk is 85% full |
| `guaranteedInstanceManagerCPU=5` | 5% | Reduce CPU reservation (we are RAM-constrained) |
| `*ReplicaCount=1` | 1 each | Single node does not need multiple CSI controller replicas |

---

## Step 4: Wait for All Pods to Start

Longhorn deploys several components. Give it a few minutes:

```bash
# Watch all pods come up
kubectl get pods -n longhorn-system -w

# Wait until all show Running (usually 2-4 minutes)
# Expected pods:
# longhorn-manager-xxxxx          1/1   Running
# longhorn-driver-deployer-xxxxx  1/1   Running
# longhorn-ui-xxxxx               1/1   Running
# csi-attacher-xxxxx              1/1   Running
# csi-provisioner-xxxxx           1/1   Running
# csi-resizer-xxxxx               1/1   Running
# csi-snapshotter-xxxxx           1/1   Running
# engine-image-xxxxx              1/1   Running
# instance-manager-xxxxx          1/1   Running
```

---

## Step 5: Set Longhorn as the Default StorageClass

```bash
# Check current StorageClasses
kubectl get storageclass

# You should see both:
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
# longhorn               driver.longhorn.io      Delete          Immediate

# Remove default from local-path
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# Set longhorn as default
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verify
kubectl get storageclass
# longhorn should now show (default)
```

---

## Step 6: Test Persistent Storage

Create a test PVC and pod to verify everything works:

```bash
cat <<'EOF' | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-longhorn-pod
spec:
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo 'Longhorn works!' > /data/test.txt && cat /data/test.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-longhorn-pvc
EOF
```

```bash
# Wait for pod to start
kubectl get pod test-longhorn-pod -w

# Check it wrote the file
kubectl logs test-longhorn-pod
# Should output: Longhorn works!

# Check the PVC is Bound
kubectl get pvc test-longhorn-pvc
# STATUS should be Bound
```

### Test persistence — delete the pod and recreate it:
```bash
# Delete the pod (PVC survives)
kubectl delete pod test-longhorn-pod

# Recreate with a pod that reads the data
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-longhorn-pod
spec:
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "cat /data/test.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-longhorn-pvc
EOF

# Check data survived
kubectl logs test-longhorn-pod
# Should still output: Longhorn works!
```

### Clean up test resources:
```bash
kubectl delete pod test-longhorn-pod
kubectl delete pvc test-longhorn-pvc
```

---

## Step 7: Access the Longhorn Dashboard

The Longhorn UI provides a visual way to manage volumes, snapshots, and backups.

```bash
# Port-forward the UI to your laptop
kubectl port-forward -n longhorn-system svc/longhorn-frontend 9000:80

# Open in browser: http://localhost:9000
```

From the dashboard you can:
- See all volumes and their health
- Create and restore snapshots
- Monitor disk usage
- Configure backup targets (S3)

> **NOTE**: In production, you would expose this behind authentication (Envoy Gateway + OAuth).
> For now, port-forward is sufficient and more secure.

---

## Step 8: Configure S3 Backup (Optional but Recommended)

Set up backups to S3 so you can recover even if the EC2 instance dies:

```bash
# First, create an S3 bucket for backups (from local machine)
aws s3 mb s3://devops-zero-longhorn-backups --region us-east-1

# Create a Kubernetes secret with AWS credentials for Longhorn
kubectl create secret generic aws-secret \
  --namespace longhorn-system \
  --from-literal=AWS_ACCESS_KEY_ID=<YOUR_ACCESS_KEY> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<YOUR_SECRET_KEY>
```

Then in the Longhorn UI (http://localhost:9000):
1. Go to **Settings** > **General**
2. Set **Backup Target**: `s3://devops-zero-longhorn-backups@us-east-1/`
3. Set **Backup Target Credential Secret**: `aws-secret`
4. Click **Save**

---

## Verify

```bash
echo "=== Longhorn Pods ==="
kubectl get pods -n longhorn-system

echo ""
echo "=== StorageClasses ==="
kubectl get storageclass

echo ""
echo "=== Longhorn Volumes ==="
kubectl get volumes.longhorn.io -n longhorn-system

echo ""
echo "=== Longhorn Nodes ==="
kubectl get nodes.longhorn.io -n longhorn-system

echo ""
echo "=== Resource Usage ==="
kubectl top pods -n longhorn-system 2>/dev/null || echo "Wait for metrics"

echo ""
echo "=== PV/PVC Status ==="
kubectl get pv,pvc -A
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Pods stuck in `ContainerCreating` | Check iscsid: `ssh devops 'sudo systemctl status iscsid'` |
| PVC stuck in `Pending` | Check Longhorn manager logs: `kubectl logs -n longhorn-system -l app=longhorn-manager` |
| `open-iscsi` not found | SSH in and install: `sudo apt-get install -y open-iscsi` |
| Volume attach failures | Check instance-manager: `kubectl logs -n longhorn-system -l longhorn.io/component=instance-manager` |
| Dashboard not loading | Verify port-forward is running and frontend pod is healthy |
| Disk space running low | Check with `ssh devops 'df -h /var/lib/longhorn'` |
| Slow volume creation | Normal for first volume (~30s). Subsequent ones are faster |

### Debug Commands:
```bash
# Longhorn manager logs (main controller)
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50

# Check Longhorn settings
kubectl get settings.longhorn.io -n longhorn-system

# Check node storage status
kubectl get nodes.longhorn.io -n longhorn-system -o yaml

# Check events
kubectl get events -n longhorn-system --sort-by='.lastTimestamp' | tail -20
```

---

## Checklist

- [ ] `open-iscsi` installed and `iscsid` running on EC2
- [ ] Longhorn Helm repo added
- [ ] Longhorn installed in `longhorn-system` namespace
- [ ] All Longhorn pods are Running (manager, UI, CSI drivers)
- [ ] Longhorn set as the default StorageClass
- [ ] `local-path` no longer the default
- [ ] Test PVC created and bound successfully
- [ ] Data persists across pod deletion and recreation
- [ ] Test resources cleaned up
- [ ] Longhorn dashboard accessible via port-forward
- [ ] (Optional) S3 backup target configured
- [ ] RAM usage is ~250MB or less

---

## What's Next?
-> [10 -- Vault Setup](10-vault-setup.md) — Install HashiCorp Vault to securely manage secrets for all your microservices.
