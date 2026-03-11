# 14 — Harbor Setup (Private Container Registry)

## Why This Matters

Every container image you build needs a place to live. Public registries like Docker
Hub work for open source, but for your own microservices you need a private registry.
Harbor is a CNCF graduated project that gives you: a private registry, vulnerability
scanning, access control, image replication, and audit logs. Running it inside your
cluster means zero network egress costs and instant image pulls (images stay local).

Without a private registry, you would push images to Docker Hub (slow, rate-limited,
and public by default) or pay for ECR ($0.10/GB/month). Harbor on Longhorn storage
costs nothing beyond the disk you already have.

On our resource-constrained cluster, we run Harbor in **RAM-optimized mode** by
disabling optional components. This brings usage down from ~1.5GB to about **500MB**.

---

## Prerequisites

| Requirement | How to Verify |
|-------------|---------------|
| k3s cluster running | `kubectl get nodes` shows Ready |
| Helm installed | `helm version --short` |
| Longhorn storage provisioner | `kubectl get storageclass` shows `longhorn` |
| cert-manager installed (Guide 12) | `kubectl get clusterissuers` |
| Envoy Gateway installed (Guide 13) | `kubectl get gateway -n envoy-gateway-system` |
| At least 2GB free RAM | `kubectl top nodes` or `free -h` on the node |
| DNS for Harbor (recommended) | `dig harbor.yourdomain.com` |

---

## Step 1: Prepare Storage

Harbor needs persistent volumes for the registry data, database, and Redis.

```bash
# Create the namespace
kubectl create namespace harbor

# Verify Longhorn is the default StorageClass (or set it)
kubectl get storageclass

# If longhorn isn't default:
# kubectl patch storageclass longhorn \
#   -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

---

## Step 2: Create TLS Certificate for Harbor

Use cert-manager to provision a TLS certificate for the Harbor registry.

### Option A: With a real domain (recommended)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: harbor-tls
  namespace: harbor
spec:
  secretName: harbor-tls-secret
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - harbor.yourdomain.com    # <-- REPLACE with your domain
  issuerRef:
    name: letsencrypt-staging   # Change to letsencrypt-production when ready
    kind: ClusterIssuer
EOF
```

### Option B: With self-signed certificate (for testing)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: harbor-tls
  namespace: harbor
spec:
  secretName: harbor-tls-secret
  duration: 8760h      # 1 year
  renewBefore: 720h
  dnsNames:
    - harbor.yourdomain.com
    - harbor.harbor.svc.cluster.local
    - core.harbor.svc.cluster.local
  issuerRef:
    name: internal-ca-issuer
    kind: ClusterIssuer
EOF

# Wait for certificate
kubectl get certificate harbor-tls -n harbor -w
# Wait for READY = True
```

---

## Step 3: Install Harbor with Helm (RAM-Optimized)

This configuration disables Trivy scanner, Notary, and Chartmuseum to save about
1GB of RAM. You can enable them later when you have more resources.

```bash
# Add the Harbor Helm repository
helm repo add harbor https://helm.goharbor.io
helm repo update

# Install Harbor with RAM-optimized settings
helm install harbor harbor/harbor \
  --namespace harbor \
  --version 1.16.1 \
  --values - <<'EOF'
# === Expose Configuration ===
expose:
  type: clusterIP
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: harbor-tls-secret

# External URL (how users access Harbor)
externalURL: https://harbor.yourdomain.com   # <-- REPLACE with your domain

# === Disable Optional Components (saves ~1GB RAM) ===
trivy:
  enabled: false       # Saves ~500MB — enable later for vulnerability scanning

notary:
  enabled: false       # Saves ~200MB — image signing (use cosign instead)

chartmuseum:
  enabled: false       # Saves ~100MB — we use OCI charts via the registry

# === Core Components (required) ===
core:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi

# === Portal (Web UI) ===
portal:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      memory: 128Mi

# === Job Service (async tasks) ===
jobservice:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      memory: 128Mi

# === Registry (stores images) ===
registry:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 256Mi

# === Database (PostgreSQL) ===
database:
  type: internal
  internal:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 256Mi

# === Redis (session cache) ===
redis:
  type: internal
  internal:
    resources:
      requests:
        cpu: 50m
        memory: 32Mi
      limits:
        memory: 64Mi

# === Storage ===
persistence:
  enabled: true
  persistentVolumeClaim:
    registry:
      storageClass: longhorn
      size: 10Gi
    database:
      storageClass: longhorn
      size: 2Gi
    redis:
      storageClass: longhorn
      size: 1Gi
    jobservice:
      jobLog:
        storageClass: longhorn
        size: 1Gi

# === Admin Credentials ===
harborAdminPassword: "ChangeMeN0w!"   # <-- CHANGE THIS

# === Cache & GC ===
cache:
  enabled: true
  expireHours: 24

# === Metrics (for Prometheus) ===
metrics:
  enabled: true
  serviceMonitor:
    enabled: false    # Enable when Prometheus is installed
EOF
```

### Wait for all pods to start:

```bash
# Watch pods come up (takes 2-3 minutes)
kubectl get pods -n harbor -w

# Expected pods (with optional components disabled):
# harbor-core-xxxxxxxxx-xxxxx           1/1  Running
# harbor-database-0                      1/1  Running
# harbor-jobservice-xxxxxxxxx-xxxxx     1/1  Running
# harbor-portal-xxxxxxxxx-xxxxx        1/1  Running
# harbor-redis-0                         1/1  Running
# harbor-registry-xxxxxxxxx-xxxxx      1/1  Running
```

---

## Step 4: Expose Harbor Through Envoy Gateway

Create an HTTPRoute to make Harbor accessible through your Gateway:

```bash
cat <<'EOF' | kubectl apply -f -
---
# Route for Harbor core API and UI
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: harbor-route
  namespace: harbor
spec:
  parentRefs:
    - name: devops-gateway
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - "harbor.yourdomain.com"   # <-- REPLACE with your domain
  rules:
    # API and Docker registry endpoints
    - matches:
        - path:
            type: PathPrefix
            value: /v2/
      backendRefs:
        - name: harbor-core
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /api/
      backendRefs:
        - name: harbor-core
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /service/
      backendRefs:
        - name: harbor-core
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /c/
      backendRefs:
        - name: harbor-core
          port: 80
    # Portal (Web UI) - catch-all
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: harbor-portal
          port: 80
EOF
```

---

## Step 5: Create Projects for Microservices

Log into Harbor and create projects for each microservice.

### Access the Web UI:

```bash
# If using a real domain:
echo "Open: https://harbor.yourdomain.com"

# If testing locally (port-forward):
kubectl port-forward -n harbor svc/harbor-portal 8443:443 &
echo "Open: https://localhost:8443"
echo "Username: admin"
echo "Password: ChangeMeN0w!"
```

### Create projects via the API:

```bash
# Set your Harbor URL
HARBOR_URL="https://harbor.yourdomain.com"
# For local testing: HARBOR_URL="https://localhost:8443"

# Create projects for each microservice
for project in api-gateway user-service order-service shared-libs; do
  curl -k -u "admin:ChangeMeN0w!" \
    -X POST "$HARBOR_URL/api/v2.0/projects" \
    -H "Content-Type: application/json" \
    -d "{
      \"project_name\": \"$project\",
      \"public\": false,
      \"storage_limit\": 5368709120
    }"
  echo " -> Created project: $project"
done

# Verify projects were created
curl -k -u "admin:ChangeMeN0w!" \
  "$HARBOR_URL/api/v2.0/projects" | jq '.[].name'
```

---

## Step 6: Configure Docker Login

### Login to Harbor from your local machine:

```bash
# If using self-signed certs, add Harbor's CA to Docker
# (skip this if using Let's Encrypt)
kubectl get secret harbor-tls-secret -n harbor \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/harbor-ca.crt

# For Docker Desktop on macOS:
sudo mkdir -p /etc/docker/certs.d/harbor.yourdomain.com
sudo cp /tmp/harbor-ca.crt /etc/docker/certs.d/harbor.yourdomain.com/ca.crt

# Login
docker login harbor.yourdomain.com
# Username: admin
# Password: ChangeMeN0w!
```

### Configure k3s containerd to trust Harbor:

On the k3s node, configure containerd to pull from Harbor:

```bash
# SSH into your EC2 instance, then:
sudo mkdir -p /etc/rancher/k3s

cat <<'EOF' | sudo tee /etc/rancher/k3s/registries.yaml
mirrors:
  "harbor.yourdomain.com":
    endpoint:
      - "https://harbor.yourdomain.com"
configs:
  "harbor.yourdomain.com":
    auth:
      username: admin
      password: ChangeMeN0w!
    tls:
      insecure_skip_verify: false    # Set to true only for self-signed certs in dev
EOF

# Restart k3s to pick up the registry config
sudo systemctl restart k3s

# Verify k3s can pull from Harbor
sudo crictl pull harbor.yourdomain.com/shared-libs/test:latest 2>/dev/null || \
  echo "Expected to fail (no image yet) — but check the error message"
```

---

## Step 7: Push and Pull a Test Image

```bash
# Pull a small test image
docker pull busybox:latest

# Tag it for Harbor
docker tag busybox:latest harbor.yourdomain.com/shared-libs/busybox:v1.0

# Push to Harbor
docker push harbor.yourdomain.com/shared-libs/busybox:v1.0

# Verify it's in Harbor
curl -k -u "admin:ChangeMeN0w!" \
  "$HARBOR_URL/api/v2.0/projects/shared-libs/repositories" | jq '.[].name'

# Pull it back (proves the round-trip works)
docker rmi harbor.yourdomain.com/shared-libs/busybox:v1.0
docker pull harbor.yourdomain.com/shared-libs/busybox:v1.0
```

### Test pulling from inside the cluster:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: harbor-pull-test
  namespace: default
spec:
  containers:
    - name: test
      image: harbor.yourdomain.com/shared-libs/busybox:v1.0
      command: ["sh", "-c", "echo 'Harbor pull successful!' && sleep 10"]
      resources:
        requests:
          cpu: 10m
          memory: 8Mi
        limits:
          memory: 16Mi
  restartPolicy: Never
EOF

# Check if the pod started successfully
kubectl get pod harbor-pull-test
kubectl logs harbor-pull-test

# Clean up
kubectl delete pod harbor-pull-test
```

---

## Step 8: Enable Vulnerability Scanning (Optional)

When you have more RAM available (e.g., after upgrading to t3.xlarge), enable Trivy:

```bash
helm upgrade harbor harbor/harbor \
  --namespace harbor \
  --reuse-values \
  --set trivy.enabled=true \
  --set trivy.resources.requests.cpu=100m \
  --set trivy.resources.requests.memory=256Mi \
  --set trivy.resources.limits.memory=512Mi

# Wait for Trivy pod
kubectl get pods -n harbor -l component=trivy -w

# Trigger a scan on the test image via the UI:
# Go to Projects -> shared-libs -> busybox -> v1.0 -> Scan
```

---

## Verify

```bash
#!/bin/bash
echo "=== Harbor Verification ==="

echo ""
echo "--- Pods ---"
kubectl get pods -n harbor
echo ""

echo "--- Persistent Volumes ---"
kubectl get pvc -n harbor
echo ""

echo "--- Services ---"
kubectl get svc -n harbor
echo ""

echo "--- Storage Usage ---"
kubectl get pvc -n harbor -o custom-columns=\
NAME:.metadata.name,\
SIZE:.spec.resources.requests.storage,\
STATUS:.status.phase
echo ""

echo "--- Registry Endpoint Test ---"
HARBOR_URL="https://harbor.yourdomain.com"   # <-- REPLACE
curl -k -s -o /dev/null -w "Harbor API Status: %{http_code}\n" \
  -u "admin:ChangeMeN0w!" "$HARBOR_URL/api/v2.0/health" 2>/dev/null || \
  echo "Cannot reach Harbor (try port-forward)"
echo ""

echo "--- Projects ---"
curl -k -s -u "admin:ChangeMeN0w!" \
  "$HARBOR_URL/api/v2.0/projects" 2>/dev/null | \
  jq -r '.[].name' 2>/dev/null || echo "Cannot list projects"
echo ""

echo "--- Resource Usage ---"
kubectl top pods -n harbor 2>/dev/null || \
  echo "Metrics server not available"
echo ""

echo "--- Certificate ---"
kubectl get certificate -n harbor
echo ""

echo "=== Verification Complete ==="
```

---

## Troubleshooting

### Harbor core pod in CrashLoopBackOff

```bash
# Check logs
kubectl logs -n harbor -l component=core --tail=50

# Common cause: database not ready yet
# Fix: wait for harbor-database-0 to be Running first
kubectl get pod harbor-database-0 -n harbor -w

# If database PVC is stuck:
kubectl get pvc -n harbor
kubectl describe pvc -n harbor data-harbor-database-0
```

### Cannot push images — "unauthorized"

```bash
# Re-login to Docker
docker logout harbor.yourdomain.com
docker login harbor.yourdomain.com

# Check if the project exists
curl -k -u "admin:ChangeMeN0w!" \
  "https://harbor.yourdomain.com/api/v2.0/projects" | jq '.[].name'

# Check robot accounts (if using them)
curl -k -u "admin:ChangeMeN0w!" \
  "https://harbor.yourdomain.com/api/v2.0/robots" | jq '.[].name'
```

### Common errors and fixes:

| Error | Cause | Fix |
|-------|-------|-----|
| `x509: certificate signed by unknown authority` | Self-signed cert not trusted | Add CA to Docker certs.d or use `--insecure-registry` |
| `413 Request Entity Too Large` | Image too large for Envoy Gateway | Add `client_max_body_size` annotation or increase proxy buffer |
| PVC stuck in Pending | Longhorn not provisioning | Check `kubectl get pods -n longhorn-system` |
| `database connection refused` | Database pod not ready | Wait for `harbor-database-0` to be 1/1 Running |
| `OOMKilled` on core/registry | Not enough memory | Increase limits in Helm values |
| `port-forward` disconnects | k3s killing idle connections | Use `while true; do kubectl port-forward ...; done` |

### Reset admin password:

```bash
# Connect to the Harbor database
kubectl exec -it -n harbor harbor-database-0 -- \
  psql -U postgres -d registry

# In the psql prompt:
# UPDATE harbor_user SET password='new-bcrypt-hash', salt='new-salt' WHERE username='admin';
# \q

# Easier: reset via Helm
helm upgrade harbor harbor/harbor \
  --namespace harbor \
  --reuse-values \
  --set harborAdminPassword="NewPassword123!"
```

---

## Checklist

- [ ] Harbor Helm chart installed in `harbor` namespace
- [ ] All core pods running (core, portal, registry, database, redis, jobservice)
- [ ] Trivy, Notary, and Chartmuseum disabled (RAM-optimized)
- [ ] TLS certificate provisioned by cert-manager
- [ ] Harbor accessible via Envoy Gateway HTTPRoute
- [ ] Projects created: api-gateway, user-service, order-service, shared-libs
- [ ] Docker login works from local machine
- [ ] k3s containerd configured to trust Harbor (`registries.yaml`)
- [ ] Push/pull test image successful
- [ ] In-cluster pull test successful
- [ ] PVCs bound on Longhorn storage
- [ ] Total memory usage around 500MB (without Trivy)

---

## What's Next?

With Harbor running, you now have a complete image lifecycle:

1. **Build** images in CI/CD (GitHub Actions)
2. **Push** to Harbor
3. **Scan** for vulnerabilities (when Trivy is enabled)
4. **Pull** from k3s for deployment

Next steps:

- **Guide 15 — PostgreSQL Operator**: Database for Harbor's metadata (optionally
  migrate from Harbor's built-in PostgreSQL to CloudNativePG for a unified database
  platform)
- **CI/CD Pipeline**: Configure GitHub Actions to build images and push to Harbor
- **Image Signing**: Use cosign to sign images in Harbor for supply chain security

> **TIP**: Change the admin password immediately after setup. Better yet, create
> robot accounts for CI/CD and personal accounts for developers. Never use the
> admin account for day-to-day operations.
