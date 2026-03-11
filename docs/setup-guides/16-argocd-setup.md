# Guide 16: ArgoCD Setup — GitOps Continuous Delivery

## Why This Matters

ArgoCD is the CNCF-graduated GitOps engine that watches your Git repository and
automatically reconciles cluster state to match declared manifests. Without
ArgoCD you would `kubectl apply` by hand, drift would go unnoticed, and rollbacks
would be painful. With it, every change goes through Git (pull request, review,
merge) and the cluster converges within seconds.

Key benefits for our platform:

- **Single source of truth** — Git commit history IS the deployment history.
- **Drift detection** — ArgoCD alerts when someone changes something via kubectl.
- **Self-healing** — unauthorized manual changes are reverted automatically.
- **App-of-Apps** — one root application manages all child apps declaratively.
- **Sync waves** — control deployment ordering (namespaces before secrets before
  databases before microservices).

Resource footprint: ~400 MB RAM on our t3.large.

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| k3s cluster running | `kubectl get nodes` shows Ready |
| Helm 3.12+ | `helm version` |
| kubectl configured | `kubectl cluster-info` |
| GitHub repo cloned | Your `devops-zero-to-hero` repo is available locally |
| cert-manager running (Guide 14) | `kubectl get pods -n cert-manager` |

---

## Step 1 — Create the ArgoCD Namespace

```bash
kubectl create namespace argocd
kubectl label namespace argocd app.kubernetes.io/managed-by=argocd
```

---

## Step 2 — Install ArgoCD via Helm

Add the Argo Helm repo and create a values file tuned for k3s:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

Create `argocd/values-k3s.yaml`:

```yaml
# argocd/values-k3s.yaml
global:
  domain: argocd.dev.localhost   # change to your domain

configs:
  params:
    # Run insecure behind Envoy Gateway TLS termination
    server.insecure: true
  cm:
    # Enable status badge on repos
    statusbadge.enabled: "true"
    # Kustomize build options
    kustomize.buildOptions: "--enable-helm"
    # Resource tracking method — label is lighter than annotation
    application.resourceTrackingMethod: label
    # Timeout for Git operations
    timeout.reconciliation: 180s
  rbac:
    policy.default: role:readonly
    policy.csv: |
      # Admin role — full access
      p, role:admin, applications, *, */*, allow
      p, role:admin, clusters, *, *, allow
      p, role:admin, repositories, *, *, allow
      p, role:admin, logs, *, *, allow
      p, role:admin, exec, *, */*, allow

      # Developer role — sync and view only
      p, role:developer, applications, get, */*, allow
      p, role:developer, applications, sync, */*, allow
      p, role:developer, logs, get, */*, allow

      # Bind groups to roles
      g, admin-team, role:admin
      g, dev-team, role:developer

# -- Server component
server:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

# -- Repo server (clones Git repos, renders manifests)
repoServer:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

# -- Application controller (reconciles desired vs live state)
controller:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: "1"
      memory: 512Mi

# -- Redis (caching layer)
redis:
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 200m
      memory: 64Mi

# -- Notifications controller (optional, Slack/webhook alerts)
notifications:
  enabled: true
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

# -- ApplicationSet controller (generates apps from templates)
applicationSet:
  enabled: true
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

Install:

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.7.5 \
  -f argocd/values-k3s.yaml \
  --wait
```

---

## Step 3 — Retrieve the Admin Password

ArgoCD generates a random admin password stored in a Secret:

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo   # newline for readability
```

Save this password — you will need it for the UI and CLI.

---

## Step 4 — Access the ArgoCD UI

Port-forward to reach the dashboard:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

Open `https://localhost:8080` in your browser (accept the self-signed cert).
Login with username `admin` and the password from Step 3.

Install the ArgoCD CLI for terminal management:

```bash
# macOS
brew install argocd

# Linux
curl -sSL -o argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/

# Login via CLI
argocd login localhost:8080 --insecure --username admin --password '<password>'
```

---

## Step 5 — Connect Your GitHub Repository

Create a repository credential so ArgoCD can pull manifests:

```bash
# Option A: HTTPS with personal access token
argocd repo add https://github.com/<you>/devops-zero-to-hero.git \
  --username git \
  --password <GITHUB_PAT> \
  --name devops-zero-to-hero

# Option B: SSH key (recommended for automation)
argocd repo add git@github.com:<you>/devops-zero-to-hero.git \
  --ssh-private-key-path ~/.ssh/id_ed25519 \
  --name devops-zero-to-hero
```

Or declare it as a Kubernetes Secret for full GitOps:

```yaml
# argocd/repo-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: devops-zero-to-hero-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/<you>/devops-zero-to-hero.git
  username: git
  password: <GITHUB_PAT>   # use ExternalSecret in production
```

```bash
kubectl apply -f argocd/repo-secret.yaml
```

---

## Step 6 — App-of-Apps Pattern (Root Application)

The App-of-Apps pattern uses a single "root" Application that points at a
directory of Application manifests. When you add a new YAML file to that
directory, ArgoCD automatically creates the child app.

Create the directory structure in your repo:

```
argocd/
  root-app.yaml
  apps/
    namespaces.yaml
    external-secrets.yaml
    postgres.yaml
    redis.yaml
    api-gateway.yaml
    user-service.yaml
    order-service.yaml
    envoy-gateway.yaml
    monitoring.yaml
    kyverno.yaml
```

### Root Application

```yaml
# argocd/root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/devops-zero-to-hero.git
    targetRevision: main
    path: argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

Apply the root app once — everything else is managed through Git:

```bash
kubectl apply -f argocd/root-app.yaml
```

---

## Step 7 — Sync Waves for Dependency Ordering

ArgoCD processes resources by sync wave number (lowest first). Use annotations
to guarantee ordering:

| Wave | Resources | Why |
|------|-----------|-----|
| 0 | Namespaces | Must exist before anything is deployed into them |
| 1 | RBAC, ServiceAccounts | Needed by workloads |
| 2 | ExternalSecrets, ConfigMaps | Secrets must be available before pods start |
| 3 | Databases (Postgres, Redis) | Services depend on data stores |
| 4 | Microservices (api-gateway, user-service, order-service) | Core workloads |
| 5 | Ingress / Gateway routes | Expose services after they are healthy |
| 6 | Monitoring, Alerts | Observe everything above |

### Example: Namespaces App (Wave 0)

```yaml
# argocd/apps/namespaces.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: namespaces
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/devops-zero-to-hero.git
    targetRevision: main
    path: manifests/namespaces
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Example: Postgres App (Wave 3)

```yaml
# argocd/apps/postgres.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/devops-zero-to-hero.git
    targetRevision: main
    path: helm/postgres
    helm:
      valueFiles:
        - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: database
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Example: API Gateway App (Wave 4)

```yaml
# argocd/apps/api-gateway.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-gateway
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/devops-zero-to-hero.git
    targetRevision: main
    path: helm/api-gateway
    helm:
      valueFiles:
        - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Step 8 — ApplicationSet with Git Directory Generator

For dynamic app creation — any new directory under `helm/` automatically becomes
an ArgoCD Application:

```yaml
# argocd/apps/microservices-appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/<you>/devops-zero-to-hero.git
        revision: main
        directories:
          - path: "helm/*"
          # Exclude infrastructure charts
          - path: "helm/postgres"
            exclude: true
          - path: "helm/redis"
            exclude: true
  template:
    metadata:
      name: "{{.path.basename}}"
      namespace: argocd
      annotations:
        argocd.argoproj.io/sync-wave: "4"
    spec:
      project: default
      source:
        repoURL: https://github.com/<you>/devops-zero-to-hero.git
        targetRevision: main
        path: "{{.path.path}}"
        helm:
          valueFiles:
            - values-dev.yaml
      destination:
        server: https://kubernetes.default.svc
        namespace: apps
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 3
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
```

---

## Step 9 — Sync Policies Deep Dive

### Auto-Sync with Self-Heal and Prune

```yaml
syncPolicy:
  automated:
    # Automatically sync when Git changes
    prune: true       # Delete resources removed from Git
    selfHeal: true    # Revert manual kubectl changes
    allowEmpty: false  # Prevent accidental deletion of all resources
  syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - PruneLast=true        # Prune after all other syncs complete
    - ServerSideApply=true  # Better conflict resolution
    - RespectIgnoreDifferences=true
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 5m
```

### Ignore Differences (for fields managed by controllers)

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas   # Ignore — HPA manages this
    - group: autoscaling
      kind: HorizontalPodAutoscaler
      jqPathExpressions:
        - .spec.metrics[].resource.target
```

---

## Step 10 — ArgoCD Notifications (Slack / Webhook)

Configure notifications so your team knows when syncs succeed or fail:

```yaml
# In argocd/values-k3s.yaml under notifications:
notifications:
  enabled: true
  argocdUrl: https://argocd.dev.localhost
  notifiers:
    service.webhook.discord: |
      url: $discord-webhook-url
      headers:
        - name: Content-Type
          value: application/json
  templates:
    template.app-sync-succeeded: |
      webhook:
        discord:
          method: POST
          body: |
            {
              "content": "Application {{.app.metadata.name}} synced successfully to {{.app.spec.destination.namespace}}"
            }
    template.app-sync-failed: |
      webhook:
        discord:
          method: POST
          body: |
            {
              "content": "ALERT: Application {{.app.metadata.name}} sync FAILED. Error: {{.app.status.operationState.message}}"
            }
  triggers:
    trigger.on-sync-succeeded: |
      - when: app.status.operationState.phase in ['Succeeded']
        send: [app-sync-succeeded]
    trigger.on-sync-failed: |
      - when: app.status.operationState.phase in ['Error', 'Failed']
        send: [app-sync-failed]
  subscriptions:
    - recipients:
        - discord
      triggers:
        - on-sync-succeeded
        - on-sync-failed
```

---

## Verify

### Check ArgoCD pods are healthy

```bash
kubectl get pods -n argocd
# Expected: all pods Running, 1/1 Ready
# argocd-application-controller-0   1/1  Running
# argocd-repo-server-xxx             1/1  Running
# argocd-server-xxx                  1/1  Running
# argocd-redis-xxx                   1/1  Running
# argocd-applicationset-controller   1/1  Running
```

### Check root app is synced

```bash
argocd app list
# NAME       CLUSTER                         NAMESPACE  STATUS  HEALTH
# root-app   https://kubernetes.default.svc  argocd     Synced  Healthy
```

### Verify repository connection

```bash
argocd repo list
# TYPE  NAME                 REPO                                            STATUS
# git   devops-zero-to-hero  https://github.com/<you>/devops-zero-to-hero   Successful
```

### Test sync wave ordering

```bash
# Watch apps sync in order
argocd app get root-app --show-operation
```

### Check resource usage

```bash
kubectl top pods -n argocd
# Total should be ~350-400MB RAM
```

---

## Troubleshooting

### Application stuck in "Unknown" or "Missing"

```bash
# Check repo server logs — usually a Git clone failure
kubectl logs -n argocd deploy/argocd-repo-server --tail=50

# Force a repo cache refresh
argocd repo get https://github.com/<you>/devops-zero-to-hero.git --refresh
```

### Sync fails with "ComparisonError"

```bash
# Usually a malformed manifest. Check the app details:
argocd app get <app-name> --show-operation

# Check controller logs for detailed errors:
kubectl logs -n argocd statefulset/argocd-application-controller --tail=100
```

### Out-of-sync but cannot determine diff

```bash
# Force a hard refresh (re-clone and re-render):
argocd app diff <app-name> --hard-refresh
```

### "Namespace not found" during sync

Verify your sync wave annotations. The namespace Application must have a lower
wave number than apps deployed into it. Double check:

```bash
kubectl get applications -n argocd -o custom-columns=\
NAME:.metadata.name,WAVE:.metadata.annotations."argocd\.argoproj\.io/sync-wave"
```

### Admin password not working

```bash
# Reset the admin password
argocd admin initial-password -n argocd
# Or patch it directly:
kubectl -n argocd patch secret argocd-secret -p \
  '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" newpassword | tr -d ':\n')'"}}'
```

### High memory on controller

The controller caches all watched resources. If memory exceeds limits:

```bash
# Reduce the number of watched resources
# In configs.cm:
resource.exclusions: |
  - apiGroups: ["events.k8s.io"]
    kinds: ["Event"]
    clusters: ["*"]
```

---

## Checklist

- [ ] ArgoCD namespace created
- [ ] Helm chart installed with k3s-tuned values
- [ ] Admin password retrieved and stored securely
- [ ] UI accessible via port-forward
- [ ] ArgoCD CLI installed and logged in
- [ ] GitHub repository connected (HTTPS or SSH)
- [ ] Root Application (App-of-Apps) applied
- [ ] Sync waves configured (0-6)
- [ ] Auto-sync with self-heal and prune enabled
- [ ] ApplicationSet for microservices created
- [ ] RBAC roles configured (admin, developer, readonly)
- [ ] Notifications configured (optional)
- [ ] Total RAM usage verified under 400MB

---

## What's Next?

With ArgoCD managing deployments declaratively, the next step is **Guide 17:
Argo Rollouts** — adding progressive delivery (canary and blue/green) so your
microservices roll out safely with automated analysis and rollback.
