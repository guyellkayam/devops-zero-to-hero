# 15 — CloudNativePG Setup (PostgreSQL Operator for Kubernetes)

## Why This Matters

Every microservice that stores data needs a database. The traditional approach is
using Amazon RDS, which costs **$15-30/month** for a small instance. CloudNativePG
runs PostgreSQL directly in your Kubernetes cluster, costs nothing beyond the compute
you already have, and teaches you the **Kubernetes Operator pattern** — one of the
most important concepts in modern infrastructure.

### Why an Operator Over Plain PostgreSQL?

A PostgreSQL container alone gives you nothing — no backups, no failover, no
monitoring, no connection pooling. You would need to script all of that yourself.
An operator watches your PostgreSQL cluster and automatically handles:

| Feature | Manual PostgreSQL | CloudNativePG Operator |
|---------|-------------------|------------------------|
| High availability | You configure streaming replication | Automatic failover |
| Backups | You write cron jobs | Scheduled + continuous WAL archiving |
| Scaling | You create new pods manually | `kubectl edit cluster` |
| Monitoring | You install and configure exporters | Built-in Prometheus metrics |
| Updates | Risky manual process | Rolling updates with zero downtime |
| Connection pooling | You deploy PgBouncer separately | Integrated PgBouncer sidecar |

### Why CloudNativePG?

CloudNativePG is maintained by EDB (the largest PostgreSQL company), it is a CNCF
Sandbox project, and it is the most actively developed PostgreSQL operator for
Kubernetes. Unlike Zalando's operator or CrunchyData's PGO, CloudNativePG was built
from scratch for Kubernetes (not adapted from pre-K8s tooling).

Resource usage: **~150MB RAM** for the operator + **~256MB per PostgreSQL instance**.

---

## Prerequisites

| Requirement | How to Verify |
|-------------|---------------|
| k3s cluster running | `kubectl get nodes` shows Ready |
| Helm installed | `helm version --short` |
| Longhorn storage provisioner | `kubectl get storageclass` shows `longhorn` |
| cert-manager installed (Guide 12) | `kubectl get clusterissuers` |
| At least 1GB free RAM | `kubectl top nodes` or `free -h` on the node |

---

## Step 1: Install CloudNativePG Operator

The operator runs as a single deployment that watches for PostgreSQL Cluster resources
across all namespaces.

```bash
# Add the CloudNativePG Helm repository
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

# Create the namespace
kubectl create namespace postgres-operator

# Install the operator
helm install cnpg cnpg/cloudnative-pg \
  --namespace postgres-operator \
  --version 0.23.0 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=256Mi \
  --set monitoring.podMonitorEnabled=false \
  --wait
```

### Verify the operator is running:

```bash
# Operator pod should be Running
kubectl get pods -n postgres-operator

# Expected:
# NAME                                     READY   STATUS    RESTARTS   AGE
# cnpg-cloudnative-pg-xxxxxxxxx-xxxxx     1/1     Running   0          60s

# Check CRDs were installed
kubectl get crds | grep cnpg

# Expected:
# backups.postgresql.cnpg.io
# clusters.postgresql.cnpg.io
# poolers.postgresql.cnpg.io
# scheduledbackups.postgresql.cnpg.io
```

---

## Step 2: Create a PostgreSQL Cluster for Development

This creates a single-instance PostgreSQL cluster suitable for development. For
production, you would increase `instances` to 3 for automatic failover.

```bash
# Create a namespace for databases
kubectl create namespace databases

cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: dev-postgres
  namespace: databases
spec:
  description: "Development PostgreSQL cluster for devops-zero-to-hero"
  imageName: ghcr.io/cloudnative-pg/postgresql:16.6-bookworm

  # Single instance for dev (use 3 for production HA)
  instances: 1

  # PostgreSQL configuration
  postgresql:
    parameters:
      # Memory settings (tuned for 256MB total)
      shared_buffers: "64MB"
      effective_cache_size: "128MB"
      work_mem: "4MB"
      maintenance_work_mem: "32MB"

      # Connection settings
      max_connections: "50"

      # WAL settings
      wal_buffers: "4MB"
      min_wal_size: "32MB"
      max_wal_size: "128MB"

      # Logging
      log_min_duration_statement: "1000"    # Log queries slower than 1s
      log_checkpoints: "on"
      log_connections: "on"
      log_disconnections: "on"
      log_lock_waits: "on"

    # HBA rules (host-based authentication)
    pg_hba:
      - host all all 10.42.0.0/16 md5       # k3s pod CIDR
      - host all all 10.43.0.0/16 md5       # k3s service CIDR

  # Bootstrap: create initial databases and users
  bootstrap:
    initdb:
      database: appdb
      owner: appuser
      secret:
        name: dev-postgres-app-credentials
      postInitSQL:
        - CREATE DATABASE userservice OWNER appuser;
        - CREATE DATABASE orderservice OWNER appuser;
        - "GRANT ALL PRIVILEGES ON DATABASE userservice TO appuser;"
        - "GRANT ALL PRIVILEGES ON DATABASE orderservice TO appuser;"

  # Resource limits
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi

  # Storage (Longhorn)
  storage:
    storageClass: longhorn
    size: 5Gi

  # WAL storage (separate volume for better performance)
  walStorage:
    storageClass: longhorn
    size: 2Gi

  # Monitoring
  monitoring:
    enablePodMonitor: false   # Enable when Prometheus is installed

  # Affinity (not needed for single-node, but good practice)
  affinity:
    topologyKey: kubernetes.io/hostname
EOF
```

### Create the application credentials secret:

```bash
# Generate a strong password
APP_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)
echo "Generated password: $APP_PASSWORD"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: dev-postgres-app-credentials
  namespace: databases
type: kubernetes.io/basic-auth
stringData:
  username: appuser
  password: "${APP_PASSWORD}"
EOF
```

> **IMPORTANT**: In production, store this password in Vault and reference it from
> there. For now we create it directly for simplicity.

### Wait for the cluster to be ready:

```bash
# Watch the cluster come up
kubectl get cluster -n databases -w

# Expected progression:
# NAME           INSTANCES   READY   STATUS                     AGE
# dev-postgres   1           0       Setting up primary          10s
# dev-postgres   1           0       Creating primary instance   30s
# dev-postgres   1           1       Cluster in healthy state    90s

# Check the pod
kubectl get pods -n databases -l cnpg.io/cluster=dev-postgres

# Expected:
# NAME              READY   STATUS    RESTARTS   AGE
# dev-postgres-1    1/1     Running   0          2m
```

---

## Step 3: Set Up Connection Pooling with PgBouncer

Connection pooling is critical for microservices. Without it, each pod would open
its own connections, quickly exhausting PostgreSQL's `max_connections`. PgBouncer
sits between your app and PostgreSQL, multiplexing many client connections onto
fewer database connections.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: dev-postgres-pooler
  namespace: databases
spec:
  # Reference the cluster
  cluster:
    name: dev-postgres

  # PgBouncer configuration
  instances: 1
  type: rw      # Read-write pooler (connects to primary)

  pgbouncer:
    poolMode: transaction    # Best for microservices
    parameters:
      max_client_conn: "100"
      default_pool_size: "10"
      min_pool_size: "2"
      reserve_pool_size: "5"
      reserve_pool_timeout: "3"
      server_idle_timeout: "300"
      log_connections: "1"
      log_disconnections: "1"

  template:
    metadata:
      labels:
        app: pgbouncer
    spec:
      containers:
        - name: pgbouncer
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              memory: 64Mi
EOF
```

### Verify the pooler:

```bash
# PgBouncer pod should be Running
kubectl get pods -n databases -l cnpg.io/poolerName=dev-postgres-pooler

# Check the pooler service
kubectl get svc -n databases | grep pooler

# Expected:
# dev-postgres-pooler-rw   ClusterIP   10.43.x.x   <none>   5432/TCP
```

---

## Step 4: Verify Database Connectivity

### Connect from inside the cluster:

```bash
# Get the connection credentials
# The operator creates secrets automatically with the naming convention:
# <cluster-name>-app for application credentials
# <cluster-name>-superuser for superuser credentials

# Show the auto-generated secrets
kubectl get secrets -n databases | grep dev-postgres

# Get the application connection string
kubectl get secret dev-postgres-app -n databases \
  -o jsonpath='{.data.uri}' | base64 -d
echo ""

# Get the superuser connection string
kubectl get secret dev-postgres-superuser -n databases \
  -o jsonpath='{.data.uri}' | base64 -d
echo ""

# Test connectivity with a temporary pod
kubectl run pg-test -n databases --rm -it \
  --image=postgres:16 \
  --restart=Never \
  --env="PGPASSWORD=$(kubectl get secret dev-postgres-app -n databases -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql -h dev-postgres-pooler-rw -U appuser -d appdb -c "
    SELECT version();
    \l
    SELECT current_database(), current_user, inet_server_addr();
  "
```

### Verify all databases were created:

```bash
kubectl run pg-dbcheck -n databases --rm -it \
  --image=postgres:16 \
  --restart=Never \
  --env="PGPASSWORD=$(kubectl get secret dev-postgres-superuser -n databases -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql -h dev-postgres-rw -U postgres -c "\l"

# Expected databases:
# appdb          (default application database)
# userservice    (for user-service microservice)
# orderservice   (for order-service microservice)
# postgres       (system database)
# template0/1    (PostgreSQL templates)
```

---

## Step 5: Create Service-Specific Users

For security, each microservice should have its own database user with access only
to its own database.

```bash
kubectl run pg-setup -n databases --rm -it \
  --image=postgres:16 \
  --restart=Never \
  --env="PGPASSWORD=$(kubectl get secret dev-postgres-superuser -n databases -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql -h dev-postgres-rw -U postgres <<'EOSQL'

-- Create service-specific users
CREATE USER user_svc_user WITH PASSWORD 'user-svc-change-me-123';
CREATE USER order_svc_user WITH PASSWORD 'order-svc-change-me-123';

-- Grant database access (each user only sees their own database)
GRANT ALL PRIVILEGES ON DATABASE userservice TO user_svc_user;
GRANT ALL PRIVILEGES ON DATABASE orderservice TO order_svc_user;

-- Connect to each database and grant schema privileges
\c userservice
GRANT ALL ON SCHEMA public TO user_svc_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO user_svc_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO user_svc_user;

\c orderservice
GRANT ALL ON SCHEMA public TO order_svc_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO order_svc_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO order_svc_user;

EOSQL
```

### Store credentials in Kubernetes secrets:

```bash
# user-service credentials
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: user-service-db-credentials
  namespace: default
type: Opaque
stringData:
  DB_HOST: dev-postgres-pooler-rw.databases.svc.cluster.local
  DB_PORT: "5432"
  DB_NAME: userservice
  DB_USER: user_svc_user
  DB_PASSWORD: "user-svc-change-me-123"
  DATABASE_URL: "postgresql://user_svc_user:user-svc-change-me-123@dev-postgres-pooler-rw.databases.svc.cluster.local:5432/userservice?sslmode=require"
EOF

# order-service credentials
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: order-service-db-credentials
  namespace: default
type: Opaque
stringData:
  DB_HOST: dev-postgres-pooler-rw.databases.svc.cluster.local
  DB_PORT: "5432"
  DB_NAME: orderservice
  DB_USER: order_svc_user
  DB_PASSWORD: "order-svc-change-me-123"
  DATABASE_URL: "postgresql://order_svc_user:order-svc-change-me-123@dev-postgres-pooler-rw.databases.svc.cluster.local:5432/orderservice?sslmode=require"
EOF
```

> **NOTE**: In a production setup, these credentials should come from Vault using
> the Vault CSI provider or the Vault Agent sidecar. We use plain Secrets here for
> clarity.

---

## Step 6: Configure Automated Backups

### Option A: Backup to S3 (Recommended for production)

```bash
# Create S3 credentials secret (use your AWS credentials)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: s3-backup-credentials
  namespace: databases
type: Opaque
stringData:
  ACCESS_KEY_ID: "your-aws-access-key"         # <-- REPLACE
  ACCESS_SECRET_KEY: "your-aws-secret-key"     # <-- REPLACE
EOF

# Update the cluster with backup configuration
kubectl patch cluster dev-postgres -n databases --type merge -p '
spec:
  backup:
    barmanObjectStore:
      destinationPath: "s3://your-backup-bucket/cnpg/dev-postgres"
      s3Credentials:
        accessKeyId:
          name: s3-backup-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-backup-credentials
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
        maxParallel: 2
      data:
        compression: gzip
    retentionPolicy: "7d"
'
```

### Create a scheduled backup:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: dev-postgres-daily-backup
  namespace: databases
spec:
  # Every day at 2 AM UTC
  schedule: "0 2 * * *"
  backupOwnerReference: self
  cluster:
    name: dev-postgres
  immediate: true    # Take a backup right now too
EOF
```

### Option B: Backup to Longhorn volume (Simpler for dev)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: dev-postgres-manual-backup
  namespace: databases
spec:
  method: volumeSnapshot
  cluster:
    name: dev-postgres
EOF
```

### Check backup status:

```bash
# List backups
kubectl get backups -n databases

# Check scheduled backups
kubectl get scheduledbackups -n databases

# Describe a backup for details
kubectl describe backup dev-postgres-manual-backup -n databases
```

---

## Step 7: Monitoring Integration (Prometheus Metrics)

CloudNativePG exposes PostgreSQL metrics on port 9187. When you install Prometheus
(separate guide), enable the PodMonitor:

```bash
# For now, check metrics are being exposed
kubectl run metrics-test -n databases --rm -it \
  --image=curlimages/curl:latest \
  --restart=Never \
  -- curl -s dev-postgres-1.dev-postgres-any.databases.svc.cluster.local:9187/metrics | head -20

# You should see lines like:
# cnpg_collector_up 1
# cnpg_pg_database_size_bytes{datname="appdb"} ...
# cnpg_pg_stat_activity_count{...} ...
```

### Key metrics to monitor later:

| Metric | What It Tells You |
|--------|-------------------|
| `cnpg_pg_database_size_bytes` | Database size (watch for growth) |
| `cnpg_pg_stat_activity_count` | Active connections |
| `cnpg_pg_replication_lag` | Replication lag (when using replicas) |
| `cnpg_pg_stat_bgwriter_buffers_checkpoint` | Checkpoint activity |
| `cnpg_backends_total` | Total backend connections |

---

## Step 8: Test Application Connectivity Pattern

This is how your microservices will connect to PostgreSQL in practice:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-connection-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db-connection-test
  template:
    metadata:
      labels:
        app: db-connection-test
    spec:
      containers:
        - name: test
          image: postgres:16
          command:
            - sh
            - -c
            - |
              echo "Testing database connectivity..."
              echo "Connecting to: $DB_HOST:$DB_PORT/$DB_NAME as $DB_USER"
              PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "
                SELECT 'Connection successful!' AS status;
                SELECT current_database() AS database, current_user AS user;
                CREATE TABLE IF NOT EXISTS health_check (
                  id SERIAL PRIMARY KEY,
                  checked_at TIMESTAMP DEFAULT NOW()
                );
                INSERT INTO health_check DEFAULT VALUES;
                SELECT * FROM health_check ORDER BY id DESC LIMIT 5;
              "
              echo "Test complete. Sleeping..."
              sleep 3600
          env:
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: user-service-db-credentials
                  key: DB_HOST
            - name: DB_PORT
              valueFrom:
                secretKeyRef:
                  name: user-service-db-credentials
                  key: DB_PORT
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: user-service-db-credentials
                  key: DB_NAME
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: user-service-db-credentials
                  key: DB_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: user-service-db-credentials
                  key: DB_PASSWORD
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
  restartPolicy: Always
EOF

# Check the test passed
kubectl logs -f deployment/db-connection-test -n default

# Clean up
kubectl delete deployment db-connection-test -n default
```

---

## Verify

```bash
#!/bin/bash
echo "=== CloudNativePG Verification ==="

echo ""
echo "--- Operator Pod ---"
kubectl get pods -n postgres-operator
echo ""

echo "--- CRDs ---"
kubectl get crds | grep cnpg
echo ""

echo "--- PostgreSQL Clusters ---"
kubectl get clusters -n databases
echo ""

echo "--- Cluster Pods ---"
kubectl get pods -n databases -l cnpg.io/cluster=dev-postgres
echo ""

echo "--- PgBouncer Pooler ---"
kubectl get poolers -n databases
kubectl get pods -n databases -l cnpg.io/poolerName=dev-postgres-pooler
echo ""

echo "--- Services ---"
kubectl get svc -n databases
echo ""

echo "--- PVCs ---"
kubectl get pvc -n databases
echo ""

echo "--- Cluster Status ---"
kubectl get cluster dev-postgres -n databases \
  -o jsonpath='
  Instances: {.spec.instances}
  Ready:     {.status.readyInstances}
  Phase:     {.status.phase}
  Primary:   {.status.currentPrimary}
'
echo ""
echo ""

echo "--- Databases ---"
kubectl get secret dev-postgres-superuser -n databases \
  -o jsonpath='{.data.password}' | base64 -d > /tmp/pgpass 2>/dev/null
echo "Superuser secret exists: $(kubectl get secret dev-postgres-superuser -n databases -o name 2>/dev/null && echo Yes || echo No)"
echo ""

echo "--- Backups ---"
kubectl get backups -n databases 2>/dev/null || echo "No backups configured"
kubectl get scheduledbackups -n databases 2>/dev/null || echo "No scheduled backups"
echo ""

echo "--- Resource Usage ---"
kubectl top pods -n postgres-operator 2>/dev/null || \
  echo "Metrics server not available"
kubectl top pods -n databases 2>/dev/null || true
echo ""

echo "=== Verification Complete ==="
```

---

## Troubleshooting

### Cluster stuck in "Setting up primary"

```bash
# Check the operator logs
kubectl logs -n postgres-operator -l app.kubernetes.io/name=cloudnative-pg --tail=50

# Check the PostgreSQL pod events
kubectl describe pod dev-postgres-1 -n databases

# Common cause: PVC not binding (Longhorn issue)
kubectl get pvc -n databases
kubectl describe pvc dev-postgres-1 -n databases
```

### Cannot connect to database

```bash
# Check the cluster is in healthy state
kubectl get cluster dev-postgres -n databases -o jsonpath='{.status.phase}'
# Should output: Cluster in healthy state

# Check services exist
kubectl get svc -n databases

# Connection endpoints:
# dev-postgres-rw          -> Primary (read-write)
# dev-postgres-ro          -> Replicas (read-only, only with instances > 1)
# dev-postgres-r           -> Any instance
# dev-postgres-pooler-rw   -> PgBouncer (read-write)

# Test DNS resolution
kubectl run dns-test --rm -it --image=busybox --restart=Never -- \
  nslookup dev-postgres-rw.databases.svc.cluster.local

# Check pg_hba allows your pod's IP range
kubectl get cluster dev-postgres -n databases \
  -o jsonpath='{.spec.postgresql.pg_hba}' | jq .
```

### Common errors and fixes:

| Error | Cause | Fix |
|-------|-------|-----|
| `FATAL: password authentication failed` | Wrong credentials | Check `kubectl get secret dev-postgres-app -n databases` |
| `FATAL: no pg_hba.conf entry for host` | Pod IP not in allowed range | Add CIDR to `spec.postgresql.pg_hba` |
| PVC stuck in Pending | Longhorn capacity or node affinity | `kubectl describe pvc` and check Longhorn dashboard |
| `OOMKilled` | PostgreSQL needs more memory | Increase `resources.limits.memory` |
| Backup failed | S3 credentials or bucket permissions | Check `kubectl describe backup` and verify IAM role |
| Pooler not connecting | Cluster not healthy | Fix the cluster first, pooler reconnects automatically |

### Useful operator commands:

```bash
# Check cluster status in detail
kubectl cnpg status dev-postgres -n databases 2>/dev/null || \
  kubectl get cluster dev-postgres -n databases -o yaml | grep -A 20 "status:"

# Promote a replica to primary (for HA clusters with instances > 1)
# kubectl cnpg promote dev-postgres dev-postgres-2 -n databases

# Restart PostgreSQL (rolling restart)
kubectl cnpg restart dev-postgres -n databases 2>/dev/null || \
  kubectl rollout restart cluster/dev-postgres -n databases

# Get PostgreSQL logs
kubectl logs dev-postgres-1 -n databases --tail=50

# Connect directly using the cnpg plugin
# Install: curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.25.0/kubectl-cnpg_1.25.0_linux_x86_64.tar.gz | tar xz -C /usr/local/bin
# kubectl cnpg psql dev-postgres -n databases
```

---

## Clean Up Test Resources

```bash
# Remove test secrets (keep the cluster and pooler)
kubectl delete secret user-service-db-credentials -n default 2>/dev/null
kubectl delete secret order-service-db-credentials -n default 2>/dev/null

# To remove EVERYTHING (including data):
# kubectl delete cluster dev-postgres -n databases
# kubectl delete namespace databases
# helm uninstall cnpg -n postgres-operator
# kubectl delete namespace postgres-operator
```

---

## Checklist

- [ ] CloudNativePG operator Helm chart installed in `postgres-operator` namespace
- [ ] Operator pod running
- [ ] CRDs installed (clusters, backups, poolers, scheduledbackups)
- [ ] PostgreSQL cluster `dev-postgres` in healthy state
- [ ] Databases created: appdb, userservice, orderservice
- [ ] Application user (`appuser`) with proper grants
- [ ] Service-specific users created (user_svc_user, order_svc_user)
- [ ] PgBouncer pooler running and accessible
- [ ] PVCs bound on Longhorn storage (data + WAL)
- [ ] Connection from test pod successful through PgBouncer
- [ ] Database credentials stored as Kubernetes Secrets
- [ ] (Optional) Automated backups configured to S3
- [ ] (Optional) Prometheus metrics exposed on port 9187
- [ ] Operator memory under 150MB, PostgreSQL instance under 256MB

---

## What's Next?

With PostgreSQL running in your cluster via CloudNativePG, you have a complete
data layer for your microservices. Each service connects through PgBouncer for
efficient connection pooling.

Next steps in the project:

- **Vault Integration**: Store database credentials in Vault instead of plain Secrets
- **Schema Migrations**: Use Flyway or golang-migrate in your CI/CD pipeline
- **Monitoring**: Enable PodMonitor when Prometheus is installed, set up alerts for
  connection count, replication lag, and disk usage
- **Scaling Up**: When ready, increase `instances: 3` for automatic high availability
  with synchronous replication

> **Architecture so far**: Requests arrive at Envoy Gateway (Guide 13) with TLS
> from cert-manager (Guide 12), get routed to microservices whose container images
> are stored in Harbor (Guide 14), and the microservices read/write data to
> PostgreSQL managed by CloudNativePG (this guide). The entire stack runs on a
> single EC2 t3.large for under $45/month.
