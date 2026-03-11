# 05 — Terraform Compute (EC2 Spot Instance + k3s)

## Why This Matters

This is the heart of the project: a single EC2 instance that runs **k3s** (lightweight
Kubernetes). Every tool you deploy later -- ArgoCD, Vault, Prometheus, your microservices --
runs on this machine.

We use a **spot instance** to cut costs by ~60%:

| Instance Type | On-Demand | Spot Price | Monthly Savings |
|--------------|-----------|------------|-----------------|
| t3.large (2 vCPU, 8 GB) | ~$60/mo | ~$24/mo | **$36/mo** |
| t3.xlarge (4 vCPU, 16 GB) | ~$120/mo | ~$48/mo | $72/mo |

> **Spot instances** are unused AWS capacity sold at a discount. AWS can reclaim them
> with 2 minutes notice, but for a learning environment this is perfectly fine. The
> interruption rate for t3.large is historically under 5%.

### What Gets Created

```
 +──────────────────────────────────────────+
 | EC2 Spot Instance (t3.large)             |
 |                                          |
 |  +── k3s (installed via user-data) ──+   |
 |  |                                    |  |
 |  |  All your K8s workloads run here  |  |
 |  +────────────────────────────────────+  |
 |                                          |
 |  IAM Role: ECR pull, S3 read,           |
 |            CloudWatch metrics            |
 +──────────────────────────────────────────+
        |                    |
   Elastic IP           SSH Key Pair
   (stable address)     (your laptop)
```

---

## Prerequisites

- [x] Completed [Guide 04 — Terraform Network](./04-terraform-network.md)
- [x] VPC, subnet, and security group exist (`terraform output` shows IDs)
- [x] An SSH key pair ready (or you will create one in Step 1)

---

## Step 1: Create or Import an SSH Key Pair

You need an SSH key to log into the EC2 instance.

### Option A: Create a New Key

```bash
# Generate an ED25519 key (more secure and shorter than RSA)
ssh-keygen -t ed25519 -f ~/.ssh/devops-zero-to-hero -C "devops-zero-to-hero" -N ""

# Verify
ls -la ~/.ssh/devops-zero-to-hero*
# Expected:
#   devops-zero-to-hero       (private key - NEVER share)
#   devops-zero-to-hero.pub   (public key - uploaded to AWS)
```

### Option B: Use an Existing Key

If you already have `~/.ssh/id_ed25519` or `~/.ssh/id_rsa`, you can use it. Just
update the path in the Terraform variables later.

---

## Step 2: Create the EC2 Module

```bash
mkdir -p terraform/modules/ec2-k3s
```

### `terraform/modules/ec2-k3s/variables.tf`

```hcl
# terraform/modules/ec2-k3s/variables.tf

variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy into"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID to deploy into"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for the instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "use_spot" {
  description = "Use spot instance (cheaper but can be interrupted)"
  type        = bool
  default     = true
}

variable "spot_max_price" {
  description = "Maximum hourly price for spot instance (empty = on-demand price cap)"
  type        = string
  default     = ""  # Empty means up to on-demand price
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
  default     = "~/.ssh/devops-zero-to-hero.pub"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "k3s_version" {
  description = "k3s version to install (empty = latest stable)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
```

### `terraform/modules/ec2-k3s/data.tf`

```hcl
# terraform/modules/ec2-k3s/data.tf

# Find the latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
```

### `terraform/modules/ec2-k3s/iam.tf`

```hcl
# terraform/modules/ec2-k3s/iam.tf
# IAM role for the EC2 instance (ECR pull, S3 read, CloudWatch)

# ─── IAM Role ──────────────────────────────────────────────────

resource "aws_iam_role" "k3s_node" {
  name = "${var.project}-${var.environment}-k3s-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-k3s-node-role"
  })
}

# ─── ECR Pull Policy ──────────────────────────────────────────

resource "aws_iam_role_policy" "ecr_pull" {
  name = "ecr-pull"
  role = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─── S3 Read Policy (for Terraform state + configs) ───────────

resource "aws_iam_role_policy" "s3_read" {
  name = "s3-read"
  role = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.project}-*",
          "arn:aws:s3:::${var.project}-*/*"
        ]
      }
    ]
  })
}

# ─── CloudWatch Policy ─────────────────────────────────────────

resource "aws_iam_role_policy" "cloudwatch" {
  name = "cloudwatch"
  role = aws_iam_role.k3s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}

# ─── Instance Profile ──────────────────────────────────────────

resource "aws_iam_instance_profile" "k3s_node" {
  name = "${var.project}-${var.environment}-k3s-node"
  role = aws_iam_role.k3s_node.name
}
```

### `terraform/modules/ec2-k3s/user-data.sh`

```bash
#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# k3s Installation User-Data Script
# Runs automatically when the EC2 instance first boots
# ─────────────────────────────────────────────────────────────────
set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "=========================================="
echo "  k3s Installation Started"
echo "  $(date)"
echo "=========================================="

# ─── System Updates ─────────────────────────────────────────────
echo "[1/5] Updating system packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl \
    wget \
    git \
    jq \
    unzip \
    apt-transport-https \
    ca-certificates \
    software-properties-common \
    nfs-common

# ─── Install AWS CLI v2 ────────────────────────────────────────
echo "[2/5] Installing AWS CLI v2..."
if ! command -v aws &>/dev/null; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp/
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws --version

# ─── Install k3s ───────────────────────────────────────────────
echo "[3/5] Installing k3s..."
K3S_VERSION="${k3s_version}"
INSTALL_ARGS=""

if [ -n "$K3S_VERSION" ]; then
    INSTALL_ARGS="INSTALL_K3S_VERSION=$K3S_VERSION"
fi

curl -sfL https://get.k3s.io | $INSTALL_ARGS sh -s - server \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb \
    --kubelet-arg="max-pods=110"

# Wait for k3s to be ready
echo "Waiting for k3s to start..."
sleep 10
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    echo "  waiting..."
    sleep 5
done
echo "  -> k3s is ready!"

# ─── Configure kubectl for ubuntu user ─────────────────────────
echo "[4/5] Configuring kubectl for ubuntu user..."
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
chmod 600 /home/ubuntu/.kube/config

# Add kubectl alias and completion to ubuntu user's bashrc
cat >> /home/ubuntu/.bashrc << 'BASHRC'

# Kubernetes aliases
export KUBECONFIG=/home/ubuntu/.kube/config
alias k='kubectl'
alias kns='kubectl config set-context --current --namespace'
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
BASHRC

# ─── Install Helm ──────────────────────────────────────────────
echo "[5/5] Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── ECR Credential Helper ─────────────────────────────────────
echo "[Bonus] Setting up ECR credential helper for k3s..."
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")

# Create k3s registries config for ECR
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml << REGISTRIES
mirrors:
  "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com":
    endpoint:
      - "https://$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
REGISTRIES

# ─── Summary ───────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Installation Complete! $(date)"
echo "=========================================="
echo ""
kubectl get nodes -o wide
echo ""
echo "k3s version: $(k3s --version)"
echo "helm version: $(helm version --short)"
echo ""
```

### `terraform/modules/ec2-k3s/main.tf`

```hcl
# terraform/modules/ec2-k3s/main.tf

# ─── SSH Key Pair ──────────────────────────────────────────────

resource "aws_key_pair" "deployer" {
  key_name   = "${var.project}-${var.environment}-deployer"
  public_key = file(var.ssh_public_key_path)

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-deployer"
  })
}

# ─── User Data Template ───────────────────────────────────────

locals {
  user_data = templatefile("${path.module}/user-data.sh", {
    k3s_version = var.k3s_version
  })
}

# ─── EC2 Instance (Spot) ──────────────────────────────────────

resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.k3s_node.name

  user_data                   = local.user_data
  user_data_replace_on_change = false

  # Spot configuration
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price                      = var.spot_max_price != "" ? var.spot_max_price : null
        instance_interruption_behavior = "stop"
        spot_instance_type             = "persistent"
      }
    }
  }

  # Root volume
  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = merge(var.tags, {
      Name = "${var.project}-${var.environment}-k3s-root"
    })
  }

  # Metadata options (IMDSv2 required for security)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # Force IMDSv2
    http_put_response_hop_limit = 2           # Required for containers
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-k3s"
  })

  # Don't destroy and recreate if AMI changes (just update next time)
  lifecycle {
    ignore_changes = [ami]
  }
}

# ─── Elastic IP ────────────────────────────────────────────────

resource "aws_eip" "k3s" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-k3s-eip"
  })
}

resource "aws_eip_association" "k3s" {
  instance_id   = aws_instance.k3s.id
  allocation_id = aws_eip.k3s.id
}
```

### `terraform/modules/ec2-k3s/outputs.tf`

```hcl
# terraform/modules/ec2-k3s/outputs.tf

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.k3s.id
}

output "instance_private_ip" {
  description = "Private IP address"
  value       = aws_instance.k3s.private_ip
}

output "elastic_ip" {
  description = "Elastic IP (stable public address)"
  value       = aws_eip.k3s.public_ip
}

output "instance_public_dns" {
  description = "Public DNS name"
  value       = aws_instance.k3s.public_dns
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/devops-zero-to-hero ubuntu@${aws_eip.k3s.public_ip}"
}

output "ami_id" {
  description = "AMI ID used for the instance"
  value       = data.aws_ami.ubuntu.id
}

output "ami_name" {
  description = "AMI name"
  value       = data.aws_ami.ubuntu.name
}

output "spot_instance" {
  description = "Whether this is a spot instance"
  value       = var.use_spot
}

output "iam_role_name" {
  description = "IAM role name for the instance"
  value       = aws_iam_role.k3s_node.name
}

output "iam_role_arn" {
  description = "IAM role ARN for the instance"
  value       = aws_iam_role.k3s_node.arn
}
```

---

## Step 3: Add Compute to the Dev Environment

Add a new file to the dev environment:

### `terraform/environments/dev/compute.tf`

```hcl
# terraform/environments/dev/compute.tf

module "ec2_k3s" {
  source = "../../modules/ec2-k3s"

  project     = var.project
  environment = var.environment

  vpc_id            = module.vpc.vpc_id
  subnet_id         = module.vpc.public_subnet_id
  security_group_id = module.vpc.k3s_security_group_id

  instance_type       = "t3.large"
  use_spot            = true
  root_volume_size    = 30
  ssh_public_key_path = var.ssh_public_key_path

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

Add the SSH variable and compute outputs to the environment.

Append to `terraform/environments/dev/variables.tf`:

```hcl
variable "ssh_public_key_path" {
  description = "Path to SSH public key"
  type        = string
  default     = "~/.ssh/devops-zero-to-hero.pub"
}
```

Append to `terraform/environments/dev/outputs.tf`:

```hcl
# ─── Compute Outputs ──────────────────────────────────────────

output "instance_id" {
  description = "EC2 instance ID"
  value       = module.ec2_k3s.instance_id
}

output "elastic_ip" {
  description = "Elastic IP for k3s node"
  value       = module.ec2_k3s.elastic_ip
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = module.ec2_k3s.ssh_command
}

output "ami_id" {
  description = "AMI used"
  value       = module.ec2_k3s.ami_id
}
```

---

## Step 4: Deploy the Compute Resources

```bash
cd terraform/environments/dev

# Re-initialize (picks up new module)
terraform init -backend-config=backend.hcl

# Preview
terraform plan

# Apply
terraform apply
```

Expected new resources:

```
Plan: 8 to add, 0 to change, 0 to destroy.

  # aws_eip.k3s
  # aws_eip_association.k3s
  # aws_iam_instance_profile.k3s_node
  # aws_iam_role.k3s_node
  # aws_iam_role_policy.cloudwatch
  # aws_iam_role_policy.ecr_pull
  # aws_iam_role_policy.s3_read
  # aws_instance.k3s
  # aws_key_pair.deployer
```

---

## Step 5: Wait for k3s Installation and Connect

The user-data script takes 3-5 minutes to complete after the instance launches.

```bash
# Get the SSH command from Terraform output
SSH_CMD=$(terraform output -raw ssh_command)
echo "${SSH_CMD}"

# Wait 3-5 minutes, then connect
${SSH_CMD}
```

Once connected, verify k3s:

```bash
# On the EC2 instance:
kubectl get nodes
# NAME               STATUS   ROLES                  AGE   VERSION
# ip-10-0-1-xxx      Ready    control-plane,master   Xm    v1.28.x+k3s1

kubectl get pods -A
# Should show coredns, metrics-server, local-path-provisioner running

# Check user-data log if anything went wrong
cat /var/log/user-data.log
```

---

## Step 6: Configure kubectl on Your Laptop

To run `kubectl` from your laptop (not just SSH), copy the kubeconfig:

```bash
ELASTIC_IP=$(terraform output -raw elastic_ip)

# Copy kubeconfig from the instance
scp -i ~/.ssh/devops-zero-to-hero ubuntu@${ELASTIC_IP}:/home/ubuntu/.kube/config /tmp/k3s-config

# Replace the internal IP with the Elastic IP
sed -i.bak "s|https://127.0.0.1:6443|https://${ELASTIC_IP}:6443|g" /tmp/k3s-config

# Merge into your local kubeconfig (or use directly)
export KUBECONFIG=/tmp/k3s-config
kubectl get nodes

# To make it permanent, merge with existing config:
mkdir -p ~/.kube
cp ~/.kube/config ~/.kube/config.backup 2>/dev/null || true
KUBECONFIG=~/.kube/config:/tmp/k3s-config kubectl config view --merge --flatten > ~/.kube/config.merged
mv ~/.kube/config.merged ~/.kube/config
```

---

## Handling Spot Interruptions

Spot instances can be reclaimed by AWS. Here is how to handle it:

### What Happens on Interruption

1. AWS sends a **2-minute warning** via instance metadata
2. The instance is **stopped** (not terminated -- we configured `stop` behavior)
3. AWS may restart it when capacity is available
4. Your **Elastic IP** stays assigned, so the address does not change
5. **EBS volume** is preserved (data survives)

### Monitoring for Interruptions

```bash
# Check spot instance status
INSTANCE_ID=$(terraform output -raw instance_id)
aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].[State.Name,SpotInstanceRequestId]' --output text

# If stopped, start it again
aws ec2 start-instances --instance-ids "${INSTANCE_ID}"
```

### If You Need Guaranteed Uptime

Switch to on-demand by changing one variable:

```hcl
# In terraform/environments/dev/compute.tf
module "ec2_k3s" {
  # ...
  use_spot = false   # Changed from true to false
}
```

Then `terraform apply`. This will recreate the instance (on-demand this time).

---

## Cost Comparison

| Resource | Monthly Cost | Notes |
|----------|-------------|-------|
| EC2 t3.large spot | ~$24 | 2 vCPU, 8 GB RAM |
| EBS gp3 30 GB | ~$2.40 | Root volume |
| Elastic IP (attached) | $0 | Free when attached to running instance |
| Elastic IP (detached) | ~$3.60 | Charged when instance is stopped |
| **Total** | **~$26-30/mo** | |

Compare with on-demand:

| Resource | Monthly Cost |
|----------|-------------|
| EC2 t3.large on-demand | ~$60 |
| EBS + EIP | ~$2.40 |
| **Total** | **~$62/mo** |

**Spot savings: ~$36/month (60% off)**

---

## Verify

```bash
cd terraform/environments/dev

# 1. Terraform outputs
terraform output

# 2. Instance is running
INSTANCE_ID=$(terraform output -raw instance_id)
aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
# Expected: running

# 3. Elastic IP is associated
ELASTIC_IP=$(terraform output -raw elastic_ip)
echo "Elastic IP: ${ELASTIC_IP}"
aws ec2 describe-addresses --public-ips "${ELASTIC_IP}" \
    --query 'Addresses[0].InstanceId' --output text
# Expected: i-0abc... (matches instance ID)

# 4. SSH works
ssh -i ~/.ssh/devops-zero-to-hero -o ConnectTimeout=10 ubuntu@${ELASTIC_IP} "echo 'SSH OK'"

# 5. k3s is running (wait 3-5 min after instance launch)
ssh -i ~/.ssh/devops-zero-to-hero ubuntu@${ELASTIC_IP} "kubectl get nodes"
# Expected: 1 node in Ready status

# 6. IAM role is attached
aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
# Expected: arn containing "k3s-node"

# 7. User-data completed successfully
ssh -i ~/.ssh/devops-zero-to-hero ubuntu@${ELASTIC_IP} \
    "tail -5 /var/log/user-data.log"
# Expected: "Installation Complete!" message
```

---

## Troubleshooting

### SSH connection refused / timeout

```bash
# Check instance state
aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].State.Name' --output text

# If "running" but SSH fails, check security group allows your IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Your IP: ${MY_IP}"
# Compare with allowed_ssh_cidrs in terraform.tfvars
```

### k3s not running after 5+ minutes

SSH in and check the user-data log:

```bash
ssh -i ~/.ssh/devops-zero-to-hero ubuntu@${ELASTIC_IP}

# Check the installation log
cat /var/log/user-data.log

# Check k3s service status
sudo systemctl status k3s

# Check k3s logs
sudo journalctl -u k3s -n 50 --no-pager
```

### "InsufficientInstanceCapacity" (spot)

No spot capacity available for t3.large in your AZ.

```bash
# Check spot pricing history for alternatives
aws ec2 describe-spot-price-history \
    --instance-types t3.large t3.xlarge t3a.large \
    --start-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --product-descriptions "Linux/UNIX" \
    --query 'SpotPriceHistory[*].[InstanceType,AvailabilityZone,SpotPrice]' \
    --output table
```

If persistent, switch to on-demand temporarily (`use_spot = false`).

### Instance was stopped (spot reclamation)

```bash
# Simply start it again
aws ec2 start-instances --instance-ids "${INSTANCE_ID}"

# Wait for it to be running
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

# k3s will auto-start on boot
ssh -i ~/.ssh/devops-zero-to-hero ubuntu@${ELASTIC_IP} "kubectl get nodes"
```

### "InvalidKeyPair.NotFound"

The SSH public key file path is wrong.

```bash
# Check the key exists
ls -la ~/.ssh/devops-zero-to-hero.pub

# If not, create it (Step 1) or update ssh_public_key_path in terraform.tfvars
```

### Want to resize the instance?

```bash
# Change instance_type in compute.tf, then:
terraform apply
# This will stop -> resize -> start the instance
```

---

## Checklist

- [ ] SSH key pair created at `~/.ssh/devops-zero-to-hero`
- [ ] EC2 module created at `terraform/modules/ec2-k3s/`
- [ ] Module files: `variables.tf`, `data.tf`, `iam.tf`, `main.tf`, `outputs.tf`, `user-data.sh`
- [ ] `compute.tf` added to dev environment
- [ ] SSH key variable added to `variables.tf`
- [ ] Compute outputs added to `outputs.tf`
- [ ] `terraform apply` creates instance + EIP + IAM role
- [ ] Instance type: t3.large spot
- [ ] EBS: 30 GB gp3 encrypted
- [ ] IAM role has ECR pull, S3 read, CloudWatch permissions
- [ ] Elastic IP associated (stable public address)
- [ ] SSH access works from your laptop
- [ ] k3s is running (`kubectl get nodes` shows Ready)
- [ ] kubectl configured on local machine (optional but recommended)

---

## What's Next?

In [Guide 06 — Terraform ECR (Container Registries)](./06-terraform-ecr.md), you will
create private container registries for your 3 microservices so you can build, push,
and deploy your own Docker images.
