# 03 — Terraform State Backend (S3 + DynamoDB)

## Why This Matters

Terraform tracks every resource it manages in a **state file** (`terraform.tfstate`).
By default, this file lives on your laptop. That creates serious problems:

| Problem | What Happens |
|---------|-------------|
| **Laptop dies** | You lose track of ALL your infrastructure. Terraform can't update or destroy anything. |
| **Team collaboration** | Two people run `terraform apply` at the same time and corrupt state |
| **Secrets in state** | Database passwords, keys — all stored in plain text locally |
| **No history** | You can't roll back to a previous state version |

The solution: store state **remotely** in S3 with **locking** via DynamoDB.

```
 You run terraform apply
         |
         v
 +-----------------+     +------------------+
 | S3 Bucket       |     | DynamoDB Table   |
 | (state storage) |     | (state locking)  |
 | - versioned     |     | - prevents races |
 | - encrypted     |     | - auto-releases  |
 +-----------------+     +------------------+
```

### The Bootstrap Chicken-and-Egg Problem

You cannot use Terraform to create the S3 bucket that Terraform needs for its own state.
That is a circular dependency. So we use a **bootstrap script** (AWS CLI) to create the
backend resources first, and then configure Terraform to use them.

---

## Prerequisites

- [x] Completed [Guide 01 — AWS Account Security](./01-aws-account-security.md)
- [x] Completed [Guide 02 — Local Tools Setup](./02-local-tools-setup.md)
- [x] AWS CLI configured (`aws sts get-caller-identity` works)
- [x] Terraform installed (`terraform --version` works)

---

## Step 1: Create the Bootstrap Script

This script creates the S3 bucket and DynamoDB table using AWS CLI.

```bash
mkdir -p terraform/00-backend
```

Create the file `terraform/00-backend/bootstrap.sh`:

```bash
#!/usr/bin/env bash
#
# Bootstrap Terraform Backend
# Creates S3 bucket + DynamoDB table for remote state
# Run this ONCE before any other Terraform commands
#
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="devops-zero-to-hero"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="${PROJECT}-tfstate-${ACCOUNT_ID}"
DYNAMODB_TABLE="terraform-locks"

echo "================================================"
echo "  Terraform Backend Bootstrap"
echo "================================================"
echo "  Account:  ${ACCOUNT_ID}"
echo "  Region:   ${AWS_REGION}"
echo "  Bucket:   ${BUCKET_NAME}"
echo "  Table:    ${DYNAMODB_TABLE}"
echo "================================================"
echo ""

# ─── Create S3 Bucket ──────────────────────────────────────────
echo "[1/5] Creating S3 bucket..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    echo "  -> Bucket already exists. Skipping."
else
    # us-east-1 doesn't use LocationConstraint
    if [ "${AWS_REGION}" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${AWS_REGION}"
    else
        aws s3api create-bucket \
            --bucket "${BUCKET_NAME}" \
            --region "${AWS_REGION}" \
            --create-bucket-configuration LocationConstraint="${AWS_REGION}"
    fi
    echo "  -> Bucket created."
fi

# ─── Enable Versioning ─────────────────────────────────────────
echo "[2/5] Enabling versioning..."
aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled
echo "  -> Versioning enabled."

# ─── Enable Server-Side Encryption ─────────────────────────────
echo "[3/5] Enabling encryption..."
aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "aws:kms"
            },
            "BucketKeyEnabled": true
        }]
    }'
echo "  -> Encryption enabled (SSE-KMS with bucket key)."

# ─── Block Public Access ───────────────────────────────────────
echo "[4/5] Blocking public access..."
aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
echo "  -> Public access blocked."

# ─── Create DynamoDB Table ─────────────────────────────────────
echo "[5/5] Creating DynamoDB table..."
if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${AWS_REGION}" 2>/dev/null; then
    echo "  -> Table already exists. Skipping."
else
    aws dynamodb create-table \
        --table-name "${DYNAMODB_TABLE}" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "${AWS_REGION}" \
        --tags \
            Key=Project,Value="${PROJECT}" \
            Key=ManagedBy,Value=bootstrap-script

    echo "  -> Waiting for table to be active..."
    aws dynamodb wait table-exists \
        --table-name "${DYNAMODB_TABLE}" \
        --region "${AWS_REGION}"
    echo "  -> Table created."
fi

# ─── Summary ───────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Bootstrap Complete!"
echo "================================================"
echo ""
echo "Add this to your Terraform configurations:"
echo ""
echo '  terraform {'
echo '    backend "s3" {'
echo "      bucket         = \"${BUCKET_NAME}\""
echo "      key            = \"<environment>/<component>/terraform.tfstate\""
echo "      region         = \"${AWS_REGION}\""
echo "      dynamodb_table = \"${DYNAMODB_TABLE}\""
echo '      encrypt        = true'
echo '    }'
echo '  }'
echo ""
```

Make it executable:

```bash
chmod +x terraform/00-backend/bootstrap.sh
```

---

## Step 2: Create the Backend Terraform Configuration

Even though the bootstrap is done via script, we create Terraform files to **document** the
backend and allow importing it later if needed.

Create `terraform/00-backend/main.tf`:

```hcl
# ─────────────────────────────────────────────────────────────────
# Terraform Backend Infrastructure
# ─────────────────────────────────────────────────────────────────
# These resources are created by bootstrap.sh (AWS CLI).
# This file documents what exists and can be used for drift detection.
#
# DO NOT run "terraform apply" here — it's for reference only.
# ─────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "devops-zero-to-hero"
      ManagedBy = "bootstrap-script"
    }
  }
}

# ─── Variables ──────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for backend resources"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name (used in resource naming)"
  type        = string
  default     = "devops-zero-to-hero"
}

# ─── Data Sources ───────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# ─── Locals ─────────────────────────────────────────────────────

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project}-tfstate-${local.account_id}"
}

# ─── S3 Bucket (reference) ─────────────────────────────────────

resource "aws_s3_bucket" "terraform_state" {
  bucket = local.bucket_name

  # Prevent accidental deletion
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── DynamoDB Table (reference) ─────────────────────────────────

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ─── Outputs ────────────────────────────────────────────────────

output "state_bucket_name" {
  description = "S3 bucket name for Terraform state"
  value       = local.bucket_name
}

output "state_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for state locking"
  value       = aws_dynamodb_table.terraform_locks.name
}
```

---

## Step 3: Run the Bootstrap

```bash
cd terraform/00-backend
./bootstrap.sh
```

Expected output:

```
================================================
  Terraform Backend Bootstrap
================================================
  Account:  123456789012
  Region:   us-east-1
  Bucket:   devops-zero-to-hero-tfstate-123456789012
  Table:    terraform-locks
================================================

[1/5] Creating S3 bucket...
  -> Bucket created.
[2/5] Enabling versioning...
  -> Versioning enabled.
[3/5] Enabling encryption...
  -> Encryption enabled (SSE-KMS with bucket key).
[4/5] Blocking public access...
  -> Public access blocked.
[5/5] Creating DynamoDB table...
  -> Waiting for table to be active...
  -> Table created.

================================================
  Bootstrap Complete!
================================================
```

---

## Step 4: Configure Backend in Environment

Now every Terraform environment you create will point to this backend.

Create the shared backend config at `terraform/environments/dev/backend.hcl`:

```hcl
# terraform/environments/dev/backend.hcl
# Shared backend configuration for dev environment
# Usage: terraform init -backend-config=backend.hcl

bucket         = "devops-zero-to-hero-tfstate-REPLACE_WITH_ACCOUNT_ID"
region         = "us-east-1"
dynamodb_table = "terraform-locks"
encrypt        = true
```

Then in each environment's `main.tf` you use a **partial** backend config:

```hcl
# terraform/environments/dev/main.tf

terraform {
  required_version = ">= 1.5"

  backend "s3" {
    # key is unique per component — set here, rest comes from backend.hcl
    key = "dev/infrastructure/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

Initialize with:

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl
```

### State Key Naming Convention

Use this pattern to keep state files organized in S3:

```
s3://devops-zero-to-hero-tfstate-{ACCOUNT_ID}/
  dev/
    infrastructure/terraform.tfstate    # VPC, EC2, security groups
    ecr/terraform.tfstate               # Container registries
    dns/terraform.tfstate               # Route53 (if used later)
  staging/
    infrastructure/terraform.tfstate
  prod/
    infrastructure/terraform.tfstate
```

---

## Step 5: Verify State Backend Works

Create a quick test to confirm the backend is working:

```bash
# Create a temp directory for testing
mkdir -p /tmp/tf-backend-test
cd /tmp/tf-backend-test

# Get your account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > main.tf << EOF
terraform {
  backend "s3" {
    bucket         = "devops-zero-to-hero-tfstate-${ACCOUNT_ID}"
    key            = "test/backend-verify/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

resource "null_resource" "test" {
  triggers = {
    timestamp = timestamp()
  }
}
EOF

terraform init
terraform apply -auto-approve

# Verify state is in S3
aws s3 ls "s3://devops-zero-to-hero-tfstate-${ACCOUNT_ID}/test/backend-verify/"

# Clean up
terraform destroy -auto-approve
aws s3 rm "s3://devops-zero-to-hero-tfstate-${ACCOUNT_ID}/test/backend-verify/terraform.tfstate"
cd -
rm -rf /tmp/tf-backend-test
```

---

## Verify

Run these checks to confirm everything is set up correctly:

```bash
# 1. Bucket exists and has versioning
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="devops-zero-to-hero-tfstate-${ACCOUNT_ID}"

echo "--- Bucket exists ---"
aws s3api head-bucket --bucket "${BUCKET}" && echo "OK" || echo "FAIL"

echo "--- Versioning enabled ---"
aws s3api get-bucket-versioning --bucket "${BUCKET}" \
    --query 'Status' --output text
# Expected: Enabled

echo "--- Encryption enabled ---"
aws s3api get-bucket-encryption --bucket "${BUCKET}" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text
# Expected: aws:kms

echo "--- Public access blocked ---"
aws s3api get-public-access-block --bucket "${BUCKET}" \
    --query 'PublicAccessBlockConfiguration'
# Expected: all true

echo "--- DynamoDB table exists ---"
aws dynamodb describe-table --table-name terraform-locks \
    --query 'Table.TableStatus' --output text
# Expected: ACTIVE
```

---

## Troubleshooting

### "BucketAlreadyOwnedByYou"

This means the bucket already exists in your account. The bootstrap script handles this
gracefully (it skips creation). This is safe.

### "BucketAlreadyExists" (without "OwnedByYou")

S3 bucket names are globally unique. Someone else has a bucket with this name.
This should not happen because we include your account ID in the name. If it does:

```bash
# Use a different suffix
export BUCKET_SUFFIX="my-unique-suffix"
# Edit the bootstrap script to use this suffix
```

### "Error acquiring the state lock"

Someone else (or a crashed process) holds the lock.

```bash
# Check who holds the lock
aws dynamodb get-item \
    --table-name terraform-locks \
    --key '{"LockID":{"S":"devops-zero-to-hero-tfstate-ACCOUNTID/dev/infrastructure/terraform.tfstate"}}'

# Force unlock (use the lock ID from the error message)
terraform force-unlock LOCK_ID
```

> **Warning**: Only force-unlock if you are sure no other Terraform process is running.

### "Access Denied" when running bootstrap

Your IAM user needs these permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:CreateBucket",
                "s3:PutBucketVersioning",
                "s3:PutEncryptionConfiguration",
                "s3:PutBucketPublicAccessBlock",
                "s3:GetBucketVersioning",
                "s3:GetEncryptionConfiguration",
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::devops-zero-to-hero-tfstate-*",
                "arn:aws:s3:::devops-zero-to-hero-tfstate-*/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:CreateTable",
                "dynamodb:DescribeTable",
                "dynamodb:GetItem",
                "dynamodb:PutItem",
                "dynamodb:DeleteItem"
            ],
            "Resource": "arn:aws:dynamodb:*:*:table/terraform-locks"
        }
    ]
}
```

If you followed Guide 01 and created an admin user, you already have these permissions.

### State File Rollback (S3 Versioning)

If your state gets corrupted, you can restore a previous version:

```bash
# List state file versions
aws s3api list-object-versions \
    --bucket "${BUCKET}" \
    --prefix "dev/infrastructure/terraform.tfstate" \
    --query 'Versions[*].[VersionId,LastModified,Size]' \
    --output table

# Restore a specific version
aws s3api get-object \
    --bucket "${BUCKET}" \
    --key "dev/infrastructure/terraform.tfstate" \
    --version-id "VERSION_ID_HERE" \
    terraform.tfstate.backup

# Review the backup, then upload it as current
aws s3 cp terraform.tfstate.backup \
    "s3://${BUCKET}/dev/infrastructure/terraform.tfstate"
```

---

## Checklist

- [ ] Bootstrap script created at `terraform/00-backend/bootstrap.sh`
- [ ] Bootstrap script executed successfully
- [ ] S3 bucket created with naming pattern `devops-zero-to-hero-tfstate-{ACCOUNT_ID}`
- [ ] Bucket versioning enabled
- [ ] Bucket encryption enabled (SSE-KMS)
- [ ] Bucket public access blocked
- [ ] DynamoDB table `terraform-locks` created with PAY_PER_REQUEST billing
- [ ] Backend config file created at `terraform/environments/dev/backend.hcl`
- [ ] Account ID placeholder replaced in `backend.hcl`
- [ ] Test init+apply with backend works (state appears in S3)
- [ ] Test state cleaned up

---

## What's Next?

In [Guide 04 — Terraform Network (VPC)](./04-terraform-network.md), you will create
the VPC, subnet, internet gateway, and security groups that your EC2 instance will live in.

All networking Terraform code will use the remote backend you just set up.
