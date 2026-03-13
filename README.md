# DevOps Zero to Hero

Complete DevOps learning platform: From junior to senior engineer. 35 production tools running on k3s/AWS, 14 implementation sprints, full CI/CD with GitOps.

## Architecture
https://miro.com/app/board/uXjVGy95E1s=/
```
GitHub (Source of Truth)
├── Code changes → GitHub Actions (CI) → Security scan → Build → Sign → Push to ECR
├── Infra changes → GitHub Actions → Terraform Apply
└── Image tag updated → ArgoCD Image Updater → ArgoCD (CD) → Deploy to k3s

AWS ($25-45/mo)
├── VPC (public subnet, no NAT = $0)
├── EC2 t3.large spot (~$24/mo)
│   └── k3s (Kubernetes)
│       ├── ArgoCD (GitOps CD)
│       ├── Argo Rollouts (Canary/Blue-Green)
│       ├── Vault + ESO (Secrets)
│       ├── Envoy Gateway (API routing)
│       ├── Harbor (Container registry)
│       ├── Longhorn (Persistent storage)
│       ├── MetalLB (Load balancer)
│       ├── CloudNativePG (PostgreSQL)
│       ├── cert-manager (TLS)
│       ├── Kyverno (Policy engine)
│       ├── Prometheus + Grafana + Loki + OTel (Observability)
│       ├── Velero (Backup)
│       ├── Dex (SSO)
│       ├── k8sgpt (AI diagnostics)
│       └── 3 Microservices (api-gateway, user-service, order-service)
└── ECR (Container registry)
```

## Deployment Strategies

| Environment | Strategy | Validation |
|-------------|----------|------------|
| **dev** | Rolling update | Auto-deploy on merge |
| **staging** | Blue/Green | 1 approval required |
| **production** | Canary (10%→25%→50%→100%) | 2 approvals + Prometheus analysis + auto-rollback |

## CI/CD Security Pipeline

```
Code Push → Gitleaks (secrets) → Semgrep (SAST) → Build → Trivy (CVE) → Syft (SBOM) → Cosign (sign) → SLSA Level 2
```

## Project Structure

```
.
├── docs/
│   ├── architecture/          # Excalidraw diagrams
│   ├── learning-paths/        # WHAT to learn (11 phases, ~61 guides)
│   │   ├── phase-0-prerequisites/
│   │   ├── phase-1-aws-foundation/
│   │   ├── phase-2-iac/
│   │   ├── phase-3-containers/
│   │   ├── phase-4-cicd-gitops/
│   │   ├── phase-5-platform-tools/
│   │   ├── phase-6-advanced-operations/
│   │   ├── phase-7-observability/
│   │   ├── phase-8-security/
│   │   ├── phase-9-platform-engineering/
│   │   └── phase-10-ai-devops/
│   └── setup-guides/          # HOW to do it (30 step-by-step guides)
├── terraform/                 # Infrastructure as Code
│   ├── 00-backend/            # S3 + DynamoDB
│   ├── modules/               # vpc, ec2-k3s, ecr, oidc-github, budget
│   └── environments/          # dev, prd
├── services/                  # 3 Microservices
│   ├── api-gateway/           # Node.js/Express
│   ├── user-service/          # Python/FastAPI
│   └── order-service/         # Node.js/Express
├── gitops/                    # ArgoCD manifests
│   ├── root-app.yaml          # App-of-Apps
│   ├── applicationsets/       # Dynamic app generation
│   ├── application/           # Kustomize base + overlays
│   └── platform/              # Helm values for 20+ tools
├── helm/                      # Helm charts per service
├── .github/workflows/         # 14 CI/CD workflows
├── scripts/                   # Bootstrap, teardown, cost
├── ai/                        # LangChain, LangGraph, k8sgpt
└── exercises/                 # 9 hands-on exercises
```

## Getting Started

Follow the setup guides in order:

### Foundation
1. [AWS Account Security](docs/setup-guides/01-aws-account-security.md) - MFA, IAM, billing
2. [Local Tools Setup](docs/setup-guides/02-local-tools-setup.md) - Install CLI tools

### Infrastructure
3. [Terraform Backend](docs/setup-guides/03-terraform-backend.md) - S3 + DynamoDB
4. [Terraform Network](docs/setup-guides/04-terraform-network.md) - VPC, subnets
5. [Terraform Compute](docs/setup-guides/05-terraform-compute.md) - EC2 spot + k3s
6. [Terraform ECR](docs/setup-guides/06-terraform-ecr.md) - Container repos

### k3s Platform
7. [k3s Cluster](docs/setup-guides/07-k3s-cluster-setup.md) - Cluster setup
8. [MetalLB](docs/setup-guides/08-metallb-setup.md) - Load balancer
9. [Longhorn](docs/setup-guides/09-longhorn-setup.md) - Storage
10. [Vault](docs/setup-guides/10-vault-setup.md) - Secrets engine
11. [ESO](docs/setup-guides/11-eso-setup.md) - External Secrets
12. [cert-manager](docs/setup-guides/12-cert-manager-setup.md) - TLS
13. [Envoy Gateway](docs/setup-guides/13-envoy-gateway-setup.md) - API gateway
14. [Harbor](docs/setup-guides/14-harbor-setup.md) - Registry
15. [PostgreSQL](docs/setup-guides/15-postgres-operator-setup.md) - Database

### GitOps + CD
16. [ArgoCD](docs/setup-guides/16-argocd-setup.md) - GitOps CD
17. [Argo Rollouts](docs/setup-guides/17-argo-rollouts-setup.md) - Canary/B-G
18. [Helm Charts](docs/setup-guides/18-helm-charts-setup.md) - Package management

### Security + Observability
19. [Kyverno](docs/setup-guides/19-kyverno-setup.md) - Policies
20. [Observability](docs/setup-guides/20-observability-setup.md) - Prometheus + Grafana + Loki + OTel
21. [Security Tools](docs/setup-guides/21-security-tools-setup.md) - Trivy + Falco + Cosign
22. [Velero](docs/setup-guides/22-backup-velero-setup.md) - Backup + DR
23. [Dex SSO](docs/setup-guides/23-dex-sso-setup.md) - Single Sign-On

### CI/CD
24. [GitHub Actions](docs/setup-guides/24-github-actions-setup.md) - CI + OIDC
25. [Image Updater](docs/setup-guides/25-image-updater-setup.md) - Auto-deploy

### Advanced
26. [Linkerd](docs/setup-guides/26-linkerd-setup.md) - Service mesh
27. [Chaos Engineering](docs/setup-guides/27-chaos-engineering-setup.md) - LitmusChaos
28. [Cost Optimization](docs/setup-guides/28-cost-optimization.md) - OpenCost
29. [AI Tools](docs/setup-guides/29-ai-tools-setup.md) - k8sgpt + Bedrock + LangChain
30. [Advanced GitOps](docs/setup-guides/30-advanced-gitops-setup.md) - Flux + Crossplane

## Tool Inventory (35 Tools)

| Category | Tools |
|----------|-------|
| **Orchestration** | k3s, Helm, Kustomize |
| **GitOps** | ArgoCD, Argo Rollouts, ArgoCD Image Updater |
| **Secrets** | HashiCorp Vault, External Secrets Operator |
| **Networking** | Envoy Gateway, MetalLB, cert-manager, ExternalDNS |
| **Storage** | Longhorn, CloudNativePG |
| **Registry** | Harbor, ECR |
| **Observability** | Prometheus, Grafana, Loki, OTel Collector, Grafana Tempo |
| **Security** | Kyverno, Trivy Operator, Falco, Cosign, Gitleaks, Semgrep |
| **CI/CD** | GitHub Actions (OIDC), Syft SBOM, SLSA |
| **Operations** | Velero, LitmusChaos, OpenCost |
| **Identity** | Dex (OIDC SSO) |
| **AI** | k8sgpt, AWS Bedrock, LangChain, LangGraph |
| **IaC** | Terraform |
| **Advanced** | Linkerd, Flux v2, Crossplane, Kaniko |

## Monthly Cost

| Resource | Cost |
|----------|------|
| EC2 t3.large spot | ~$24 |
| S3 + DynamoDB (TF state) | $0.02 |
| ECR (3 repos) | $0-0.50 |
| GitHub Actions | Free |
| All OSS tools | Free |
| AWS Bedrock (AI) | $5-20 |
| **Total** | **~$25-45/mo** |

Run `make teardown` to destroy everything when not learning ($0 idle).

## Quick Commands

```bash
make plan          # Terraform plan
make apply         # Terraform apply
make destroy       # Terraform destroy
make cost          # Check AWS spend
make status        # k3s cluster status
make install-all   # Install all k8s tools
make teardown      # Destroy everything safely
```

## Tech Stack

| Tool | Purpose | CNCF Status |
|------|---------|-------------|
| Terraform | Infrastructure as Code | - |
| k3s | Lightweight Kubernetes | Sandbox |
| ArgoCD | GitOps CD | Graduated |
| Argo Rollouts | Progressive Delivery | Incubating |
| Vault | Secrets Management | - |
| ESO | Secret Sync | - |
| Envoy Gateway | API Gateway | Graduated (Envoy) |
| Harbor | Container Registry | Graduated |
| Longhorn | Storage | Incubating |
| Prometheus | Metrics | Graduated |
| Kyverno | Policy Engine | Incubating |
| Linkerd | Service Mesh | Graduated |
| Falco | Runtime Security | Graduated |
| LitmusChaos | Chaos Engineering | Incubating |
| Velero | Backup & DR | - |
| OTel | Telemetry | Incubating |
| Flux v2 | GitOps (alternative) | Graduated |
| Crossplane | K8s-native IaC | Incubating |
