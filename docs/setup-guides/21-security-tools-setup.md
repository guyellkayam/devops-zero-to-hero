# 21 — Security Tools Setup

## Why This Matters

Running containers in production without security tooling is like leaving your front door open.
You need multiple layers of defense:

| Layer | Tool | What It Does |
|-------|------|-------------|
| **Image Scanning** | Trivy Operator | Continuously scans every image in your cluster for CVEs |
| **Runtime Detection** | Falco | Detects suspicious behavior inside running containers |
| **Supply Chain** | Cosign + Kyverno | Signs images in CI, blocks unsigned images at admission |
| **Network** | Network Policies | Default-deny traffic between namespaces |
| **Pod Hardening** | Pod Security Admission | Prevents privileged containers, host mounts, etc. |

Together these give you defense-in-depth: even if one layer fails, the others catch threats.

Trivy Operator was created by Aqua Security (Israeli company, CNCF project). Falco is a CNCF
graduated project -- the standard for runtime security in Kubernetes.

---

## Prerequisites

- k3s cluster running (guide 03+)
- Helm installed locally
- kubectl access to your cluster
- cert-manager installed (guide 09)
- Kyverno installed (guide 15) -- for policy enforcement
- ~400MB total RAM for all security tools

---

## Step 1: Install Trivy Operator

Trivy Operator runs inside your cluster and automatically scans every container image.
It creates `VulnerabilityReport` CRDs you can query with kubectl.

### Add the Aqua Security Helm repo:

```bash
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm repo update
```

### Create namespace and install:

```bash
kubectl create namespace trivy-system

helm install trivy-operator aqua/trivy-operator \
  --namespace trivy-system \
  --version 0.24.1 \
  --set trivy.ignoreUnfixed=true \
  --set operator.scanJobTimeout=5m \
  --set operator.scannerReportTTL=24h \
  --set operator.vulnerabilityScannerEnabled=true \
  --set operator.configAuditScannerEnabled=true \
  --set operator.rbacAssessmentScannerEnabled=true \
  --set operator.infraAssessmentScannerEnabled=false \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=256Mi
```

**Key settings explained:**
- `ignoreUnfixed=true` -- Skips CVEs that have no patch available (reduces noise)
- `scanJobTimeout=5m` -- Prevents scan jobs from hanging on large images
- `configAuditScannerEnabled=true` -- Also checks misconfigurations (privileged pods, etc.)
- `rbacAssessmentScannerEnabled=true` -- Flags overly permissive RBAC

### Create a scan policy to enforce severity thresholds:

Save as `trivy-scan-policy.yaml`:

```yaml
# trivy-scan-policy.yaml
# This ConfigMap configures which severities Trivy reports on.
# Combined with Kyverno policies, you can block deployments with CRITICAL CVEs.
apiVersion: v1
kind: ConfigMap
metadata:
  name: trivy-operator-trivy-config
  namespace: trivy-system
data:
  # Only report CRITICAL and HIGH (ignore MEDIUM/LOW/UNKNOWN)
  trivy.severity: "CRITICAL,HIGH"
  # Skip scanning dev/test images under 30 days old
  trivy.skipDirs: "/tmp,/var/cache"
  # Use the GitHub Advisory Database in addition to NVD
  trivy.additionalVulnerabilitySources: "glad"
```

```bash
kubectl apply -f trivy-scan-policy.yaml
```

### Query vulnerability reports:

```bash
# List all vulnerability reports
kubectl get vulnerabilityreports -A

# Get detailed report for a specific workload
kubectl get vulnerabilityreports -n apps -o json | \
  jq '.items[] | {
    name: .metadata.name,
    image: .report.artifact.repository,
    critical: .report.summary.criticalCount,
    high: .report.summary.highCount
  }'

# Find all images with CRITICAL vulnerabilities
kubectl get vulnerabilityreports -A -o json | \
  jq '.items[] | select(.report.summary.criticalCount > 0) | {
    namespace: .metadata.namespace,
    image: .report.artifact.repository,
    tag: .report.artifact.tag,
    critical: .report.summary.criticalCount
  }'
```

---

## Step 2: Install Falco for Runtime Security

Falco monitors system calls and detects suspicious runtime behavior:
shell exec in containers, sensitive file access, unexpected network connections.

### Install Falco with Helm:

```bash
kubectl create namespace falco

helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --version 4.11.0 \
  --set driver.kind=modern_ebpf \
  --set falcosidekick.enabled=true \
  --set falcosidekick.config.slack.webhookurl="" \
  --set collectors.containerd.enabled=true \
  --set collectors.containerd.socket=/run/k3s/containerd/containerd.sock \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi \
  --set resources.limits.memory=512Mi \
  --set-string 'falco.rules_files[0]=/etc/falco/falco_rules.yaml' \
  --set-string 'falco.rules_files[1]=/etc/falco/falco_rules.local.yaml' \
  --set-string 'falco.rules_files[2]=/etc/falco/rules.d'
```

**Note on k3s**: The containerd socket path for k3s is `/run/k3s/containerd/containerd.sock`,
not the default `/run/containerd/containerd.sock`. The `driver.kind=modern_ebpf` uses the
modern eBPF driver which works without kernel headers.

### Create custom rules for our microservices:

Save as `falco-custom-rules.yaml`:

```yaml
# falco-custom-rules.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-custom-rules
  namespace: falco
data:
  custom-rules.yaml: |
    # ============================================
    # Custom Falco Rules for devops-zero-to-hero
    # ============================================

    # Rule 1: Detect shell spawned in any application container
    - rule: Shell Spawned in App Container
      desc: >
        Detect when a shell (bash, sh, zsh) is spawned inside an application
        container. This should never happen in production.
      condition: >
        spawned_process
        and container
        and proc.name in (bash, sh, zsh, csh, ksh, dash)
        and k8s.ns.name in (apps, staging, production)
      output: >
        ALERT: Shell spawned in application container
        (user=%user.name command=%proc.cmdline container=%container.name
        namespace=%k8s.ns.name pod=%k8s.pod.name image=%container.image.repository)
      priority: WARNING
      tags: [shell, mitre_execution]

    # Rule 2: Detect reading sensitive files
    - rule: Sensitive File Read in App Container
      desc: >
        Detect attempts to read sensitive files like /etc/shadow or
        service account tokens from application containers.
      condition: >
        open_read
        and container
        and k8s.ns.name in (apps, staging, production)
        and (fd.name startswith /etc/shadow
             or fd.name startswith /etc/passwd
             or fd.name startswith /var/run/secrets/kubernetes.io)
      output: >
        ALERT: Sensitive file read in app container
        (user=%user.name file=%fd.name container=%container.name
        namespace=%k8s.ns.name pod=%k8s.pod.name)
      priority: ERROR
      tags: [filesystem, mitre_credential_access]

    # Rule 3: Detect unexpected outbound connections from api-gateway
    - rule: Unexpected Outbound Connection from API Gateway
      desc: >
        api-gateway should only connect to user-service and order-service.
        Flag any connection to external IPs.
      condition: >
        outbound
        and container
        and k8s.ns.name = "apps"
        and container.image.repository contains "api-gateway"
        and not (fd.sip in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
      output: >
        ALERT: api-gateway connecting to unexpected external IP
        (ip=%fd.sip port=%fd.sport container=%container.name pod=%k8s.pod.name)
      priority: WARNING
      tags: [network, mitre_exfiltration]

    # Rule 4: Detect package manager usage in running containers
    - rule: Package Manager in Container
      desc: >
        Detect npm install, pip install, apt-get, or apk add inside
        running containers. Packages should only be installed at build time.
      condition: >
        spawned_process
        and container
        and proc.name in (npm, pip, pip3, apt, apt-get, apk, yum, dnf)
      output: >
        ALERT: Package manager used in running container
        (command=%proc.cmdline container=%container.name
        namespace=%k8s.ns.name pod=%k8s.pod.name)
      priority: WARNING
      tags: [software_mgmt, mitre_execution]

    # Rule 5: Detect crypto mining indicators
    - rule: Crypto Mining Detected
      desc: Detect processes commonly associated with cryptocurrency mining.
      condition: >
        spawned_process
        and container
        and (proc.name in (xmrig, minerd, minergate, ccminer)
             or proc.cmdline contains "stratum+tcp"
             or proc.cmdline contains "pool.minexmr")
      output: >
        CRITICAL: Potential crypto mining detected
        (command=%proc.cmdline container=%container.name
        namespace=%k8s.ns.name pod=%k8s.pod.name image=%container.image.repository)
      priority: CRITICAL
      tags: [crypto, mitre_execution]
```

```bash
kubectl apply -f falco-custom-rules.yaml

# Restart Falco to pick up custom rules
kubectl rollout restart daemonset/falco -n falco
```

### View Falco alerts:

```bash
# Follow Falco logs for real-time alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f --tail=50

# Test: exec into a pod to trigger the shell rule
kubectl exec -it deploy/api-gateway -n apps -- /bin/sh
# You should see a WARNING in Falco logs within seconds
```

---

## Step 3: Set Up Cosign Keyless Image Signing

Cosign (by Sigstore) provides keyless image signing -- no private keys to manage.
It uses OIDC identity from GitHub Actions to sign images.

### Install Cosign locally (already in guide 02):

```bash
# Verify cosign is installed
cosign version

# If not:
brew install cosign
```

### Sign an image manually (for testing):

```bash
# This opens a browser for OIDC login
cosign sign <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway:v1.0.0

# Verify the signature
cosign verify <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway:v1.0.0 \
  --certificate-identity-regexp="https://github.com/guyellkayam/devops-zero-to-hero" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

### Keyless signing in GitHub Actions (automated):

This is the snippet used in CI/CD (full workflow in Guide 24):

```yaml
# In your GitHub Actions workflow:
- name: Sign image with Cosign (keyless)
  env:
    COSIGN_EXPERIMENTAL: "1"
  run: |
    cosign sign --yes \
      ${{ env.ECR_REGISTRY }}/${{ env.ECR_REPOSITORY }}@${{ steps.build.outputs.digest }}
```

GitHub Actions automatically provides the OIDC token. No keys needed.

### Create Kyverno policy to require signed images:

Save as `kyverno-require-signed-images.yaml`:

```yaml
# kyverno-require-signed-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
  annotations:
    policies.kyverno.io/title: Require Signed Container Images
    policies.kyverno.io/description: >
      Ensures all container images deployed to production namespaces
      are signed with Cosign using keyless signing from our GitHub Actions.
spec:
  validationFailureAction: Enforce  # Block unsigned images
  background: true
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - apps
                - staging
                - production
      verifyImages:
        - imageReferences:
            - "<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/guyellkayam/devops-zero-to-hero/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
          mutateDigest: true    # Replace tags with digests
          verifyDigest: true    # Ensure digest matches
          required: true        # Fail if no signature found

    # Allow system images (not from our ECR) without signatures
    - name: skip-system-images
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kube-system
                - trivy-system
                - falco
                - argocd
      verifyImages:
        - imageReferences:
            - "*"
          required: false
```

```bash
kubectl apply -f kyverno-require-signed-images.yaml

# Test: try to deploy an unsigned image to apps namespace
kubectl run test-unsigned --image=nginx:latest -n apps
# Should be BLOCKED by Kyverno

# Clean up
kubectl delete pod test-unsigned -n apps --ignore-not-found
```

---

## Step 4: Network Policies (Default-Deny + Allow Rules)

k3s ships with kube-router or Flannel CNI. For NetworkPolicy support with Flannel,
k3s uses kube-router for policy enforcement by default.

### Default-deny all traffic in the apps namespace:

Save as `network-policies.yaml`:

```yaml
# network-policies.yaml

# 1. Default deny ALL ingress and egress in apps namespace
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: apps
spec:
  podSelector: {}    # Matches ALL pods in namespace
  policyTypes:
    - Ingress
    - Egress

# 2. Allow DNS resolution (required for service discovery)
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: apps
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53

# 3. api-gateway: allow ingress from ingress controller, egress to user-service and order-service
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-gateway
  namespace: apps
spec:
  podSelector:
    matchLabels:
      app: api-gateway
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # From ingress controller (traefik in k3s)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
      ports:
        - protocol: TCP
          port: 3000
  egress:
    # To user-service
    - to:
        - podSelector:
            matchLabels:
              app: user-service
      ports:
        - protocol: TCP
          port: 8000
    # To order-service
    - to:
        - podSelector:
            matchLabels:
              app: order-service
      ports:
        - protocol: TCP
          port: 3001

# 4. user-service: allow ingress from api-gateway only
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-user-service
  namespace: apps
spec:
  podSelector:
    matchLabels:
      app: user-service
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api-gateway
      ports:
        - protocol: TCP
          port: 8000
  egress:
    # To database (if running in-cluster)
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432

# 5. order-service: allow ingress from api-gateway only
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-order-service
  namespace: apps
spec:
  podSelector:
    matchLabels:
      app: order-service
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api-gateway
      ports:
        - protocol: TCP
          port: 3001
  egress:
    # To database (if running in-cluster)
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432

# 6. Allow Prometheus scraping from monitoring namespace
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: apps
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9090
        - protocol: TCP
          port: 3000
        - protocol: TCP
          port: 8000
        - protocol: TCP
          port: 3001
```

```bash
# Label the namespace (required for namespaceSelector)
kubectl label namespace apps kubernetes.io/metadata.name=apps --overwrite
kubectl label namespace kube-system kubernetes.io/metadata.name=kube-system --overwrite
kubectl label namespace monitoring kubernetes.io/metadata.name=monitoring --overwrite

kubectl apply -f network-policies.yaml

# Verify policies are active
kubectl get networkpolicies -n apps
```

### Test network isolation:

```bash
# From api-gateway, you SHOULD be able to reach user-service
kubectl exec deploy/api-gateway -n apps -- wget -qO- http://user-service:8000/health

# From a random pod, you should NOT be able to reach user-service
kubectl run test-netpol --rm -it --image=busybox -n apps -- wget -qO- --timeout=3 http://user-service:8000/health
# Expected: connection timeout (blocked by NetworkPolicy)
```

---

## Step 5: Pod Security Admission (PSA)

Pod Security Admission is built into Kubernetes (no extra install). It enforces
security standards at the namespace level.

There are three profiles:
- **privileged** -- No restrictions (for system namespaces)
- **baseline** -- Prevents known privilege escalations
- **restricted** -- Heavily hardened (our target for app workloads)

### Apply PSA labels to namespaces:

```bash
# apps namespace: enforce restricted (block non-compliant pods)
kubectl label namespace apps \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

# staging namespace: enforce restricted
kubectl label namespace staging \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

# monitoring namespace: enforce baseline (some tools need more permissions)
kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

# System namespaces: privileged (they need it)
kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite

kubectl label namespace falco \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite
```

### Make your pods comply with the restricted profile:

Your pod specs must include these settings to pass the `restricted` profile:

```yaml
# Required securityContext for restricted PSA profile
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: api-gateway
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        capabilities:
          drop:
            - ALL
      # If your app writes to /tmp, mount an emptyDir
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

### Test PSA enforcement:

```bash
# This should FAIL in apps namespace (running as root)
kubectl run test-psa --image=nginx:latest -n apps
# Error: would violate PodSecurity "restricted:latest"

# This should SUCCEED (proper security context)
kubectl apply -n apps -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-psa-compliant
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test
      image: busybox:latest
      command: ["sleep", "10"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF

# Clean up
kubectl delete pod test-psa-compliant -n apps --ignore-not-found
```

---

## Verify

### Trivy Operator:

```bash
# Check operator is running
kubectl get pods -n trivy-system
# NAME                              READY   STATUS    RESTARTS   AGE
# trivy-operator-xxx                1/1     Running   0          5m

# Check vulnerability reports are being generated (may take a few minutes)
kubectl get vulnerabilityreports -A --no-headers | wc -l
# Should be > 0 after a few minutes

# Check for critical vulnerabilities
kubectl get vulnerabilityreports -A -o json | \
  jq '[.items[] | select(.report.summary.criticalCount > 0)] | length'
```

### Falco:

```bash
# Check Falco daemonset is running on all nodes
kubectl get pods -n falco -o wide
# Should show one pod per node

# Trigger a test alert
kubectl exec deploy/api-gateway -n apps -- ls /etc/shadow 2>/dev/null

# Check Falco detected it
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=10 | grep -i "sensitive"
```

### Cosign + Kyverno:

```bash
# Try deploying an unsigned image -- should be blocked
kubectl run test-unsigned --image=nginx:latest -n apps 2>&1
# Expected: admission webhook denied the request

# Verify a signed image passes (use your actual signed image)
# cosign verify <your-signed-image> --certificate-identity-regexp=...
```

### Network Policies:

```bash
kubectl get networkpolicies -n apps
# NAME                  POD-SELECTOR      AGE
# default-deny-all      <none>            5m
# allow-dns             <none>            5m
# allow-api-gateway     app=api-gateway   5m
# allow-user-service    app=user-service  5m
# allow-order-service   app=order-service 5m
# allow-prometheus-scrape <none>          5m
```

### Pod Security Admission:

```bash
# Check namespace labels
kubectl get ns apps -o jsonpath='{.metadata.labels}' | jq .
# Should show pod-security.kubernetes.io/enforce=restricted
```

---

## Troubleshooting

### Trivy scan jobs stuck in Pending

```bash
# Check if scan jobs have resource issues
kubectl get jobs -n trivy-system
kubectl describe job <job-name> -n trivy-system

# Common fix: increase scan job timeout or memory
helm upgrade trivy-operator aqua/trivy-operator \
  --namespace trivy-system \
  --set operator.scanJobTimeout=10m \
  --reuse-values
```

### Falco not detecting events on k3s

```bash
# Verify the containerd socket path
ls -la /run/k3s/containerd/containerd.sock

# Check Falco driver loaded
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "driver"

# If modern_ebpf fails, try the older approach
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --set driver.kind=ebpf \
  --reuse-values
```

### Network Policies blocking legitimate traffic

```bash
# Temporarily check what's blocked by switching to audit-only
kubectl annotate networkpolicy default-deny-all -n apps \
  description="temporarily debugging" --overwrite

# Check pod labels match your selectors
kubectl get pods -n apps --show-labels

# Trace network issues
kubectl exec deploy/api-gateway -n apps -- wget -qO- --timeout=5 http://user-service:8000/health
```

### Pod rejected by PSA

```bash
# Get detailed rejection reason
kubectl describe pod <pod-name> -n apps

# Common issue: missing securityContext
# Add these to your Deployment/Pod spec:
# securityContext.runAsNonRoot: true
# securityContext.seccompProfile.type: RuntimeDefault
# containers[].securityContext.allowPrivilegeEscalation: false
# containers[].securityContext.capabilities.drop: ["ALL"]
```

### Cosign verification fails

```bash
# Check the certificate identity and issuer
cosign verify <image> \
  --certificate-identity-regexp="https://github.com/guyellkayam/*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  2>&1

# Common issue: image was signed with different identity
# Fix: ensure your GitHub Actions workflow uses the correct repository
```

---

## Checklist

- [ ] Trivy Operator installed and scanning images
- [ ] VulnerabilityReport CRDs are being populated
- [ ] Falco installed with k3s containerd socket
- [ ] Custom Falco rules deployed for our microservices
- [ ] Shell-in-container alert tested and working
- [ ] Cosign keyless signing tested locally
- [ ] Kyverno policy blocks unsigned images in apps namespace
- [ ] Default-deny NetworkPolicy applied to apps namespace
- [ ] Per-service allow rules permit only expected traffic
- [ ] DNS egress allowed for service discovery
- [ ] Prometheus scraping allowed from monitoring namespace
- [ ] PSA `restricted` profile enforced on apps and staging namespaces
- [ ] PSA `baseline` profile enforced on monitoring namespace
- [ ] Application pods comply with restricted security context
- [ ] Test: privileged pod rejected in apps namespace

---

## What's Next?

With security tooling in place, you have:
- **Preventive controls**: Kyverno blocks unsigned/vulnerable images, PSA blocks privileged pods
- **Detective controls**: Trivy finds CVEs, Falco detects runtime threats
- **Network segmentation**: Only expected traffic flows between services

Next up: **Guide 22 -- Backup & Disaster Recovery with Velero** to ensure you can recover
from failures, and **Guide 24 -- GitHub Actions** to integrate Cosign and Trivy into your CI/CD pipeline.
