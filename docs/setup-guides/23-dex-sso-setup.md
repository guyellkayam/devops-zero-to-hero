# 23 — Dex SSO Setup (Single Sign-On with GitHub)

## Why This Matters

Without SSO, every tool in your stack has separate credentials:
- ArgoCD has its own admin password
- Grafana has its own login
- Each new team member needs accounts created in every tool

Dex solves this by acting as an OIDC identity provider that connects to GitHub.
One GitHub login grants access to ArgoCD, Grafana, and any future tools.

**Why Dex over Keycloak?**

| | Dex | Keycloak |
|-|-----|----------|
| RAM | ~80MB | ~500MB+ |
| Complexity | Minimal config | Full admin UI, DB |
| Use case | OIDC proxy | Enterprise IAM |
| For this project | Perfect fit | Overkill |

Dex is 6x lighter and does exactly what we need: translate GitHub OAuth into OIDC tokens.

---

## Prerequisites

- k3s cluster running
- Helm installed
- cert-manager installed (guide 09) for TLS certificates
- A domain pointing to your cluster (e.g., `dex.devops.example.com`)
- ArgoCD installed (guide 08)
- Grafana installed (guide 12)
- GitHub account for creating an OAuth App

---

## Step 1: Create GitHub OAuth Application

You need a GitHub OAuth App so Dex can authenticate users through GitHub.

1. Go to **GitHub** -> **Settings** -> **Developer settings** -> **OAuth Apps** -> **New OAuth App**
2. Fill in:
   - **Application name**: `devops-zero-to-hero-dex`
   - **Homepage URL**: `https://dex.devops.example.com`
   - **Authorization callback URL**: `https://dex.devops.example.com/callback`
3. Click **Register application**
4. Copy the **Client ID**
5. Click **Generate a new client secret** and copy it immediately

Save these values -- you will need them in the next step:
```
GITHUB_CLIENT_ID=<your-client-id>
GITHUB_CLIENT_SECRET=<your-client-secret>
```

---

## Step 2: Create Kubernetes Secrets

Store the GitHub OAuth credentials as a Kubernetes Secret:

```bash
kubectl create namespace dex

kubectl create secret generic github-oauth \
  --namespace dex \
  --from-literal=client-id="${GITHUB_CLIENT_ID}" \
  --from-literal=client-secret="${GITHUB_CLIENT_SECRET}"
```

Create secrets for Dex's client applications (ArgoCD and Grafana):

```bash
# Generate random secrets for each client
ARGOCD_DEX_SECRET=$(openssl rand -hex 16)
GRAFANA_DEX_SECRET=$(openssl rand -hex 16)

# Save these -- you will need them when configuring ArgoCD and Grafana
echo "ArgoCD Dex Secret: ${ARGOCD_DEX_SECRET}"
echo "Grafana Dex Secret: ${GRAFANA_DEX_SECRET}"

kubectl create secret generic dex-client-secrets \
  --namespace dex \
  --from-literal=argocd-secret="${ARGOCD_DEX_SECRET}" \
  --from-literal=grafana-secret="${GRAFANA_DEX_SECRET}"
```

---

## Step 3: Install Dex with Helm

Save as `dex-values.yaml`:

```yaml
# dex-values.yaml
replicaCount: 1

image:
  tag: v2.40.0

resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    memory: 128Mi

# Dex configuration
config:
  # The issuer URL must match what clients expect
  issuer: https://dex.devops.example.com

  # In-memory storage (fine for single-node; use etcd/SQL for HA)
  storage:
    type: memory

  # Enable the web frontend for login
  web:
    http: 0.0.0.0:5556

  # GitHub connector
  connectors:
    - type: github
      id: github
      name: GitHub
      config:
        clientID: $GITHUB_CLIENT_ID
        clientSecret: $GITHUB_CLIENT_SECRET
        redirectURI: https://dex.devops.example.com/callback
        # Restrict to your GitHub organization (optional but recommended)
        # If you don't have an org, comment out the orgs section
        orgs:
          - name: your-github-org
            # Optionally restrict to specific teams
            # teams:
            #   - devops-team
            #   - platform-team
        # Load teams to map GitHub teams to K8s RBAC groups
        loadAllGroups: true
        teamNameField: slug
        useLoginAsID: true

  # OAuth2 clients (applications that use Dex for authentication)
  staticClients:
    # ArgoCD
    - id: argocd
      name: ArgoCD
      # This secret must match what's configured in ArgoCD
      secretEnv: ARGOCD_CLIENT_SECRET
      redirectURIs:
        - https://argocd.devops.example.com/auth/callback
    # Grafana
    - id: grafana
      name: Grafana
      secretEnv: GRAFANA_CLIENT_SECRET
      redirectURIs:
        - https://grafana.devops.example.com/login/generic_oauth

# Inject secrets as environment variables
envVars:
  - name: GITHUB_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: github-oauth
        key: client-id
  - name: GITHUB_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: github-oauth
        key: client-secret
  - name: ARGOCD_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: dex-client-secrets
        key: argocd-secret
  - name: GRAFANA_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: dex-client-secrets
        key: grafana-secret

# Ingress for external access
ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: dex.devops.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: dex-tls
      hosts:
        - dex.devops.example.com

# Service configuration
service:
  type: ClusterIP
  ports:
    http:
      port: 5556
```

### Install:

```bash
helm repo add dex https://charts.dexidp.io
helm repo update

helm install dex dex/dex \
  --namespace dex \
  --version 0.19.1 \
  --values dex-values.yaml
```

---

## Step 4: Configure ArgoCD SSO with Dex

Update ArgoCD's configuration to use Dex as the OIDC provider.

### Update ArgoCD ConfigMap:

```bash
kubectl edit configmap argocd-cm -n argocd
```

Add the following under `data:`:

```yaml
data:
  url: https://argocd.devops.example.com
  oidc.config: |
    name: GitHub (via Dex)
    issuer: https://dex.devops.example.com
    clientID: argocd
    clientSecret: $oidc.dex.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
```

### Create the ArgoCD OIDC secret:

```bash
# Use the same secret you generated in Step 2
kubectl patch secret argocd-secret -n argocd --type merge -p "{
  \"stringData\": {
    \"oidc.dex.clientSecret\": \"${ARGOCD_DEX_SECRET}\"
  }
}"
```

### Configure ArgoCD RBAC (map GitHub teams to ArgoCD roles):

```bash
kubectl edit configmap argocd-rbac-cm -n argocd
```

```yaml
data:
  # Default policy: read-only for authenticated users
  policy.default: role:readonly

  policy.csv: |
    # GitHub org admins get ArgoCD admin
    g, your-github-org:devops-team, role:admin

    # Platform team can manage apps but not settings
    g, your-github-org:platform-team, role:admin

    # Developers get read-only access
    g, your-github-org:developers, role:readonly

    # Custom role: can sync but not delete
    p, role:deployer, applications, sync, */*, allow
    p, role:deployer, applications, get, */*, allow
    p, role:deployer, applications, list, */*, allow
    g, your-github-org:deployers, role:deployer

  # Map OIDC groups claim to ArgoCD groups
  scopes: '[groups]'
```

### Restart ArgoCD to pick up changes:

```bash
kubectl rollout restart deployment argocd-server -n argocd
```

---

## Step 5: Configure Grafana SSO with Dex

Update Grafana's configuration to use Dex for authentication.

### If Grafana was installed with Helm, update values:

Save as `grafana-sso-values.yaml`:

```yaml
# grafana-sso-values.yaml
# Add to your existing Grafana Helm values
grafana.ini:
  server:
    root_url: https://grafana.devops.example.com

  auth.generic_oauth:
    enabled: true
    name: GitHub (via Dex)
    allow_sign_up: true
    client_id: grafana
    client_secret: ${GRAFANA_DEX_SECRET}
    scopes: openid profile email groups
    auth_url: https://dex.devops.example.com/auth
    token_url: https://dex.devops.example.com/token
    api_url: https://dex.devops.example.com/userinfo
    tls_skip_verify_insecure: false
    # Map OIDC groups to Grafana roles
    role_attribute_path: >
      contains(groups[*], 'your-github-org:devops-team') && 'Admin' ||
      contains(groups[*], 'your-github-org:platform-team') && 'Editor' ||
      'Viewer'
    # Allow users to be assigned to organizations based on groups
    allow_assign_grafana_admin: true

  # Disable basic auth login form (optional -- keep as fallback)
  auth:
    disable_login_form: false
```

### Apply with Helm upgrade:

```bash
helm upgrade grafana grafana/grafana \
  --namespace monitoring \
  --values grafana-sso-values.yaml \
  --reuse-values
```

### Or if using a ConfigMap, update directly:

```bash
kubectl create secret generic grafana-dex-secret \
  --namespace monitoring \
  --from-literal=client-secret="${GRAFANA_DEX_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Grafana
kubectl rollout restart deployment grafana -n monitoring
```

---

## Step 6: RBAC Mapping (GitHub Teams to Kubernetes Roles)

Create Kubernetes ClusterRoleBindings that map GitHub team groups (passed through
Dex OIDC tokens) to Kubernetes RBAC roles.

Save as `dex-rbac-bindings.yaml`:

```yaml
# dex-rbac-bindings.yaml

# DevOps team: full cluster admin
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dex-devops-team-admin
subjects:
  - kind: Group
    name: "your-github-org:devops-team"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io

# Platform team: can manage apps and monitoring namespaces
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-engineer
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]  # Can read but not create/modify secrets
  - apiGroups: [""]
    resources: ["pods/exec", "pods/portforward"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dex-platform-team
subjects:
  - kind: Group
    name: "your-github-org:platform-team"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform-engineer
  apiGroup: rbac.authorization.k8s.io

# Developers: read-only access to apps namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-readonly
  namespace: apps
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["pods", "deployments", "services", "configmaps", "ingresses", "jobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dex-developers-readonly
  namespace: apps
subjects:
  - kind: Group
    name: "your-github-org:developers"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer-readonly
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f dex-rbac-bindings.yaml
```

### Configure kubectl to use Dex OIDC:

To allow developers to use `kubectl` with their GitHub identity, they can use
kubelogin (OIDC helper for kubectl):

```bash
# Install kubelogin
brew install int128/kubelogin/kubelogin

# Add OIDC user to kubeconfig
kubectl config set-credentials dex-user \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login \
  --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://dex.devops.example.com \
  --exec-arg=--oidc-client-id=kubectl \
  --exec-arg=--oidc-extra-scope=groups \
  --exec-arg=--oidc-extra-scope=email

# Set the context to use the OIDC user
kubectl config set-context dex-context \
  --cluster=default \
  --user=dex-user

kubectl config use-context dex-context

# First kubectl command will open browser for GitHub login
kubectl get pods -n apps
```

**Note**: For kubectl OIDC to work, you need to add `kubectl` as a static client
in Dex and configure your k3s API server with OIDC flags. This is optional and
typically only needed for multi-user team setups.

---

## Verify

### Dex is running:

```bash
kubectl get pods -n dex
# NAME                   READY   STATUS    RESTARTS   AGE
# dex-xxx                1/1     Running   0          5m

# Check Dex discovery endpoint
curl -s https://dex.devops.example.com/.well-known/openid-configuration | jq .
# Should return OIDC metadata with issuer, auth endpoint, token endpoint, etc.
```

### ArgoCD SSO works:

```bash
# Open ArgoCD in browser
echo "https://argocd.devops.example.com"

# You should see a "LOG IN VIA GITHUB (VIA DEX)" button
# Click it -> GitHub OAuth -> redirected back to ArgoCD logged in
# Check your role:
# Click user icon (top right) -> User Info -> should show your groups
```

### Grafana SSO works:

```bash
# Open Grafana in browser
echo "https://grafana.devops.example.com"

# You should see a "Sign in with GitHub (via Dex)" button
# Click it -> GitHub OAuth -> redirected back to Grafana logged in
# Check your role: Administration -> Users -> your user should have correct role
```

### RBAC mapping:

```bash
# As a devops-team member, you should have admin access
kubectl auth can-i '*' '*' --as-group="your-github-org:devops-team"
# yes

# As a developer, you should have limited access
kubectl auth can-i get pods -n apps --as-group="your-github-org:developers"
# yes
kubectl auth can-i delete pods -n apps --as-group="your-github-org:developers"
# no
```

---

## Troubleshooting

### Dex login redirects to error page

```bash
# Check Dex logs
kubectl logs -n dex deploy/dex --tail=50

# Common issues:
# 1. Wrong redirect URI in GitHub OAuth App
#    Fix: Go to GitHub -> Developer settings -> OAuth Apps -> check callback URL
#    Must match: https://dex.devops.example.com/callback

# 2. Client ID/Secret mismatch
kubectl get secret github-oauth -n dex -o jsonpath='{.data.client-id}' | base64 -d
# Verify this matches your GitHub OAuth App
```

### ArgoCD shows "Login failed"

```bash
# Check if ArgoCD can reach Dex
kubectl exec deploy/argocd-server -n argocd -- \
  wget -qO- --timeout=5 https://dex.devops.example.com/.well-known/openid-configuration

# Check ArgoCD OIDC config
kubectl get configmap argocd-cm -n argocd -o yaml | grep -A 10 "oidc.config"

# Verify the client secret matches
kubectl get secret argocd-secret -n argocd -o jsonpath='{.data.oidc\.dex\.clientSecret}' | base64 -d
```

### GitHub groups not showing up in tokens

```bash
# Test: decode the JWT token from Dex
# After logging in, check the token claims:
# In ArgoCD: User Info -> shows groups
# In Grafana: check server logs for the group claim

# Fix: ensure loadAllGroups: true in Dex GitHub connector config
# Fix: ensure your GitHub user is a member of the org (not just a collaborator)
# Fix: org membership must be public (or use org:read scope)
```

### Grafana shows "Viewer" role instead of "Admin"

```bash
# Check the role_attribute_path in Grafana config
kubectl get configmap grafana -n monitoring -o yaml | grep role_attribute_path

# Ensure your GitHub org team name exactly matches
# Use slug format: "devops-team" not "DevOps Team"
# Test the JMESPath expression at https://jmespath.org/

# Also check: is your org membership public on GitHub?
```

---

## Checklist

- [ ] GitHub OAuth App created with correct callback URL
- [ ] GitHub OAuth credentials stored as Kubernetes Secret
- [ ] Dex Helm chart installed in dex namespace
- [ ] Dex discovery endpoint returns OIDC configuration
- [ ] TLS certificate issued for dex.devops.example.com
- [ ] ArgoCD ConfigMap updated with OIDC config pointing to Dex
- [ ] ArgoCD RBAC maps GitHub teams to roles (admin, readonly, deployer)
- [ ] ArgoCD login via GitHub works (browser test)
- [ ] Grafana configured with generic_oauth pointing to Dex
- [ ] Grafana role mapping works (Admin/Editor/Viewer based on team)
- [ ] Grafana login via GitHub works (browser test)
- [ ] Kubernetes RBAC bindings created for GitHub teams
- [ ] Resource usage confirmed under 128MB

---

## What's Next?

With SSO in place, your team can:
- Log into ArgoCD and Grafana with their GitHub accounts
- Get role-based access automatically based on their GitHub team membership
- No need to manage separate passwords for each tool

Next: **Guide 24 -- GitHub Actions CI/CD Setup** to build the complete CI pipeline
that builds, scans, signs, and pushes container images.
