# Guide 19: Kyverno Setup — Kubernetes Policy Engine

## Why This Matters

A Kubernetes cluster without policies is like a production database without
constraints — anyone can deploy a container running as root, without resource
limits, pulling `:latest` tags, with no labels. Eventually, something breaks
catastrophically and nobody can trace which team owns the broken pod.

Kyverno (CNCF Incubating) is a policy engine that intercepts every API request
and validates, mutates, or generates resources based on rules you define. It
prevents bad configurations from reaching the cluster at all.

**Why Kyverno over OPA/Gatekeeper:**

| Feature | Kyverno | OPA/Gatekeeper |
|---------|---------|----------------|
| Policy language | Native YAML | Rego (custom language) |
| Learning curve | Low (if you know K8s YAML) | High (new language) |
| Mutation support | Built-in | Limited |
| Generation support | Built-in (auto-create resources) | Not supported |
| Policy reports | Native CRD | Requires additional setup |
| Community | Growing fast, CNCF Incubating | Mature, CNCF Graduated |

For a learning platform with YAML-first workflows, Kyverno is the better fit.

Resource footprint: ~250 MB RAM.

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| k3s cluster running | `kubectl get nodes` |
| Helm 3.12+ | `helm version` |
| ArgoCD installed (Guide 16) | `argocd app list` |

---

## Step 1 — Create the Namespace

```bash
kubectl create namespace kyverno
```

---

## Step 2 — Install Kyverno via Helm

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
```

Create `kyverno/values-k3s.yaml`:

```yaml
# kyverno/values-k3s.yaml

# -- Admission controller (validates/mutates requests)
admissionController:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

# -- Background controller (applies policies to existing resources)
backgroundController:
  replicas: 1
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# -- Cleanup controller (removes expired resources)
cleanupController:
  replicas: 1
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

# -- Reports controller (generates policy reports)
reportsController:
  replicas: 1
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# -- Webhook configuration
config:
  # Exclude system namespaces from policy enforcement
  resourceFilters:
    - "[Event,*,*]"
    - "[*,kube-system,*]"
    - "[*,kube-public,*]"
    - "[*,kube-node-lease,*]"
    - "[*,kyverno,*]"
    - "[*,argocd,*]"          # Don't block ArgoCD operations
    - "[*,cert-manager,*]"
    - "[*,argo-rollouts,*]"

# -- Metrics for Prometheus
features:
  policyReports:
    enabled: true
```

Install:

```bash
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --version 3.3.4 \
  -f kyverno/values-k3s.yaml \
  --wait
```

---

## Step 3 — Understanding Policy Modes

Kyverno policies run in two modes:

| Mode | `validationFailureAction` | Behavior |
|------|---------------------------|----------|
| **Audit** | `Audit` | Logs violations in PolicyReport but allows the resource |
| **Enforce** | `Enforce` | Blocks the API request — resource is rejected |

**Best practice:** Start every policy in Audit mode. Review the PolicyReport for
violations. Fix existing resources. Then switch to Enforce.

---

## Step 4 — Policy 1: Require Resource Limits

Every pod must specify CPU and memory requests/limits. Without this, a single
runaway container can starve the entire node.

```yaml
# kyverno/policies/require-resource-limits.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
  annotations:
    policies.kyverno.io/title: Require Resource Limits
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      All containers must specify CPU and memory requests and limits
      to prevent resource starvation on our t3.large (8GB) node.
spec:
  validationFailureAction: Audit     # Start in Audit, switch to Enforce later
  background: true
  rules:
    - name: check-container-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
                - database
                - monitoring
      validate:
        message: >-
          Container {{request.object.spec.containers[*].name}} in pod
          {{request.object.metadata.name}} must have CPU and memory
          requests and limits defined.
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
                    cpu: "?*"
    # Also check init containers
    - name: check-init-container-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
                - database
      preconditions:
        all:
          - key: "{{ request.object.spec.initContainers[] | length(@) }}"
            operator: GreaterThanOrEquals
            value: 1
      validate:
        message: "Init containers must also have resource limits."
        pattern:
          spec:
            initContainers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
                    cpu: "?*"
```

---

## Step 5 — Policy 2: Disallow Privileged Containers

Privileged containers have unrestricted host access. Block them entirely.

```yaml
# kyverno/policies/disallow-privileged.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow Privileged Containers
    policies.kyverno.io/category: Pod Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Privileged containers can access all host devices and bypass
      security boundaries. This policy blocks them across all
      application namespaces.
spec:
  validationFailureAction: Enforce   # Critical — enforce immediately
  background: true
  rules:
    - name: deny-privileged-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
                - database
      validate:
        message: >-
          Privileged containers are not allowed. Container
          {{request.object.spec.containers[*].name}} in namespace
          {{request.object.metadata.namespace}} sets privileged=true.
        pattern:
          spec:
            containers:
              - securityContext:
                  privileged: "!true"
    - name: deny-privileged-init-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
                - database
      preconditions:
        all:
          - key: "{{ request.object.spec.initContainers[] | length(@) }}"
            operator: GreaterThanOrEquals
            value: 1
      validate:
        message: "Init containers cannot run as privileged."
        pattern:
          spec:
            initContainers:
              - securityContext:
                  privileged: "!true"
    - name: deny-host-namespaces
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
                - database
      validate:
        message: "Host namespaces (hostNetwork, hostPID, hostIPC) are not allowed."
        pattern:
          spec:
            =(hostNetwork): false
            =(hostPID): false
            =(hostIPC): false
```

---

## Step 6 — Policy 3: Block Latest Tag

The `:latest` tag is mutable — it points to whatever was pushed most recently.
Using it in production means you cannot reproduce a deployment or audit what
version is running.

```yaml
# kyverno/policies/block-latest-tag.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-latest-tag
  annotations:
    policies.kyverno.io/title: Block Latest Image Tag
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Images must use explicit version tags or SHA digests.
      The :latest tag is mutable and breaks reproducibility.
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: block-latest-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
                - database
      validate:
        message: >-
          Image '{{request.object.spec.containers[*].image}}' uses
          the :latest tag or no tag at all. Use an explicit version
          tag (e.g., :1.2.3) or a SHA digest.
        pattern:
          spec:
            containers:
              - image: "!*:latest & *:*"
    - name: block-latest-init-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
      preconditions:
        all:
          - key: "{{ request.object.spec.initContainers[] | length(@) }}"
            operator: GreaterThanOrEquals
            value: 1
      validate:
        message: "Init container images cannot use :latest tag."
        pattern:
          spec:
            initContainers:
              - image: "!*:latest & *:*"
```

---

## Step 7 — Policy 4: Require Labels

Labels are how we identify ownership, enable monitoring selectors, and filter in
dashboards. Every pod must have `app`, `version`, and `team` labels.

```yaml
# kyverno/policies/require-labels.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  annotations:
    policies.kyverno.io/title: Require Standard Labels
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Pod, Deployment
    policies.kyverno.io/description: >-
      All workloads in application namespaces must have app, version,
      and team labels for observability and ownership tracking.
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: require-app-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - DaemonSet
              namespaces:
                - apps
                - database
          - resources:
              kinds:
                - Rollout
              namespaces:
                - apps
      validate:
        message: >-
          The label 'app' is required on {{request.object.kind}}
          {{request.object.metadata.name}}.
        pattern:
          metadata:
            labels:
              app: "?*"
          spec:
            template:
              metadata:
                labels:
                  app: "?*"
    - name: require-version-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - Rollout
              namespaces:
                - apps
      validate:
        message: >-
          The label 'version' is required on pod template of
          {{request.object.kind}} {{request.object.metadata.name}}.
        pattern:
          spec:
            template:
              metadata:
                labels:
                  version: "?*"
    - name: require-team-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - Rollout
              namespaces:
                - apps
      validate:
        message: >-
          The label 'team' is required on pod template of
          {{request.object.kind}} {{request.object.metadata.name}}.
        pattern:
          spec:
            template:
              metadata:
                labels:
                  team: "?*"
```

---

## Step 8 — Policy 5: Require Signed Images (Cosign Verification)

This policy verifies that container images are signed with Cosign before they
can run in the cluster. Only images signed by your CI pipeline's key are
admitted.

```yaml
# kyverno/policies/require-signed-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
  annotations:
    policies.kyverno.io/title: Require Cosign Image Signatures
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Container images from our registry must be signed with Cosign.
      This ensures only images built by our CI pipeline can run.
spec:
  validationFailureAction: Audit     # Switch to Enforce after signing pipeline is ready
  background: true
  webhookTimeoutSeconds: 30          # Signature verification can take time
  rules:
    - name: verify-image-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
      verifyImages:
        - imageReferences:
            - "ghcr.io/<you>/*"      # Only verify images from our registry
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...your-cosign-public-key...
                      -----END PUBLIC KEY-----
          # Mutate the image reference to use the digest (immutable)
          mutateDigest: true
          # Verify attestations (SBOM, vulnerability scan results)
          required: true
```

To generate a Cosign key pair for your CI pipeline:

```bash
# Generate a key pair (do this once, store the private key in Vault)
cosign generate-key-pair

# Sign an image in CI
cosign sign --key cosign.key ghcr.io/<you>/api-gateway:1.0.0

# Verify locally
cosign verify --key cosign.pub ghcr.io/<you>/api-gateway:1.0.0
```

---

## Step 9 — Apply All Policies

```bash
kubectl apply -f kyverno/policies/
```

Or manage them through ArgoCD (recommended):

```yaml
# argocd/apps/kyverno-policies.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno-policies
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/devops-zero-to-hero.git
    targetRevision: main
    path: kyverno/policies
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Step 10 — View Policy Reports

Kyverno creates PolicyReport and ClusterPolicyReport resources that show which
resources pass or fail each policy.

### List all violations

```bash
# Cluster-wide report
kubectl get clusterpolicyreport -o wide

# Namespace-specific report
kubectl get policyreport -n apps -o wide
```

### Detailed violation output

```bash
kubectl get policyreport -n apps -o jsonpath='{range .items[*].results[?(@.result=="fail")]}{.policy}: {.message}{"\n"}{end}'
```

### Example output

```
require-resource-limits: Container nginx in pod test-pod must have CPU and memory requests and limits defined.
block-latest-tag: Image 'nginx:latest' uses the :latest tag or no tag at all.
require-labels: The label 'team' is required on pod template of Deployment test-deploy.
```

---

## Step 11 — Transition from Audit to Enforce

After fixing all violations reported in Audit mode, switch policies to Enforce:

```bash
# Check current violations — fix all of these first
kubectl get policyreport -A -o jsonpath='{range .items[*].results[?(@.result=="fail")]}{.policy}: {.resources[0].name} - {.message}{"\n"}{end}'

# When violations are zero, update the policy
kubectl patch clusterpolicy require-resource-limits \
  --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

Recommended enforcement order:

1. **disallow-privileged** — enforce immediately (critical security)
2. **require-resource-limits** — enforce after all Helm charts have resources
3. **block-latest-tag** — enforce after all images use version tags
4. **require-labels** — enforce after Helm templates include all labels
5. **require-signed-images** — enforce after CI signing pipeline is operational

---

## Step 12 — Bonus: Mutation Policy (Auto-Add Labels)

Kyverno can automatically add missing labels rather than just blocking:

```yaml
# kyverno/policies/mutate-add-defaults.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-labels
  annotations:
    policies.kyverno.io/title: Add Default Labels
    policies.kyverno.io/category: Best Practices
spec:
  rules:
    - name: add-managed-by-label
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - Rollout
              namespaces:
                - apps
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              +(managed-by): argocd
          spec:
            template:
              metadata:
                labels:
                  +(managed-by): argocd
    - name: add-security-context-defaults
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                securityContext:
                  +(runAsNonRoot): true
                  +(readOnlyRootFilesystem): true
                  +(allowPrivilegeEscalation): false
```

---

## Verify

### Check Kyverno pods are healthy

```bash
kubectl get pods -n kyverno
# Expected:
# kyverno-admission-controller-xxx       1/1  Running
# kyverno-background-controller-xxx      1/1  Running
# kyverno-cleanup-controller-xxx         1/1  Running
# kyverno-reports-controller-xxx         1/1  Running
```

### List all cluster policies

```bash
kubectl get clusterpolicy
# NAME                      ADMISSION   BACKGROUND   VALIDATE ACTION   READY
# require-resource-limits   true        true         Audit             true
# disallow-privileged       true        true         Enforce           true
# block-latest-tag          true        true         Audit             true
# require-labels            true        true         Audit             true
# require-signed-images     true        true         Audit             true
```

### Test policy enforcement

```bash
# This should be BLOCKED by disallow-privileged:
kubectl run test-priv --image=nginx --restart=Never -n apps \
  --overrides='{"spec":{"containers":[{"name":"test","image":"nginx","securityContext":{"privileged":true}}]}}'
# Expected: Error from server: admission webhook denied the request

# This should PASS:
kubectl run test-ok --image=nginx:1.25 --restart=Never -n apps \
  --overrides='{"spec":{"containers":[{"name":"test","image":"nginx:1.25","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'
# Expected: pod/test-ok created

# Clean up
kubectl delete pod test-ok -n apps
```

### Check policy reports for violations

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
```

### Check RAM usage

```bash
kubectl top pods -n kyverno
# Total should be ~200-250MB
```

---

## Troubleshooting

### Webhook timeout causing pod creation failures

```bash
# Check webhook health
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl get mutatingwebhookconfigurations | grep kyverno

# If webhooks are failing, check controller logs
kubectl logs -n kyverno deploy/kyverno-admission-controller --tail=50

# Emergency: temporarily disable validation (use with caution)
kubectl annotate validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  webhooks.failurePolicy=Ignore --overwrite
```

### Policy not applying to existing resources

Background scan may take a few minutes. Force it:

```bash
# Trigger a background scan
kubectl annotate clusterpolicy require-resource-limits \
  policies.kyverno.io/rescan=true --overwrite
```

### ArgoCD sync blocked by Kyverno

If Kyverno blocks ArgoCD from deploying a resource, check the ArgoCD sync
error message — it will contain the Kyverno denial reason. Either fix the
manifest or add the argocd namespace to `resourceFilters` in the Kyverno
values.

### Policy report shows "error" status

```bash
# Get detailed error
kubectl describe policyreport -n apps

# Usually means the policy has a syntax error
kubectl get clusterpolicy require-resource-limits -o yaml
```

### Kyverno consuming too much memory

Reduce background scan frequency:

```yaml
# In kyverno/values-k3s.yaml
config:
  backgroundScan:
    interval: 2h     # Default is 1h
```

---

## Checklist

- [ ] kyverno namespace created
- [ ] Kyverno Helm chart installed with k3s-tuned values
- [ ] System namespaces excluded from policy enforcement
- [ ] Policy 1: require-resource-limits (Audit mode)
- [ ] Policy 2: disallow-privileged (Enforce mode)
- [ ] Policy 3: block-latest-tag (Audit mode)
- [ ] Policy 4: require-labels (Audit mode)
- [ ] Policy 5: require-signed-images (Audit mode)
- [ ] Policies managed via ArgoCD
- [ ] PolicyReports reviewed for existing violations
- [ ] Enforcement tested (privileged pod blocked)
- [ ] Mutation policy for default labels (optional)
- [ ] Total RAM usage verified under 250MB

---

## What's Next?

With policies guarding the cluster against misconfigurations, the final
infrastructure piece is **Guide 20: Observability Setup** — deploying
Prometheus, Grafana, Loki, and OpenTelemetry Collector so you can see metrics,
logs, and traces across every microservice.
