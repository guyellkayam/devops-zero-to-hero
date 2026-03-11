# Guide 17: Argo Rollouts Setup — Progressive Delivery

## Why This Matters

Standard Kubernetes Deployments use a rolling update strategy: they replace pods
one-by-one until all replicas run the new version. If the new version has a
subtle bug (memory leak, elevated error rate), you only discover it after
**every** pod has been replaced — at which point all users are affected.

Argo Rollouts replaces the Deployment resource with a Rollout resource that adds:

- **Canary deployments** — route 10% of traffic to the new version, measure
  success metrics, then gradually increase to 100%.
- **Blue/Green deployments** — spin up the new version alongside the old,
  validate it, then switch traffic atomically.
- **Automated analysis** — query Prometheus for error rates and latency; auto-
  rollback if thresholds are breached.
- **Integration with ArgoCD** — Rollouts appear as first-class resources in the
  ArgoCD UI.

Resource footprint: ~150 MB RAM.

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| k3s cluster running | `kubectl get nodes` |
| ArgoCD installed (Guide 16) | `kubectl get pods -n argocd` |
| Helm 3.12+ | `helm version` |
| Prometheus running (or will be set up in Guide 20) | Needed for AnalysisTemplates |

---

## Step 1 — Create the Namespace

```bash
kubectl create namespace argo-rollouts
```

---

## Step 2 — Install Argo Rollouts via Helm

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

Create `argo-rollouts/values-k3s.yaml`:

```yaml
# argo-rollouts/values-k3s.yaml
controller:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 500m
      memory: 192Mi
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true        # Requires Prometheus Operator (Guide 20)
      namespace: monitoring

dashboard:
  enabled: true
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi
```

Install:

```bash
helm install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts \
  --version 2.38.0 \
  -f argo-rollouts/values-k3s.yaml \
  --wait
```

---

## Step 3 — Install the kubectl Plugin

The plugin gives you `kubectl argo rollouts` commands for managing rollouts
from the terminal:

```bash
# macOS
brew install argoproj/tap/kubectl-argo-rollouts

# Linux
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# Verify
kubectl argo rollouts version
```

---

## Step 4 — Blue/Green Strategy (for Staging)

Blue/Green is ideal for staging environments where you want instant switchover
after validation. The old version stays alive until you promote.

```yaml
# helm/api-gateway/templates/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ include "api-gateway.fullname" . }}
  labels:
    {{- include "api-gateway.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      {{- include "api-gateway.selectorLabels" . | nindent 6 }}
  {{- if eq .Values.strategy.type "blueGreen" }}
  strategy:
    blueGreen:
      # The active Service routes production traffic
      activeService: {{ include "api-gateway.fullname" . }}
      # The preview Service routes to the new (green) version
      previewService: {{ include "api-gateway.fullname" . }}-preview
      # Auto-promote after analysis passes
      autoPromotionEnabled: {{ .Values.strategy.blueGreen.autoPromote | default false }}
      # Seconds to wait before scaling down old version
      scaleDownDelaySeconds: 30
      # Run analysis before promotion
      prePromotionAnalysis:
        templates:
          - templateName: success-rate
          - templateName: latency-check
        args:
          - name: service-name
            value: {{ include "api-gateway.fullname" . }}-preview
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "api-gateway.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: {{ .Values.service.targetPort }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            httpGet:
              path: /healthz
              port: {{ .Values.service.targetPort }}
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: {{ .Values.service.targetPort }}
            initialDelaySeconds: 5
```

Blue/Green requires two Services — active and preview:

```yaml
# helm/api-gateway/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "api-gateway.fullname" . }}
spec:
  selector:
    {{- include "api-gateway.selectorLabels" . | nindent 4 }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "api-gateway.fullname" . }}-preview
spec:
  selector:
    {{- include "api-gateway.selectorLabels" . | nindent 4 }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
```

Staging values:

```yaml
# helm/api-gateway/values-staging.yaml
strategy:
  type: blueGreen
  blueGreen:
    autoPromote: true
```

---

## Step 5 — Canary Strategy (for Production)

Canary gradually shifts traffic to the new version in steps. If any step's
analysis fails, the rollout automatically rolls back.

```yaml
# helm/user-service/templates/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ include "user-service.fullname" . }}
  labels:
    {{- include "user-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      {{- include "user-service.selectorLabels" . | nindent 6 }}
  {{- if eq .Values.strategy.type "canary" }}
  strategy:
    canary:
      # The stable Service (current production)
      stableService: {{ include "user-service.fullname" . }}
      # The canary Service (new version)
      canaryService: {{ include "user-service.fullname" . }}-canary
      # Traffic routing via Envoy Gateway / Istio / Nginx
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: {{ include "user-service.fullname" . }}
            namespace: {{ .Release.Namespace }}
      steps:
        # Step 1: 10% traffic to canary, run analysis for 2 minutes
        - setWeight: 10
        - pause: { duration: 30s }
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
            args:
              - name: service-name
                value: {{ include "user-service.fullname" . }}-canary

        # Step 2: 25% traffic
        - setWeight: 25
        - pause: { duration: 60s }
        - analysis:
            templates:
              - templateName: success-rate
            args:
              - name: service-name
                value: {{ include "user-service.fullname" . }}-canary

        # Step 3: 50% traffic
        - setWeight: 50
        - pause: { duration: 60s }
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
            args:
              - name: service-name
                value: {{ include "user-service.fullname" . }}-canary

        # Step 4: Full promotion
        - setWeight: 100
      # Maximum surge and unavailable during canary
      maxSurge: 1
      maxUnavailable: 0
      # Abort and rollback on analysis failure
      abortScaleDownDelaySeconds: 30
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "user-service.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: {{ .Values.service.targetPort }}
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: user-service-db
                  key: url
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

Production values:

```yaml
# helm/user-service/values-production.yaml
replicaCount: 3

strategy:
  type: canary

image:
  repository: ghcr.io/<you>/user-service
  tag: "1.2.0"  # ArgoCD Image Updater can automate this

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

---

## Step 6 — AnalysisTemplates (Prometheus Queries)

AnalysisTemplates define success criteria. Argo Rollouts runs the queries during
each analysis step and aborts the rollout if they fail.

### Success Rate Analysis

```yaml
# manifests/analysis/success-rate.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: apps
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      # Run every 30 seconds, require 3 consecutive successes
      interval: 30s
      count: 3
      successCondition: result[0] >= 0.99
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus-kube-prometheus-prometheus.monitoring:9090
          query: |
            sum(rate(
              http_requests_total{
                service="{{args.service-name}}",
                status=~"2.."
              }[2m]
            )) /
            sum(rate(
              http_requests_total{
                service="{{args.service-name}}"
              }[2m]
            ))
```

### Latency Check Analysis

```yaml
# manifests/analysis/latency-check.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: latency-check
  namespace: apps
spec:
  args:
    - name: service-name
  metrics:
    - name: p99-latency
      interval: 30s
      count: 3
      # p99 latency must be under 500ms
      successCondition: result[0] < 500
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus-kube-prometheus-prometheus.monitoring:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(
                http_request_duration_milliseconds_bucket{
                  service="{{args.service-name}}"
                }[2m]
              )) by (le)
            )
```

### Error Rate Analysis (alternative to success rate)

```yaml
# manifests/analysis/error-rate.yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: error-rate
  namespace: apps
spec:
  args:
    - name: service-name
  metrics:
    - name: error-rate
      interval: 30s
      count: 3
      # Error rate must be under 1%
      successCondition: result[0] < 0.01
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus-kube-prometheus-prometheus.monitoring:9090
          query: |
            sum(rate(
              http_requests_total{
                service="{{args.service-name}}",
                status=~"5.."
              }[2m]
            )) /
            sum(rate(
              http_requests_total{
                service="{{args.service-name}}"
              }[2m]
            ))
```

Apply the analysis templates:

```bash
kubectl apply -f manifests/analysis/
```

---

## Step 7 — Auto-Rollback on Failure

Auto-rollback is built in. When any analysis step's `failureLimit` is breached,
the Rollout automatically:

1. Sets canary weight back to 0% (or switches blue/green back to active).
2. Scales down the failed ReplicaSet.
3. Sets the Rollout status to `Degraded`.

You can also trigger a manual abort:

```bash
# Abort a running canary
kubectl argo rollouts abort user-service -n apps

# Retry after fixing the issue
kubectl argo rollouts retry rollout user-service -n apps

# Manually promote a paused rollout
kubectl argo rollouts promote user-service -n apps
```

---

## Step 8 — Rollouts Dashboard UI

Access the built-in dashboard:

```bash
kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100 &
```

Open `http://localhost:3100` to see:
- All Rollouts across namespaces
- Current step and traffic weight
- Analysis run results (pass/fail with Prometheus data)
- Promote / Abort buttons

---

## Step 9 — Integration with ArgoCD

ArgoCD needs to recognize the Rollout CRD as a health-checkable resource. Add
this to your ArgoCD ConfigMap:

```yaml
# In argocd/values-k3s.yaml under configs.cm:
configs:
  cm:
    resource.customizations: |
      argoproj.io/Rollout:
        health.lua: |
          hs = {}
          if obj.status ~= nil then
            if obj.status.conditions ~= nil then
              for _, condition in ipairs(obj.status.conditions) do
                if condition.type == "Paused" and condition.status == "True" then
                  hs.status = "Suspended"
                  hs.message = condition.message
                  return hs
                end
                if condition.type == "InvalidSpec" then
                  hs.status = "Degraded"
                  hs.message = condition.message
                  return hs
                end
              end
            end
            if obj.status.phase == "Healthy" then
              hs.status = "Healthy"
              hs.message = "Rollout is healthy"
            elseif obj.status.phase == "Paused" then
              hs.status = "Suspended"
              hs.message = "Rollout is paused"
            elseif obj.status.phase == "Degraded" then
              hs.status = "Degraded"
              hs.message = "Rollout is degraded"
            else
              hs.status = "Progressing"
              hs.message = "Rollout is progressing"
            end
          end
          return hs
```

After updating the Helm values, upgrade ArgoCD:

```bash
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  -f argocd/values-k3s.yaml
```

---

## Step 10 — Complete Example: Order Service Canary

Putting it all together for the order-service:

```yaml
# helm/order-service/templates/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: order-service
  labels:
    app: order-service
    version: {{ .Values.image.tag | quote }}
    team: backend
spec:
  replicas: {{ .Values.replicaCount }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: order-service
  strategy:
    canary:
      stableService: order-service
      canaryService: order-service-canary
      steps:
        - setWeight: 10
        - pause: { duration: 30s }
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
            args:
              - name: service-name
                value: order-service-canary
        - setWeight: 25
        - pause: { duration: 60s }
        - analysis:
            templates:
              - templateName: success-rate
            args:
              - name: service-name
                value: order-service-canary
        - setWeight: 50
        - pause: { duration: 60s }
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
            args:
              - name: service-name
                value: order-service-canary
        - setWeight: 100
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: order-service
    spec:
      serviceAccountName: order-service
      containers:
        - name: order-service
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 3000
              name: http
          env:
            - name: NODE_ENV
              value: {{ .Values.env | default "production" }}
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: order-service-db
                  key: url
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: order-service-redis
                  key: url
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /ready
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
```

---

## Verify

### Check Argo Rollouts controller is running

```bash
kubectl get pods -n argo-rollouts
# Expected:
# argo-rollouts-xxx   1/1  Running
# argo-rollouts-dashboard-xxx  1/1  Running
```

### List rollouts

```bash
kubectl argo rollouts list rollouts -n apps
# NAME             STRATEGY  STATUS   STEP  SET-WEIGHT  READY  DESIRED
# api-gateway      BlueGreen Healthy  -     -           2/2    2
# user-service     Canary    Healthy  4/4   100         3/3    3
# order-service    Canary    Healthy  4/4   100         3/3    3
```

### Watch a rollout in real time

```bash
kubectl argo rollouts get rollout user-service -n apps --watch
```

### Verify analysis templates exist

```bash
kubectl get analysistemplates -n apps
# NAME            AGE
# success-rate    5m
# latency-check   5m
# error-rate      5m
```

### Check RAM usage

```bash
kubectl top pods -n argo-rollouts
# Should be ~100-150MB total
```

---

## Troubleshooting

### Rollout stuck in "Paused" state

```bash
# Check why it paused
kubectl argo rollouts get rollout <name> -n apps

# If it is waiting for manual promotion:
kubectl argo rollouts promote <name> -n apps

# If analysis failed — check AnalysisRun:
kubectl get analysisruns -n apps
kubectl describe analysisrun <latest-run> -n apps
```

### AnalysisRun returns "no data"

Prometheus may not have metrics yet. Check:

```bash
# Verify the metric exists in Prometheus
curl -s "http://localhost:9090/api/v1/query?query=http_requests_total" | jq .

# Common issue: metric name mismatch. Check your app's /metrics endpoint:
kubectl port-forward svc/user-service -n apps 8080:80
curl localhost:8080/metrics | grep http_requests
```

### Canary weight not changing (traffic not splitting)

Ensure traffic routing is configured. For basic canary without traffic routing,
Argo Rollouts uses replica ratio — which is approximate, not exact:

```bash
# Verify services have correct selectors
kubectl describe svc user-service -n apps
kubectl describe svc user-service-canary -n apps
```

### Rollout in "Degraded" state after abort

```bash
# Retry the rollout (goes back to stable version)
kubectl argo rollouts retry rollout <name> -n apps

# Or set to a specific image to trigger a new rollout
kubectl argo rollouts set image <name> <container>=<image>:<tag> -n apps
```

### CRD not recognized by ArgoCD

```bash
# Check CRDs are installed
kubectl get crd rollouts.argoproj.io analysistemplates.argoproj.io

# Restart ArgoCD application controller to pick up new CRDs
kubectl rollout restart statefulset argocd-application-controller -n argocd
```

---

## Checklist

- [ ] argo-rollouts namespace created
- [ ] Argo Rollouts Helm chart installed
- [ ] kubectl-argo-rollouts plugin installed
- [ ] Blue/Green strategy configured for staging
- [ ] Canary strategy configured for production (10% -> 25% -> 50% -> 100%)
- [ ] AnalysisTemplate: success-rate (>= 99%)
- [ ] AnalysisTemplate: latency-check (p99 < 500ms)
- [ ] AnalysisTemplate: error-rate (< 1%)
- [ ] Auto-rollback tested (abort on analysis failure)
- [ ] Dashboard UI accessible via port-forward
- [ ] ArgoCD resource customization for Rollout health
- [ ] Total RAM usage verified under 150MB

---

## What's Next?

Now that ArgoCD handles declarative delivery and Argo Rollouts handles
progressive rollout, the next step is **Guide 18: Helm Charts** — creating
proper Helm charts for each microservice with environment-specific values,
hooks, and testing.
