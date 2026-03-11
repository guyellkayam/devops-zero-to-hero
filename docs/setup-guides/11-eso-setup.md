# 11 — External Secrets Operator (ESO) Setup

## Why This Matters
You have Vault storing all your secrets securely (guide 10). But your pods need those secrets
as Kubernetes Secrets — environment variables or mounted files. How do you bridge the gap?

You could manually copy secrets from Vault to Kubernetes. But then you have two sources of truth,
no auto-rotation, and a manual process that does not scale. The External Secrets Operator (ESO)
solves this by **automatically syncing secrets from Vault into Kubernetes Secrets**:

```
Vault (source of truth)
  |
  |  ESO polls every 1h (configurable)
  |
  v
K8s Secret (auto-created/updated)
  |
  v
Pod reads via env var or volume mount
```

When you update a secret in Vault, ESO detects the change and updates the Kubernetes Secret.
Pods pick up the new value on their next restart (or immediately with volume mounts).

**The full flow in practice:**
1. DevOps engineer writes secret to Vault: `vault kv put secret/postgres password=NewPass123`
2. ESO detects the change within its refresh interval
3. ESO updates the Kubernetes Secret `postgres-credentials`
4. Pod restarts or reads the new mounted secret file

~80MB RAM usage.

---

## Prerequisites
- k3s cluster running (from guide 07)
- Vault installed and configured with Kubernetes auth (from guide 10)
- ESO role `eso-role` created in Vault (from guide 10, Step 8)
- kubectl and Helm working from local machine
- `eso` namespace exists (created in guide 07)

---

## Step 1: Add the ESO Helm Repository

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```

---

## Step 2: Install External Secrets Operator

```bash
helm install external-secrets external-secrets/external-secrets \
  --namespace eso \
  --create-namespace \
  --set installCRDs=true \
  --set resources.requests.memory=64Mi \
  --set resources.requests.cpu=50m \
  --set resources.limits.memory=128Mi \
  --set resources.limits.cpu=100m \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.memory=64Mi \
  --set certController.resources.requests.memory=32Mi \
  --set certController.resources.limits.memory=64Mi \
  --wait
```

### Wait for All Pods:
```bash
kubectl get pods -n eso -w

# Expected (all Running):
# NAME                                                READY   STATUS    RESTARTS   AGE
# external-secrets-xxxxxxxxx-xxxxx                    1/1     Running   0          30s
# external-secrets-webhook-xxxxxxxxx-xxxxx            1/1     Running   0          30s
# external-secrets-cert-controller-xxxxxxxxx-xxxxx    1/1     Running   0          30s
```

- **external-secrets**: Main controller that reconciles ExternalSecret CRDs
- **webhook**: Validates ExternalSecret manifests on creation
- **cert-controller**: Manages TLS certificates for the webhook

---

## Step 3: Create a ServiceAccount for Vault Auth

ESO needs a Kubernetes ServiceAccount to authenticate with Vault:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: eso
---
apiVersion: v1
kind: Secret
metadata:
  name: external-secrets-token
  namespace: eso
  annotations:
    kubernetes.io/service-account.name: external-secrets
type: kubernetes.io/service-account-token
EOF
```

```bash
# Verify the token was created
kubectl get secret external-secrets-token -n eso
# Should show a secret of type kubernetes.io/service-account-token
```

---

## Step 4: Create ClusterSecretStore

The ClusterSecretStore defines **how** ESO connects to Vault. It is cluster-wide, so
ExternalSecrets in any namespace can reference it.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-role"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "eso"
          secretRef:
            name: "external-secrets-token"
            namespace: "eso"
            key: "token"
EOF
```

### What Each Field Means:

| Field | Value | Why |
|-------|-------|-----|
| `server` | `http://vault.vault.svc...` | Internal Kubernetes DNS name for Vault |
| `path` | `secret` | The KV v2 mount path we created in guide 10 |
| `version` | `v2` | KV version 2 (supports secret versioning) |
| `role` | `eso-role` | The Vault role we created in guide 10, Step 8 |
| `serviceAccountRef` | `external-secrets` | The ServiceAccount ESO uses to authenticate |

### Verify the Store Is Connected:
```bash
kubectl get clustersecretstore vault-backend

# Expected:
# NAME            AGE   STATUS   CAPABILITIES   READY
# vault-backend   10s   Valid    ReadWrite      True

# If STATUS is not Valid, check:
kubectl describe clustersecretstore vault-backend
```

> **IMPORTANT**: The STATUS must show `Valid` and READY must be `True`.
> If it shows an error, Vault is either sealed, unreachable, or the role/policy is misconfigured.

---

## Step 5: Create ExternalSecrets for Each Service

Now create ExternalSecret resources that tell ESO which Vault secrets to sync.

### PostgreSQL Credentials:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
  namespace: apps-production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: postgres-credentials
    creationPolicy: Owner
  data:
  - secretKey: POSTGRES_USER
    remoteRef:
      key: postgres
      property: username
  - secretKey: POSTGRES_PASSWORD
    remoteRef:
      key: postgres
      property: password
  - secretKey: POSTGRES_HOST
    remoteRef:
      key: postgres
      property: host
  - secretKey: POSTGRES_PORT
    remoteRef:
      key: postgres
      property: port
  - secretKey: POSTGRES_DB
    remoteRef:
      key: postgres
      property: database
EOF
```

### Redis Credentials:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: redis-credentials
  namespace: apps-production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: redis-credentials
    creationPolicy: Owner
  data:
  - secretKey: REDIS_PASSWORD
    remoteRef:
      key: redis
      property: password
  - secretKey: REDIS_HOST
    remoteRef:
      key: redis
      property: host
  - secretKey: REDIS_PORT
    remoteRef:
      key: redis
      property: port
EOF
```

### Application API Keys:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-api-keys
  namespace: apps-production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: app-api-keys
    creationPolicy: Owner
  data:
  - secretKey: GITHUB_TOKEN
    remoteRef:
      key: app-api-keys
      property: github_token
  - secretKey: SLACK_WEBHOOK
    remoteRef:
      key: app-api-keys
      property: slack_webhook
  - secretKey: SMTP_PASSWORD
    remoteRef:
      key: app-api-keys
      property: smtp_password
EOF
```

### Harbor Registry Credentials:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: harbor-credentials
  namespace: apps-production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: harbor-credentials
    creationPolicy: Owner
  data:
  - secretKey: HARBOR_ADMIN_PASSWORD
    remoteRef:
      key: harbor
      property: admin_password
  - secretKey: HARBOR_ROBOT_TOKEN
    remoteRef:
      key: harbor
      property: robot_token
EOF
```

---

## Step 6: Verify Secrets Are Synced

```bash
# Check all ExternalSecrets
kubectl get externalsecret -n apps-production

# Expected (all should show SecretSynced / True):
# NAME                   STORE           REFRESH   STATUS         READY
# postgres-credentials   vault-backend   1h        SecretSynced   True
# redis-credentials      vault-backend   1h        SecretSynced   True
# app-api-keys           vault-backend   1h        SecretSynced   True
# harbor-credentials     vault-backend   1h        SecretSynced   True

# Check the actual K8s Secrets were created
kubectl get secrets -n apps-production

# Verify a secret's content
kubectl get secret postgres-credentials -n apps-production -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
# Should output: SuperSecure-DB-Pass-2024
```

---

## Step 7: Test End-to-End — Secret in a Pod

Deploy a test pod that reads the synced secret as environment variables:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-eso-pod
  namespace: apps-production
spec:
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo DB=$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB user=$POSTGRES_USER && sleep 3600"]
    envFrom:
    - secretRef:
        name: postgres-credentials
  restartPolicy: Never
EOF
```

```bash
# Wait for pod to start
kubectl get pod test-eso-pod -n apps-production -w

# Check the output
kubectl logs test-eso-pod -n apps-production
# Expected: DB=postgres.apps-production.svc.cluster.local:5432/devops_app user=devops_admin
```

The pod successfully reads secrets that originated in Vault, without the pod knowing
anything about Vault. It just sees normal environment variables.

### Clean up:
```bash
kubectl delete pod test-eso-pod -n apps-production
```

---

## Step 8: Test Secret Rotation

Update a secret in Vault and watch ESO sync it:

```bash
# Get your Vault token
export VAULT_TOKEN=$(cat vault-init.json | jq -r '.root_token')
# For dev mode: export VAULT_TOKEN=root

# Update the postgres password in Vault
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault kv put secret/postgres \
    username=devops_admin \
    password=NewRotatedPassword-2024 \
    host=postgres.apps-production.svc.cluster.local \
    port=5432 \
    database=devops_app
"

# Force an immediate refresh (instead of waiting 1h)
kubectl annotate externalsecret postgres-credentials \
  -n apps-production \
  force-sync=$(date +%s) \
  --overwrite

# Wait a few seconds, then check the K8s secret
sleep 5
kubectl get secret postgres-credentials -n apps-production \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
# Should now output: NewRotatedPassword-2024
```

---

## How It All Connects — Architecture Diagram

```
+-------------------+      +--------------------+      +------------------+
|                   |      |                    |      |                  |
|   Vault           | <--- |   ESO Controller   | ---> |  K8s Secret      |
|   (secret/postgres)|     |   (polls every 1h) |      |  (postgres-creds)|
|                   |      |                    |      |                  |
+-------------------+      +--------------------+      +--------+---------+
                                                                |
                                                                v
                                                       +--------+---------+
                                                       |                  |
                                                       |   Your Pod       |
                                                       |   env:           |
                                                       |     POSTGRES_USER|
                                                       |     POSTGRES_PASS|
                                                       |                  |
                                                       +------------------+
```

1. **You** store secrets in Vault (manually or via CI/CD)
2. **ESO** authenticates to Vault using the Kubernetes ServiceAccount
3. **ESO** reads the secret and creates/updates a Kubernetes Secret
4. **Your Pod** reads the Kubernetes Secret as environment variables
5. When the Vault secret changes, ESO updates the K8s Secret on the next refresh cycle

---

## Verify

```bash
echo "=== ESO Pods ==="
kubectl get pods -n eso

echo ""
echo "=== ClusterSecretStore ==="
kubectl get clustersecretstore

echo ""
echo "=== ExternalSecrets ==="
kubectl get externalsecret -A

echo ""
echo "=== Synced K8s Secrets ==="
kubectl get secrets -n apps-production

echo ""
echo "=== Resource Usage ==="
kubectl top pods -n eso 2>/dev/null || echo "Wait for metrics"

echo ""
echo "=== Secret Sync Events ==="
kubectl get events -n apps-production --field-selector reason=Updated --sort-by='.lastTimestamp' 2>/dev/null | tail -10
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| ClusterSecretStore shows `InvalidProviderConfig` | Vault is sealed or unreachable. Unseal Vault (guide 10, Step 4), check: `kubectl exec -n vault vault-0 -- vault status` |
| ExternalSecret shows `SecretSyncedError` | Check ESO logs: `kubectl logs -n eso -l app.kubernetes.io/name=external-secrets` |
| `could not get provider client` | ServiceAccount token might be expired. Delete and recreate the `external-secrets-token` secret |
| `permission denied` from Vault | Check the `eso-policy` in Vault covers `secret/data/*` (note the `data/` prefix for KV v2) |
| Secret not updating after Vault change | Force sync: `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite` |
| Wrong namespace for ExternalSecret | ExternalSecrets create K8s Secrets in the **same namespace** as the ExternalSecret resource |
| `403` errors in ESO logs | Verify Vault role binds to correct ServiceAccount name and namespace |

### Debug Commands:
```bash
# ESO controller logs (most useful for debugging)
kubectl logs -n eso -l app.kubernetes.io/name=external-secrets --tail=50

# Describe a failing ExternalSecret
kubectl describe externalsecret postgres-credentials -n apps-production

# Check the ClusterSecretStore details
kubectl describe clustersecretstore vault-backend

# Verify Vault K8s auth is working
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault read auth/kubernetes/role/eso-role
"

# Test Vault connectivity from ESO namespace
kubectl run vault-test --rm -it --image=curlimages/curl -n eso -- \
  curl -s http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

---

## Checklist

- [ ] ESO Helm repo added
- [ ] External Secrets Operator installed in `eso` namespace
- [ ] All ESO pods Running (controller, webhook, cert-controller)
- [ ] ServiceAccount and token created for Vault auth
- [ ] ClusterSecretStore `vault-backend` shows `Valid` / `Ready: True`
- [ ] ExternalSecret for postgres created and `SecretSynced`
- [ ] ExternalSecret for redis created and `SecretSynced`
- [ ] ExternalSecret for app-api-keys created and `SecretSynced`
- [ ] ExternalSecret for harbor created and `SecretSynced`
- [ ] K8s Secrets created in `apps-production` namespace
- [ ] Secret values match what is stored in Vault
- [ ] Test pod successfully reads secrets as environment variables
- [ ] Secret rotation tested — Vault update flows through to K8s Secret
- [ ] Test resources cleaned up
- [ ] RAM usage is ~80MB or less

---

## What's Next?
-> [12 -- ArgoCD Setup](12-argocd-setup.md) — Install ArgoCD for GitOps-based continuous deployment. Your Git repo becomes the single source of truth for all Kubernetes manifests.
