# Guide 20: Observability Setup — LGTM Stack (Logs, Grafana, Traces, Metrics)

## Why This Matters

You cannot fix what you cannot see. Observability is the combination of metrics,
logs, and traces that lets you answer any question about your system's behavior
without deploying new code. On our single-node k3s cluster running 35 tools and
3 microservices, observability is how you will:

- **Detect** — know when error rates spike or a pod is OOMKilled.
- **Diagnose** — correlate a Grafana alert to specific log lines in Loki.
- **Decide** — feed Prometheus metrics into Argo Rollouts AnalysisTemplates for
  automated canary promotion or rollback.

This guide deploys the full LGTM stack:

| Component | Role | RAM Budget |
|-----------|------|------------|
| **Prometheus** | Scrapes and stores time-series metrics | ~300 MB |
| **Grafana** | Dashboard UI and alerting | ~150 MB |
| **Loki** | Log aggregation (like Prometheus for logs) | ~150 MB |
| **Promtail** | Ships container logs to Loki | ~50 MB (DaemonSet) |
| **OTel Collector** | Unified telemetry pipeline | ~300 MB |
| **AlertManager** | Routes and deduplicates alerts | Included in kube-prometheus-stack |

Total: ~950 MB — fits within our 8 GB node alongside all other workloads.

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| k3s cluster running | `kubectl get nodes` |
| Helm 3.12+ | `helm version` |
| ArgoCD installed (Guide 16) | `argocd app list` |
| At least 1.5 GB free RAM | `kubectl top nodes` |

---

## Step 1 — Create the Monitoring Namespace

```bash
kubectl create namespace monitoring
kubectl label namespace monitoring app.kubernetes.io/managed-by=argocd
```

---

## Step 2 — Install Prometheus + Grafana (kube-prometheus-stack)

The `kube-prometheus-stack` Helm chart bundles Prometheus, Grafana, AlertManager,
node-exporter, kube-state-metrics, and ServiceMonitor CRDs in one install.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Create `monitoring/prometheus-values.yaml`:

```yaml
# monitoring/prometheus-values.yaml

# -- Prometheus server
prometheus:
  prometheusSpec:
    # Retention period (7 days is enough for a learning platform)
    retention: 7d
    retentionSize: "5GB"

    # Resource limits for our t3.large
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: "1"
        memory: 512Mi

    # Storage (use local-path provisioner from k3s)
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi

    # Scrape all ServiceMonitors across namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}

    # Scrape all PodMonitors across namespaces
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorSelector: {}
    podMonitorNamespaceSelector: {}

    # Additional scrape configs for services without ServiceMonitor
    additionalScrapeConfigs: []

# -- Grafana
grafana:
  enabled: true
  adminUser: admin
  adminPassword: ""   # Auto-generated, retrieve from Secret
  persistence:
    enabled: true
    storageClassName: local-path
    size: 2Gi
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

  # Pre-provision data sources
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.monitoring:3100
      access: proxy
      isDefault: false
      jsonData:
        maxLines: 1000

  # Pre-provision dashboards
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: "custom"
          orgId: 1
          folder: "DevOps Zero to Hero"
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/custom

  dashboards:
    custom:
      # Kubernetes cluster overview
      k8s-cluster:
        gnetId: 7249
        revision: 1
        datasource: Prometheus
      # Node exporter
      node-exporter:
        gnetId: 1860
        revision: 37
        datasource: Prometheus
      # Namespace overview
      k8s-namespaces:
        gnetId: 15758
        revision: 37
        datasource: Prometheus
      # ArgoCD dashboard
      argocd:
        gnetId: 14584
        revision: 1
        datasource: Prometheus

  # Grafana sidecar for ConfigMap-based dashboards
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: ALL

# -- AlertManager
alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: "null"
      routes:
        - receiver: "critical"
          matchers:
            - severity = critical
          repeat_interval: 1h
        - receiver: "warning"
          matchers:
            - severity = warning
          repeat_interval: 4h
    receivers:
      - name: "null"
      - name: "critical"
        webhook_configs:
          - url: "http://localhost:9093/api/v1/alerts"   # Replace with Slack/Discord webhook
            send_resolved: true
      - name: "warning"
        webhook_configs:
          - url: "http://localhost:9093/api/v1/alerts"

# -- Node exporter (system metrics)
nodeExporter:
  resources:
    requests:
      cpu: 10m
      memory: 16Mi
    limits:
      cpu: 100m
      memory: 32Mi

# -- Kube state metrics
kubeStateMetrics:
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

# -- Default PrometheusRules (alerting rules)
defaultRules:
  create: true
  rules:
    alertmanager: true
    etcd: false            # Not applicable for k3s (embedded)
    configReloaders: true
    general: true
    k8sContainerCpuUsageSecondsTotal: true
    k8sContainerMemoryCache: true
    k8sContainerMemoryRss: true
    k8sContainerMemorySwap: true
    k8sContainerMemoryWorkingSetBytes: true
    k8sPodOwner: true
    kubeApiserverAvailability: true
    kubeApiserverBurnrate: true
    kubeApiserverHistogram: true
    kubeApiserverSlos: true
    kubeControllerManager: false   # k3s embedded
    kubeSchedulerAlerting: false   # k3s embedded
    kubeProxy: false               # k3s uses its own proxy
    kubernetesApps: true
    kubernetesResources: true
    kubernetesStorage: true
    kubernetesSystem: true
    network: true
    node: true
    nodeExporterAlerting: true
    prometheus: true
```

Install:

```bash
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 67.4.0 \
  -f monitoring/prometheus-values.yaml \
  --wait
```

---

## Step 3 — ServiceMonitors for Our Microservices

ServiceMonitors tell Prometheus which endpoints to scrape. Create one for each
microservice:

### API Gateway ServiceMonitor

```yaml
# monitoring/servicemonitors/api-gateway.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: api-gateway
  namespace: monitoring
  labels:
    release: prometheus   # Must match the Helm release label selector
spec:
  namespaceSelector:
    matchNames:
      - apps
  selector:
    matchLabels:
      app.kubernetes.io/name: api-gateway
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
```

### User Service ServiceMonitor

```yaml
# monitoring/servicemonitors/user-service.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: user-service
  namespace: monitoring
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
      - apps
  selector:
    matchLabels:
      app.kubernetes.io/name: user-service
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
```

### Order Service ServiceMonitor

```yaml
# monitoring/servicemonitors/order-service.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-service
  namespace: monitoring
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
      - apps
  selector:
    matchLabels:
      app.kubernetes.io/name: order-service
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
```

Apply:

```bash
kubectl apply -f monitoring/servicemonitors/
```

---

## Step 4 — Custom AlertManager Rules

Create alerts specific to our platform:

```yaml
# monitoring/alerts/platform-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-alerts
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
    # -- Pod health alerts
    - name: pod-health
      rules:
        - alert: PodCrashLooping
          expr: |
            increase(kube_pod_container_status_restarts_total{
              namespace=~"apps|database"
            }[15m]) > 3
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.pod }} is crash looping"
            description: >-
              Pod {{ $labels.pod }} in namespace {{ $labels.namespace }}
              has restarted {{ $value }} times in the last 15 minutes.

        - alert: PodNotReady
          expr: |
            kube_pod_status_ready{
              condition="true",
              namespace=~"apps|database"
            } == 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} is not ready"
            description: >-
              Pod {{ $labels.pod }} in {{ $labels.namespace }} has been
              not-ready for more than 5 minutes.

    # -- Resource alerts
    - name: resource-usage
      rules:
        - alert: HighCPUUsage
          expr: |
            (
              sum(rate(container_cpu_usage_seconds_total{
                namespace=~"apps|database",
                container!=""
              }[5m])) by (pod, namespace)
              /
              sum(kube_pod_container_resource_limits{
                resource="cpu",
                namespace=~"apps|database"
              }) by (pod, namespace)
            ) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "High CPU usage on {{ $labels.pod }}"
            description: >-
              Pod {{ $labels.pod }} in {{ $labels.namespace }} is using
              {{ $value | humanizePercentage }} of its CPU limit.

        - alert: HighMemoryUsage
          expr: |
            (
              container_memory_working_set_bytes{
                namespace=~"apps|database",
                container!=""
              }
              /
              kube_pod_container_resource_limits{
                resource="memory",
                namespace=~"apps|database"
              }
            ) > 0.9
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High memory usage on {{ $labels.pod }}"
            description: >-
              Pod {{ $labels.pod }} is using
              {{ $value | humanizePercentage }} of its memory limit.
              OOMKill risk.

        - alert: PodOOMKilled
          expr: |
            kube_pod_container_status_last_terminated_reason{
              reason="OOMKilled",
              namespace=~"apps|database"
            } == 1
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Container {{ $labels.container }} was OOMKilled"
            description: >-
              Container {{ $labels.container }} in pod {{ $labels.pod }}
              was killed due to out-of-memory. Increase memory limits.

    # -- Disk alerts
    - name: disk-usage
      rules:
        - alert: DiskAlmostFull
          expr: |
            (
              node_filesystem_avail_bytes{mountpoint="/"}
              /
              node_filesystem_size_bytes{mountpoint="/"}
            ) < 0.15
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Disk almost full on {{ $labels.instance }}"
            description: >-
              Root filesystem has only
              {{ $value | humanizePercentage }} free space remaining.

    # -- Application-specific alerts
    - name: application-health
      rules:
        - alert: HighErrorRate
          expr: |
            (
              sum(rate(http_requests_total{
                status=~"5..",
                namespace="apps"
              }[5m])) by (service)
              /
              sum(rate(http_requests_total{
                namespace="apps"
              }[5m])) by (service)
            ) > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "High error rate on {{ $labels.service }}"
            description: >-
              Service {{ $labels.service }} has a 5xx error rate of
              {{ $value | humanizePercentage }} over the last 5 minutes.

        - alert: HighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_milliseconds_bucket{
                namespace="apps"
              }[5m])) by (le, service)
            ) > 1000
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High p99 latency on {{ $labels.service }}"
            description: >-
              Service {{ $labels.service }} p99 latency is
              {{ $value }}ms (threshold: 1000ms).
```

Apply:

```bash
kubectl apply -f monitoring/alerts/
```

---

## Step 5 — Custom Grafana Dashboard for Microservices

Create a ConfigMap-based dashboard that Grafana sidecar auto-loads:

```yaml
# monitoring/dashboards/microservices-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: microservices-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"    # Sidecar picks this up automatically
data:
  microservices.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 1,
      "id": null,
      "links": [],
      "panels": [
        {
          "title": "Request Rate by Service",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{namespace=\"apps\"}[5m])) by (service)",
              "legendFormat": "{{ service }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "reqps"
            }
          }
        },
        {
          "title": "Error Rate by Service",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{namespace=\"apps\",status=~\"5..\"}[5m])) by (service) / sum(rate(http_requests_total{namespace=\"apps\"}[5m])) by (service)",
              "legendFormat": "{{ service }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percentunit",
              "thresholds": {
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 0.01 },
                  { "color": "red", "value": 0.05 }
                ]
              }
            }
          }
        },
        {
          "title": "P99 Latency by Service",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
          "targets": [
            {
              "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_milliseconds_bucket{namespace=\"apps\"}[5m])) by (le, service))",
              "legendFormat": "{{ service }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "ms",
              "thresholds": {
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 200 },
                  { "color": "red", "value": 500 }
                ]
              }
            }
          }
        },
        {
          "title": "Memory Usage by Pod",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
          "targets": [
            {
              "expr": "container_memory_working_set_bytes{namespace=\"apps\",container!=\"\"}",
              "legendFormat": "{{ pod }} / {{ container }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "bytes"
            }
          }
        },
        {
          "title": "CPU Usage by Pod",
          "type": "timeseries",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 },
          "targets": [
            {
              "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"apps\",container!=\"\"}[5m])) by (pod)",
              "legendFormat": "{{ pod }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "short"
            }
          }
        },
        {
          "title": "Pod Restarts",
          "type": "stat",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 },
          "targets": [
            {
              "expr": "increase(kube_pod_container_status_restarts_total{namespace=\"apps\"}[1h])",
              "legendFormat": "{{ pod }}",
              "refId": "A"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "thresholds": {
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 1 },
                  { "color": "red", "value": 3 }
                ]
              }
            }
          }
        }
      ],
      "refresh": "30s",
      "schemaVersion": 39,
      "tags": ["devops-zero-to-hero", "microservices"],
      "templating": { "list": [] },
      "time": { "from": "now-1h", "to": "now" },
      "title": "Microservices Overview",
      "uid": "microservices-overview"
    }
```

Apply:

```bash
kubectl apply -f monitoring/dashboards/
```

---

## Step 6 — Install Loki (Log Aggregation)

Loki is like Prometheus but for logs. We use single-binary mode (monolithic)
which is perfect for k3s — no need for a distributed setup.

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

Create `monitoring/loki-values.yaml`:

```yaml
# monitoring/loki-values.yaml

# Single-binary mode (all components in one pod)
deploymentMode: SingleBinary

loki:
  auth_enabled: false     # Single-tenant for simplicity
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h

  limits_config:
    retention_period: 168h           # 7 days
    max_query_length: 24h
    max_entries_limit_per_query: 5000
    ingestion_rate_mb: 4
    ingestion_burst_size_mb: 8

singleBinary:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  persistence:
    enabled: true
    storageClass: local-path
    size: 5Gi

# Disable components not needed in single-binary mode
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0

# Gateway (optional, we access Loki directly)
gateway:
  enabled: false

# Chunk cache
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# Monitoring
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
  lokiCanary:
    enabled: false
```

Install:

```bash
helm install loki grafana/loki \
  --namespace monitoring \
  --version 6.23.0 \
  -f monitoring/loki-values.yaml \
  --wait
```

---

## Step 7 — Install Promtail (Log Shipping)

Promtail runs as a DaemonSet on every node, reads container log files, and
pushes them to Loki:

```yaml
# monitoring/promtail-values.yaml

config:
  clients:
    - url: http://loki:3100/loki/api/v1/push

  snippets:
    # Add Kubernetes metadata labels to logs
    pipelineStages:
      - cri: {}
      - multiline:
          firstline: '^\d{4}-\d{2}-\d{2}|^{"level"'
          max_wait_time: 3s
      - labeldrop:
          - filename
          - stream

resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 64Mi

tolerations:
  - effect: NoSchedule
    operator: Exists
```

Install:

```bash
helm install promtail grafana/promtail \
  --namespace monitoring \
  --version 6.16.6 \
  -f monitoring/promtail-values.yaml \
  --wait
```

---

## Step 8 — LogQL Query Examples

Once Loki is running, query logs in Grafana's Explore tab using LogQL:

### View all logs from a service

```logql
{namespace="apps", app="api-gateway"}
```

### Filter error logs

```logql
{namespace="apps", app="user-service"} |= "ERROR"
```

### Parse JSON logs and filter by status code

```logql
{namespace="apps", app="order-service"}
  | json
  | status >= 500
```

### Count errors per minute by service

```logql
sum(rate({namespace="apps"} |= "error" [1m])) by (app)
```

### Logs from a specific pod

```logql
{namespace="apps", pod=~"api-gateway-.*"}
  | json
  | line_format "{{.timestamp}} [{{.level}}] {{.message}}"
```

### Logs containing a correlation ID

```logql
{namespace="apps"} |= "correlation-id=abc-123-def"
```

---

## Step 9 — OpenTelemetry Collector (Telemetry Pipeline)

The OTel Collector acts as a unified receiver/processor/exporter for metrics and
logs. It decouples your applications from specific backends.

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

Create `monitoring/otel-collector-values.yaml`:

```yaml
# monitoring/otel-collector-values.yaml

mode: deployment    # Single instance (not DaemonSet)

replicaCount: 1

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 384Mi

ports:
  otlp:
    enabled: true
    containerPort: 4317     # gRPC
    servicePort: 4317
    protocol: TCP
  otlp-http:
    enabled: true
    containerPort: 4318     # HTTP
    servicePort: 4318
    protocol: TCP
  prometheus:
    enabled: true
    containerPort: 8889
    servicePort: 8889
    protocol: TCP

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

    # Scrape Prometheus metrics from OTel Collector itself
    prometheus:
      config:
        scrape_configs:
          - job_name: otel-collector
            scrape_interval: 30s
            static_configs:
              - targets: ["localhost:8888"]

  processors:
    # Batch telemetry before exporting (reduces network calls)
    batch:
      timeout: 10s
      send_batch_size: 1024
      send_batch_max_size: 2048

    # Add resource attributes
    resource:
      attributes:
        - key: cluster
          value: devops-zero-to-hero
          action: upsert
        - key: environment
          value: dev
          action: upsert

    # Memory limiter to prevent OOM
    memory_limiter:
      check_interval: 5s
      limit_mib: 300
      spike_limit_mib: 50

    # Filter out noisy spans/metrics
    filter:
      metrics:
        exclude:
          match_type: regexp
          metric_names:
            - ".*_test_.*"

  exporters:
    # Export metrics to Prometheus
    prometheusremotewrite:
      endpoint: "http://prometheus-kube-prometheus-prometheus.monitoring:9090/api/v1/write"
      resource_to_telemetry_conversion:
        enabled: true

    # Export logs to Loki
    loki:
      endpoint: "http://loki.monitoring:3100/loki/api/v1/push"
      default_labels_enabled:
        exporter: true
        job: true

    # Debug exporter (for troubleshooting)
    debug:
      verbosity: basic

  service:
    pipelines:
      metrics:
        receivers: [otlp, prometheus]
        processors: [memory_limiter, resource, batch]
        exporters: [prometheusremotewrite]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, resource, batch]
        exporters: [loki]

  # Health and telemetry
  extensions:
    health_check:
      endpoint: 0.0.0.0:13133
    zpages:
      endpoint: 0.0.0.0:55679

serviceMonitor:
  enabled: true
  namespace: monitoring
```

Install:

```bash
helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --version 0.107.0 \
  -f monitoring/otel-collector-values.yaml \
  --wait
```

---

## Step 10 — Instrument Microservices to Send Telemetry

### Node.js (api-gateway, order-service)

```bash
npm install @opentelemetry/sdk-node \
  @opentelemetry/auto-instrumentations-node \
  @opentelemetry/exporter-metrics-otlp-grpc \
  @opentelemetry/exporter-logs-otlp-grpc
```

```javascript
// tracing.js — require this FIRST in your app entry point
const { NodeSDK } = require("@opentelemetry/sdk-node");
const {
  getNodeAutoInstrumentations,
} = require("@opentelemetry/auto-instrumentations-node");
const {
  OTLPMetricExporter,
} = require("@opentelemetry/exporter-metrics-otlp-grpc");

const sdk = new NodeSDK({
  serviceName: process.env.SERVICE_NAME || "api-gateway",
  autoDetectResources: true,
  instrumentations: [getNodeAutoInstrumentations()],
  metricReader: new OTLPMetricExporter({
    url:
      process.env.OTEL_EXPORTER_OTLP_ENDPOINT ||
      "http://otel-collector.monitoring:4317",
  }),
});

sdk.start();
```

### Python/FastAPI (user-service)

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
```

```python
# otel_setup.py
from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource
import os

def setup_telemetry():
    resource = Resource.create({
        "service.name": os.getenv("SERVICE_NAME", "user-service"),
        "service.version": os.getenv("SERVICE_VERSION", "1.0.0"),
    })

    exporter = OTLPMetricExporter(
        endpoint=os.getenv(
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "http://otel-collector.monitoring:4317"
        ),
        insecure=True,
    )

    reader = PeriodicExportingMetricReader(exporter, export_interval_millis=30000)
    provider = MeterProvider(resource=resource, metric_readers=[reader])
    metrics.set_meter_provider(provider)
```

---

## Step 11 — Access Grafana

```bash
# Get Grafana admin password
kubectl get secret -n monitoring prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
echo

# Port-forward Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80 &
```

Open `http://localhost:3000`, login with `admin` / `<password>`.

Navigate to:
- **Dashboards > DevOps Zero to Hero > Microservices Overview** for the custom dashboard
- **Dashboards > General > Kubernetes / Views / Global** for cluster overview
- **Explore** and select **Loki** datasource to query logs

---

## Verify

### Check all monitoring pods are healthy

```bash
kubectl get pods -n monitoring
# Expected pods (names will vary):
# prometheus-kube-prometheus-prometheus-0     2/2   Running
# prometheus-grafana-xxx                      3/3   Running
# alertmanager-prometheus-kube-prometheus-alertmanager-0  2/2  Running
# prometheus-kube-state-metrics-xxx           1/1   Running
# prometheus-prometheus-node-exporter-xxx     1/1   Running
# loki-0                                     1/1   Running
# promtail-xxx                               1/1   Running
# otel-collector-xxx                         1/1   Running
```

### Verify Prometheus targets

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090 &
# Open http://localhost:9090/targets
# All targets should show "UP"
```

### Verify Loki is receiving logs

```bash
# Query Loki directly
curl -s "http://localhost:3100/loki/api/v1/labels" | jq .
# Should return: namespace, pod, app, etc.

# Or in Grafana Explore: {namespace="apps"} should return log lines
```

### Verify OTel Collector health

```bash
kubectl port-forward svc/otel-collector -n monitoring 13133:13133 &
curl localhost:13133/health
# {"status":"Server available","upSince":"...","uptime":"..."}
```

### Check total RAM usage

```bash
kubectl top pods -n monitoring --sort-by=memory
# Total should be under 950MB:
# Prometheus: ~300MB
# Grafana: ~150MB
# Loki: ~150MB
# Promtail: ~50MB
# OTel Collector: ~200MB
# kube-state-metrics + node-exporter: ~100MB
```

---

## Troubleshooting

### Prometheus "TargetDown" for a ServiceMonitor

```bash
# Verify the ServiceMonitor labels match the Prometheus selector
kubectl get prometheus -n monitoring -o yaml | grep -A5 serviceMonitorSelector

# Check the ServiceMonitor is in the correct namespace
kubectl get servicemonitors -A

# Verify the target service has matching labels
kubectl get svc -n apps --show-labels
```

### Grafana shows "No data" for dashboards

```bash
# Verify Prometheus data source is configured
# In Grafana: Configuration > Data Sources > Prometheus
# URL should be: http://prometheus-kube-prometheus-prometheus:9090

# Test a query directly
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
curl "http://localhost:9090/api/v1/query?query=up" | jq '.data.result | length'
```

### Loki not receiving logs

```bash
# Check Promtail logs
kubectl logs -n monitoring daemonset/promtail --tail=50

# Common issue: Promtail cannot access /var/log/pods
# Verify the DaemonSet volume mounts:
kubectl get daemonset promtail -n monitoring -o yaml | grep -A10 volumeMounts
```

### OTel Collector pipeline errors

```bash
# Check collector logs for exporter errors
kubectl logs -n monitoring deploy/otel-collector --tail=100

# Verify the Prometheus remote write endpoint is reachable
kubectl exec -n monitoring deploy/otel-collector -- \
  wget -q -O- http://prometheus-kube-prometheus-prometheus:9090/-/ready
```

### AlertManager not sending alerts

```bash
# Check AlertManager is receiving alerts
kubectl port-forward svc/alertmanager-prometheus-kube-prometheus-alertmanager -n monitoring 9093:9093
curl localhost:9093/api/v1/alerts | jq '.data | length'

# Check alert routing
curl localhost:9093/api/v1/status | jq '.data.config'
```

### Node running out of memory

If the monitoring stack pushes the node past 8 GB:

```bash
# Reduce Prometheus retention
kubectl patch prometheus prometheus-kube-prometheus-prometheus -n monitoring \
  --type merge -p '{"spec":{"retention":"3d","retentionSize":"3GB"}}'

# Reduce Loki retention
# Edit loki-values.yaml: retention_period: 72h, then helm upgrade
```

---

## Checklist

- [ ] monitoring namespace created
- [ ] kube-prometheus-stack installed (Prometheus + Grafana + AlertManager)
- [ ] Prometheus storage configured (10Gi, local-path)
- [ ] ServiceMonitor for api-gateway
- [ ] ServiceMonitor for user-service
- [ ] ServiceMonitor for order-service
- [ ] Custom PrometheusRule alerts (PodCrashLooping, HighCPU, DiskFull, HighErrorRate, HighLatency)
- [ ] Grafana accessible via port-forward
- [ ] Loki datasource added to Grafana
- [ ] Custom microservices dashboard loaded in Grafana
- [ ] Pre-built dashboards (cluster, node-exporter, ArgoCD)
- [ ] Loki installed in single-binary mode
- [ ] Promtail DaemonSet shipping container logs to Loki
- [ ] LogQL queries tested in Grafana Explore
- [ ] OpenTelemetry Collector installed
- [ ] OTel Collector exporting metrics to Prometheus
- [ ] OTel Collector exporting logs to Loki
- [ ] Microservice instrumentation (Node.js + Python)
- [ ] AlertManager routing configured
- [ ] Total RAM usage verified under 950MB

---

## What's Next?

With observability in place, you now have visibility across every layer of the
platform. The foundation is complete: infrastructure (k3s, networking, storage),
security (Vault, Kyverno, signed images), delivery (ArgoCD, Argo Rollouts, Helm
charts), and observability (Prometheus, Grafana, Loki, OTel).

Next steps to explore:

- **CI Pipeline** — GitHub Actions to build, test, sign, and push images, then
  update Helm values for ArgoCD to sync.
- **Chaos Engineering** — LitmusChaos or Chaos Mesh to validate your alerts
  fire correctly.
- **Cost Optimization** — Kubecost or OpenCost to track per-namespace spending.
- **Service Mesh** — Istio or Linkerd for mTLS, traffic mirroring, and
  circuit-breaking.
