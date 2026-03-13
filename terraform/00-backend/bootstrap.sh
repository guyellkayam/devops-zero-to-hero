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