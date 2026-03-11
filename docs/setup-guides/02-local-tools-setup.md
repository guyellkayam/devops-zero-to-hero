# 02 — Local Development Tools Setup

## Why Each Tool Is Needed

| Tool | What It Does | Why You Need It |
|------|-------------|-----------------|
| **AWS CLI** | Talk to AWS from terminal | Create/manage AWS resources |
| **Terraform** | Define infrastructure as code | Reproducible, version-controlled infra |
| **kubectl** | Talk to Kubernetes clusters | Deploy, debug, manage K8s workloads |
| **Helm** | Package manager for K8s | Install ArgoCD, cert-manager, Harbor, etc. |
| **Docker** | Build container images | Package your app into containers |
| **k9s** | Terminal UI for K8s | Visual way to see pods, logs, debug |
| **jq** | Parse JSON in terminal | Process AWS/K8s command outputs |
| **Git** | Version control | Everything is in Git |
| **gh** | GitHub CLI | Create repos, PRs, manage workflows |
| **cosign** | Container image signing | Sign and verify container images |
| **trivy** | Security scanner | Scan images for CVEs locally |

---

## Installation (macOS with Homebrew)

### Install All Tools
```bash
# Core tools
brew install awscli
brew install terraform
brew install kubectl
brew install helm
brew install --cask docker   # Docker Desktop

# Recommended
brew install k9s
brew install jq
brew install gh

# Security tools (used in CI/CD too)
brew install cosign
brew install trivy
brew install syft

# Optional but useful
brew install kubectx          # Switch clusters/namespaces quickly
brew install stern             # Multi-pod log tailing
brew install yq               # YAML processor (like jq for YAML)
```

### Verify Everything Works
```bash
echo "=== AWS CLI ===" && aws --version
echo "=== Terraform ===" && terraform --version
echo "=== kubectl ===" && kubectl version --client --short 2>/dev/null || kubectl version --client
echo "=== Helm ===" && helm version --short
echo "=== Docker ===" && docker --version
echo "=== k9s ===" && k9s version --short 2>/dev/null || echo "k9s not installed (optional)"
echo "=== jq ===" && jq --version
echo "=== Git ===" && git --version
echo "=== gh ===" && gh --version
echo "=== cosign ===" && cosign version 2>/dev/null || echo "cosign not installed"
echo "=== trivy ===" && trivy --version 2>/dev/null || echo "trivy not installed"
```

All should return version numbers without errors.

---

## Configure Tools

### AWS CLI (already done in guide 01)
```bash
aws configure
aws sts get-caller-identity
```

### Docker — Verify Running
```bash
docker ps
# Should return empty table (no error)
# If error: start Docker Desktop app
```

### GitHub CLI — Authenticate
```bash
gh auth login
# Choose: GitHub.com → HTTPS → Login with a web browser
# Follow the prompts

# Verify
gh auth status
```

### kubectl — Will Configure After K8s is Up
No config needed yet. After k3s is deployed (guide 07), we'll copy the kubeconfig.

### Helm — Add Common Repos
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add jetstack https://charts.jetstack.io
helm repo add harbor https://helm.goharbor.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

---

## Tool Cheat Sheet

### Terraform
```bash
terraform init        # Download providers, initialize
terraform plan        # Preview what will change
terraform apply       # Create/update resources
terraform destroy     # Delete everything (careful!)
terraform fmt         # Format code
terraform validate    # Check syntax
terraform state list  # List managed resources
```

### kubectl
```bash
kubectl get nodes              # List cluster nodes
kubectl get pods               # List pods
kubectl get pods -A            # All namespaces
kubectl get svc -A             # All services
kubectl logs <pod-name>        # View pod logs
kubectl logs -f <pod-name>     # Follow logs
kubectl describe pod <name>    # Detailed pod info
kubectl apply -f file.yaml     # Apply manifest
kubectl delete -f file.yaml    # Delete resources
kubectl port-forward svc/X 8080:80  # Access service locally
kubectl exec -it <pod> -- sh   # Shell into pod
kubectl top pods -A            # Resource usage
```

### Helm
```bash
helm repo add <name> <url>     # Add chart repository
helm repo update               # Refresh repos
helm search repo <keyword>     # Search for charts
helm install <name> <chart> -n <ns>  # Install a chart
helm upgrade <name> <chart> -n <ns>  # Upgrade a release
helm uninstall <name> -n <ns>  # Remove a release
helm list -A                   # List all releases
helm show values <chart>       # View default values
```

### Docker
```bash
docker build -t myapp:v1 .     # Build image
docker run -p 3000:3000 myapp  # Run container
docker ps                      # List running containers
docker images                  # List local images
docker push <registry>/myapp   # Push to registry
docker logs <container>        # View container logs
docker system prune -f         # Clean up unused resources
```

### k9s (Terminal UI)
```bash
k9s                            # Launch k9s
# Inside k9s:
# :pods       → list pods
# :svc        → list services
# :ns         → list namespaces
# :deploy     → list deployments
# /           → filter
# d           → describe
# l           → logs
# s           → shell
# ctrl-d      → delete
# :q          → quit
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `brew: command not found` | Install Homebrew: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| `terraform: command not found` | Run `brew install terraform` then restart terminal |
| Docker permission errors | Start Docker Desktop app first |
| `gh auth` fails | Try `gh auth login --web` |
| kubectl old version | `brew upgrade kubectl` |
| Helm repo add fails | Check internet connection, try `helm repo update` |

---

## Checklist

- [ ] AWS CLI installed and configured
- [ ] Terraform installed and `terraform --version` works
- [ ] kubectl installed and `kubectl version --client` works
- [ ] Helm installed and `helm version` works
- [ ] Docker Desktop installed and running
- [ ] k9s installed (recommended)
- [ ] jq installed
- [ ] GitHub CLI installed and authenticated
- [ ] cosign installed (for image signing)
- [ ] trivy installed (for security scanning)
- [ ] All verification commands pass

---

## What's Next?
→ [03 — Terraform Backend](03-terraform-backend.md)
