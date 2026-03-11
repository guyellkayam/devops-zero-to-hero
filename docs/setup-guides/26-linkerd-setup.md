# 26 — Linkerd Service Mesh Setup

## Why This Matters
In production, every service talks to every other service over the network. Without a service mesh,
you have no encryption between services (anyone who gets on the node can sniff traffic), no
per-route metrics, no traffic splitting, and no retries/timeouts at the infrastructure level.

Linkerd is the CNCF graduated service mesh written in Rust. Here is why we chose it over Istio:

| Feature | Linkerd | Istio |
|---------|---------|-------|
| **Sidecar RAM** | ~2MB per pod | ~10-50MB per pod |
| **Control plane RAM** | ~250MB | ~1-2GB |
| **Complexity** | Simple, opinionated | Flexible, complex |
| **mTLS** | Automatic, zero-config | Requires configuration |
| **Language** | Rust (micro-proxy) | C++ (Envoy) |
| **CNCF status** | Graduated | Graduated |

With 8GB total RAM and 35 tools running, every megabyte counts. Linkerd's Rust-based micro-proxy
(linkerd2-proxy) uses 5x less memory per sidecar than Istio's Envoy sidecars. For our learning
platform with 3 microservices, that is ~6MB vs ~30-150MB in sidecar overhead alone.

What you get: automatic mTLS between all services, golden metrics (latency, throughput, success
rate) per route, traffic splitting for canary deployments, and retries/timeouts -- all without
changing a single line of application code.

---

## Prerequisites
- k3s cluster running (guide 07)
- kubectl configured and working
- Helm 3 installed (guide 02)
- Prometheus + Grafana running (guide 14/15)
- At least one microservice deployed (guide 17+)
- ~250MB RAM available for Linkerd control plane

---

## RAM Budget Impact

| Component | RAM Usage | Notes |
|-----------|-----------|-------|
| **linkerd-destination** | ~80MB | Service discovery, traffic policy |
| **linkerd-identity** | ~50MB | mTLS certificate management |
| **linkerd-proxy-injector** | ~40MB | Webhook for sidecar injection |
| **linkerd-viz (dashboard)** | ~80MB | Optional, metrics + dashboard |
| **Per-sidecar proxy** | ~2MB each | Rust micro-proxy per pod |
| **Total** | ~250MB + ~2MB/pod | |

---

## Step 1: Install the Linkerd CLI

The CLI is used for installation, validation, and debugging.

```bash
# Download the latest stable Linkerd CLI
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install | sh

# Add to PATH
export PATH=$HOME/.linkerd2/bin:$PATH

# Make it permanent
echo 'export PATH=$HOME/.linkerd2/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# Verify installation
linkerd version --client
```

Expected output:
```
Client version: stable-2.14.x
```

---

## Step 2: Validate Your Cluster

Before installing the control plane, verify your cluster is compatible.

```bash
# Run pre-installation checks
linkerd check --pre
```

This checks:
- Kubernetes version compatibility
- RBAC permissions
- Node resources
- Network policies

All checks should pass with green checkmarks. If any fail, the output tells you exactly what
to fix.

---

## Step 3: Install Linkerd CRDs

Linkerd uses a two-phase install: CRDs first, then control plane.

```bash
# Install Custom Resource Definitions
linkerd install --crds | kubectl apply -f -
```

Verify CRDs are installed:
```bash
kubectl get crds | grep linkerd
```

Expected output includes:
```
authorizationpolicies.policy.linkerd.io
httproutes.policy.linkerd.io
meshtlsauthentications.policy.linkerd.io
networkauthentications.policy.linkerd.io
serverauthorizations.policy.linkerd.io
servers.policy.linkerd.io
serviceprofiles.linkerd.io
```

---

## Step 4: Install the Linkerd Control Plane

```bash
# Install control plane with resource limits appropriate for t3.large
linkerd install \
  --set proxy.resources.cpu.limit=100m \
  --set proxy.resources.memory.limit=50Mi \
  --set proxy.resources.cpu.request=10m \
  --set proxy.resources.memory.request=20Mi \
  | kubectl apply -f -
```

Wait for the control plane to become ready:
```bash
# Watch pods come up
kubectl get pods -n linkerd -w

# Run post-install validation (wait until all pass)
linkerd check
```

The `linkerd check` command runs ~30 checks. All should be green. This typically takes 1-2
minutes after install.

---

## Step 5: Install the Viz Extension (Dashboard + Metrics)

The viz extension provides the Linkerd dashboard and integrates with Prometheus.

```bash
# Install viz extension with resource constraints
linkerd viz install \
  --set prometheus.enabled=false \
  --set grafana.enabled=false \
  | kubectl apply -f -
```

> **Why disable built-in Prometheus/Grafana?** We already have them running from guides 14/15.
> We will configure Linkerd to use our existing stack instead of duplicating it.

Wait for viz to become ready:
```bash
kubectl get pods -n linkerd-viz -w

# Validate
linkerd viz check
```

### Access the Dashboard

```bash
# Port-forward the dashboard (from local machine)
linkerd viz dashboard &

# Or manually:
kubectl port-forward -n linkerd-viz svc/web 8084:8084
```

Open http://localhost:8084 in your browser. You will see an empty dashboard until we inject
sidecars into our services.

---

## Step 6: Inject Sidecars Into Your Microservices

Linkerd uses a mutating admission webhook to automatically inject the sidecar proxy into pods.
You enable it per-namespace with an annotation.

### Option A: Annotate the Namespace (Recommended)

```bash
# Inject into your microservices namespace
kubectl annotate namespace apps linkerd.io/inject=enabled

# Restart deployments so existing pods get the sidecar
kubectl rollout restart deployment -n apps
```

### Option B: Inject Specific Deployments

```bash
# Inject a single deployment
kubectl get deployment -n apps api-service -o yaml \
  | linkerd inject - \
  | kubectl apply -f -
```

### Verify Injection

```bash
# Check that pods have 2 containers (app + linkerd-proxy)
kubectl get pods -n apps -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
```

Expected output shows each pod has both the app container and `linkerd-proxy`:
```
api-service-abc123      api-service linkerd-proxy
frontend-def456         frontend linkerd-proxy
worker-ghi789           worker linkerd-proxy
```

Check injection status:
```bash
# Detailed view
linkerd viz stat deploy -n apps
```

Expected output:
```
NAME          MESHED   SUCCESS   RPS   LATENCY_P50   LATENCY_P95   LATENCY_P99
api-service   1/1      100.00%   2.4   1ms           5ms           10ms
frontend      1/1      100.00%   1.8   2ms           8ms           15ms
worker        1/1      100.00%   0.5   3ms           12ms          25ms
```

---

## Step 7: Verify Automatic mTLS

One of Linkerd's best features: mTLS is automatic. Once sidecars are injected, all
communication between meshed services is encrypted with mutual TLS. Zero configuration needed.

```bash
# Check mTLS status between services
linkerd viz edges deploy -n apps
```

Expected output:
```
SRC            DST            SRC_NS   DST_NS   SECURED
frontend       api-service    apps     apps     true
api-service    worker         apps     apps     true
```

The `SECURED: true` column confirms mTLS is active.

### Inspect Certificates

```bash
# See the identity certificates used
linkerd viz tap deploy/api-service -n apps --to deploy/worker -n apps | head -5
```

You will see `tls=true` in the tap output, confirming encrypted traffic.

### How mTLS Works in Linkerd

```
┌─────────────┐         mTLS tunnel          ┌─────────────┐
│  frontend   │                               │ api-service │
│  ┌───────┐  │  ┌──────────┐  ┌──────────┐  │  ┌───────┐  │
│  │  app  │──┼──│ linkerd  │──│ linkerd  │──┼──│  app  │  │
│  └───────┘  │  │  proxy   │  │  proxy   │  │  └───────┘  │
│             │  └──────────┘  └──────────┘  │             │
└─────────────┘    sidecar       sidecar      └─────────────┘
```

The app sends plain HTTP to localhost. The linkerd-proxy sidecar intercepts it, encrypts with
mTLS, sends to the destination proxy, which decrypts and forwards to the destination app.
Your app code does not change at all.

---

## Step 8: Service Profiles for Per-Route Metrics

Service profiles tell Linkerd about your API routes so you get metrics per endpoint, not just
per service.

```bash
# Create a service profile for api-service
cat <<'EOF' | kubectl apply -f -
apiVersion: linkerd.io/v1alpha2
kind: ServiceProfile
metadata:
  name: api-service.apps.svc.cluster.local
  namespace: apps
spec:
  routes:
    - name: GET /api/health
      condition:
        method: GET
        pathRegex: /api/health
    - name: GET /api/products
      condition:
        method: GET
        pathRegex: /api/products
    - name: GET /api/products/{id}
      condition:
        method: GET
        pathRegex: /api/products/[^/]+
    - name: POST /api/orders
      condition:
        method: POST
        pathRegex: /api/orders
      # Enable retries for this route
      isRetryable: true
    - name: GET /api/orders/{id}
      condition:
        method: GET
        pathRegex: /api/orders/[^/]+
EOF
```

### Configure Timeouts and Retries

```bash
# Add timeout and retry budget to the service profile
cat <<'EOF' | kubectl apply -f -
apiVersion: linkerd.io/v1alpha2
kind: ServiceProfile
metadata:
  name: api-service.apps.svc.cluster.local
  namespace: apps
spec:
  retryBudget:
    retryRatio: 0.2        # Max 20% of requests can be retries
    minRetriesPerSecond: 10 # Always allow at least 10 retries/sec
    ttl: 10s                # Retry budget window
  routes:
    - name: GET /api/health
      condition:
        method: GET
        pathRegex: /api/health
      timeout: 5s
    - name: POST /api/orders
      condition:
        method: POST
        pathRegex: /api/orders
      timeout: 30s
      isRetryable: true
EOF
```

### View Per-Route Metrics

```bash
# See metrics broken down by route
linkerd viz routes deploy/api-service -n apps
```

Expected output:
```
ROUTE                    SERVICE        SUCCESS   RPS   LATENCY_P50   LATENCY_P95
GET /api/health          api-service    100.00%   0.5   1ms           2ms
GET /api/products        api-service    100.00%   1.2   3ms           8ms
GET /api/products/{id}   api-service     99.80%   0.8   5ms           15ms
POST /api/orders         api-service     99.50%   0.4   10ms          25ms
[DEFAULT]                api-service    100.00%   0.1   2ms           5ms
```

---

## Step 9: Traffic Splitting for Canary Deployments

Linkerd supports traffic splitting using the Gateway API HTTPRoute resource or TrafficSplit
CRD for canary deployments.

### Set Up a Canary with TrafficSplit

```bash
# Deploy canary version of api-service
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service-canary
  namespace: apps
  labels:
    app: api-service
    version: canary
  annotations:
    linkerd.io/inject: enabled
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-service
      version: canary
  template:
    metadata:
      labels:
        app: api-service
        version: canary
    spec:
      containers:
        - name: api-service
          image: your-registry/api-service:v2.0.0-canary
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
EOF
```

```bash
# Create a TrafficSplit: 90% stable, 10% canary
cat <<'EOF' | kubectl apply -f -
apiVersion: split.smi-spec.io/v1alpha2
kind: TrafficSplit
metadata:
  name: api-service-split
  namespace: apps
spec:
  service: api-service
  backends:
    - service: api-service-stable
      weight: 900
    - service: api-service-canary
      weight: 100
EOF
```

### Gradually Shift Traffic

```bash
# After validating canary metrics, increase to 50/50
cat <<'EOF' | kubectl apply -f -
apiVersion: split.smi-spec.io/v1alpha2
kind: TrafficSplit
metadata:
  name: api-service-split
  namespace: apps
spec:
  service: api-service
  backends:
    - service: api-service-stable
      weight: 500
    - service: api-service-canary
      weight: 500
EOF
```

```bash
# Monitor canary vs stable
linkerd viz stat deploy -n apps -l version=canary
linkerd viz stat deploy -n apps -l version=stable
```

### Watch Live Traffic

```bash
# Tap live requests to the canary
linkerd viz tap deploy/api-service-canary -n apps

# See top routes (like 'top' for services)
linkerd viz top deploy/api-service -n apps
```

---

## Step 10: Integrate with Existing Prometheus and Grafana

Since we already run Prometheus and Grafana, configure them to scrape Linkerd metrics.

### Add Linkerd Scrape Config to Prometheus

```bash
# Create a scrape config for Linkerd
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: linkerd-prometheus-scrape
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
data:
  linkerd-scrape.yaml: |
    - job_name: 'linkerd-controller'
      kubernetes_sd_configs:
        - role: pod
          namespaces:
            names:
              - linkerd
              - linkerd-viz
      relabel_configs:
        - source_labels:
            - __meta_kubernetes_pod_container_port_name
          action: keep
          regex: admin-http
        - source_labels:
            - __meta_kubernetes_pod_container_name
          action: replace
          target_label: component

    - job_name: 'linkerd-service-mirror'
      kubernetes_sd_configs:
        - role: pod
      relabel_configs:
        - source_labels:
            - __meta_kubernetes_pod_label_linkerd_io_control_plane_component
            - __meta_kubernetes_pod_container_port_name
          action: keep
          regex: linkerd-service-mirror;admin-http$

    - job_name: 'linkerd-proxy'
      kubernetes_sd_configs:
        - role: pod
      relabel_configs:
        - source_labels:
            - __meta_kubernetes_pod_container_name
            - __meta_kubernetes_pod_container_port_name
            - __meta_kubernetes_pod_label_linkerd_io_control_plane_ns
          action: keep
          regex: ^linkerd-proxy;linkerd-admin;linkerd$
        - source_labels:
            - __meta_kubernetes_namespace
          action: replace
          target_label: namespace
        - source_labels:
            - __meta_kubernetes_pod_name
          action: replace
          target_label: pod
        - source_labels:
            - __meta_kubernetes_pod_label_linkerd_io_proxy_job
          action: replace
          target_label: k8s_job
        - action: labeldrop
          regex: __meta_kubernetes_pod_label_linkerd_io_proxy_job
        - action: labelmap
          regex: __meta_kubernetes_pod_label_linkerd_io_proxy_(.+)
        - action: labeldrop
          regex: __meta_kubernetes_pod_label_linkerd_io_proxy_(.+)
        - action: labelmap
          regex: __meta_kubernetes_pod_label_linkerd_io_(.+)
        - action: labelmap
          regex: __meta_kubernetes_pod_label_(.+)
          replacement: __tmp_pod_label_$1
        - action: labelmap
          regex: __tmp_pod_label_linkerd_io_(.+)
          replacement: __tmp_pod_label_$1
        - action: labeldrop
          regex: __tmp_pod_label_(.+)
EOF
```

### Import Linkerd Grafana Dashboards

```bash
# Download official Linkerd Grafana dashboards
# Dashboard IDs for grafana.com:
# - Linkerd Top Line:    15474
# - Linkerd Health:      15486
# - Linkerd Service:     15475
# - Linkerd Route:       15476
# - Linkerd Multicluster: 15488

# Create a ConfigMap for auto-provisioning the top-line dashboard
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: linkerd-grafana-dashboards
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  linkerd-top-line.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "title": "Linkerd Top Line",
      "uid": "linkerd-top-line",
      "panels": [
        {
          "title": "Success Rate",
          "type": "stat",
          "targets": [
            {
              "expr": "sum(irate(response_total{classification=\"success\", namespace=\"apps\"}[30s])) / sum(irate(response_total{namespace=\"apps\"}[30s]))",
              "legendFormat": "Success Rate"
            }
          ],
          "gridPos": { "h": 6, "w": 8, "x": 0, "y": 0 }
        },
        {
          "title": "Request Rate",
          "type": "stat",
          "targets": [
            {
              "expr": "sum(irate(response_total{namespace=\"apps\"}[30s]))",
              "legendFormat": "RPS"
            }
          ],
          "gridPos": { "h": 6, "w": 8, "x": 8, "y": 0 }
        },
        {
          "title": "P95 Latency",
          "type": "stat",
          "targets": [
            {
              "expr": "histogram_quantile(0.95, sum(irate(response_latency_ms_bucket{namespace=\"apps\"}[30s])) by (le))",
              "legendFormat": "P95"
            }
          ],
          "gridPos": { "h": 6, "w": 8, "x": 16, "y": 0 }
        }
      ]
    }
EOF
```

### Key Linkerd Metrics for Alerting

```yaml
# Add to your PrometheusRule (guides 14/15)
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: linkerd-alerts
  namespace: monitoring
spec:
  groups:
    - name: linkerd.rules
      rules:
        - alert: LinkerdHighErrorRate
          expr: |
            sum(rate(response_total{classification="failure", namespace="apps"}[5m])) by (deployment)
            /
            sum(rate(response_total{namespace="apps"}[5m])) by (deployment)
            > 0.05
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "High error rate on {{ $labels.deployment }}"
            description: "{{ $labels.deployment }} has >5% error rate ({{ $value | humanizePercentage }})"

        - alert: LinkerdHighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(response_latency_ms_bucket{namespace="apps"}[5m])) by (le, deployment)
            ) > 500
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High P99 latency on {{ $labels.deployment }}"
            description: "{{ $labels.deployment }} P99 latency is {{ $value }}ms"

        - alert: LinkerdMeshTLSNotSecured
          expr: |
            sum(tcp_open_total{namespace="apps", tls="not_provided_by_remote"}) by (deployment) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Unencrypted traffic detected for {{ $labels.deployment }}"
```

---

## Verify

Run the full Linkerd validation suite:

```bash
# 1. Check control plane health
linkerd check

# 2. Check viz extension
linkerd viz check

# 3. Verify meshed services
linkerd viz stat deploy -n apps

# 4. Verify mTLS is active
linkerd viz edges deploy -n apps

# 5. Check per-route metrics (if service profiles configured)
linkerd viz routes deploy/api-service -n apps

# 6. View real-time traffic
linkerd viz top deploy -n apps

# 7. Check resource usage
kubectl top pods -n linkerd
kubectl top pods -n linkerd-viz
```

### Quick Smoke Test

```bash
# Generate traffic and watch metrics update in real time
kubectl run curl-test --rm -it --image=curlimages/curl -- sh -c '
  for i in $(seq 1 50); do
    curl -s http://api-service.apps.svc.cluster.local:8080/api/health
    sleep 0.1
  done
'

# Immediately check stats
linkerd viz stat deploy -n apps --from deploy/curl-test
```

---

## Troubleshooting

### Sidecar Not Injecting

```bash
# Check namespace annotation
kubectl get namespace apps -o jsonpath='{.metadata.annotations.linkerd\.io/inject}'
# Should output: enabled

# Check webhook is running
kubectl get pods -n linkerd -l linkerd.io/control-plane-component=proxy-injector

# Check webhook logs
kubectl logs -n linkerd -l linkerd.io/control-plane-component=proxy-injector -f

# Force re-inject by restarting deployment
kubectl rollout restart deployment -n apps
```

### mTLS Not Working

```bash
# Check identity service
kubectl logs -n linkerd -l linkerd.io/control-plane-component=identity

# Verify certificates
linkerd viz tap deploy/api-service -n apps | grep tls

# Check if both sides are meshed (both must have sidecars)
linkerd viz edges deploy -n apps
```

### High Latency After Mesh

```bash
# Check proxy resource limits (might be CPU throttled)
kubectl describe pod -n apps <pod-name> | grep -A5 linkerd-proxy

# If proxies are CPU throttled, increase limits:
# Re-install with higher proxy CPU:
linkerd install --set proxy.resources.cpu.limit=200m | kubectl apply -f -
```

### Dashboard Not Loading

```bash
# Check viz pods
kubectl get pods -n linkerd-viz

# Check web UI logs
kubectl logs -n linkerd-viz -l linkerd.io/extension=viz -l component=web

# Restart viz
kubectl rollout restart deployment -n linkerd-viz
```

### Control Plane Unhealthy

```bash
# Full diagnostics
linkerd check --output json | jq '.categories[] | select(.checks[] | .result == "error")'

# Check each component
for comp in destination identity proxy-injector; do
  echo "=== $comp ==="
  kubectl logs -n linkerd -l linkerd.io/control-plane-component=$comp --tail=20
done
```

---

## Checklist

- [ ] Linkerd CLI installed and on PATH
- [ ] Pre-installation checks pass (`linkerd check --pre`)
- [ ] Linkerd CRDs installed
- [ ] Control plane installed and healthy (`linkerd check`)
- [ ] Viz extension installed (`linkerd viz check`)
- [ ] Sidecars injected into microservices namespace
- [ ] Pods show 2 containers (app + linkerd-proxy)
- [ ] mTLS verified between services (`linkerd viz edges`)
- [ ] Service profiles created for per-route metrics
- [ ] Traffic splitting configured for canary deployment
- [ ] Prometheus scraping Linkerd metrics
- [ ] Grafana dashboards imported
- [ ] Alerting rules added for error rate and latency
- [ ] Dashboard accessible via port-forward
- [ ] Control plane using ~250MB RAM total

---

## What's Next?
With Linkerd providing automatic mTLS, per-route metrics, and traffic splitting, your service
communication is now encrypted, observable, and controllable without any application code changes.

Next, proceed to **Guide 27 -- Chaos Engineering Setup** where we will use LitmusChaos to
intentionally break things and verify that our mesh, monitoring, and alerting all respond
correctly when failures happen.
