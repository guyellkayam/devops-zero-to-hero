# 30 — Advanced GitOps: Flux, Crossplane, Kaniko, and Platform Engineering

## Why This Matters
Through 29 guides, we built a production-grade DevOps platform with ArgoCD as our GitOps
engine, Terraform for infrastructure, and Docker builds on CI runners. This guide introduces
the next evolution of each: Flux v2 as an alternative GitOps tool, Crossplane for
Kubernetes-native infrastructure as code, and Kaniko for secure in-cluster container builds.
Together, these form the foundation of a modern Internal Developer Platform.

This is not about replacing what we built. It is about understanding the alternatives and
knowing when each tool is the right choice. In interviews and production environments, you
will encounter all of these.

---

## Prerequisites
- k3s cluster running (guide 07)
- kubectl, Helm, and Git installed (guide 02)
- ArgoCD running (guide 12) -- for comparison
- Terraform running (guide 03) -- for comparison
- AWS CLI configured with admin permissions
- GitHub personal access token (for Flux)
- ~400MB RAM available for all tools in this guide

---

## Part 1: Flux v2 — Alternative CNCF GitOps

### Flux vs ArgoCD: When to Use Each

| Feature | Flux v2 | ArgoCD |
|---------|---------|--------|
| **CNCF status** | Graduated | Graduated |
| **Architecture** | CRD-native, pull-based | Server + UI, push/pull |
| **UI** | Weave GitOps (separate) | Built-in web UI |
| **Multi-tenancy** | Native (per-namespace) | AppProject-based |
| **Helm support** | HelmRelease CRD | Helm app type |
| **Kustomize** | Native Kustomize CRD | Built-in |
| **Notifications** | Provider CRDs | Built-in |
| **Image automation** | Built-in (ImagePolicy) | Image Updater (separate) |
| **RAM usage** | ~150MB | ~400MB |
| **Best for** | GitOps purists, multi-tenant | Teams wanting UI, app-of-apps |

**Rule of thumb**: Use ArgoCD when you want a visual dashboard for your team. Use Flux when you
want everything as Kubernetes CRDs with no UI dependency.

### Step 1.1: Install the Flux CLI

```bash
# macOS
brew install fluxcd/tap/flux

# Linux
curl -s https://fluxcd.io/install.sh | sudo bash

# Verify
flux --version
```

### Step 1.2: Pre-Flight Check

```bash
# Verify cluster compatibility
flux check --pre
```

All checks should pass. This verifies Kubernetes version, RBAC, and CRD support.

### Step 1.3: Bootstrap Flux with GitHub

Flux bootstraps itself: it installs its components AND creates the Git repository structure
for managing itself.

```bash
# Export your GitHub token
export GITHUB_TOKEN=<your-github-pat>

# Bootstrap Flux
flux bootstrap github \
  --owner=<your-github-username> \
  --repository=devops-flux-config \
  --branch=main \
  --path=clusters/devops-lab \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller
```

This creates:
1. A GitHub repository `devops-flux-config` (if it does not exist)
2. Flux components in the `flux-system` namespace
3. A `clusters/devops-lab/` directory structure in the repo

```bash
# Verify Flux is running
flux check
kubectl get pods -n flux-system
```

Expected pods:
```
NAME                                          READY   STATUS    RESTARTS
helm-controller-abc123                        1/1     Running   0
image-automation-controller-def456            1/1     Running   0
image-reflector-controller-ghi789             1/1     Running   0
kustomize-controller-jkl012                   1/1     Running   0
notification-controller-mno345                1/1     Running   0
source-controller-pqr678                      1/1     Running   0
```

### Step 1.4: Deploy an Application with Flux

Create a GitRepository source and Kustomization:

```bash
# Create a source pointing to your app repo
flux create source git devops-apps \
  --url=https://github.com/<your-username>/devops-zero-to-hero \
  --branch=main \
  --interval=1m

# Create a Kustomization to deploy from a path in the repo
flux create kustomization apps \
  --source=devops-apps \
  --path="./k8s/apps" \
  --prune=true \
  --interval=5m \
  --target-namespace=apps \
  --health-check-timeout=3m
```

Or as YAML (committed to the Flux config repo):

```yaml
# clusters/devops-lab/apps-source.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: devops-apps
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/<your-username>/devops-zero-to-hero
  ref:
    branch: main
---
# clusters/devops-lab/apps-kustomization.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: devops-apps
  path: ./k8s/apps
  prune: true
  targetNamespace: apps
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: api-service
      namespace: apps
    - apiVersion: apps/v1
      kind: Deployment
      name: frontend
      namespace: apps
  timeout: 3m
```

### Step 1.5: Helm Releases with Flux

```yaml
# clusters/devops-lab/helm-repos.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
# clusters/devops-lab/redis-release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: redis
  namespace: apps
spec:
  interval: 5m
  chart:
    spec:
      chart: redis
      version: "18.x"
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  values:
    architecture: standalone
    auth:
      enabled: true
      existingSecret: redis-auth
    master:
      resources:
        requests:
          cpu: 25m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
```

### Step 1.6: Image Automation (Auto-Update on New Image Push)

```yaml
# clusters/devops-lab/image-automation.yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: api-service
  namespace: flux-system
spec:
  image: <account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-lab/api-service
  interval: 5m
  provider: aws
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: api-service
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: api-service
  policy:
    semver:
      range: ">=1.0.0"
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: api-service-update
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: devops-apps
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: flux-bot
        email: flux@devops-lab.local
      messageTemplate: "chore: update api-service to {{.NewImage}}"
    push:
      branch: main
  update:
    path: ./k8s/apps
    strategy: Setters
```

### Step 1.7: Monitor Flux

```bash
# Check all Flux resources
flux get all

# Watch reconciliation
flux get kustomizations --watch

# Check events
flux events

# Suspend/resume reconciliation
flux suspend kustomization apps
flux resume kustomization apps
```

---

## Part 2: Crossplane — Kubernetes-Native Infrastructure as Code

### Crossplane vs Terraform: When to Use Each

| Feature | Crossplane | Terraform |
|---------|-----------|-----------|
| **Paradigm** | Kubernetes CRDs (declarative, reconciling) | HCL (declarative, apply-based) |
| **State** | Kubernetes etcd (always reconciling) | State file (S3/local) |
| **Drift detection** | Continuous (every reconcile interval) | Manual (`terraform plan`) |
| **Language** | YAML (K8s manifests) | HCL |
| **Composability** | Composite Resources (XRDs) | Modules |
| **Multi-cloud** | Provider CRDs | Provider plugins |
| **Team model** | Self-service via K8s RBAC | Central team runs apply |
| **Best for** | Platform teams, self-service | Infrastructure teams, complex IaC |

**Rule of thumb**: Use Terraform when an infrastructure team manages resources centrally. Use
Crossplane when you want developers to self-service infrastructure through Kubernetes.

### Step 2.1: Install Crossplane

```bash
# Add Crossplane Helm repo
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

# Install Crossplane
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi
```

Wait for Crossplane to be ready:
```bash
kubectl get pods -n crossplane-system -w
```

### Step 2.2: Install the AWS Provider

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:v1.2.1
  runtimeConfigRef:
    name: default
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-ec2
spec:
  package: xpkg.upbound.io/upbound/provider-aws-ec2:v1.2.1
EOF
```

Wait for providers to be healthy:
```bash
kubectl get providers -w
```

### Step 2.3: Configure AWS Credentials for Crossplane

```bash
# Create a Kubernetes secret with AWS credentials
kubectl create secret generic aws-creds \
  --namespace crossplane-system \
  --from-literal=credentials="[default]
aws_access_key_id = $(aws configure get aws_access_key_id)
aws_secret_access_key = $(aws configure get aws_secret_access_key)"

# Create a ProviderConfig
cat <<'EOF' | kubectl apply -f -
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-creds
      key: credentials
EOF
```

### Step 2.4: Create an S3 Bucket from a Kubernetes Manifest

This is the magic of Crossplane: create AWS resources using `kubectl apply`.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: s3.aws.upbound.io/v1beta2
kind: Bucket
metadata:
  name: devops-lab-crossplane-test
spec:
  forProvider:
    region: us-east-1
    tags:
      ManagedBy: crossplane
      Environment: learning
  providerConfigRef:
    name: default
---
apiVersion: s3.aws.upbound.io/v1beta1
kind: BucketVersioning
metadata:
  name: devops-lab-crossplane-test-versioning
spec:
  forProvider:
    bucketRef:
      name: devops-lab-crossplane-test
    region: us-east-1
    versioningConfiguration:
      - status: Enabled
  providerConfigRef:
    name: default
---
apiVersion: s3.aws.upbound.io/v1beta2
kind: BucketServerSideEncryptionConfiguration
metadata:
  name: devops-lab-crossplane-test-encryption
spec:
  forProvider:
    bucketRef:
      name: devops-lab-crossplane-test
    region: us-east-1
    rule:
      - applyServerSideEncryptionByDefault:
          - sseAlgorithm: AES256
  providerConfigRef:
    name: default
EOF
```

Watch the bucket get created:
```bash
kubectl get bucket -w
```

Verify in AWS:
```bash
aws s3 ls | grep crossplane
```

### Step 2.5: Composite Resources (XRDs) — Reusable Abstractions

XRDs let you create platform-level abstractions. Developers request an "ObjectStorage" and
get a fully configured S3 bucket with encryption, versioning, and lifecycle policies.

```bash
# Define the Composite Resource Definition (XRD)
cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xobjectstorages.platform.devops-lab.io
spec:
  group: platform.devops-lab.io
  names:
    kind: XObjectStorage
    plural: xobjectstorages
  claimNames:
    kind: ObjectStorage
    plural: objectstorages
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                parameters:
                  type: object
                  properties:
                    region:
                      type: string
                      default: us-east-1
                    environment:
                      type: string
                      enum: ["dev", "staging", "prod"]
                    versioning:
                      type: boolean
                      default: true
                  required:
                    - environment
EOF
```

```bash
# Define the Composition (how the XRD maps to actual AWS resources)
cat <<'EOF' | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: objectstorage-aws
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: platform.devops-lab.io/v1alpha1
    kind: XObjectStorage
  resources:
    - name: bucket
      base:
        apiVersion: s3.aws.upbound.io/v1beta2
        kind: Bucket
        spec:
          forProvider:
            region: us-east-1
            tags:
              ManagedBy: crossplane
          providerConfigRef:
            name: default
      patches:
        - fromFieldPath: spec.parameters.region
          toFieldPath: spec.forProvider.region
        - fromFieldPath: spec.parameters.environment
          toFieldPath: spec.forProvider.tags.Environment

    - name: versioning
      base:
        apiVersion: s3.aws.upbound.io/v1beta1
        kind: BucketVersioning
        spec:
          forProvider:
            region: us-east-1
            versioningConfiguration:
              - status: Enabled
          providerConfigRef:
            name: default
      patches:
        - fromFieldPath: spec.parameters.region
          toFieldPath: spec.forProvider.region

    - name: encryption
      base:
        apiVersion: s3.aws.upbound.io/v1beta2
        kind: BucketServerSideEncryptionConfiguration
        spec:
          forProvider:
            region: us-east-1
            rule:
              - applyServerSideEncryptionByDefault:
                  - sseAlgorithm: AES256
          providerConfigRef:
            name: default
      patches:
        - fromFieldPath: spec.parameters.region
          toFieldPath: spec.forProvider.region
EOF
```

Now developers can request storage with a simple claim:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: platform.devops-lab.io/v1alpha1
kind: ObjectStorage
metadata:
  name: my-app-data
  namespace: apps
spec:
  parameters:
    environment: dev
    region: us-east-1
    versioning: true
EOF
```

Check the status:
```bash
kubectl get objectstorage -n apps
kubectl get composite
kubectl get bucket
```

### Step 2.6: Clean Up Crossplane Resources

```bash
# Delete the claim (this deletes all composed resources including the S3 bucket)
kubectl delete objectstorage my-app-data -n apps

# Delete the test bucket
kubectl delete bucket devops-lab-crossplane-test

# Verify in AWS
aws s3 ls | grep crossplane
# Should return nothing
```

---

## Part 3: Kaniko — Secure In-Cluster Container Builds

### Why Kaniko?

Traditional Docker builds require a Docker daemon with root access -- a security risk in shared
clusters. Kaniko builds container images inside a Kubernetes pod without needing a Docker daemon
or privileged access.

| Feature | Kaniko | Docker-in-Docker | Buildkit |
|---------|--------|-------------------|----------|
| **Docker daemon** | Not needed | Required | Not needed |
| **Privileged mode** | Not needed | Required | Optional |
| **Security** | Rootless | Root required | Rootless option |
| **K8s native** | K8s Job | Sidecar/DinD | Sidecar |
| **Cache** | Layer caching to registry | Local cache | Local/registry |

### Step 3.1: Create a Kaniko Build Job

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kaniko-build-api-service
  namespace: apps
spec:
  backoffLimit: 1
  template:
    spec:
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:latest
          args:
            - "--context=git://github.com/<your-username>/devops-zero-to-hero#refs/heads/main"
            - "--context-sub-path=services/api-service"
            - "--dockerfile=Dockerfile"
            - "--destination=<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-lab/api-service:latest"
            - "--cache=true"
            - "--cache-repo=<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-lab/cache"
            - "--snapshotMode=redo"
            - "--compressed-caching=false"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
          volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
      volumes:
        - name: docker-config
          secret:
            secretName: ecr-docker-config
      restartPolicy: Never
EOF
```

### Step 3.2: ECR Authentication for Kaniko

```bash
# Create ECR docker config secret
# This needs to be refreshed every 12 hours (ECR tokens expire)
ECR_TOKEN=$(aws ecr get-login-password --region us-east-1)
ECR_REGISTRY="<account-id>.dkr.ecr.us-east-1.amazonaws.com"

kubectl create secret docker-registry ecr-docker-config \
  --namespace apps \
  --docker-server=$ECR_REGISTRY \
  --docker-username=AWS \
  --docker-password=$ECR_TOKEN
```

For automated token refresh, create a CronJob:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ecr-token-refresh
  namespace: apps
spec:
  schedule: "0 */10 * * *"  # Every 10 hours (tokens expire at 12)
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: ecr-refresh-sa
          containers:
            - name: ecr-refresh
              image: amazon/aws-cli:latest
              command:
                - /bin/sh
                - -c
                - |
                  TOKEN=$(aws ecr get-login-password --region us-east-1)
                  REGISTRY="<account-id>.dkr.ecr.us-east-1.amazonaws.com"

                  kubectl delete secret ecr-docker-config -n apps --ignore-not-found
                  kubectl create secret docker-registry ecr-docker-config \
                    --namespace apps \
                    --docker-server=$REGISTRY \
                    --docker-username=AWS \
                    --docker-password=$TOKEN
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
                limits:
                  cpu: 50m
                  memory: 64Mi
          restartPolicy: OnFailure
EOF
```

### Step 3.3: Kaniko in CI/CD Pipeline

Create a reusable build template that ArgoCD or Flux can trigger:

```yaml
# k8s/build/kaniko-template.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: build-SERVICE_NAME-BUILD_ID
  namespace: ci
  labels:
    app: kaniko-build
    service: SERVICE_NAME
spec:
  ttlSecondsAfterFinished: 3600  # Auto-cleanup after 1 hour
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: kaniko-build
    spec:
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:latest
          args:
            - "--context=git://github.com/YOUR_ORG/YOUR_REPO#refs/heads/BRANCH"
            - "--context-sub-path=services/SERVICE_NAME"
            - "--dockerfile=Dockerfile"
            - "--destination=REGISTRY/SERVICE_NAME:TAG"
            - "--cache=true"
            - "--cache-repo=REGISTRY/cache"
            - "--snapshotMode=redo"
          env:
            - name: GIT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: git-credentials
                  key: token
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
          volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
      volumes:
        - name: docker-config
          secret:
            secretName: ecr-docker-config
      restartPolicy: Never
```

Build script:
```bash
#!/bin/bash
# scripts/build.sh — Trigger a Kaniko build
SERVICE=$1
TAG=${2:-$(git rev-parse --short HEAD)}
BUILD_ID=$(date +%s)

sed "s/SERVICE_NAME/$SERVICE/g; s/BUILD_ID/$BUILD_ID/g; s/TAG/$TAG/g" \
  k8s/build/kaniko-template.yaml | kubectl apply -f -

echo "Build started: build-$SERVICE-$BUILD_ID"
echo "Watch: kubectl logs -n ci -l service=$SERVICE -f"
```

---

## Part 4: Platform Engineering Concepts

### What is an Internal Developer Platform (IDP)?

An IDP is a self-service layer that abstracts infrastructure complexity so developers can
deploy, manage, and observe their applications without needing to understand every
infrastructure detail.

```
┌──────────────────────────────────────────────────────────┐
│                    Developer Experience                    │
│    "I need a database"  →  kubectl apply -f db-claim.yaml │
├──────────────────────────────────────────────────────────┤
│                   Internal Developer Platform              │
│  ┌───────────┐  ┌───────────┐  ┌───────────────────────┐ │
│  │ Crossplane │  │   ArgoCD  │  │   Service Catalog     │ │
│  │  (Infra)   │  │  (GitOps) │  │  (Self-service UI)    │ │
│  └───────────┘  └───────────┘  └───────────────────────┘ │
├──────────────────────────────────────────────────────────┤
│                   Infrastructure Layer                     │
│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌───────────┐  │
│  │  k3s │  │  AWS │  │ Vault│  │Linkerd│  │ Monitoring│  │
│  └──────┘  └──────┘  └──────┘  └──────┘  └───────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Golden Paths

A Golden Path is a pre-built, opinionated template for common tasks. Instead of every team
inventing their own deployment pipeline, you provide a proven path.

```yaml
# golden-paths/new-microservice/template.yaml
# Developers fill in the blanks; the platform handles the rest
apiVersion: platform.devops-lab.io/v1alpha1
kind: Microservice
metadata:
  name: {{ .serviceName }}
  namespace: {{ .team }}
spec:
  # Application
  image: {{ .registry }}/{{ .serviceName }}
  port: 8080
  replicas: 2

  # Infrastructure (auto-provisioned via Crossplane)
  database:
    type: postgresql
    size: small  # Maps to db.t3.micro
  cache:
    type: redis
    size: small

  # Observability (auto-configured)
  monitoring:
    enabled: true
    slo:
      availability: 99.9
      latencyP99Ms: 500

  # Security (auto-configured via Linkerd + Vault)
  mesh:
    enabled: true
    mtls: strict
  secrets:
    vault:
      path: secret/data/{{ .team }}/{{ .serviceName }}

  # Deployment (auto-configured via ArgoCD)
  deployment:
    strategy: canary
    canarySteps: [5, 25, 50, 100]
    analysisInterval: 5m
```

### Self-Service Infrastructure with Crossplane Claims

With Crossplane XRDs from Step 2.5, developers request infrastructure through Kubernetes:

```yaml
# Developer creates this in their namespace:
apiVersion: platform.devops-lab.io/v1alpha1
kind: Database
metadata:
  name: orders-db
  namespace: team-backend
spec:
  parameters:
    engine: postgresql
    size: small
    environment: dev
```

The platform team's Composition handles:
- Creating an RDS instance (or a PostgreSQL pod for dev)
- Configuring security groups
- Creating Vault secrets with credentials
- Injecting credentials via External Secrets Operator

### Platform Maturity Model

| Level | Description | What We Built |
|-------|-------------|---------------|
| **Level 0** | Manual kubectl | Guide 07 |
| **Level 1** | GitOps (ArgoCD/Flux) | Guide 12 / Part 1 |
| **Level 2** | Automated pipelines | Guides 18-20 |
| **Level 3** | Self-service infra (Crossplane) | Part 2 |
| **Level 4** | Full IDP with golden paths | Part 4 |
| **Level 5** | AI-augmented operations | Guide 29 |

Our devops-zero-to-hero project takes you from Level 0 to Level 5.

---

## Verify

### Flux

```bash
# 1. Flux CLI installed
flux --version

# 2. Flux check passes
flux check

# 3. Flux components running
kubectl get pods -n flux-system

# 4. Sources syncing
flux get sources git

# 5. Kustomizations reconciling
flux get kustomizations
```

### Crossplane

```bash
# 1. Crossplane pods running
kubectl get pods -n crossplane-system

# 2. Providers healthy
kubectl get providers

# 3. ProviderConfig exists
kubectl get providerconfig

# 4. XRDs defined
kubectl get xrd

# 5. Compositions available
kubectl get compositions

# 6. Test bucket (if created)
kubectl get bucket
```

### Kaniko

```bash
# 1. Build job completed
kubectl get jobs -n apps | grep kaniko

# 2. Build logs
kubectl logs -n apps job/kaniko-build-api-service

# 3. Image pushed to ECR
aws ecr describe-images \
  --repository-name devops-lab/api-service \
  --query 'imageDetails[*].{Tags:imageTags,Pushed:imagePushedAt}' \
  --output table

# 4. ECR token refresh CronJob
kubectl get cronjob -n apps ecr-token-refresh
```

---

## Troubleshooting

### Flux: Reconciliation Failed

```bash
# Check events
flux events --for Kustomization/apps

# Check source status
flux get source git devops-apps

# Force reconciliation
flux reconcile kustomization apps --with-source

# Check controller logs
kubectl logs -n flux-system deploy/kustomize-controller --tail=50
```

### Crossplane: Resource Stuck in "Syncing"

```bash
# Check managed resource status
kubectl describe bucket devops-lab-crossplane-test

# Look for events
kubectl get events --field-selector reason=CannotCreate

# Check provider logs
kubectl logs -n crossplane-system -l pkg.crossplane.io/revision -c package-runtime --tail=50

# Verify credentials
kubectl get secret aws-creds -n crossplane-system -o yaml | head
```

### Crossplane: Provider Installation Stuck

```bash
# Check provider revision
kubectl get providerrevision

# If stuck in "Unhealthy", check provider pod
kubectl get pods -n crossplane-system -l pkg.crossplane.io/revision

# Check for resource limits
kubectl describe pod -n crossplane-system -l pkg.crossplane.io/revision | grep -A5 "Events"
```

### Kaniko: Build Fails with Auth Error

```bash
# Verify ECR secret exists and is not expired
kubectl get secret ecr-docker-config -n apps -o yaml

# Regenerate the secret
ECR_TOKEN=$(aws ecr get-login-password --region us-east-1)
kubectl delete secret ecr-docker-config -n apps
kubectl create secret docker-registry ecr-docker-config \
  --namespace apps \
  --docker-server=<account-id>.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$ECR_TOKEN
```

### Kaniko: Build OOM Killed

```bash
# Check pod events
kubectl describe job kaniko-build-api-service -n apps | tail -20

# Increase memory limits
# Edit the Job spec: limits.memory: 2Gi

# For large builds, also consider:
# --compressed-caching=false reduces memory at the cost of speed
# --snapshotMode=redo is lighter than the default
```

---

## Checklist

### Flux v2
- [ ] Flux CLI installed
- [ ] Flux bootstrapped with GitHub
- [ ] All Flux controllers running in flux-system namespace
- [ ] GitRepository source created and syncing
- [ ] Kustomization deployed and reconciling
- [ ] HelmRelease deployed (optional)
- [ ] Image automation configured (optional)
- [ ] Understand when to use Flux vs ArgoCD

### Crossplane
- [ ] Crossplane installed in crossplane-system namespace
- [ ] AWS S3 provider installed and healthy
- [ ] ProviderConfig created with AWS credentials
- [ ] S3 bucket created via kubectl apply
- [ ] Bucket verified in AWS console
- [ ] XRD (CompositeResourceDefinition) created
- [ ] Composition created for XRD
- [ ] Claim (ObjectStorage) tested
- [ ] Cleanup: all test resources deleted
- [ ] Understand when to use Crossplane vs Terraform

### Kaniko
- [ ] Kaniko build Job template created
- [ ] ECR authentication secret configured
- [ ] ECR token refresh CronJob running
- [ ] Successful image build and push
- [ ] Build script for triggering builds
- [ ] Understand when to use Kaniko vs Docker builds

### Platform Engineering
- [ ] Understand IDP architecture
- [ ] Golden Path template reviewed
- [ ] Self-service infrastructure concept understood
- [ ] Platform maturity model assessed

---

## What's Next?
Congratulations. You have built a complete DevOps platform from scratch:

- **Infrastructure**: AWS EC2 spot instance with Terraform (~$25-45/mo)
- **Orchestration**: k3s with 35+ tools on 8GB RAM
- **GitOps**: ArgoCD (primary) + Flux v2 (alternative)
- **Security**: Vault, mTLS (Linkerd), RBAC, network policies
- **Observability**: Prometheus, Grafana, Loki, OpenTelemetry
- **Deployment**: Argo Rollouts (canary/blue-green), Kaniko builds
- **Resilience**: LitmusChaos, GameDays
- **Cost**: OpenCost, spot instances, VPA, lifecycle policies
- **AI**: k8sgpt, Bedrock, LangChain agents, LangGraph workflows
- **Platform**: Crossplane for self-service infra, golden paths

You are now equipped to design, build, and operate production-grade infrastructure. The next
step is to take these patterns into real projects and continue iterating.
