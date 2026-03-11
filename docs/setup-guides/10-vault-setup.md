# 10 — HashiCorp Vault Setup

## Why This Matters
Every application needs secrets — database passwords, API keys, TLS certificates, OAuth tokens.
The worst practice is hardcoding them in code or Kubernetes manifests. The slightly-less-bad
practice is using Kubernetes Secrets (which are just base64-encoded, not encrypted at rest by
default).

HashiCorp Vault is purpose-built for secrets management. It provides:

- **Encryption at rest and in transit** for all secrets
- **Access policies** — each service only sees its own secrets
- **Audit logging** — who accessed what, when
- **Dynamic secrets** — generate DB credentials on-the-fly with auto-expiry
- **Kubernetes-native auth** — pods authenticate using their ServiceAccount

In our architecture, Vault is the **single source of truth** for secrets. The External Secrets
Operator (guide 11) syncs them into Kubernetes Secrets so your pods can consume them.

```
Vault (source of truth)
  --> ESO syncs secrets
    --> K8s Secret created
      --> Pod reads as env var or volume mount
```

~200MB RAM usage.

---

## Prerequisites
- k3s cluster running (from guide 07)
- Longhorn storage configured as default StorageClass (from guide 09)
- kubectl and Helm working from local machine
- `vault` namespace exists (created in guide 07)

---

## Part A: Dev Mode (For Learning)

Dev mode runs Vault in-memory with auto-unseal. Perfect for learning and experimenting.
Data is **lost on restart** — do not use in production.

### Step 1: Add the HashiCorp Helm Repository

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### Step 2: Install Vault in Dev Mode

```bash
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --set server.dev.enabled=true \
  --set server.dev.devRootToken=root \
  --set server.resources.requests.memory=128Mi \
  --set server.resources.requests.cpu=100m \
  --set server.resources.limits.memory=256Mi \
  --set server.resources.limits.cpu=250m \
  --set injector.enabled=false \
  --set ui.enabled=true \
  --wait
```

> **Why `injector.enabled=false`?** We use External Secrets Operator (guide 11) instead
> of the Vault Agent Injector. ESO is more GitOps-friendly and works better with ArgoCD.

### Step 3: Verify Dev Mode

```bash
# Check pod is running
kubectl get pods -n vault

# Expected:
# NAME                                    READY   STATUS    RESTARTS   AGE
# vault-0                                 1/1     Running   0          30s

# Port-forward the Vault UI
kubectl port-forward -n vault svc/vault 8200:8200

# Open: http://localhost:8200
# Token: root
```

**Skip to Step 5** (Enable KV v2) if you just want to learn. Come back to Part B when
you are ready for production-grade setup.

---

## Part B: Production Mode (Persistent, Sealed)

Production mode stores data on Longhorn persistent storage and requires manual unsealing.

### Step 1: Create Vault Values File

```bash
cat <<'EOF' > vault-values.yaml
server:
  # Resource limits for our 8GB budget
  resources:
    requests:
      memory: 128Mi
      cpu: 100m
    limits:
      memory: 256Mi
      cpu: 250m

  # Persistent storage using Longhorn
  dataStorage:
    enabled: true
    size: 5Gi
    storageClass: longhorn
    accessMode: ReadWriteOnce

  # Standalone mode (single node, no HA)
  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "file" {
        path = "/vault/data"
      }

  # Disable HA (single node)
  ha:
    enabled: false

# We use ESO instead of the Vault Agent Injector
injector:
  enabled: false

# Enable the Vault UI
ui:
  enabled: true
EOF
```

### Step 2: Install Vault in Production Mode

```bash
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  -f vault-values.yaml \
  --wait
```

### Step 3: Initialize Vault

The very first time Vault starts in production mode, it is **sealed** and needs initialization.

```bash
# Check status — should show "Sealed: true"
kubectl exec -n vault vault-0 -- vault status 2>/dev/null || true

# Initialize with 1 key share and 1 threshold (simple for learning)
# In real production, use 5 shares with threshold of 3 (Shamir's Secret Sharing)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > vault-init.json
```

> **CRITICAL**: Save `vault-init.json` securely! It contains:
> - **Unseal Key(s)**: Needed every time Vault restarts
> - **Root Token**: Full admin access
>
> Store these in a password manager. If you lose them, you lose access to all secrets.

### Step 4: Unseal Vault

```bash
# Extract the unseal key
VAULT_UNSEAL_KEY=$(cat vault-init.json | jq -r '.unseal_keys_b64[0]')

# Unseal
kubectl exec -n vault vault-0 -- vault operator unseal $VAULT_UNSEAL_KEY

# Verify — "Sealed" should now be "false"
kubectl exec -n vault vault-0 -- vault status
```

**Expected output** (key lines):
```
Sealed          false
Total Shares    1
Threshold       1
```

> **IMPORTANT**: You must unseal Vault every time the pod restarts.
> For auto-unseal in production, use AWS KMS. See the troubleshooting section.

---

## Step 5: Enable the KV v2 Secrets Engine

KV v2 (Key-Value version 2) is the most common secrets engine. It supports versioning,
so you can roll back to previous secret values.

```bash
# Set the Vault address and token for exec commands
export VAULT_TOKEN=$(cat vault-init.json | jq -r '.root_token')
# For dev mode, use: export VAULT_TOKEN=root

# Enable KV v2 at the path "secret/"
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault secrets enable -path=secret -version=2 kv
"
```

> **Note**: In dev mode, `secret/` is already enabled by default. If you get
> "path is already in use", that is fine — it means it is already there.

---

## Step 6: Store Sample Secrets

Organize secrets by service name. This maps cleanly to ESO ExternalSecrets in guide 11.

```bash
# Database credentials
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'

  # PostgreSQL credentials
  vault kv put secret/postgres \
    username=devops_admin \
    password=SuperSecure-DB-Pass-2024 \
    host=postgres.apps-production.svc.cluster.local \
    port=5432 \
    database=devops_app

  # Redis credentials
  vault kv put secret/redis \
    password=Redis-Auth-Token-2024 \
    host=redis.apps-production.svc.cluster.local \
    port=6379

  # Application API keys
  vault kv put secret/app-api-keys \
    github_token=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
    slack_webhook=https://hooks.slack.com/services/T00/B00/xxxx \
    smtp_password=SES-SMTP-Password-Here

  # Harbor registry credentials
  vault kv put secret/harbor \
    admin_password=Harbor-Admin-2024 \
    robot_token=robot-push-token-here
"
```

### Verify Secrets Were Stored:
```bash
# List all secrets
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault kv list secret/
"

# Read a specific secret
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault kv get secret/postgres
"
```

---

## Step 7: Create Access Policies

Policies define who can read which secrets. Each microservice gets a policy that limits
access to only its own secrets.

```bash
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'

  # Policy for the main application — can read postgres, redis, and API keys
  vault policy write app-policy - <<POLICY
path \"secret/data/postgres\" {
  capabilities = [\"read\"]
}
path \"secret/data/redis\" {
  capabilities = [\"read\"]
}
path \"secret/data/app-api-keys\" {
  capabilities = [\"read\"]
}
POLICY

  # Policy for CI/CD — can read harbor credentials
  vault policy write cicd-policy - <<POLICY
path \"secret/data/harbor\" {
  capabilities = [\"read\"]
}
POLICY

  # Policy for ESO — can read ALL secrets (it syncs them to K8s)
  vault policy write eso-policy - <<POLICY
path \"secret/data/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"secret/metadata/*\" {
  capabilities = [\"read\", \"list\"]
}
POLICY
"

# Verify policies
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault policy list
"
```

---

## Step 8: Enable Kubernetes Auth Method

This allows Kubernetes pods to authenticate with Vault using their ServiceAccount token.
ESO will use this to fetch secrets.

```bash
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'

  # Enable Kubernetes auth
  vault auth enable kubernetes

  # Configure it to use the in-cluster Kubernetes API
  vault write auth/kubernetes/config \
    kubernetes_host=\"https://\${KUBERNETES_PORT_443_TCP_ADDR}:443\"
"
```

### Create a Role for ESO:

```bash
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'

  # Create a role that ESO's service account will use
  vault write auth/kubernetes/role/eso-role \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=eso \
    policies=eso-policy \
    ttl=1h
"
```

This says: "Any pod in the `eso` namespace using the `external-secrets` ServiceAccount
can authenticate and gets the `eso-policy` (read all secrets)."

---

## Step 9: Access the Vault UI

```bash
kubectl port-forward -n vault svc/vault 8200:8200
# Open: http://localhost:8200
# Login method: Token
# Token: (your root token from vault-init.json, or "root" for dev mode)
```

From the UI you can:
- Browse and manage secrets
- View/edit policies
- Monitor audit logs
- See lease information

---

## Verify

```bash
echo "=== Vault Pods ==="
kubectl get pods -n vault

echo ""
echo "=== Vault Status ==="
kubectl exec -n vault vault-0 -- vault status 2>/dev/null || echo "Vault may be sealed"

echo ""
echo "=== Vault Secrets Engines ==="
kubectl exec -n vault vault-0 -- sh -c "export VAULT_TOKEN='${VAULT_TOKEN}' && vault secrets list" 2>/dev/null

echo ""
echo "=== Vault Policies ==="
kubectl exec -n vault vault-0 -- sh -c "export VAULT_TOKEN='${VAULT_TOKEN}' && vault policy list" 2>/dev/null

echo ""
echo "=== Vault Auth Methods ==="
kubectl exec -n vault vault-0 -- sh -c "export VAULT_TOKEN='${VAULT_TOKEN}' && vault auth list" 2>/dev/null

echo ""
echo "=== Resource Usage ==="
kubectl top pods -n vault 2>/dev/null || echo "Wait for metrics"

echo ""
echo "=== Persistent Volume ==="
kubectl get pvc -n vault
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Vault pod `Running` but `0/1 Ready` | Vault is sealed. Run the unseal command from Step 4 |
| `permission denied` errors | Check you are using the correct VAULT_TOKEN |
| `vault: command not found` in exec | Use full path: `kubectl exec -n vault vault-0 -- /bin/vault status` |
| PVC stuck in Pending | Verify Longhorn is working: `kubectl get pods -n longhorn-system` |
| Lost unseal keys | In dev mode: just reinstall. In production: your data is unrecoverable — this is by design |
| Need auto-unseal | Use AWS KMS auto-unseal (see below) |
| `connection refused` on port-forward | Vault might have restarted and be sealed. Unseal it first |

### Auto-Unseal with AWS KMS (Production Enhancement):

For production, you should not rely on manual unsealing. Add this to your Vault config:

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "your-kms-key-id"
}
```

This requires an IAM role attached to the EC2 instance with `kms:Encrypt` and `kms:Decrypt`
permissions. Vault will automatically unseal using KMS on restart.

### Debug Commands:
```bash
# Vault server logs
kubectl logs -n vault vault-0

# Check Vault health endpoint
kubectl exec -n vault vault-0 -- wget -qO- http://127.0.0.1:8200/v1/sys/health 2>/dev/null

# Check Kubernetes auth config
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault read auth/kubernetes/config
"

# List auth roles
kubectl exec -n vault vault-0 -- sh -c "
  export VAULT_TOKEN='${VAULT_TOKEN}'
  vault list auth/kubernetes/role
"
```

---

## Checklist

- [ ] HashiCorp Helm repo added
- [ ] Vault installed in `vault` namespace
- [ ] Vault pod is Running and Ready
- [ ] (Production) Vault initialized — unseal keys and root token saved securely
- [ ] (Production) Vault unsealed — `Sealed: false`
- [ ] KV v2 secrets engine enabled at `secret/`
- [ ] Sample secrets stored: postgres, redis, app-api-keys, harbor
- [ ] Access policies created: app-policy, cicd-policy, eso-policy
- [ ] Kubernetes auth method enabled
- [ ] ESO role created with `eso-policy`
- [ ] Vault UI accessible via port-forward
- [ ] RAM usage is ~200MB or less
- [ ] `vault-init.json` saved in a secure location (password manager)

---

## What's Next?
-> [11 -- ESO Setup](11-eso-setup.md) — Install External Secrets Operator to automatically sync Vault secrets into Kubernetes Secrets.
