# 22 — Backup & Disaster Recovery with Velero

## Why This Matters

Without backups, a single `kubectl delete namespace apps` or a corrupted etcd database
means you lose everything -- Deployments, ConfigMaps, Secrets, PVCs. Rebuilding from
scratch takes hours.

Velero gives you:
- **Scheduled backups** of all Kubernetes resources (YAML definitions + persistent volumes)
- **One-command disaster recovery** -- restore an entire namespace in minutes
- **Migration** -- move workloads between clusters
- **Pre-upgrade safety net** -- backup before risky changes, rollback if things break

Resource usage: ~200MB RAM, minimal CPU.

---

## Prerequisites

- k3s cluster running
- Helm installed
- AWS CLI configured
- S3 bucket for backups (we will create one)
- IAM credentials for Velero to access S3
- Longhorn installed (guide 13) if using volume snapshots

---

## Step 1: Create S3 Bucket for Backups

```bash
# Set variables
export VELERO_BUCKET="devops-zero-to-hero-velero-backups"
export AWS_REGION="us-east-1"

# Create the S3 bucket
aws s3api create-bucket \
  --bucket ${VELERO_BUCKET} \
  --region ${AWS_REGION}

# Enable versioning (so backup files can be recovered if accidentally deleted)
aws s3api put-bucket-versioning \
  --bucket ${VELERO_BUCKET} \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket ${VELERO_BUCKET} \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }
    ]
  }'

# Block all public access
aws s3api put-public-access-block \
  --bucket ${VELERO_BUCKET} \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Add lifecycle rule: delete backups older than 30 days
aws s3api put-bucket-lifecycle-configuration \
  --bucket ${VELERO_BUCKET} \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "DeleteOldBackups",
        "Status": "Enabled",
        "Filter": {
          "Prefix": "backups/"
        },
        "Expiration": {
          "Days": 30
        },
        "NoncurrentVersionExpiration": {
          "NoncurrentDays": 7
        }
      }
    ]
  }'
```

---

## Step 2: Create IAM Policy and User for Velero

```bash
# Create the IAM policy
cat > /tmp/velero-iam-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::devops-zero-to-hero-velero-backups/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::devops-zero-to-hero-velero-backups"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name VeleroBackupPolicy \
  --policy-document file:///tmp/velero-iam-policy.json

# Create IAM user for Velero
aws iam create-user --user-name velero-backup

# Attach the policy
aws iam attach-user-policy \
  --user-name velero-backup \
  --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/VeleroBackupPolicy

# Create access keys
aws iam create-access-key --user-name velero-backup > /tmp/velero-keys.json

# Extract keys (save these securely)
export VELERO_ACCESS_KEY=$(jq -r '.AccessKey.AccessKeyId' /tmp/velero-keys.json)
export VELERO_SECRET_KEY=$(jq -r '.AccessKey.SecretAccessKey' /tmp/velero-keys.json)
echo "Access Key: ${VELERO_ACCESS_KEY}"
echo "Secret Key: ${VELERO_SECRET_KEY}"

# IMPORTANT: Delete the temp file with keys
rm -f /tmp/velero-keys.json
```

---

## Step 3: Install Velero with Helm

```bash
# Create credentials file for Velero
cat > /tmp/velero-credentials <<EOF
[default]
aws_access_key_id=${VELERO_ACCESS_KEY}
aws_secret_access_key=${VELERO_SECRET_KEY}
EOF

# Create namespace
kubectl create namespace velero

# Create the secret
kubectl create secret generic velero-credentials \
  --namespace velero \
  --from-file=cloud=/tmp/velero-credentials

# Delete the temp credentials file
rm -f /tmp/velero-credentials

# Add Helm repo
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update
```

### Install Velero:

Save as `velero-values.yaml`:

```yaml
# velero-values.yaml
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.10.1
    volumeMounts:
      - mountPath: /target
        name: plugins

configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: devops-zero-to-hero-velero-backups
      prefix: backups
      config:
        region: us-east-1

  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: us-east-1

  # Default backup TTL (how long to keep backups)
  defaultBackupTTL: "720h"  # 30 days

  # Features
  features: "EnableCSI"

credentials:
  existingSecret: velero-credentials

# Resource limits for t3.large budget
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi

# Deploy metrics for Prometheus scraping
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    namespace: velero

# Backup schedules
schedules:
  # Daily backup of apps namespace at 2:00 AM UTC
  daily-apps-backup:
    disabled: false
    schedule: "0 2 * * *"
    useOwnerReferencesInBackup: false
    template:
      ttl: "168h"  # Keep for 7 days
      includedNamespaces:
        - apps
      includedResources:
        - deployments
        - services
        - configmaps
        - secrets
        - ingresses
        - persistentvolumeclaims
        - persistentvolumes
      snapshotVolumes: true
      storageLocation: default
      volumeSnapshotLocations:
        - default

  # Daily backup of monitoring stack
  daily-monitoring-backup:
    disabled: false
    schedule: "0 3 * * *"
    useOwnerReferencesInBackup: false
    template:
      ttl: "168h"
      includedNamespaces:
        - monitoring
      snapshotVolumes: false
      storageLocation: default

  # Weekly full cluster backup (Saturday 1:00 AM UTC)
  weekly-full-backup:
    disabled: false
    schedule: "0 1 * * 6"
    useOwnerReferencesInBackup: false
    template:
      ttl: "720h"  # Keep for 30 days
      includedNamespaces:
        - apps
        - monitoring
        - argocd
        - staging
      snapshotVolumes: true
      storageLocation: default
      volumeSnapshotLocations:
        - default
```

```bash
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --version 7.2.1 \
  --values velero-values.yaml
```

---

## Step 4: Install Velero CLI

The Velero CLI makes managing backups much easier than using kubectl.

```bash
# macOS
brew install velero

# Verify
velero version
# Client: v1.14.x
# Server: v1.14.x
```

---

## Step 5: Manual Backup Operations

### Create an on-demand backup:

```bash
# Backup the entire apps namespace
velero backup create apps-manual-backup \
  --include-namespaces apps \
  --snapshot-volumes=true \
  --wait

# Check backup status
velero backup describe apps-manual-backup
velero backup logs apps-manual-backup
```

### Backup specific resources:

```bash
# Backup only Deployments and Services
velero backup create apps-deployments-only \
  --include-namespaces apps \
  --include-resources deployments,services \
  --wait

# Backup by label selector
velero backup create api-gateway-backup \
  --include-namespaces apps \
  --selector app=api-gateway \
  --wait
```

### List and inspect backups:

```bash
# List all backups
velero backup get

# Describe a specific backup
velero backup describe apps-manual-backup --details

# Check what's in a backup
velero backup describe apps-manual-backup --details | grep -A 20 "Resource List"
```

---

## Step 6: Disaster Recovery Practice

This is the most important part. You must practice restoring before you need it.

### Scenario: Entire namespace deleted

```bash
# STEP 1: Verify current state
kubectl get all -n apps
# You should see your deployments, pods, services

# STEP 2: Create a fresh backup before the test
velero backup create pre-dr-test-backup \
  --include-namespaces apps \
  --snapshot-volumes=true \
  --wait

# Verify backup completed
velero backup describe pre-dr-test-backup

# STEP 3: Simulate disaster -- delete the namespace
kubectl delete namespace apps
# WARNING: This deletes EVERYTHING in the namespace

# Verify it's gone
kubectl get namespace apps
# Error: namespace "apps" not found

# STEP 4: Restore from backup
velero restore create apps-restore \
  --from-backup pre-dr-test-backup \
  --wait

# STEP 5: Verify restoration
kubectl get all -n apps
# All your deployments, services, pods should be back

# Check restore details
velero restore describe apps-restore
velero restore logs apps-restore
```

### Scenario: Restore a single resource

```bash
# Restore only the api-gateway deployment
velero restore create restore-api-gateway \
  --from-backup apps-manual-backup \
  --include-resources deployments \
  --selector app=api-gateway \
  --wait
```

### Scenario: Restore to a different namespace

```bash
# Restore apps namespace content into apps-staging
velero restore create restore-to-staging \
  --from-backup apps-manual-backup \
  --namespace-mappings apps:apps-staging \
  --wait
```

---

## Step 7: Volume Snapshots with Longhorn Integration

If you use Longhorn for persistent storage, Velero can take volume snapshots.

### Configure Longhorn as the CSI snapshot provider:

Save as `velero-longhorn-config.yaml`:

```yaml
# velero-longhorn-config.yaml
# VolumeSnapshotClass for Longhorn CSI
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot-class
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
```

```bash
kubectl apply -f velero-longhorn-config.yaml
```

### Backup with volume snapshots:

```bash
# Backup PVCs with Longhorn snapshots
velero backup create apps-with-volumes \
  --include-namespaces apps \
  --snapshot-volumes=true \
  --csi-snapshot-timeout=10m \
  --wait

# Check volume snapshot status
kubectl get volumesnapshots -n apps
kubectl get volumesnapshotcontents
```

---

## Step 8: Backup Retention Policies

Velero handles retention through TTL (Time To Live) on each backup.

### Retention strategy:

| Backup Type | Schedule | TTL | Purpose |
|------------|----------|-----|---------|
| Daily apps | 2:00 AM UTC | 7 days | Quick recovery from recent issues |
| Daily monitoring | 3:00 AM UTC | 7 days | Recover dashboards and alerts |
| Weekly full | Saturday 1:00 AM | 30 days | Longer-term recovery point |
| Pre-deploy | Before each deploy | 24 hours | Rollback failed deployments |

### Create a pre-deployment backup script:

Save as `scripts/pre-deploy-backup.sh`:

```bash
#!/bin/bash
# pre-deploy-backup.sh
# Run this before deploying to create a restore point

set -euo pipefail

NAMESPACE="${1:-apps}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="pre-deploy-${NAMESPACE}-${TIMESTAMP}"

echo "Creating pre-deployment backup: ${BACKUP_NAME}"

velero backup create "${BACKUP_NAME}" \
  --include-namespaces "${NAMESPACE}" \
  --snapshot-volumes=true \
  --ttl 24h \
  --wait

STATUS=$(velero backup get "${BACKUP_NAME}" -o json | jq -r '.status.phase')

if [ "${STATUS}" = "Completed" ]; then
  echo "Backup ${BACKUP_NAME} completed successfully"
  echo "To restore: velero restore create --from-backup ${BACKUP_NAME}"
else
  echo "ERROR: Backup ${BACKUP_NAME} failed with status: ${STATUS}"
  velero backup logs "${BACKUP_NAME}"
  exit 1
fi
```

```bash
chmod +x scripts/pre-deploy-backup.sh
```

### Manually clean up old backups:

```bash
# List all backups sorted by creation time
velero backup get --output json | \
  jq -r '.items | sort_by(.metadata.creationTimestamp) | .[] |
    [.metadata.name, .status.phase, .metadata.creationTimestamp] | @tsv'

# Delete a specific backup
velero backup delete old-backup-name --confirm

# Delete all backups older than 7 days
velero backup get --output json | \
  jq -r '.items[] | select(
    (.metadata.creationTimestamp | fromdateiso8601) < (now - 604800)
  ) | .metadata.name' | \
  xargs -I{} velero backup delete {} --confirm
```

---

## Verify

```bash
# 1. Velero server is running
kubectl get pods -n velero
# NAME                     READY   STATUS    RESTARTS   AGE
# velero-xxx               1/1     Running   0          5m

# 2. Backup storage location is available
velero backup-location get
# NAME      PROVIDER   BUCKET/PREFIX                                    PHASE       LAST VALIDATED
# default   aws        devops-zero-to-hero-velero-backups/backups       Available   2024-01-01 00:00:00

# 3. Scheduled backups are configured
velero schedule get
# NAME                       STATUS    CREATED                         SCHEDULE      BACKUP TTL
# daily-apps-backup          Enabled   2024-01-01 00:00:00 +0000 UTC  0 2 * * *     168h0m0s
# daily-monitoring-backup    Enabled   2024-01-01 00:00:00 +0000 UTC  0 3 * * *     168h0m0s
# weekly-full-backup         Enabled   2024-01-01 00:00:00 +0000 UTC  0 1 * * 6     720h0m0s

# 4. Create a test backup and verify it works
velero backup create test-verify --include-namespaces default --wait
velero backup describe test-verify
# Phase: Completed

# 5. Check S3 bucket has data
aws s3 ls s3://devops-zero-to-hero-velero-backups/backups/ --recursive | head -10

# 6. Clean up test backup
velero backup delete test-verify --confirm
```

---

## Troubleshooting

### Backup stuck in "InProgress"

```bash
# Check Velero logs
kubectl logs -n velero deploy/velero --tail=50

# Common causes:
# 1. S3 credentials expired or wrong
kubectl get secret velero-credentials -n velero -o jsonpath='{.data.cloud}' | base64 -d

# 2. S3 bucket doesn't exist or wrong region
aws s3 ls s3://devops-zero-to-hero-velero-backups/

# 3. Volume snapshot hanging
kubectl get volumesnapshots -A
# Delete stuck snapshots:
kubectl delete volumesnapshot <name> -n <namespace>
```

### "BackupStorageLocation unavailable"

```bash
# Check the BSL status
velero backup-location get
kubectl describe backupstoragelocation default -n velero

# Fix: verify S3 access
aws s3 ls s3://devops-zero-to-hero-velero-backups/ --region us-east-1

# If bucket policy changed, recreate the secret:
kubectl delete secret velero-credentials -n velero
kubectl create secret generic velero-credentials \
  --namespace velero \
  --from-file=cloud=/tmp/velero-credentials
kubectl rollout restart deploy/velero -n velero
```

### Restore fails with "already exists"

```bash
# Use --existing-resource-policy to handle conflicts
velero restore create my-restore \
  --from-backup my-backup \
  --existing-resource-policy update \
  --wait

# Or restore only specific resources
velero restore create my-restore \
  --from-backup my-backup \
  --include-resources deployments,services \
  --wait
```

### High memory usage

```bash
# Check current resource usage
kubectl top pod -n velero

# Reduce memory with smaller batch sizes (add to values.yaml)
# configuration:
#   uploaderType: kopia
# Then upgrade:
helm upgrade velero vmware-tanzu/velero \
  --namespace velero \
  --values velero-values.yaml \
  --reuse-values
```

---

## Checklist

- [ ] S3 bucket created with versioning, encryption, and lifecycle rules
- [ ] IAM user created with scoped permissions for Velero
- [ ] Velero Helm chart installed in velero namespace
- [ ] Velero CLI installed and can communicate with server
- [ ] BackupStorageLocation shows "Available"
- [ ] Daily apps backup schedule created (2:00 AM UTC, 7-day TTL)
- [ ] Daily monitoring backup schedule created (3:00 AM UTC, 7-day TTL)
- [ ] Weekly full backup schedule created (Saturday 1:00 AM, 30-day TTL)
- [ ] Manual backup tested and completed successfully
- [ ] Disaster recovery practiced: delete namespace then restore
- [ ] Restore verified: all resources came back correctly
- [ ] Volume snapshots configured with Longhorn (if using PVCs)
- [ ] Pre-deployment backup script saved and executable
- [ ] S3 bucket lifecycle deletes backups older than 30 days

---

## What's Next?

You now have a safety net for your cluster. Key workflows to remember:
- **Before risky changes**: `./scripts/pre-deploy-backup.sh apps`
- **After disaster**: `velero restore create --from-backup <latest-backup>`
- **Before cluster upgrades**: Full backup of all namespaces

Next: **Guide 23 -- Dex SSO Setup** for centralized authentication, so multiple
team members can securely access ArgoCD, Grafana, and other tools.
