# DevOps Zero to Hero - Project Instructions

## Project Overview
Complete DevOps learning platform with 35 production tools on k3s/AWS.
Repo: `devops-zero-to-hero` | Owner: `guyellkayam`

## Architecture
- **Cloud**: AWS (EC2 t3.large spot, VPC public subnet, ECR)
- **K8s**: k3s single-node cluster
- **GitOps**: ArgoCD + Argo Rollouts (canary/blue-green)
- **CI/CD**: GitHub Actions with OIDC (zero secrets)
- **Secrets**: Vault → ESO → K8s Secrets
- **Observability**: Prometheus + Grafana + Loki + OTel + Tempo
- **Security**: Kyverno + Trivy + Falco + Cosign + SLSA
- **AI**: k8sgpt + Bedrock + LangChain/LangGraph

## Coding Standards

### Terraform
- Use modules for reusability (`terraform/modules/`)
- Separate environments (`terraform/environments/dev/`, `prd/`)
- Remote state in S3 + DynamoDB locking
- Always use `terraform fmt` and `terraform validate`
- Tag all resources: `Project=devops-zero-to-hero`, `Environment=dev|prd`, `ManagedBy=terraform`

### Kubernetes/Helm
- One namespace per tool
- Always set resource requests AND limits
- Use Kustomize for app overlays, Helm for 3rd-party tools
- Network policies: default-deny, explicit allow
- Pod Security Admission: restricted profile

### GitHub Actions
- OIDC for AWS (never use long-lived access keys)
- Reusable workflows for common patterns
- Security scanning in every CI pipeline
- GitHub Environments with approval gates for staging/prod

### Microservices
- api-gateway: Node.js/Express
- user-service: Python/FastAPI
- order-service: Node.js/Express
- All services expose `/health` and `/metrics` (Prometheus)
- Structured JSON logging

### Documentation
- Learning paths go in `docs/learning-paths/phase-N-*/`
- Setup guides go in `docs/setup-guides/NN-name.md`
- Each guide: Why → How (step-by-step) → Verify → Troubleshooting

## File Naming
- Terraform: `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`
- K8s manifests: lowercase with hyphens (e.g., `cluster-issuer.yaml`)
- Setup guides: numbered `NN-name.md`
- Learning paths: descriptive `topic-name.md`

## Key Paths
- Terraform modules: `terraform/modules/`
- ArgoCD apps: `gitops/apps/`
- Platform Helm values: `gitops/platform/`
- App manifests: `gitops/application/`
- CI/CD: `.github/workflows/`
- Scripts: `scripts/`

## Common Commands
```bash
make plan          # Terraform plan for dev
make apply         # Terraform apply for dev
make destroy       # Terraform destroy for dev
make cost          # AWS cost report
make status        # k3s cluster status
make install-all   # Install all platform tools
make teardown      # Full teardown (EC2 + all resources)
```

## Important Rules
- NEVER commit secrets, keys, or credentials
- NEVER use `latest` tag for container images
- Always test Terraform changes with `plan` before `apply`
- All containers run as non-root
- Every deployment needs liveness + readiness probes
