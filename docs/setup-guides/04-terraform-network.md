# 04 — Terraform Network (VPC, Subnets, Security Groups)

## Why This Matters

Every AWS resource needs a network to live in. A **VPC** (Virtual Private Cloud) is your
own isolated network inside AWS. Without it, your EC2 instance has nowhere to run.

```
 Internet
    |
    v
 +-------------------+
 | Internet Gateway   |  <-- doorway between VPC and internet
 +-------------------+
    |
    v
 +-------------------+
 | Public Subnet      |  <-- 10.0.1.0/24 (256 IPs)
 | (us-east-1a)       |
 |                    |
 |  [EC2 Instance]    |  <-- your k3s server lives here
 |  [Security Groups] |  <-- firewall rules
 +-------------------+
    |
 +-------------------+
 | VPC: 10.0.0.0/16   |  <-- 65,536 IPs total
 +-------------------+
```

### Why Public Subnet Only?

A typical production setup uses private subnets + a **NAT Gateway** ($32/month).
For a learning environment that is unnecessary overhead. We use a public subnet with
security groups as the firewall. This saves $32/month while teaching the same concepts.

| Setup | Monthly Cost | Complexity | Good For |
|-------|-------------|------------|----------|
| Public subnet only | $0 | Simple | Learning, dev |
| Public + Private + NAT | ~$32 | Medium | Staging, prod |
| Multi-AZ + NAT redundant | ~$64 | Complex | Production HA |

---

## Prerequisites

- [x] Completed [Guide 03 — Terraform Backend](./03-terraform-backend.md)
- [x] S3 state bucket and DynamoDB lock table exist
- [x] `backend.hcl` has your account ID filled in

---

## Step 1: Create the VPC Module

Modules are reusable Terraform building blocks. Create the VPC module:

```bash
mkdir -p terraform/modules/vpc
```

### `terraform/modules/vpc/variables.tf`

```hcl
# terraform/modules/vpc/variables.tf

variable "project" {
  description = "Project name used in resource naming and tags"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "AZ for the public subnet"
  type        = string
  default     = "us-east-1a"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into instances"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Restrict this in production!
}

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}
```

### `terraform/modules/vpc/main.tf`

```hcl
# terraform/modules/vpc/main.tf

# ─── VPC ────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpc"
  })
}

# ─── Internet Gateway ──────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-igw"
  })
}

# ─── Public Subnet ─────────────────────────────────────────────

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-public-subnet"
    Type = "public"
  })
}

# ─── Route Table ───────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── Security Group: K3s Node ──────────────────────────────────

resource "aws_security_group" "k3s_node" {
  name_prefix = "${var.project}-${var.environment}-k3s-"
  description = "Security group for k3s single-node cluster"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-k3s-sg"
  })

  # Prevent Terraform from trying to recreate on name conflicts
  lifecycle {
    create_before_destroy = true
  }
}

# ─── Ingress Rules (separate resources for clarity) ────────────

# SSH access
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "SSH access"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.allowed_ssh_cidrs[0]

  tags = { Name = "ssh" }
}

# HTTP
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "HTTP traffic"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "http" }
}

# HTTPS
resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "HTTPS traffic"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "https" }
}

# Kubernetes API (for kubectl from your laptop)
resource "aws_vpc_security_group_ingress_rule" "k8s_api" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "Kubernetes API server"
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.allowed_ssh_cidrs[0]

  tags = { Name = "k8s-api" }
}

# NodePort range (for services exposed via NodePort)
resource "aws_vpc_security_group_ingress_rule" "nodeport" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "Kubernetes NodePort range"
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "nodeport" }
}

# ─── Egress Rule ───────────────────────────────────────────────

# Allow all outbound traffic (instance needs to pull images, updates, etc.)
resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "all-outbound" }
}
```

### `terraform/modules/vpc/outputs.tf`

```hcl
# terraform/modules/vpc/outputs.tf

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "public_subnet_cidr" {
  description = "CIDR block of the public subnet"
  value       = aws_subnet.public.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the internet gateway"
  value       = aws_internet_gateway.main.id
}

output "k3s_security_group_id" {
  description = "ID of the k3s node security group"
  value       = aws_security_group.k3s_node.id
}

output "k3s_security_group_name" {
  description = "Name of the k3s node security group"
  value       = aws_security_group.k3s_node.name
}
```

---

## Step 2: Create the Dev Environment Configuration

```bash
mkdir -p terraform/environments/dev
```

### `terraform/environments/dev/main.tf`

```hcl
# terraform/environments/dev/main.tf
# ─────────────────────────────────────────────────────────────────
# Dev Environment - Network + Compute
# ─────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5"

  backend "s3" {
    key = "dev/infrastructure/terraform.tfstate"
  }

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
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
```

### `terraform/environments/dev/variables.tf`

```hcl
# terraform/environments/dev/variables.tf

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "devops-zero-to-hero"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH (restrict to your IP!)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
```

### `terraform/environments/dev/network.tf`

```hcl
# terraform/environments/dev/network.tf

module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment

  vpc_cidr           = "10.0.0.0/16"
  public_subnet_cidr = "10.0.1.0/24"
  availability_zone  = "${var.aws_region}a"

  allowed_ssh_cidrs = var.allowed_ssh_cidrs

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

### `terraform/environments/dev/outputs.tf`

```hcl
# terraform/environments/dev/outputs.tf

# ─── Network Outputs ───────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = module.vpc.public_subnet_id
}

output "k3s_security_group_id" {
  description = "K3s security group ID"
  value       = module.vpc.k3s_security_group_id
}
```

### `terraform/environments/dev/backend.hcl`

```hcl
# terraform/environments/dev/backend.hcl
#
# Usage: terraform init -backend-config=backend.hcl
#
# IMPORTANT: Replace REPLACE_WITH_ACCOUNT_ID with your actual AWS account ID.
#            Run: aws sts get-caller-identity --query Account --output text

bucket         = "devops-zero-to-hero-tfstate-REPLACE_WITH_ACCOUNT_ID"
region         = "us-east-1"
dynamodb_table = "terraform-locks"
encrypt        = true
```

---

## Step 3: Restrict SSH to Your IP (Recommended)

Before deploying, lock down SSH to your current IP address:

```bash
# Get your public IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Your IP: ${MY_IP}"
```

Create a `terraform.tfvars` file:

```bash
cat > terraform/environments/dev/terraform.tfvars << EOF
allowed_ssh_cidrs = ["${MY_IP}/32"]
EOF
```

> **Note**: If your IP changes (VPN, coffee shop, etc.), update this value and re-apply.

---

## Step 4: Deploy the Network

```bash
cd terraform/environments/dev

# Initialize with remote backend
terraform init -backend-config=backend.hcl

# Preview what will be created
terraform plan

# Apply (creates VPC, subnet, IGW, route table, security group)
terraform apply
```

Expected output:

```
Plan: 10 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + k3s_security_group_id = (known after apply)
  + public_subnet_id      = (known after apply)
  + vpc_id                = (known after apply)

Do you want to perform these actions?
  Enter a value: yes

Apply complete! Resources: 10 added, 0 changed, 0 destroyed.

Outputs:

k3s_security_group_id = "sg-0abc123def456..."
public_subnet_id = "subnet-0abc123def456..."
vpc_id = "vpc-0abc123def456..."
```

---

## Verify

After `terraform apply` completes, verify the network:

```bash
cd terraform/environments/dev

# 1. Check Terraform outputs
terraform output

# 2. Verify VPC in AWS
VPC_ID=$(terraform output -raw vpc_id)
echo "VPC ID: ${VPC_ID}"

aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" \
    --query 'Vpcs[0].[CidrBlock,State]' --output text
# Expected: 10.0.0.0/16   available

# 3. Verify subnet
SUBNET_ID=$(terraform output -raw public_subnet_id)
aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" \
    --query 'Subnets[0].[CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' --output text
# Expected: 10.0.1.0/24   us-east-1a   True

# 4. Verify security group rules
SG_ID=$(terraform output -raw k3s_security_group_id)
echo "--- Ingress Rules ---"
aws ec2 describe-security-group-rules \
    --filters Name=group-id,Values="${SG_ID}" \
    --query 'SecurityGroupRules[?!IsEgress].[Description,FromPort,ToPort,CidrIpv4]' \
    --output table

# Expected ports: 22, 80, 443, 6443, 30000-32767

# 5. Verify internet gateway attached
IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters Name=attachment.vpc-id,Values="${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
echo "IGW: ${IGW_ID}"
# Expected: igw-0...

# 6. Verify route table has internet route
aws ec2 describe-route-tables \
    --filters Name=vpc-id,Values="${VPC_ID}" Name=association.main,Values=false \
    --query 'RouteTables[0].Routes[*].[DestinationCidrBlock,GatewayId]' --output table
# Expected row: 0.0.0.0/0   igw-0...
```

---

## Troubleshooting

### "Error: creating VPC: VpcLimitExceeded"

AWS has a default limit of 5 VPCs per region.

```bash
# Check how many VPCs you have
aws ec2 describe-vpcs --query 'length(Vpcs)' --output text

# Delete unused VPCs (careful!) or request a limit increase
```

### "Error: configuring Terraform AWS Provider: no valid credential sources"

AWS CLI is not configured properly.

```bash
# Test your credentials
aws sts get-caller-identity

# If it fails, reconfigure
aws configure
```

### Security group rule already exists

If you see a conflict, it means a rule with the same parameters exists.

```bash
# List existing rules
aws ec2 describe-security-group-rules \
    --filters Name=group-id,Values=sg-YOUR_SG_ID \
    --output table
```

### "Error loading state: AccessDenied"

Your backend.hcl has the wrong bucket name, or your credentials lack S3 permissions.

```bash
# Verify the bucket name
aws sts get-caller-identity --query Account --output text
# Make sure this matches the ID in backend.hcl
```

### Want to change your IP for SSH?

```bash
# Get new IP
MY_IP=$(curl -s https://checkip.amazonaws.com)

# Update tfvars
echo "allowed_ssh_cidrs = [\"${MY_IP}/32\"]" > terraform/environments/dev/terraform.tfvars

# Re-apply (only security group rules change)
cd terraform/environments/dev
terraform apply
```

---

## Checklist

- [ ] VPC module created at `terraform/modules/vpc/`
- [ ] Module has `variables.tf`, `main.tf`, `outputs.tf`
- [ ] Dev environment created at `terraform/environments/dev/`
- [ ] `backend.hcl` has your real account ID (not placeholder)
- [ ] `terraform.tfvars` restricts SSH to your IP (recommended)
- [ ] `terraform init -backend-config=backend.hcl` succeeds
- [ ] `terraform plan` shows ~10 resources to create
- [ ] `terraform apply` completes without errors
- [ ] VPC exists with CIDR 10.0.0.0/16
- [ ] Public subnet exists with CIDR 10.0.1.0/24
- [ ] Internet gateway is attached to VPC
- [ ] Security group has ports: 22, 80, 443, 6443, 30000-32767
- [ ] State file visible in S3 bucket under `dev/infrastructure/`
- [ ] All resources tagged with Project, Environment, ManagedBy

---

## What's Next?

In [Guide 05 — Terraform Compute (EC2 + k3s)](./05-terraform-compute.md), you will
launch a spot EC2 instance inside this VPC, install k3s automatically via user-data,
and configure an Elastic IP for a stable address.
