# 06 — Terraform ECR (Container Registries)

## Why This Matters

Your 3 microservices (api-gateway, user-service, order-service) need a place to store
their Docker images. **ECR** (Elastic Container Registry) is AWS's private Docker registry.

```
 Developer pushes image             k3s pulls image
         |                                 |
         v                                 v
 +───────────────────────────────────────────────+
 | ECR                                           |
 |                                               |
 |  api-gateway     :v1.0  :v1.1  :latest       |
 |  user-service    :v1.0  :v1.1  :latest       |
 |  order-service   :v1.0  :v1.1  :latest       |
 |                                               |
 |  Features:                                    |
 |  - Image scanning on push (find CVEs)        |
 |  - Lifecycle policy (auto-cleanup old images) |
 |  - Private (no public access)                 |
 +───────────────────────────────────────────────+
```

### Why Not Docker Hub?

| Feature | Docker Hub (Free) | ECR |
|---------|------------------|-----|
| Private repos | 1 | Unlimited |
| Pull rate limit | 100 pulls/6h | Unlimited (in same region) |
| Image scanning | Paid | Included |
| Speed from EC2 | Internet speed | AWS internal (fast) |
| Cost | Free (limited) | ~$0.10/GB/month |
| Auth integration | Separate creds | IAM (already set up) |

ECR is the natural choice when your infrastructure is on AWS. The EC2 instance's IAM
role (from Guide 05) already has ECR pull permissions.

---

## Prerequisites

- [x] Completed [Guide 05 — Terraform Compute](./05-terraform-compute.md)
- [x] EC2 instance running with k3s and IAM role
- [x] Docker installed locally (`docker --version`)

---

## Step 1: Create the ECR Module

```bash
mkdir -p terraform/modules/ecr
```

### `terraform/modules/ecr/variables.tf`

```hcl
# terraform/modules/ecr/variables.tf

variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "repositories" {
  description = "List of ECR repository names to create"
  type        = list(string)
  default = [
    "api-gateway",
    "user-service",
    "order-service"
  ]
}

variable "image_tag_mutability" {
  description = "Tag mutability setting (MUTABLE or IMMUTABLE)"
  type        = string
  default     = "MUTABLE"
  # MUTABLE = you can overwrite :latest
  # IMMUTABLE = once tagged, can never be overwritten (safer for prod)
}

variable "scan_on_push" {
  description = "Enable image vulnerability scanning on push"
  type        = bool
  default     = true
}

variable "max_image_count" {
  description = "Maximum number of tagged images to keep per repo"
  type        = number
  default     = 10
}

variable "untagged_image_expiry_days" {
  description = "Days to keep untagged images before cleanup"
  type        = number
  default     = 1
}

variable "enable_github_oidc" {
  description = "Create IAM OIDC provider and role for GitHub Actions"
  type        = bool
  default     = false
}

variable "github_org" {
  description = "GitHub organization or username (for OIDC trust policy)"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository name (for OIDC trust policy)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
```

### `terraform/modules/ecr/main.tf`

```hcl
# terraform/modules/ecr/main.tf

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ─── ECR Repositories ─────────────────────────────────────────

resource "aws_ecr_repository" "repos" {
  for_each = toset(var.repositories)

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  # Enable encryption with AWS-managed KMS key
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name    = "${var.project}/${each.value}"
    Service = each.value
  })
}

# ─── Lifecycle Policy ─────────────────────────────────────────
# Applied to each repository: keeps last N tagged images,
# removes untagged images after X days

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = toset(var.repositories)
  repository = aws_ecr_repository.repos[each.value].name

  policy = jsonencode({
    rules = [
      {
        # Rule 1: Remove untagged images after N days
        rulePriority = 1
        description  = "Remove untagged images after ${var.untagged_image_expiry_days} day(s)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiry_days
        }
        action = {
          type = "expire"
        }
      },
      {
        # Rule 2: Keep only last N tagged images
        rulePriority = 2
        description  = "Keep only last ${var.max_image_count} tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v", "sha-", "latest"]
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ─── GitHub Actions OIDC (Optional) ───────────────────────────
# Allows GitHub Actions to push images without storing AWS credentials

# Check if OIDC provider already exists
data "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

# Create OIDC provider only if it does not exist
resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc && length(data.aws_iam_openid_connect_provider.github) == 0 ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = merge(var.tags, {
    Name = "github-actions-oidc"
  })
}

locals {
  oidc_provider_arn = var.enable_github_oidc ? (
    length(data.aws_iam_openid_connect_provider.github) > 0
    ? data.aws_iam_openid_connect_provider.github[0].arn
    : aws_iam_openid_connect_provider.github[0].arn
  ) : ""
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions_ecr" {
  count = var.enable_github_oidc ? 1 : 0

  name = "${var.project}-${var.environment}-github-actions-ecr"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-github-actions-ecr"
  })
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  count = var.enable_github_oidc ? 1 : 0

  name = "ecr-push-pull"
  role = aws_iam_role.github_actions_ecr[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = [for repo in aws_ecr_repository.repos : repo.arn]
      }
    ]
  })
}
```

### `terraform/modules/ecr/outputs.tf`

```hcl
# terraform/modules/ecr/outputs.tf

output "repository_urls" {
  description = "Map of repository name to URL"
  value       = { for name, repo in aws_ecr_repository.repos : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of repository name to ARN"
  value       = { for name, repo in aws_ecr_repository.repos : name => repo.arn }
}

output "registry_id" {
  description = "ECR registry ID (AWS account ID)"
  value       = data.aws_caller_identity.current.account_id
}

output "registry_url" {
  description = "ECR registry URL (without repo name)"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "docker_login_command" {
  description = "Command to authenticate Docker with ECR"
  value       = "aws ecr get-login-password --region ${data.aws_region.current.name} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions (empty if OIDC not enabled)"
  value       = var.enable_github_oidc ? aws_iam_role.github_actions_ecr[0].arn : ""
}
```

---

## Step 2: Add ECR to the Dev Environment

### `terraform/environments/dev/ecr.tf`

```hcl
# terraform/environments/dev/ecr.tf

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment

  repositories = [
    "api-gateway",
    "user-service",
    "order-service"
  ]

  scan_on_push               = true
  max_image_count            = 10
  untagged_image_expiry_days = 1

  # Enable GitHub OIDC when ready for CI/CD (Guide 24)
  enable_github_oidc = false
  # github_org       = "your-github-username"
  # github_repo      = "devops-zero-to-hero"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

Add ECR outputs to `terraform/environments/dev/outputs.tf`:

```hcl
# ─── ECR Outputs ───────────────────────────────────────────────

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.ecr.repository_urls
}

output "ecr_registry_url" {
  description = "ECR registry base URL"
  value       = module.ecr.registry_url
}

output "ecr_docker_login_command" {
  description = "Docker login command for ECR"
  value       = module.ecr.docker_login_command
  sensitive   = false
}
```

---

## Step 3: Deploy ECR Repositories

```bash
cd terraform/environments/dev

# Re-initialize (new module)
terraform init -backend-config=backend.hcl

# Preview
terraform plan

# Apply
terraform apply
```

Expected output:

```
Plan: 9 to add, 0 to change, 0 to destroy.

  # module.ecr.aws_ecr_repository.repos["api-gateway"]
  # module.ecr.aws_ecr_repository.repos["order-service"]
  # module.ecr.aws_ecr_repository.repos["user-service"]
  # module.ecr.aws_ecr_lifecycle_policy.repos["api-gateway"]
  # module.ecr.aws_ecr_lifecycle_policy.repos["order-service"]
  # module.ecr.aws_ecr_lifecycle_policy.repos["user-service"]

Apply complete! Resources: 9 added, 0 changed, 0 destroyed.

Outputs:

ecr_repository_urls = {
  "api-gateway"   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-zero-to-hero/api-gateway"
  "order-service" = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-zero-to-hero/order-service"
  "user-service"  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-zero-to-hero/user-service"
}
```

---

## Step 4: Build and Push a Test Image

Let us verify the end-to-end flow: build an image, push it to ECR, confirm it arrives.

### Authenticate Docker with ECR

```bash
# Get the login command from Terraform
cd terraform/environments/dev
eval $(terraform output -raw ecr_docker_login_command)

# Expected: "Login Succeeded"
```

### Build and Push a Test Image

```bash
# Create a minimal test Dockerfile
mkdir -p /tmp/ecr-test
cat > /tmp/ecr-test/Dockerfile << 'EOF'
FROM alpine:3.19
RUN echo "ECR push test - devops-zero-to-hero" > /app.txt
CMD ["cat", "/app.txt"]
EOF

# Get the registry URL
REGISTRY=$(terraform output -raw ecr_registry_url)
REPO="${REGISTRY}/devops-zero-to-hero/api-gateway"

# Build
docker build -t "${REPO}:test" /tmp/ecr-test/

# Push
docker push "${REPO}:test"

# Verify it's in ECR
aws ecr describe-images \
    --repository-name devops-zero-to-hero/api-gateway \
    --query 'imageDetails[*].[imageTags,imagePushedAt,imageSizeInBytes]' \
    --output table

# Check scan results (takes a minute after push)
sleep 60
aws ecr describe-image-scan-findings \
    --repository-name devops-zero-to-hero/api-gateway \
    --image-id imageTag=test \
    --query 'imageScanFindings.findingSeverityCounts' \
    --output json

# Clean up test image
docker rmi "${REPO}:test"
rm -rf /tmp/ecr-test
```

---

## Step 5: Push Images from EC2 (Using IAM Role)

The EC2 instance already has ECR permissions via its IAM role. Test pulling:

```bash
ELASTIC_IP=$(terraform output -raw elastic_ip)
REGISTRY=$(terraform output -raw ecr_registry_url)

ssh -i ~/.ssh/devops-zero-to-hero ubuntu@${ELASTIC_IP} << EOF
# Authenticate with ECR (uses instance IAM role - no credentials needed!)
aws ecr get-login-password --region us-east-1 | \
    sudo k3s ctr images pull --user AWS --password-stdin \
    ${REGISTRY}/devops-zero-to-hero/api-gateway:test

# Verify the image is available
sudo k3s ctr images ls | grep api-gateway
EOF
```

---

## Step 6: Useful Docker Commands Reference

Save these for daily use:

```bash
# ─── ECR Authentication (expires after 12 hours) ──────────────
aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin \
    $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com

# ─── Build & Push Pattern ─────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
SERVICE="api-gateway"  # or user-service, order-service
TAG="v1.0.0"

docker build -t "${REGISTRY}/devops-zero-to-hero/${SERVICE}:${TAG}" .
docker push "${REGISTRY}/devops-zero-to-hero/${SERVICE}:${TAG}"

# Also tag as latest
docker tag "${REGISTRY}/devops-zero-to-hero/${SERVICE}:${TAG}" \
           "${REGISTRY}/devops-zero-to-hero/${SERVICE}:latest"
docker push "${REGISTRY}/devops-zero-to-hero/${SERVICE}:latest"

# ─── List Images in a Repository ──────────────────────────────
aws ecr describe-images \
    --repository-name "devops-zero-to-hero/${SERVICE}" \
    --query 'imageDetails | sort_by(@, &imagePushedAt) | reverse(@) | [*].[imageTags[0],imagePushedAt]' \
    --output table

# ─── Check Scan Results ───────────────────────────────────────
aws ecr describe-image-scan-findings \
    --repository-name "devops-zero-to-hero/${SERVICE}" \
    --image-id imageTag="${TAG}" \
    --query 'imageScanFindings.findingSeverityCounts'

# ─── Delete a Specific Image ──────────────────────────────────
aws ecr batch-delete-image \
    --repository-name "devops-zero-to-hero/${SERVICE}" \
    --image-ids imageTag=test
```

---

## GitHub Actions OIDC (Preview for Guide 24)

When you are ready for CI/CD, enable OIDC to let GitHub Actions push images
**without storing any AWS credentials as secrets**.

```hcl
# terraform/environments/dev/ecr.tf - enable these:
module "ecr" {
  # ...existing config...

  enable_github_oidc = true
  github_org         = "your-github-username"
  github_repo        = "devops-zero-to-hero"
}
```

Then in your GitHub Actions workflow:

```yaml
# .github/workflows/build.yml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write    # Required for OIDC
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.ECR_ROLE_ARN }}  # From Terraform output
          aws-region: us-east-1

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and Push
        run: |
          docker build -t ${{ env.ECR_REGISTRY }}/devops-zero-to-hero/api-gateway:${{ github.sha }} .
          docker push ${{ env.ECR_REGISTRY }}/devops-zero-to-hero/api-gateway:${{ github.sha }}
```

This will be covered in detail in **Guide 24 — CI/CD with GitHub Actions**.

---

## Verify

```bash
cd terraform/environments/dev

# 1. Repositories exist
aws ecr describe-repositories \
    --query 'repositories[*].[repositoryName,repositoryUri]' \
    --output table
# Expected: 3 repos (api-gateway, user-service, order-service)

# 2. Lifecycle policies applied
for SERVICE in api-gateway user-service order-service; do
    echo "--- ${SERVICE} ---"
    aws ecr get-lifecycle-policy \
        --repository-name "devops-zero-to-hero/${SERVICE}" \
        --query 'lifecyclePolicyText' --output text | jq '.rules | length'
done
# Expected: 2 rules per repo

# 3. Image scanning enabled
for SERVICE in api-gateway user-service order-service; do
    echo "--- ${SERVICE} ---"
    aws ecr describe-repositories \
        --repository-names "devops-zero-to-hero/${SERVICE}" \
        --query 'repositories[0].imageScanningConfiguration.scanOnPush' \
        --output text
done
# Expected: true for all

# 4. Docker login works
eval $(terraform output -raw ecr_docker_login_command)
# Expected: Login Succeeded

# 5. Terraform outputs look correct
terraform output ecr_repository_urls
```

---

## Troubleshooting

### "denied: Your authorization token has expired"

ECR tokens expire after **12 hours**. Re-authenticate:

```bash
eval $(terraform output -raw ecr_docker_login_command)
```

### "no basic auth credentials" when pushing

You forgot to log in, or logged into the wrong registry.

```bash
# Check which registries Docker knows about
cat ~/.docker/config.json | jq '.auths | keys'

# Login again
eval $(terraform output -raw ecr_docker_login_command)
```

### "RepositoryAlreadyExistsException"

The repository already exists. Terraform handles this gracefully with `for_each`.
If you get this error outside Terraform, the repo is already there -- just use it.

### Image scanning shows CRITICAL vulnerabilities

Check the findings:

```bash
aws ecr describe-image-scan-findings \
    --repository-name "devops-zero-to-hero/api-gateway" \
    --image-id imageTag=latest \
    --query 'imageScanFindings.findings[?severity==`CRITICAL`].[name,description]' \
    --output table
```

Fix by updating base images in your Dockerfile (e.g., use `alpine:3.19` instead of
`alpine:3.17`).

### Lifecycle policy not cleaning up images

Lifecycle policies run approximately once every 24 hours. Check the policy:

```bash
aws ecr get-lifecycle-policy-preview \
    --repository-name "devops-zero-to-hero/api-gateway" \
    --query 'previewResults[*].[imageTags,action.type]' \
    --output table
```

### "Error assuming role" in GitHub Actions

OIDC trust policy is likely wrong. Verify:

```bash
# Check the trust policy
ROLE_ARN=$(terraform output -raw github_actions_role_arn 2>/dev/null)
aws iam get-role --role-name "${ROLE_ARN##*/}" \
    --query 'Role.AssumeRolePolicyDocument' --output json | jq .
```

Make sure `github_org` and `github_repo` match exactly (case-sensitive).

---

## Cost Reference

ECR costs are minimal for a learning project:

| Resource | Monthly Cost |
|----------|-------------|
| Storage | ~$0.10/GB/month |
| Data transfer (same region) | Free |
| Data transfer (cross-region) | $0.01/GB |
| Image scanning (basic) | Free (first 100 scans/month) |

With 3 small microservice images (~100 MB each), expect **under $0.50/month** for ECR.

---

## Checklist

- [ ] ECR module created at `terraform/modules/ecr/`
- [ ] Module files: `variables.tf`, `main.tf`, `outputs.tf`
- [ ] `ecr.tf` added to dev environment
- [ ] ECR outputs added to `outputs.tf`
- [ ] `terraform apply` creates 3 repositories + 3 lifecycle policies
- [ ] Repository: `devops-zero-to-hero/api-gateway`
- [ ] Repository: `devops-zero-to-hero/user-service`
- [ ] Repository: `devops-zero-to-hero/order-service`
- [ ] Image scanning on push enabled for all repos
- [ ] Lifecycle policy: keep last 10 tagged images
- [ ] Lifecycle policy: remove untagged images after 1 day
- [ ] Docker login to ECR works from your laptop
- [ ] Test image pushed and visible in ECR
- [ ] Test image scan completed (check for vulnerabilities)
- [ ] EC2 instance can pull from ECR (IAM role auth)
- [ ] Test image cleaned up

---

## What's Next?

With networking, compute, and container registries in place, your AWS infrastructure
is complete. In the next guides you will:

- **Guide 07** — Verify k3s and install core add-ons (metrics-server, cert-manager)
- **Guide 08** — Install ArgoCD for GitOps deployments
- **Guide 09** — Set up HashiCorp Vault for secrets management

Your microservices will be built locally, pushed to ECR, and deployed to k3s via
ArgoCD -- the full DevOps pipeline.
