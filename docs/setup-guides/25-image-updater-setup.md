# 25 — ArgoCD Image Updater Setup

## Why This Matters

After Guide 24, your CI pipeline builds, scans, signs, and pushes images to ECR.
ArgoCD watches your Git repository and syncs changes to the cluster.
But there is a gap: **who updates the Git repository when a new image lands in ECR?**

Without ArgoCD Image Updater, you need a manual step or a custom script to:
1. Detect that a new image was pushed
2. Update the image tag in your GitOps overlay
3. Commit and push the change
4. Wait for ArgoCD to sync

ArgoCD Image Updater automates this. It polls your ECR repositories, detects new images,
and either writes back to Git or updates ArgoCD directly.

```
CI Pipeline                  ArgoCD Image Updater              ArgoCD
──────────                  ────────────────────              ──────
Build image ──> Push to ECR ──> Detects new image ──> Updates Git ──> Syncs to cluster
```

This closes the CI/CD loop completely. A commit to your service code triggers a fully
automated pipeline from source to production.

Resource usage: ~100MB RAM.

---

## Prerequisites

- ArgoCD installed and managing applications (guide 08)
- ECR repositories with images (guide 24)
- GitOps repository structure with Kustomize overlays
- AWS OIDC or IAM access for Image Updater to pull from ECR
- Git write access (deploy key or GitHub App) for write-back

---

## Step 1: Install ArgoCD Image Updater

### Option A: Helm install (standalone)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace argocd-image-updater 2>/dev/null || true
```

Save as `image-updater-values.yaml`:

```yaml
# image-updater-values.yaml

# Resource limits for t3.large budget
resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    memory: 128Mi

# Configure image registries
config:
  # ArgoCD API server connection
  argocd:
    serverAddress: argocd-server.argocd.svc.cluster.local
    insecure: true   # Within cluster, TLS is not needed
    plaintext: false

  # Registry configuration
  registries:
    - name: ECR
      api_url: https://<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
      prefix: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
      credentials: ext:/scripts/ecr-login.sh
      credsexpire: 10h
      default: true

  # Log level (debug for troubleshooting, info for production)
  logLevel: info

  # Check interval (how often to poll for new images)
  interval: 2m

# Mount the ECR login script
extraVolumes:
  - name: ecr-login
    configMap:
      name: ecr-login-script
      defaultMode: 0755

extraVolumeMounts:
  - name: ecr-login
    mountPath: /scripts

# Service account with AWS access
serviceAccount:
  create: true
  name: argocd-image-updater
  annotations:
    # If using IRSA (IAM Roles for Service Accounts)
    # eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/ImageUpdaterRole
```

### Create the ECR login helper script:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ecr-login-script
  namespace: argocd-image-updater
data:
  ecr-login.sh: |
    #!/bin/sh
    # This script generates ECR credentials for ArgoCD Image Updater.
    # It uses the AWS CLI to get an authorization token.
    aws ecr get-login-password --region us-east-1
EOF
```

### Create AWS credentials secret (for ECR access):

```bash
# Option 1: Static credentials (simpler for learning)
kubectl create secret generic aws-ecr-credentials \
  --namespace argocd-image-updater \
  --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
  --from-literal=AWS_DEFAULT_REGION="us-east-1"

# Option 2: Use a ServiceAccount with IRSA (production best practice on EKS)
# For k3s, Option 1 is simpler since IRSA requires EKS
```

### Update the Helm values to mount AWS credentials:

Add to `image-updater-values.yaml`:

```yaml
# Add AWS credentials as environment variables
extraEnv:
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: aws-ecr-credentials
        key: AWS_ACCESS_KEY_ID
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: aws-ecr-credentials
        key: AWS_SECRET_ACCESS_KEY
  - name: AWS_DEFAULT_REGION
    valueFrom:
      secretKeyRef:
        name: aws-ecr-credentials
        key: AWS_DEFAULT_REGION
```

### Install:

```bash
helm install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd-image-updater \
  --version 0.11.0 \
  --values image-updater-values.yaml
```

### Option B: Install as ArgoCD addon (in argocd namespace)

If you prefer to run Image Updater in the same namespace as ArgoCD:

```bash
helm install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --version 0.11.0 \
  --values image-updater-values.yaml \
  --set config.argocd.serverAddress=argocd-server.argocd.svc.cluster.local
```

---

## Step 2: Configure Git Write-Back

Image Updater needs to write image tag changes back to your Git repository.
There are two methods:

### Method 1: Git write-back (recommended)

Image Updater commits the new image tag to your Git repository.
ArgoCD then detects the Git change and syncs.

**Create a GitHub deploy key** (with write access):

```bash
# Generate an SSH key pair for Image Updater
ssh-keygen -t ed25519 -C "argocd-image-updater" -f /tmp/image-updater-key -N ""

# Add the PUBLIC key as a deploy key to your GitHub repo (with write access)
gh repo deploy-key add /tmp/image-updater-key.pub \
  --repo guyellkayam/devops-zero-to-hero \
  --title "ArgoCD Image Updater" \
  --allow-write

# Store the PRIVATE key as a Kubernetes secret
kubectl create secret generic git-write-back-key \
  --namespace argocd-image-updater \
  --from-file=sshPrivateKey=/tmp/image-updater-key

# Clean up the local key files
rm -f /tmp/image-updater-key /tmp/image-updater-key.pub
```

### Method 2: ArgoCD parameter write-back

Instead of committing to Git, Image Updater updates the ArgoCD Application
resource directly with a parameter override. No Git access needed, but changes
are not persisted in Git (lost if the Application is recreated).

```yaml
# In the ArgoCD Application annotation:
argocd-image-updater.argoproj.io/write-back-method: argocd
```

**We will use Method 1 (Git)** for this guide because it provides a full audit trail
and survives ArgoCD Application recreation.

---

## Step 3: Configure ArgoCD Applications with Image Updater Annotations

Image Updater is configured through **annotations on ArgoCD Application resources**.
No separate configuration files needed.

### api-gateway Application:

Save as `gitops/applications/api-gateway.yaml`:

```yaml
# gitops/applications/api-gateway.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-gateway
  namespace: argocd
  annotations:
    # ── Image Updater Configuration ──

    # Which images to watch (comma-separated for multiple)
    argocd-image-updater.argoproj.io/image-list: >-
      api-gateway=<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway

    # Update strategy: use the latest semantic version tag
    argocd-image-updater.argoproj.io/api-gateway.update-strategy: semver

    # Constraint: only pick up tags matching a semver pattern
    argocd-image-updater.argoproj.io/api-gateway.allow-tags: "regexp:^v?[0-9]+\\.[0-9]+\\.[0-9]+$"

    # Alternatively: use the most recently pushed image (by date)
    # argocd-image-updater.argoproj.io/api-gateway.update-strategy: newest-build
    # argocd-image-updater.argoproj.io/api-gateway.allow-tags: "regexp:^sha-[a-f0-9]{7}$"

    # Write-back: commit to Git
    argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd-image-updater/git-write-back-key
    argocd-image-updater.argoproj.io/write-back-target: kustomization
    argocd-image-updater.argoproj.io/git-branch: main

spec:
  project: default
  source:
    repoURL: https://github.com/guyellkayam/devops-zero-to-hero.git
    targetRevision: main
    path: gitops/overlays/dev
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

### user-service Application:

Save as `gitops/applications/user-service.yaml`:

```yaml
# gitops/applications/user-service.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: user-service
  namespace: argocd
  annotations:
    argocd-image-updater.argoproj.io/image-list: >-
      user-service=<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/user-service

    argocd-image-updater.argoproj.io/user-service.update-strategy: semver
    argocd-image-updater.argoproj.io/user-service.allow-tags: "regexp:^v?[0-9]+\\.[0-9]+\\.[0-9]+$"

    argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd-image-updater/git-write-back-key
    argocd-image-updater.argoproj.io/write-back-target: kustomization
    argocd-image-updater.argoproj.io/git-branch: main
spec:
  project: default
  source:
    repoURL: https://github.com/guyellkayam/devops-zero-to-hero.git
    targetRevision: main
    path: gitops/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### order-service Application:

Save as `gitops/applications/order-service.yaml`:

```yaml
# gitops/applications/order-service.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: order-service
  namespace: argocd
  annotations:
    argocd-image-updater.argoproj.io/image-list: >-
      order-service=<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/order-service

    argocd-image-updater.argoproj.io/order-service.update-strategy: semver
    argocd-image-updater.argoproj.io/order-service.allow-tags: "regexp:^v?[0-9]+\\.[0-9]+\\.[0-9]+$"

    argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd-image-updater/git-write-back-key
    argocd-image-updater.argoproj.io/write-back-target: kustomization
    argocd-image-updater.argoproj.io/git-branch: main
spec:
  project: default
  source:
    repoURL: https://github.com/guyellkayam/devops-zero-to-hero.git
    targetRevision: main
    path: gitops/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
kubectl apply -f gitops/applications/api-gateway.yaml
kubectl apply -f gitops/applications/user-service.yaml
kubectl apply -f gitops/applications/order-service.yaml
```

---

## Step 4: GitOps Overlay Structure

Image Updater writes changes to your Kustomize overlay. Here is the expected
directory structure:

```
gitops/
  base/
    api-gateway/
      deployment.yaml
      service.yaml
      kustomization.yaml
    user-service/
      deployment.yaml
      service.yaml
      kustomization.yaml
    order-service/
      deployment.yaml
      service.yaml
      kustomization.yaml
  overlays/
    dev/
      kustomization.yaml          # <-- Image Updater writes here
    staging/
      kustomization.yaml
    prod/
      kustomization.yaml
  applications/
    api-gateway.yaml
    user-service.yaml
    order-service.yaml
```

### Base kustomization (example for api-gateway):

Save as `gitops/base/api-gateway/kustomization.yaml`:

```yaml
# gitops/base/api-gateway/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

images:
  - name: api-gateway
    newName: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway
    newTag: latest   # This gets overridden by the overlay
```

### Dev overlay:

Save as `gitops/overlays/dev/kustomization.yaml`:

```yaml
# gitops/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: apps

resources:
  - ../../base/api-gateway
  - ../../base/user-service
  - ../../base/order-service

# Image Updater will add/modify entries here automatically:
images:
  - name: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway
    newTag: v1.0.0
  - name: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/user-service
    newTag: v1.0.0
  - name: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/order-service
    newTag: v1.0.0
```

When Image Updater detects a new `v1.1.0` tag for api-gateway in ECR, it will
automatically update the `newTag` field and commit to Git:

```yaml
images:
  - name: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway
    newTag: v1.1.0    # <-- Updated automatically
```

---

## Step 5: Environment Promotion Flow

This is the full flow from a new image to production:

### Automatic: New image to dev

```
1. Developer pushes code to services/api-gateway/
2. GitHub Actions CI builds, scans, signs image → pushes v1.2.0 to ECR
3. Image Updater detects v1.2.0 in ECR (within 2 minutes)
4. Image Updater updates gitops/overlays/dev/kustomization.yaml
5. Image Updater commits: "chore: update api-gateway to v1.2.0"
6. ArgoCD detects Git change
7. ArgoCD syncs: deploys v1.2.0 to dev namespace
```

### Semi-automatic: Promote dev to staging

For staging, you want human oversight. Create a promotion workflow that opens a PR.

Save as `.github/workflows/promote-to-staging.yml`:

```yaml
# .github/workflows/promote-to-staging.yml
name: Promote to Staging

on:
  workflow_dispatch:
    inputs:
      service:
        description: "Service to promote"
        required: true
        type: choice
        options:
          - api-gateway
          - user-service
          - order-service
          - all
      confirm:
        description: "Type 'promote' to confirm"
        required: true

jobs:
  promote:
    name: Promote to Staging
    runs-on: ubuntu-latest
    if: ${{ github.event.inputs.confirm == 'promote' }}
    steps:
      - uses: actions/checkout@v4

      - name: Get dev image versions
        id: dev-versions
        run: |
          # Extract current dev image tags
          DEV_FILE="gitops/overlays/dev/kustomization.yaml"

          if [ "${{ inputs.service }}" = "all" ]; then
            SERVICES="api-gateway user-service order-service"
          else
            SERVICES="${{ inputs.service }}"
          fi

          for svc in ${SERVICES}; do
            TAG=$(grep -A1 "${svc}" ${DEV_FILE} | grep newTag | awk '{print $2}')
            echo "${svc}_tag=${TAG}" >> $GITHUB_OUTPUT
            echo "${svc}: ${TAG}"
          done

      - name: Update staging overlay
        run: |
          STAGING_FILE="gitops/overlays/staging/kustomization.yaml"
          DEV_FILE="gitops/overlays/dev/kustomization.yaml"

          if [ "${{ inputs.service }}" = "all" ]; then
            # Copy all image tags from dev to staging
            cp ${DEV_FILE} ${STAGING_FILE}
            # Update namespace reference
            sed -i 's/namespace: apps/namespace: staging/' ${STAGING_FILE}
          else
            # Update specific service tag
            DEV_TAG=$(grep -A1 "${{ inputs.service }}" ${DEV_FILE} | grep newTag | awk '{print $2}')
            sed -i "/${{ inputs.service }}/{n;s/newTag: .*/newTag: ${DEV_TAG}/}" ${STAGING_FILE}
          fi

      - name: Create promotion PR
        uses: peter-evans/create-pull-request@v6
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          branch: promote/staging-${{ github.run_number }}
          title: "promote(staging): ${{ inputs.service }} from dev"
          body: |
            ## Promotion to Staging

            **Service**: ${{ inputs.service }}
            **Triggered by**: @${{ github.actor }}

            ### Image Versions (from dev)
            Check the file diff for exact versions being promoted.

            ### Checklist
            - [ ] Dev environment is healthy
            - [ ] No critical alerts in monitoring
            - [ ] Smoke tests passed on dev

            _This PR was created by the promotion workflow._
          labels: |
            promotion
            staging
          reviewers: ${{ github.actor }}
```

### Manual with PR: Promote staging to production

Save as `.github/workflows/promote-to-production.yml`:

```yaml
# .github/workflows/promote-to-production.yml
name: Promote to Production

on:
  workflow_dispatch:
    inputs:
      service:
        description: "Service to promote"
        required: true
        type: choice
        options:
          - api-gateway
          - user-service
          - order-service
          - all
      confirm:
        description: "Type the service name (or 'all') to confirm"
        required: true

jobs:
  validate:
    name: Validate Promotion
    runs-on: ubuntu-latest
    if: ${{ github.event.inputs.confirm == github.event.inputs.service }}
    steps:
      - uses: actions/checkout@v4

      - name: Verify staging is healthy
        run: |
          echo "In a real setup, this would:"
          echo "- Check ArgoCD sync status for staging"
          echo "- Run smoke tests against staging"
          echo "- Verify no critical alerts"
          # kubectl get application -n argocd | grep staging
          # curl -sf https://api-staging.devops.example.com/health

  promote:
    name: Create Production PR
    needs: validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Update production overlay
        run: |
          PROD_FILE="gitops/overlays/prod/kustomization.yaml"
          STAGING_FILE="gitops/overlays/staging/kustomization.yaml"

          if [ "${{ inputs.service }}" = "all" ]; then
            cp ${STAGING_FILE} ${PROD_FILE}
            sed -i 's/namespace: staging/namespace: production/' ${PROD_FILE}
          else
            STAGING_TAG=$(grep -A1 "${{ inputs.service }}" ${STAGING_FILE} | grep newTag | awk '{print $2}')
            sed -i "/${{ inputs.service }}/{n;s/newTag: .*/newTag: ${STAGING_TAG}/}" ${PROD_FILE}
          fi

      - name: Create production PR (requires 2 approvals)
        uses: peter-evans/create-pull-request@v6
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          branch: promote/prod-${{ github.run_number }}
          title: "promote(prod): ${{ inputs.service }} from staging"
          body: |
            ## Production Promotion

            **Service**: ${{ inputs.service }}
            **Triggered by**: @${{ github.actor }}

            ### Pre-deployment Checks
            - [ ] Staging has been running this version for at least 1 hour
            - [ ] No increase in error rates on staging
            - [ ] Load testing completed (if applicable)
            - [ ] Rollback plan documented
            - [ ] On-call engineer notified

            ### Rollback
            If issues are found after deployment:
            ```bash
            # Revert this PR's merge commit
            git revert <merge-commit-sha>
            git push
            # ArgoCD will auto-sync the rollback
            ```

            **This PR requires 2 approvals before merge.**
          labels: |
            promotion
            production
            requires-review
```

### Full promotion flow visualization:

```
ECR (new image v1.2.0)
    |
    v (automatic, within 2 min)
Image Updater → commits to gitops/overlays/dev/
    |
    v (automatic)
ArgoCD syncs → dev namespace running v1.2.0
    |
    v (manual trigger: promote-to-staging workflow)
PR created: "promote(staging): api-gateway from dev"
    |
    v (1 approval required)
PR merged → gitops/overlays/staging/ updated
    |
    v (automatic)
ArgoCD syncs → staging namespace running v1.2.0
    |
    v (manual trigger: promote-to-production workflow)
PR created: "promote(prod): api-gateway from staging"
    |
    v (2 approvals required)
PR merged → gitops/overlays/prod/ updated
    |
    v (automatic)
ArgoCD syncs → production namespace running v1.2.0
```

---

## Step 6: Update Strategies

Image Updater supports several strategies for selecting which image tag to deploy:

### semver (recommended for tagged releases)

```yaml
# Deploy the highest semantic version tag
argocd-image-updater.argoproj.io/myimage.update-strategy: semver
argocd-image-updater.argoproj.io/myimage.allow-tags: "regexp:^v[0-9]+\\.[0-9]+\\.[0-9]+$"
# Constraint: only pick patch versions of v1.x
argocd-image-updater.argoproj.io/myimage.semver-constraint: "~1"
```

### newest-build (for SHA-tagged images)

```yaml
# Deploy the most recently pushed image
argocd-image-updater.argoproj.io/myimage.update-strategy: newest-build
argocd-image-updater.argoproj.io/myimage.allow-tags: "regexp:^sha-[a-f0-9]{7}$"
```

### digest (for immutable references)

```yaml
# Track digest changes for a specific tag (e.g., "latest")
argocd-image-updater.argoproj.io/myimage.update-strategy: digest
```

### alphabetical (for date-based tags)

```yaml
# Deploy the alphabetically last tag (works with YYYYMMDD-HHMMSS format)
argocd-image-updater.argoproj.io/myimage.update-strategy: alphabetical
argocd-image-updater.argoproj.io/myimage.allow-tags: "regexp:^20[0-9]{6}-[0-9]{6}$"
```

---

## Verify

### Image Updater is running:

```bash
kubectl get pods -n argocd-image-updater
# NAME                                       READY   STATUS    RESTARTS   AGE
# argocd-image-updater-xxx                   1/1     Running   0          5m
```

### Image Updater can access ECR:

```bash
# Check logs for registry connectivity
kubectl logs -n argocd-image-updater deploy/argocd-image-updater --tail=20

# Look for lines like:
# "Successfully fetched image tags" or
# "Setting new image to <image>:<tag>"

# Look for errors like:
# "Could not get tags" (registry auth issue)
# "No image found" (wrong repository name)
```

### Image Updater detects your applications:

```bash
# Check which applications Image Updater is monitoring
kubectl logs -n argocd-image-updater deploy/argocd-image-updater | grep -i "processing"

# You should see:
# "Processing application api-gateway"
# "Processing application user-service"
# "Processing application order-service"
```

### End-to-end test:

```bash
# 1. Tag and push a new version to ECR
docker pull nginx:alpine
docker tag nginx:alpine <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway:v1.99.0
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
docker push <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/api-gateway:v1.99.0

# 2. Wait 2-3 minutes for Image Updater to detect it
sleep 180

# 3. Check Git for the automated commit
git pull
git log --oneline -5
# Should see: "chore: update api-gateway to v1.99.0" (or similar)

# 4. Check ArgoCD for the sync
kubectl get application api-gateway -n argocd -o jsonpath='{.status.sync.status}'
# Should show: Synced

# 5. Verify the pod is running the new image
kubectl get pods -n apps -l app=api-gateway -o jsonpath='{.items[*].spec.containers[*].image}'
```

### Promotion workflow test:

```bash
# Trigger staging promotion
gh workflow run promote-to-staging.yml -f service=api-gateway -f confirm=promote

# Check the PR was created
gh pr list --label promotion
```

---

## Troubleshooting

### Image Updater not detecting new images

```bash
# Check the logs for errors
kubectl logs -n argocd-image-updater deploy/argocd-image-updater --tail=50

# Common issues:
# 1. ECR auth failure
#    "could not get tags from registry"
#    Fix: check AWS credentials secret
kubectl get secret aws-ecr-credentials -n argocd-image-updater -o yaml

# 2. Wrong image name in annotation
#    The annotation image name must match the ECR repository URL exactly
kubectl get application api-gateway -n argocd -o yaml | grep image-list

# 3. Tag doesn't match allow-tags pattern
#    If using semver strategy, tags must be valid semver (v1.0.0)
#    Test your regex: echo "v1.2.3" | grep -P '^v?[0-9]+\.[0-9]+\.[0-9]+$'
```

### Image Updater detects image but doesn't update Git

```bash
# Check write-back configuration
kubectl get application api-gateway -n argocd -o yaml | grep write-back

# Common issues:
# 1. Git SSH key doesn't have write access
#    Fix: verify deploy key has write permission on GitHub

# 2. Branch protection rules blocking commits
#    Fix: allow the deploy key to push to main, or use a PR-based write-back

# 3. Wrong branch name
#    Verify: argocd-image-updater.argoproj.io/git-branch matches your default branch
```

### "Application not found" in logs

```bash
# Image Updater must have access to ArgoCD API
# Check the ArgoCD connection
kubectl logs -n argocd-image-updater deploy/argocd-image-updater | grep -i "argocd"

# If using a different namespace than argocd:
# Ensure the service address is correct in the config
# argocd.serverAddress: argocd-server.argocd.svc.cluster.local
```

### ECR token expiration

```bash
# ECR tokens expire after 12 hours
# Image Updater should auto-refresh using the ecr-login.sh script
# If not working, check the script is mounted correctly:
kubectl exec -n argocd-image-updater deploy/argocd-image-updater -- ls -la /scripts/
kubectl exec -n argocd-image-updater deploy/argocd-image-updater -- /scripts/ecr-login.sh
```

### Kustomization file not updated correctly

```bash
# Image Updater writes to .argocd-source-<app-name>.yaml by default
# With write-back-target: kustomization, it should update kustomization.yaml
# Check what file was modified:
git diff HEAD~1 -- gitops/overlays/dev/

# If it creates .argocd-source-* files instead:
# Ensure the annotation is set:
# argocd-image-updater.argoproj.io/write-back-target: kustomization
```

---

## Checklist

- [ ] ArgoCD Image Updater Helm chart installed
- [ ] AWS credentials configured for ECR access
- [ ] ECR login helper script mounted and executable
- [ ] Git write-back deploy key created with write access
- [ ] Deploy key secret created in Kubernetes
- [ ] api-gateway Application annotated with Image Updater config
- [ ] user-service Application annotated with Image Updater config
- [ ] order-service Application annotated with Image Updater config
- [ ] Image Updater logs show "Processing application" for all 3 services
- [ ] Image Updater can fetch tags from ECR (no auth errors)
- [ ] End-to-end test: push image -> Image Updater commits -> ArgoCD syncs
- [ ] GitOps overlay structure created (base + dev/staging/prod overlays)
- [ ] Promote-to-staging workflow created and tested
- [ ] Promote-to-production workflow created and tested
- [ ] Staging promotion creates PR requiring 1 approval
- [ ] Production promotion creates PR requiring 2 approvals
- [ ] Resource usage confirmed under 128MB

---

## What's Next?

With Image Updater in place, your CI/CD pipeline is fully automated end-to-end:

```
Code commit → GitHub Actions CI → ECR → Image Updater → Git → ArgoCD → Cluster
```

The complete flow for environment promotion:
1. **Dev**: Fully automatic (Image Updater commits to dev overlay)
2. **Staging**: Semi-automatic (workflow creates PR, 1 approval merges)
3. **Production**: Manual with guardrails (workflow creates PR, 2 approvals merge)

You now have a production-grade CI/CD pipeline with:
- Zero long-lived secrets (OIDC)
- Supply chain security (Cosign signing, SBOM, SLSA provenance)
- Automated vulnerability scanning (Trivy, Semgrep, Gitleaks)
- GitOps-based deployments (ArgoCD)
- Automated image updates (Image Updater)
- Environment promotion with approval gates

Congratulations -- your DevOps platform is complete.
