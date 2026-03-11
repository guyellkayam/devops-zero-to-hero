# 24 — GitHub Actions CI/CD Pipeline Setup

## Why This Matters

Your CI/CD pipeline is the assembly line of your software delivery. Every commit goes through:
1. **Build** -- create a container image
2. **Scan** -- check for secrets, vulnerabilities, code issues
3. **Sign** -- cryptographically prove the image came from your pipeline
4. **Push** -- store in ECR
5. **Attest** -- generate provenance (SLSA Level 2)

Without this, you are either deploying manually (slow, error-prone) or deploying
without verification (insecure).

This guide uses **OIDC authentication** -- zero long-lived AWS secrets in GitHub.
GitHub Actions gets temporary credentials by proving its identity to AWS.

---

## Prerequisites

- GitHub repository: `guyellkayam/devops-zero-to-hero`
- AWS account with ECR repositories created
- AWS CLI configured locally (to set up IAM resources)
- ArgoCD installed (guide 08) -- for the CD side
- Cosign understanding (guide 21) -- for image signing
- Three microservices in the repo:
  - `services/api-gateway/` (Node.js)
  - `services/user-service/` (Python/FastAPI)
  - `services/order-service/` (Node.js)

---

## Step 1: Set Up AWS OIDC Provider for GitHub Actions

This lets GitHub Actions authenticate to AWS without storing access keys.

### Create the OIDC identity provider:

```bash
# Get the GitHub Actions OIDC thumbprint
# (This rarely changes, but you can verify at https://token.actions.githubusercontent.com)
THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

# Create the OIDC provider
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "${THUMBPRINT}"
```

### Create IAM role for GitHub Actions:

Save as `github-actions-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:guyellkayam/devops-zero-to-hero:*"
        }
      }
    }
  ]
}
```

```bash
# Replace ACCOUNT_ID with your actual AWS account ID
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i.bak "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" github-actions-trust-policy.json

# Create the role
aws iam create-role \
  --role-name GitHubActionsRole \
  --assume-role-policy-document file://github-actions-trust-policy.json

# Create the permissions policy
cat > github-actions-permissions.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:DescribeRepositories",
        "ecr:ListImages",
        "ecr:DescribeImages"
      ],
      "Resource": [
        "arn:aws:ecr:us-east-1:*:repository/api-gateway",
        "arn:aws:ecr:us-east-1:*:repository/user-service",
        "arn:aws:ecr:us-east-1:*:repository/order-service"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name GitHubActionsRole \
  --policy-name ECRAccess \
  --policy-document file://github-actions-permissions.json

# Note the role ARN -- you'll need this in workflow files
echo "Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/GitHubActionsRole"
```

### Create ECR repositories (if not already done):

```bash
for repo in api-gateway user-service order-service; do
  aws ecr create-repository \
    --repository-name ${repo} \
    --region us-east-1 \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    2>/dev/null || echo "Repository ${repo} already exists"
done

# Set lifecycle policy to keep only last 10 images (save storage costs)
for repo in api-gateway user-service order-service; do
  aws ecr put-lifecycle-policy \
    --repository-name ${repo} \
    --region us-east-1 \
    --lifecycle-policy-text '{
      "rules": [
        {
          "rulePriority": 1,
          "description": "Keep last 10 images",
          "selection": {
            "tagStatus": "any",
            "countType": "imageCountMoreThan",
            "countNumber": 10
          },
          "action": {
            "type": "expire"
          }
        }
      ]
    }'
done
```

---

## Step 2: GitHub Repository Settings

### Add the AWS Role ARN as a repository secret:

```bash
# Using GitHub CLI
gh secret set AWS_ROLE_ARN --body "arn:aws:iam::${AWS_ACCOUNT_ID}:role/GitHubActionsRole"
gh secret set AWS_ACCOUNT_ID --body "${AWS_ACCOUNT_ID}"
gh secret set AWS_REGION --body "us-east-1"
```

### Configure GitHub Environments with approval gates:

```bash
# Create environments
# dev: auto-deploy (no approval)
gh api repos/guyellkayam/devops-zero-to-hero/environments/dev -X PUT

# staging: requires 1 approval
gh api repos/guyellkayam/devops-zero-to-hero/environments/staging -X PUT -f '{
  "reviewers": [
    {"type": "User", "id": <YOUR_GITHUB_USER_ID>}
  ],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}'

# production: requires 2 approvals
gh api repos/guyellkayam/devops-zero-to-hero/environments/production -X PUT -f '{
  "reviewers": [
    {"type": "User", "id": <YOUR_GITHUB_USER_ID>},
    {"type": "User", "id": <SECOND_REVIEWER_ID>}
  ],
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}'
```

**Note**: You can also configure environments through the GitHub web UI:
Repository -> Settings -> Environments.

---

## Step 3: Reusable Workflow -- Build and Push

This is the core reusable workflow that every service calls. It handles building,
scanning, signing, and pushing images.

Save as `.github/workflows/build-and-push.yml`:

```yaml
# .github/workflows/build-and-push.yml
name: Build and Push Image

on:
  workflow_call:
    inputs:
      service-name:
        required: true
        type: string
        description: "Service name (api-gateway, user-service, order-service)"
      service-path:
        required: true
        type: string
        description: "Path to the service directory"
      dockerfile:
        required: false
        type: string
        default: "Dockerfile"
        description: "Dockerfile name"
    outputs:
      image-digest:
        description: "The image digest"
        value: ${{ jobs.build.outputs.digest }}
      image-tag:
        description: "The image tag"
        value: ${{ jobs.build.outputs.tag }}
      image-uri:
        description: "Full image URI with digest"
        value: ${{ jobs.build.outputs.uri }}

permissions:
  id-token: write    # OIDC token for AWS + Cosign
  contents: read     # Checkout code
  packages: write    # Push to GHCR (if used)
  security-events: write  # Upload SARIF results

jobs:
  # ────────────────────────────────────────────
  # Job 1: Security Scanning (parallel with build)
  # ────────────────────────────────────────────
  security-scan:
    name: Security Scan
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      # Gitleaks: scan for leaked secrets in code
      - name: Gitleaks - Secret Detection
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          args: detect --source=${{ inputs.service-path }} --verbose

      # Semgrep: Static Application Security Testing (SAST)
      - name: Semgrep - SAST Scan
        uses: semgrep/semgrep-action@v1
        with:
          config: >-
            p/default
            p/owasp-top-ten
            p/nodejs
            p/python
          paths: ${{ inputs.service-path }}
        env:
          SEMGREP_RULES: >-
            p/default
            p/owasp-top-ten

  # ────────────────────────────────────────────
  # Job 2: Build, Scan Image, Sign, Push
  # ────────────────────────────────────────────
  build:
    name: Build & Push
    runs-on: ubuntu-latest
    outputs:
      digest: ${{ steps.build-push.outputs.digest }}
      tag: ${{ steps.meta.outputs.version }}
      uri: ${{ steps.image-uri.outputs.uri }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      # ── AWS OIDC Authentication ──
      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION || 'us-east-1' }}

      - name: Login to Amazon ECR
        id: ecr-login
        uses: aws-actions/amazon-ecr-login@v2

      # ── Image Metadata ──
      - name: Docker metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: |
            ${{ steps.ecr-login.outputs.registry }}/${{ inputs.service-name }}
          tags: |
            # Branch-based tag
            type=ref,event=branch
            # PR-based tag
            type=ref,event=pr
            # Semver tag from git tag
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            # SHA-based tag (always)
            type=sha,prefix=sha-,format=short
            # Latest tag on main branch
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}

      # ── Build with BuildKit + GHA Cache ──
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push image
        id: build-push
        uses: docker/build-push-action@v6
        with:
          context: ${{ inputs.service-path }}
          file: ${{ inputs.service-path }}/${{ inputs.dockerfile }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          platforms: linux/amd64,linux/arm64
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: true
          sbom: true

      - name: Output image URI
        id: image-uri
        run: |
          URI="${{ steps.ecr-login.outputs.registry }}/${{ inputs.service-name }}@${{ steps.build-push.outputs.digest }}"
          echo "uri=${URI}" >> $GITHUB_OUTPUT
          echo "Image URI: ${URI}"

      # ── Trivy: CVE Scanning ──
      - name: Trivy - Vulnerability Scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: "${{ steps.ecr-login.outputs.registry }}/${{ inputs.service-name }}@${{ steps.build-push.outputs.digest }}"
          format: "sarif"
          output: "trivy-results.sarif"
          severity: "CRITICAL,HIGH"
          exit-code: "1"
          ignore-unfixed: true

      - name: Upload Trivy scan results to GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: "trivy-results.sarif"

      # ── Syft: SBOM Generation ──
      - name: Syft - Generate SBOM
        uses: anchore/sbom-action@v0
        with:
          image: "${{ steps.ecr-login.outputs.registry }}/${{ inputs.service-name }}@${{ steps.build-push.outputs.digest }}"
          format: spdx-json
          output-file: sbom.spdx.json
          artifact-name: "${{ inputs.service-name }}-sbom"

      # ── Cosign: Keyless Image Signing ──
      - name: Install Cosign
        uses: sigstore/cosign-installer@v3

      - name: Sign image with Cosign (keyless)
        env:
          COSIGN_EXPERIMENTAL: "1"
        run: |
          cosign sign --yes \
            --recursive \
            ${{ steps.ecr-login.outputs.registry }}/${{ inputs.service-name }}@${{ steps.build-push.outputs.digest }}

      # ── SLSA Level 2: Provenance Attestation ──
      - name: Attest provenance
        uses: actions/attest-build-provenance@v1
        with:
          subject-name: "${{ steps.ecr-login.outputs.registry }}/${{ inputs.service-name }}"
          subject-digest: "${{ steps.build-push.outputs.digest }}"
          push-to-registry: true

      # ── Attach SBOM as attestation ──
      - name: Attest SBOM
        run: |
          cosign attest --yes \
            --predicate sbom.spdx.json \
            --type spdxjson \
            ${{ steps.ecr-login.outputs.registry }}/${{ inputs.service-name }}@${{ steps.build-push.outputs.digest }}
```

---

## Step 4: Per-Service CI Workflows

Each service has its own workflow that triggers on changes to its directory
and calls the reusable build workflow.

### api-gateway CI:

Save as `.github/workflows/ci-api-gateway.yml`:

```yaml
# .github/workflows/ci-api-gateway.yml
name: CI - API Gateway

on:
  push:
    branches: [main]
    paths:
      - "services/api-gateway/**"
      - ".github/workflows/ci-api-gateway.yml"
      - ".github/workflows/build-and-push.yml"
  pull_request:
    branches: [main]
    paths:
      - "services/api-gateway/**"

permissions:
  id-token: write
  contents: read
  packages: write
  security-events: write

jobs:
  # ── Unit Tests ──
  test:
    name: Unit Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"
          cache-dependency-path: services/api-gateway/package-lock.json

      - name: Install dependencies
        working-directory: services/api-gateway
        run: npm ci

      - name: Run linter
        working-directory: services/api-gateway
        run: npm run lint --if-present

      - name: Run tests
        working-directory: services/api-gateway
        run: npm test -- --coverage --ci
        env:
          NODE_ENV: test

      - name: Upload coverage
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: api-gateway-coverage
          path: services/api-gateway/coverage/

  # ── Build & Push (only on main branch) ──
  build:
    name: Build & Push
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    uses: ./.github/workflows/build-and-push.yml
    with:
      service-name: api-gateway
      service-path: services/api-gateway
    secrets: inherit

  # ── PR Preview Environment ──
  preview:
    name: PR Preview
    needs: test
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    environment:
      name: preview
      url: ${{ steps.deploy-preview.outputs.url }}
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Login to ECR
        id: ecr-login
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build preview image
        uses: docker/build-push-action@v6
        id: build
        with:
          context: services/api-gateway
          push: true
          tags: |
            ${{ steps.ecr-login.outputs.registry }}/api-gateway:pr-${{ github.event.pull_request.number }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Deploy PR preview
        id: deploy-preview
        run: |
          PR_NUM=${{ github.event.pull_request.number }}
          echo "url=https://pr-${PR_NUM}.preview.devops.example.com" >> $GITHUB_OUTPUT
          echo "Preview would be deployed to: pr-${PR_NUM}.preview.devops.example.com"
          # In a real setup, you would create a temporary ArgoCD Application here
          # pointing to the PR image tag

      - name: Comment PR with preview URL
        uses: peter-evans/create-or-update-comment@v4
        with:
          issue-number: ${{ github.event.pull_request.number }}
          body: |
            ## Preview Environment
            Your changes have been deployed to a preview environment.
            **URL**: https://pr-${{ github.event.pull_request.number }}.preview.devops.example.com
            **Image**: `${{ steps.ecr-login.outputs.registry }}/api-gateway:pr-${{ github.event.pull_request.number }}`
```

### user-service CI:

Save as `.github/workflows/ci-user-service.yml`:

```yaml
# .github/workflows/ci-user-service.yml
name: CI - User Service

on:
  push:
    branches: [main]
    paths:
      - "services/user-service/**"
      - ".github/workflows/ci-user-service.yml"
      - ".github/workflows/build-and-push.yml"
  pull_request:
    branches: [main]
    paths:
      - "services/user-service/**"

permissions:
  id-token: write
  contents: read
  packages: write
  security-events: write

jobs:
  # ── Unit Tests (Python/FastAPI) ──
  test:
    name: Unit Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: "pip"
          cache-dependency-path: services/user-service/requirements*.txt

      - name: Install dependencies
        working-directory: services/user-service
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt
          pip install -r requirements-dev.txt 2>/dev/null || true

      - name: Run linter (ruff)
        working-directory: services/user-service
        run: |
          pip install ruff
          ruff check .
          ruff format --check .

      - name: Run tests
        working-directory: services/user-service
        run: |
          pip install pytest pytest-cov pytest-asyncio
          pytest --cov=. --cov-report=xml --cov-report=html -v
        env:
          TESTING: "true"

      - name: Upload coverage
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: user-service-coverage
          path: services/user-service/htmlcov/

  # ── Build & Push ──
  build:
    name: Build & Push
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    uses: ./.github/workflows/build-and-push.yml
    with:
      service-name: user-service
      service-path: services/user-service
    secrets: inherit
```

### order-service CI:

Save as `.github/workflows/ci-order-service.yml`:

```yaml
# .github/workflows/ci-order-service.yml
name: CI - Order Service

on:
  push:
    branches: [main]
    paths:
      - "services/order-service/**"
      - ".github/workflows/ci-order-service.yml"
      - ".github/workflows/build-and-push.yml"
  pull_request:
    branches: [main]
    paths:
      - "services/order-service/**"

permissions:
  id-token: write
  contents: read
  packages: write
  security-events: write

jobs:
  # ── Unit Tests (Node.js) ──
  test:
    name: Unit Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"
          cache-dependency-path: services/order-service/package-lock.json

      - name: Install dependencies
        working-directory: services/order-service
        run: npm ci

      - name: Run linter
        working-directory: services/order-service
        run: npm run lint --if-present

      - name: Run tests
        working-directory: services/order-service
        run: npm test -- --coverage --ci
        env:
          NODE_ENV: test

  # ── Build & Push ──
  build:
    name: Build & Push
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    uses: ./.github/workflows/build-and-push.yml
    with:
      service-name: order-service
      service-path: services/order-service
    secrets: inherit
```

---

## Step 5: Composite Action for Security Scanning

Create a reusable composite action that any workflow can use for security scanning.

Save as `.github/actions/security-scan/action.yml`:

```yaml
# .github/actions/security-scan/action.yml
name: "Security Scan"
description: "Run Gitleaks, Semgrep, and Trivy scans"

inputs:
  scan-path:
    description: "Path to scan"
    required: true
  image-ref:
    description: "Container image reference for Trivy (optional)"
    required: false
    default: ""
  fail-on-severity:
    description: "Trivy severity threshold to fail on"
    required: false
    default: "CRITICAL,HIGH"

runs:
  using: "composite"
  steps:
    # Secret detection
    - name: Gitleaks - Secret Detection
      uses: gitleaks/gitleaks-action@v2
      shell: bash
      env:
        GITHUB_TOKEN: ${{ github.token }}

    # SAST scanning
    - name: Semgrep - SAST
      uses: semgrep/semgrep-action@v1
      with:
        config: p/default p/owasp-top-ten

    # Container image vulnerability scan (if image provided)
    - name: Trivy - Container Scan
      if: inputs.image-ref != ''
      uses: aquasecurity/trivy-action@master
      with:
        image-ref: ${{ inputs.image-ref }}
        format: "table"
        severity: ${{ inputs.fail-on-severity }}
        exit-code: "1"
        ignore-unfixed: true

    # Filesystem vulnerability scan (dependencies)
    - name: Trivy - Filesystem Scan
      uses: aquasecurity/trivy-action@master
      with:
        scan-type: "fs"
        scan-ref: ${{ inputs.scan-path }}
        format: "table"
        severity: ${{ inputs.fail-on-severity }}
        exit-code: "1"
```

### Usage in a workflow:

```yaml
- name: Security Scan
  uses: ./.github/actions/security-scan
  with:
    scan-path: services/api-gateway
    image-ref: "123456789.dkr.ecr.us-east-1.amazonaws.com/api-gateway:sha-abc123"
```

---

## Step 6: GitHub Environments with Deployment Approvals

The environments were created in Step 2. Here is how to use them in a deployment workflow.

Save as `.github/workflows/deploy.yml`:

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  workflow_run:
    workflows: ["CI - API Gateway", "CI - User Service", "CI - Order Service"]
    types: [completed]
    branches: [main]

permissions:
  id-token: write
  contents: write

jobs:
  # ── Deploy to Dev (automatic) ──
  deploy-dev:
    name: Deploy to Dev
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Get latest image tag
        id: get-tag
        run: |
          # Get the service name from the triggering workflow
          WORKFLOW="${{ github.event.workflow_run.name }}"
          case "${WORKFLOW}" in
            "CI - API Gateway") SERVICE="api-gateway" ;;
            "CI - User Service") SERVICE="user-service" ;;
            "CI - Order Service") SERVICE="order-service" ;;
          esac
          echo "service=${SERVICE}" >> $GITHUB_OUTPUT

          # Get latest image digest from ECR
          DIGEST=$(aws ecr describe-images \
            --repository-name ${SERVICE} \
            --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageDigest' \
            --output text)
          echo "digest=${DIGEST}" >> $GITHUB_OUTPUT

      - name: Update dev overlay
        run: |
          SERVICE=${{ steps.get-tag.outputs.service }}
          DIGEST=${{ steps.get-tag.outputs.digest }}
          REGISTRY="${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-east-1.amazonaws.com"

          # Update the kustomization overlay for dev
          cd gitops/overlays/dev
          kustomize edit set image \
            ${REGISTRY}/${SERVICE}=${REGISTRY}/${SERVICE}@${DIGEST}

      - name: Commit and push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add gitops/
          git commit -m "deploy(dev): update ${{ steps.get-tag.outputs.service }} to ${{ steps.get-tag.outputs.digest }}" || exit 0
          git push

  # ── Deploy to Staging (1 approval required) ──
  deploy-staging:
    name: Deploy to Staging
    needs: deploy-dev
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main   # Get latest after dev deploy

      - name: Promote to staging
        run: |
          echo "Promoting dev images to staging overlay..."
          # Copy image references from dev overlay to staging overlay
          # In practice, ArgoCD Image Updater handles this (see Guide 25)

  # ── Deploy to Production (2 approvals required) ──
  deploy-production:
    name: Deploy to Production
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main

      - name: Promote to production
        run: |
          echo "Promoting staging images to production overlay..."
          # Same pattern as staging
```

---

## Step 7: Complete Workflow Visualization

Here is how all the pieces fit together:

```
Developer pushes to services/api-gateway/
    |
    v
ci-api-gateway.yml triggers
    |
    ├─> test (npm test)
    |     |
    |     v (on main branch only)
    ├─> build-and-push.yml (reusable)
    |     |
    |     ├─> security-scan (parallel)
    |     |     ├─> Gitleaks (secrets)
    |     |     └─> Semgrep (SAST)
    |     |
    |     └─> build (sequential)
    |           ├─> AWS OIDC login
    |           ├─> ECR login
    |           ├─> Docker build (BuildKit + GHA cache)
    |           ├─> Push multi-arch image (amd64/arm64)
    |           ├─> Trivy CVE scan (fail on CRITICAL/HIGH)
    |           ├─> Syft SBOM generation
    |           ├─> Cosign keyless signing
    |           └─> SLSA provenance attestation
    |
    v
deploy.yml triggers (on successful CI)
    |
    ├─> deploy-dev (automatic)
    |     └─> Update gitops/overlays/dev → ArgoCD syncs
    |
    ├─> deploy-staging (1 approval gate)
    |     └─> Update gitops/overlays/staging → ArgoCD syncs
    |
    └─> deploy-production (2 approval gates)
          └─> Update gitops/overlays/prod → ArgoCD syncs
```

---

## Verify

### OIDC authentication works:

```bash
# Create a minimal test workflow
cat > .github/workflows/test-oidc.yml <<'EOF'
name: Test OIDC
on: workflow_dispatch
permissions:
  id-token: write
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1
      - name: Verify AWS identity
        run: aws sts get-caller-identity
EOF

# Push and trigger manually
git add .github/workflows/test-oidc.yml
git commit -m "test: verify OIDC authentication"
git push
gh workflow run test-oidc.yml

# Watch the run
gh run watch
```

### CI pipeline triggers correctly:

```bash
# Make a change to api-gateway
echo "// trigger CI" >> services/api-gateway/index.js
git add services/api-gateway/index.js
git commit -m "test: trigger api-gateway CI"
git push

# Watch the CI run
gh run list --workflow=ci-api-gateway.yml
gh run watch
```

### Images are pushed and signed:

```bash
# Check ECR for the new image
aws ecr describe-images \
  --repository-name api-gateway \
  --query 'sort_by(imageDetails,& imagePushedAt)[-1]'

# Verify Cosign signature
cosign verify \
  ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/api-gateway:latest \
  --certificate-identity-regexp="https://github.com/guyellkayam/devops-zero-to-hero" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

### GitHub Security tab shows results:

```
Go to: https://github.com/guyellkayam/devops-zero-to-hero/security
- Code scanning alerts: Semgrep findings
- Dependabot alerts: Trivy CVE findings
- Secret scanning: Gitleaks results
```

---

## Troubleshooting

### OIDC "Not authorized to perform: sts:AssumeRoleWithWebIdentity"

```bash
# Check the trust policy matches your repository
aws iam get-role --role-name GitHubActionsRole --query 'Role.AssumeRolePolicyDocument'

# Common issues:
# 1. Repository name mismatch (case-sensitive)
#    "repo:guyellkayam/devops-zero-to-hero:*" must match exactly

# 2. Missing id-token permission in workflow
#    Ensure: permissions: id-token: write

# 3. Wrong audience
#    Must be "sts.amazonaws.com" in both trust policy and workflow
```

### ECR push fails with "no basic auth credentials"

```bash
# Ensure the ECR login step runs BEFORE the build step
# Check the aws-actions/amazon-ecr-login@v2 action output

# Verify the IAM role has ECR permissions
aws ecr get-authorization-token --region us-east-1
```

### Trivy scan fails on CRITICAL vulnerability

```bash
# This is expected behavior -- the pipeline blocks insecure images
# Options:
# 1. Fix the vulnerability by updating the base image
# 2. If unfixed, add to .trivyignore:
echo "CVE-2024-XXXXX" >> services/api-gateway/.trivyignore
# 3. Temporarily lower severity (not recommended for production)
```

### Multi-arch build is slow

```bash
# The first build takes longer because there's no cache
# Subsequent builds use GitHub Actions cache (type=gha)
# If still slow, consider:
# 1. Build only amd64 for PRs, multi-arch only on main:
#    platforms: ${{ github.event_name == 'pull_request' && 'linux/amd64' || 'linux/amd64,linux/arm64' }}
# 2. Use a larger runner: runs-on: ubuntu-latest-4-cores
```

### Cosign signing fails

```bash
# Ensure the workflow has id-token: write permission
# Ensure COSIGN_EXPERIMENTAL=1 is set (or use cosign v2+ which defaults to keyless)
# Check: is the Sigstore infrastructure up? https://status.sigstore.dev/
```

---

## Checklist

- [ ] AWS OIDC provider created for GitHub Actions
- [ ] IAM role with trust policy scoped to your repository
- [ ] IAM role has ECR push/pull permissions for all 3 repositories
- [ ] ECR repositories created for api-gateway, user-service, order-service
- [ ] ECR lifecycle policies set (keep last 10 images)
- [ ] Repository secrets set: AWS_ROLE_ARN, AWS_ACCOUNT_ID, AWS_REGION
- [ ] GitHub Environments created: dev (auto), staging (1 approval), production (2 approvals)
- [ ] Reusable workflow `build-and-push.yml` created
- [ ] Per-service workflows created: ci-api-gateway, ci-user-service, ci-order-service
- [ ] Composite action `security-scan` created
- [ ] Deployment workflow `deploy.yml` created
- [ ] OIDC test workflow runs successfully
- [ ] CI triggers on push to service directories
- [ ] Gitleaks detects test secrets
- [ ] Semgrep SAST results appear in Security tab
- [ ] Trivy blocks images with CRITICAL CVEs
- [ ] Syft generates SBOM artifacts
- [ ] Cosign keyless signing works
- [ ] SLSA provenance attestation attached
- [ ] Multi-arch images (amd64/arm64) built and pushed
- [ ] PR preview environment deploys on pull requests
- [ ] Deployment workflow promotes through dev -> staging -> production

---

## What's Next?

Your CI pipeline now builds, scans, signs, and pushes verified container images.
The CD side (ArgoCD) watches the Git repository for changes.

But there is a gap: who updates the Git repository when a new image is pushed?
That is what **Guide 25 -- ArgoCD Image Updater** solves. It automatically detects
new images in ECR and updates the GitOps overlays, closing the loop between CI and CD.
