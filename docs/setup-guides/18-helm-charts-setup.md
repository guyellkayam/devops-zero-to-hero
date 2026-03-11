# Guide 18: Helm Charts Setup — Packaging Microservices

## Why This Matters

Helm is the package manager for Kubernetes. Instead of maintaining dozens of raw
YAML manifests per microservice per environment, you write templates once and
inject environment-specific values at deploy time. Benefits:

- **DRY manifests** — one chart template serves dev, staging, and production.
- **Version control** — each chart has a version; rollbacks are trivial.
- **Dependency management** — `Chart.yaml` declares sub-chart dependencies.
- **Testing** — `helm template` renders locally; `helm lint` catches errors
  before they reach the cluster.
- **Publishing** — push charts to Harbor (our registry from Guide 15) for
  consumption by ArgoCD.

This guide creates charts for all three microservices:
- `api-gateway` (Node.js)
- `user-service` (Python / FastAPI)
- `order-service` (Node.js)

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| Helm 3.12+ | `helm version` |
| kubectl configured | `kubectl cluster-info` |
| ArgoCD installed (Guide 16) | `argocd app list` |
| Argo Rollouts installed (Guide 17) | `kubectl get crd rollouts.argoproj.io` |
| Harbor registry (Guide 15) | `helm repo list` shows harbor |

---

## Step 1 — Chart Directory Structure

Create the scaffold for all three services:

```bash
mkdir -p helm/{api-gateway,user-service,order-service}/templates
```

The final tree looks like this:

```
helm/
  api-gateway/
    Chart.yaml
    values.yaml
    values-dev.yaml
    values-staging.yaml
    values-production.yaml
    templates/
      _helpers.tpl
      rollout.yaml
      service.yaml
      hpa.yaml
      networkpolicy.yaml
      serviceaccount.yaml
      configmap.yaml
      hooks/
        db-migrate-job.yaml
  user-service/
    Chart.yaml
    values.yaml
    values-dev.yaml
    values-staging.yaml
    values-production.yaml
    templates/
      _helpers.tpl
      rollout.yaml
      service.yaml
      hpa.yaml
      networkpolicy.yaml
      serviceaccount.yaml
      configmap.yaml
      hooks/
        db-migrate-job.yaml
  order-service/
    Chart.yaml
    values.yaml
    values-dev.yaml
    values-staging.yaml
    values-production.yaml
    templates/
      _helpers.tpl
      rollout.yaml
      service.yaml
      hpa.yaml
      networkpolicy.yaml
      serviceaccount.yaml
      configmap.yaml
```

---

## Step 2 — Chart.yaml

Each service gets its own `Chart.yaml`. Here is the api-gateway example (adapt
name/description for the others):

```yaml
# helm/api-gateway/Chart.yaml
apiVersion: v2
name: api-gateway
description: API Gateway microservice (Node.js) - routes and aggregates requests
type: application
version: 0.1.0       # Chart version (bump on template changes)
appVersion: "1.0.0"  # Application version (matches Docker image tag)
maintainers:
  - name: DevOps Team
    email: devops@example.com
dependencies: []
```

```yaml
# helm/user-service/Chart.yaml
apiVersion: v2
name: user-service
description: User Service (Python/FastAPI) - authentication and user management
type: application
version: 0.1.0
appVersion: "1.0.0"
maintainers:
  - name: DevOps Team
    email: devops@example.com
```

```yaml
# helm/order-service/Chart.yaml
apiVersion: v2
name: order-service
description: Order Service (Node.js) - order processing and management
type: application
version: 0.1.0
appVersion: "1.0.0"
maintainers:
  - name: DevOps Team
    email: devops@example.com
```

---

## Step 3 — Template Helpers (_helpers.tpl)

Shared template functions used across all templates. This file is identical for
all three charts — just change the chart name reference:

```yaml
# helm/api-gateway/templates/_helpers.tpl
{{/*
Expand the name of the chart.
*/}}
{{- define "api-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "api-gateway.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "api-gateway.labels" -}}
helm.sh/chart: {{ include "api-gateway.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "api-gateway.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: devops-zero-to-hero
team: {{ .Values.team | default "platform" }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "api-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "api-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "api-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "api-gateway.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
```

---

## Step 4 — Default values.yaml

The base values file contains all configurable parameters with sensible
defaults:

```yaml
# helm/api-gateway/values.yaml

# -- Number of replicas (overridden by HPA in staging/prod)
replicaCount: 1

image:
  repository: ghcr.io/<you>/api-gateway
  tag: "1.0.0"
  pullPolicy: IfNotPresent

# -- Deployment strategy
strategy:
  type: canary   # canary or blueGreen
  canary:
    steps:
      - setWeight: 10
      - pause: { duration: 30s }
      - setWeight: 50
      - pause: { duration: 60s }
      - setWeight: 100
  blueGreen:
    autoPromote: false

# -- Service configuration
service:
  type: ClusterIP
  port: 80
  targetPort: 3000

# -- Resource requests and limits
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

# -- Horizontal Pod Autoscaler
autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilization: 70
  targetMemoryUtilization: 80

# -- ServiceAccount
serviceAccount:
  create: true
  annotations: {}
  name: ""

# -- Pod labels
team: platform
version: "1.0.0"

# -- Environment variables
env:
  NODE_ENV: production
  LOG_LEVEL: info
  PORT: "3000"

# -- Secrets (injected via ExternalSecret, referenced by name)
secrets:
  enabled: true
  externalSecretName: api-gateway-secrets

# -- Network policy
networkPolicy:
  enabled: true
  ingress:
    # Allow traffic from Envoy Gateway namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: envoy-gateway-system
      ports:
        - port: 3000
    # Allow traffic from monitoring namespace (Prometheus scraping)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - port: 3000
  egress:
    - to: []  # Allow all egress by default

# -- Probes
livenessProbe:
  httpGet:
    path: /healthz
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 15
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /ready
    port: 3000
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3

# -- Database migration hook
migration:
  enabled: false
  image: ""
  command: []
```

---

## Step 5 — Environment-Specific Values

### Dev values (minimal resources, no autoscaling)

```yaml
# helm/api-gateway/values-dev.yaml
replicaCount: 1

image:
  tag: "latest"
  pullPolicy: Always

strategy:
  type: canary
  canary:
    steps:
      - setWeight: 100   # Skip canary steps in dev

resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 64Mi

autoscaling:
  enabled: false

env:
  NODE_ENV: development
  LOG_LEVEL: debug

networkPolicy:
  enabled: false   # Relaxed in dev
```

### Staging values (blue/green, moderate resources)

```yaml
# helm/api-gateway/values-staging.yaml
replicaCount: 2

image:
  tag: "1.0.0-rc.1"

strategy:
  type: blueGreen
  blueGreen:
    autoPromote: true

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 4
  targetCPUUtilization: 75

env:
  NODE_ENV: staging
  LOG_LEVEL: info
```

### Production values (canary with analysis, full resources)

```yaml
# helm/api-gateway/values-production.yaml
replicaCount: 3

image:
  tag: "1.0.0"

strategy:
  type: canary
  canary:
    steps:
      - setWeight: 10
      - pause: { duration: 30s }
      - analysis:
          templates:
            - templateName: success-rate
            - templateName: latency-check
      - setWeight: 25
      - pause: { duration: 60s }
      - analysis:
          templates:
            - templateName: success-rate
      - setWeight: 50
      - pause: { duration: 60s }
      - analysis:
          templates:
            - templateName: success-rate
            - templateName: latency-check
      - setWeight: 100

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilization: 70
  targetMemoryUtilization: 80

env:
  NODE_ENV: production
  LOG_LEVEL: warn
```

---

## Step 6 — Rollout Template

Uses Argo Rollouts instead of a Deployment:

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
  strategy:
    {{- if eq .Values.strategy.type "canary" }}
    canary:
      stableService: {{ include "api-gateway.fullname" . }}
      canaryService: {{ include "api-gateway.fullname" . }}-canary
      steps:
        {{- toYaml .Values.strategy.canary.steps | nindent 8 }}
      maxSurge: 1
      maxUnavailable: 0
    {{- else if eq .Values.strategy.type "blueGreen" }}
    blueGreen:
      activeService: {{ include "api-gateway.fullname" . }}
      previewService: {{ include "api-gateway.fullname" . }}-preview
      autoPromotionEnabled: {{ .Values.strategy.blueGreen.autoPromote }}
      scaleDownDelaySeconds: 30
    {{- end }}
  template:
    metadata:
      labels:
        {{- include "api-gateway.selectorLabels" . | nindent 8 }}
        app: {{ include "api-gateway.name" . }}
        version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
        team: {{ .Values.team | default "platform" }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: {{ .Values.service.targetPort | quote }}
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: {{ include "api-gateway.serviceAccountName" . }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          env:
            {{- range $key, $value := .Values.env }}
            - name: {{ $key }}
              value: {{ $value | quote }}
            {{- end }}
            {{- if .Values.secrets.enabled }}
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.externalSecretName }}
                  key: db-password
                  optional: true
            {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
```

---

## Step 7 — Service Templates

```yaml
# helm/api-gateway/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "api-gateway.fullname" . }}
  labels:
    {{- include "api-gateway.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      protocol: TCP
      name: http
  selector:
    {{- include "api-gateway.selectorLabels" . | nindent 4 }}
---
{{- if eq .Values.strategy.type "canary" }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "api-gateway.fullname" . }}-canary
  labels:
    {{- include "api-gateway.labels" . | nindent 4 }}
    role: canary
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      protocol: TCP
      name: http
  selector:
    {{- include "api-gateway.selectorLabels" . | nindent 4 }}
{{- end }}
{{- if eq .Values.strategy.type "blueGreen" }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "api-gateway.fullname" . }}-preview
  labels:
    {{- include "api-gateway.labels" . | nindent 4 }}
    role: preview
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      protocol: TCP
      name: http
  selector:
    {{- include "api-gateway.selectorLabels" . | nindent 4 }}
{{- end }}
```

---

## Step 8 — HPA Template

```yaml
# helm/api-gateway/templates/hpa.yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "api-gateway.fullname" . }}
  labels:
    {{- include "api-gateway.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    name: {{ include "api-gateway.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilization }}
    {{- if .Values.autoscaling.targetMemoryUtilization }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetMemoryUtilization }}
    {{- end }}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
{{- end }}
```

---

## Step 9 — NetworkPolicy Template

```yaml
# helm/api-gateway/templates/networkpolicy.yaml
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "api-gateway.fullname" . }}
  labels:
    {{- include "api-gateway.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "api-gateway.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    {{- toYaml .Values.networkPolicy.ingress | nindent 4 }}
  egress:
    # Allow DNS resolution
    - to: []
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    {{- if .Values.networkPolicy.egress }}
    {{- toYaml .Values.networkPolicy.egress | nindent 4 }}
    {{- end }}
{{- end }}
```

---

## Step 10 — ServiceAccount Template

```yaml
# helm/api-gateway/templates/serviceaccount.yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "api-gateway.serviceAccountName" . }}
  labels:
    {{- include "api-gateway.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: false
{{- end }}
```

---

## Step 11 — Helm Hooks for Database Migrations

Helm hooks run Jobs at specific lifecycle points. Pre-install / pre-upgrade
hooks run database migrations before the new pods start.

```yaml
# helm/user-service/templates/hooks/db-migrate-job.yaml
{{- if .Values.migration.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "user-service.fullname" . }}-migrate-{{ .Release.Revision }}
  labels:
    {{- include "user-service.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 300
  template:
    metadata:
      labels:
        app: {{ include "user-service.name" . }}-migrate
    spec:
      restartPolicy: Never
      serviceAccountName: {{ include "user-service.serviceAccountName" . }}
      containers:
        - name: migrate
          image: "{{ .Values.migration.image | default .Values.image.repository }}:{{ .Values.image.tag }}"
          command:
            {{- toYaml .Values.migration.command | nindent 12 }}
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.externalSecretName }}
                  key: database-url
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
{{- end }}
```

User-service migration values:

```yaml
# In helm/user-service/values.yaml
migration:
  enabled: true
  command:
    - "python"
    - "-m"
    - "alembic"
    - "upgrade"
    - "head"
```

---

## Step 12 — User-Service Specifics (Python/FastAPI)

The user-service has slightly different probe paths and environment:

```yaml
# helm/user-service/values.yaml (differences from api-gateway)
image:
  repository: ghcr.io/<you>/user-service
  tag: "1.0.0"

service:
  port: 80
  targetPort: 8000   # FastAPI default port

env:
  PYTHONUNBUFFERED: "1"
  LOG_LEVEL: info
  UVICORN_WORKERS: "2"

livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 15
  periodSeconds: 15

readinessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 10
  periodSeconds: 10

migration:
  enabled: true
  command:
    - "python"
    - "-m"
    - "alembic"
    - "upgrade"
    - "head"
```

---

## Step 13 — Chart Testing

### Lint all charts

```bash
helm lint helm/api-gateway/
helm lint helm/user-service/
helm lint helm/order-service/
```

### Render templates locally (dry-run)

```bash
# Render with dev values
helm template api-gateway helm/api-gateway/ -f helm/api-gateway/values-dev.yaml

# Render with production values and inspect output
helm template api-gateway helm/api-gateway/ \
  -f helm/api-gateway/values-production.yaml \
  --output-dir /tmp/rendered

# Inspect a specific template
helm template api-gateway helm/api-gateway/ \
  -f helm/api-gateway/values-production.yaml \
  -s templates/rollout.yaml
```

### Validate rendered YAML against cluster

```bash
helm template api-gateway helm/api-gateway/ \
  -f helm/api-gateway/values-dev.yaml | \
  kubectl apply --dry-run=server -f -
```

---

## Step 14 — Publishing to Harbor

Push charts to your Harbor registry so ArgoCD can pull from a chart repo
instead of a Git repo:

```bash
# Package the chart
helm package helm/api-gateway/
# Output: api-gateway-0.1.0.tgz

# Push to Harbor
helm push api-gateway-0.1.0.tgz oci://harbor.dev.localhost/charts

# Repeat for other services
helm package helm/user-service/ && helm push user-service-0.1.0.tgz oci://harbor.dev.localhost/charts
helm package helm/order-service/ && helm push order-service-0.1.0.tgz oci://harbor.dev.localhost/charts
```

ArgoCD can then reference the chart as a Helm source:

```yaml
# argocd/apps/api-gateway.yaml (chart repo variant)
spec:
  source:
    chart: api-gateway
    repoURL: oci://harbor.dev.localhost/charts
    targetRevision: 0.1.0
    helm:
      valueFiles:
        - values-dev.yaml
```

---

## Step 15 — Kustomize vs Helm: When to Use Which

| Aspect | Helm | Kustomize |
|--------|------|-----------|
| Use when | You need templating, conditionals, loops | You need simple patches/overlays |
| Complexity | Higher (Go templates) | Lower (plain YAML patches) |
| Packaging | Publishable charts (.tgz) | Directory-based, no packaging |
| Versioning | Chart version + app version | Git commit |
| Ecosystem | Massive chart repository ecosystem | Built into kubectl |
| Our approach | Microservice charts | Infrastructure overlays |

**Our convention:**

- **Helm** for microservices (`helm/api-gateway`, `helm/user-service`,
  `helm/order-service`) — they benefit from templating and per-environment values.
- **Kustomize** for cluster infrastructure (`manifests/base/` +
  `manifests/overlays/dev/`) — namespaces, RBAC, network policies that differ
  only slightly between environments.

Example Kustomize overlay for dev namespace config:

```yaml
# manifests/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: apps

resources:
  - ../../base/namespaces

patches:
  - target:
      kind: Namespace
      name: apps
    patch: |
      - op: add
        path: /metadata/labels/environment
        value: dev
```

---

## Verify

### Lint all charts

```bash
for chart in helm/*/; do
  echo "--- Linting $chart ---"
  helm lint "$chart"
done
# Each should show: 1 chart(s) linted, 0 chart(s) failed
```

### Template render succeeds for all environments

```bash
for env in dev staging production; do
  for chart in api-gateway user-service order-service; do
    echo "--- $chart / $env ---"
    helm template "$chart" "helm/$chart/" -f "helm/$chart/values-$env.yaml" > /dev/null && echo "OK" || echo "FAIL"
  done
done
```

### Verify ArgoCD can sync the charts

```bash
argocd app list
# All apps should show Synced / Healthy
```

---

## Troubleshooting

### "Error: template: ... function not defined"

You are using a Helm function that does not exist. Common mistake: using
`{{ .Values.foo.bar }}` when `foo` is nil. Fix with `default`:

```yaml
{{ .Values.foo.bar | default "fallback" }}
```

Or guard with `if`:

```yaml
{{- if .Values.foo }}
  bar: {{ .Values.foo.bar }}
{{- end }}
```

### "YAML parse error" during helm template

Usually an indentation issue. The `nindent` function is your friend:

```yaml
# Wrong
labels:
  {{ include "chart.labels" . }}

# Right
labels:
  {{- include "chart.labels" . | nindent 4 }}
```

### ArgoCD shows "OutOfSync" for HPA replicas

The HPA controller updates `spec.replicas` on the Rollout, causing ArgoCD to
see a diff. Add an ignore rule to the Application:

```yaml
spec:
  ignoreDifferences:
    - group: argoproj.io
      kind: Rollout
      jsonPointers:
        - /spec/replicas
```

### Helm hook Job stays in "Failed"

```bash
# Check the Job logs
kubectl logs job/user-service-migrate-2 -n apps

# Delete failed hook resources manually
kubectl delete job user-service-migrate-2 -n apps
```

### Chart version conflict in Harbor

Helm OCI registries reject duplicate versions. Bump `version` in `Chart.yaml`
before pushing:

```bash
# Update Chart.yaml version
sed -i 's/version: 0.1.0/version: 0.1.1/' helm/api-gateway/Chart.yaml
helm package helm/api-gateway/
helm push api-gateway-0.1.1.tgz oci://harbor.dev.localhost/charts
```

---

## Checklist

- [ ] Chart scaffold created for api-gateway, user-service, order-service
- [ ] Chart.yaml with proper metadata for each service
- [ ] _helpers.tpl with name, fullname, labels, selectorLabels functions
- [ ] values.yaml with sensible defaults
- [ ] values-dev.yaml (minimal resources, debug logging)
- [ ] values-staging.yaml (blue/green, moderate resources)
- [ ] values-production.yaml (canary with analysis, full resources)
- [ ] Rollout template (supports both canary and blueGreen via values)
- [ ] Service template (with canary/preview variants)
- [ ] HPA template (conditional on autoscaling.enabled)
- [ ] NetworkPolicy template (conditional on networkPolicy.enabled)
- [ ] ServiceAccount template
- [ ] Database migration hook for user-service
- [ ] All charts pass `helm lint`
- [ ] All charts render cleanly with `helm template`
- [ ] Charts published to Harbor OCI registry
- [ ] ArgoCD syncs all charts successfully

---

## What's Next?

With Helm charts packaging your microservices and ArgoCD deploying them through
Git, the next step is **Guide 19: Kyverno Setup** — enforcing policies that
prevent misconfigurations (missing resource limits, privileged containers,
unsigned images) from ever reaching your cluster.
