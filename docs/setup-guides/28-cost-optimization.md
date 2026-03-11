# 28 — Cost Optimization with OpenCost and AWS Strategies

## Why This Matters
The entire point of this learning platform is running a production-grade DevOps stack for
$25-45/month instead of the $500+/month it would cost with managed services. But without
visibility into what is actually costing money, you are flying blind. A misconfigured PVC, a
forgotten NAT gateway, or an idle cluster over a weekend can double your bill.

OpenCost is a CNCF sandbox project that provides real-time Kubernetes cost allocation. Here is
why we chose it over Kubecost:

| Feature | OpenCost | Kubecost Free | Kubecost Enterprise |
|---------|----------|---------------|---------------------|
| **RAM usage** | ~100MB | ~300MB | ~500MB+ |
| **License** | Apache 2.0 | Freemium | Commercial |
| **CNCF status** | Sandbox | N/A | N/A |
| **Cost allocation** | Namespace, label, pod | Limited | Full |
| **Cloud cost** | AWS integration | Limited | Full |
| **Recommendations** | Basic | Basic | Advanced |
| **Price** | Free | Free (limited) | $199+/node/yr |

OpenCost uses 3x less RAM than Kubecost while giving us the cost allocation we need. Combined
with AWS-level optimization strategies (spot instances, right-sizing, scheduling), we keep
costs rock-bottom.

---

## Prerequisites
- k3s cluster running (guide 07)
- kubectl and Helm installed (guide 02)
- Prometheus running (guide 14)
- Grafana running (guide 15)
- AWS CLI configured with appropriate permissions
- Terraform state accessible (guide 03)
- ~100MB RAM available for OpenCost

---

## Our Cost Architecture

Here is how our ~$25-45/month breaks down:

| Resource | Monthly Cost | Strategy |
|----------|-------------|----------|
| **EC2 t3.large (spot)** | $15-25 | Spot instance, 60-70% savings |
| **EBS 30GB gp3** | $2.40 | Minimal storage, lifecycle policies |
| **S3 (Terraform state)** | $0.10 | Versioning + lifecycle |
| **Route53 hosted zone** | $0.50 | 1 zone |
| **Data transfer** | $1-5 | Minimal egress |
| **ECR (container images)** | $0.50-2 | Lifecycle policies |
| **NAT Gateway** | $0 | We do NOT use one |
| **Total** | ~$25-35 | |

> **The #1 cost killer**: NAT Gateways at $32/month + data processing fees. We avoid this
> entirely by using a public subnet with a security group.

---

## Step 1: Install OpenCost

```bash
# Create the namespace
kubectl create namespace opencost

# Add the OpenCost Helm repository
helm repo add opencost https://opencost.github.io/opencost-helm-chart
helm repo update

# Install OpenCost with resource constraints
helm install opencost opencost/opencost \
  --namespace opencost \
  --set opencost.exporter.defaultClusterId="devops-lab" \
  --set opencost.exporter.resources.requests.cpu=10m \
  --set opencost.exporter.resources.requests.memory=32Mi \
  --set opencost.exporter.resources.limits.cpu=100m \
  --set opencost.exporter.resources.limits.memory=128Mi \
  --set opencost.ui.enabled=true \
  --set opencost.ui.resources.requests.cpu=10m \
  --set opencost.ui.resources.requests.memory=16Mi \
  --set opencost.ui.resources.limits.cpu=100m \
  --set opencost.ui.resources.limits.memory=64Mi \
  --set opencost.prometheus.internal.serviceName=prometheus-kube-prometheus-prometheus \
  --set opencost.prometheus.internal.namespaceName=monitoring \
  --set opencost.prometheus.internal.port=9090
```

Wait for pods to be ready:
```bash
kubectl get pods -n opencost -w
```

---

## Step 2: Configure Custom Pricing

Since we run on spot instances, configure OpenCost with our actual pricing.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-custom-pricing
  namespace: opencost
data:
  default.json: |
    {
      "provider": "custom",
      "description": "DevOps Lab - t3.large spot pricing",
      "CPU": "0.0116",
      "spotCPU": "0.0116",
      "RAM": "0.0058",
      "spotRAM": "0.0058",
      "GPU": "0",
      "storage": "0.00013",
      "zoneNetworkEgress": "0.01",
      "regionNetworkEgress": "0.01",
      "internetNetworkEgress": "0.09"
    }
EOF
```

> **Pricing explanation**: t3.large spot in us-east-1 is roughly $0.0250/hr. With 2 vCPU and
> 8GB RAM, that is $0.0116/vCPU-hr and $0.0058/GB-hr. These values feed into OpenCost's
> allocation model.

---

## Step 3: Access the OpenCost UI

```bash
# Port-forward the OpenCost UI
kubectl port-forward svc/opencost -n opencost 9090:9090
```

Open http://localhost:9090 in your browser. You will see cost allocation broken down by
namespace, controller, and pod.

### Key Views in the UI

1. **Namespace view**: See which namespaces cost the most
2. **Controller view**: Cost per deployment/statefulset
3. **Pod view**: Individual pod costs

---

## Step 4: Cost Allocation by Namespace, Team, and Service

### Query the OpenCost API

```bash
# Cost allocation by namespace (last 24 hours)
kubectl port-forward svc/opencost -n opencost 9003:9003 &

# Namespace-level costs
curl -s "http://localhost:9003/allocation/compute?window=24h&aggregate=namespace" | jq '.data[] | to_entries[] | {namespace: .key, totalCost: .value.totalCost}'

# Service-level costs (by controller)
curl -s "http://localhost:9003/allocation/compute?window=24h&aggregate=controller" | jq '.data[] | to_entries[] | {controller: .key, cpuCost: .value.cpuCost, ramCost: .value.ramCost, totalCost: .value.totalCost}'

# Cost by label (team-based allocation)
curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=label:team" | jq '.data[] | to_entries[] | {team: .key, totalCost: .value.totalCost}'
```

### Label Your Resources for Cost Tracking

```bash
# Add team labels to deployments for cost allocation
kubectl label deployment -n apps api-service team=backend cost-center=engineering
kubectl label deployment -n apps frontend team=frontend cost-center=engineering
kubectl label deployment -n apps worker team=backend cost-center=engineering
kubectl label deployment -n monitoring prometheus-kube-prometheus-prometheus team=platform cost-center=infrastructure
kubectl label deployment -n argocd argocd-server team=platform cost-center=infrastructure
```

---

## Step 5: AWS Spot Instance Optimization

Our biggest cost saving: spot instances give us 60-70% off on-demand pricing.

### Terraform Spot Configuration

```hcl
# In your Terraform EC2 module (terraform/modules/ec2/main.tf)
resource "aws_spot_instance_request" "devops_lab" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.large"
  spot_type              = "persistent"
  wait_for_fulfillment   = true
  instance_interruption_behavior = "stop"

  # Bid at on-demand price (you pay spot price, but never get outbid)
  spot_price = "0.0832"

  vpc_security_group_ids = [aws_security_group.devops_lab.id]
  subnet_id              = aws_subnet.public.id
  key_name               = aws_key_pair.devops.key_name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    iops        = 3000
    throughput  = 125
    encrypted   = true
  }

  tags = {
    Name        = "devops-lab"
    Environment = "learning"
    ManagedBy   = "terraform"
  }
}
```

### Spot Interruption Handling Script

```bash
# Install on EC2: /usr/local/bin/spot-interruption-handler.sh
cat <<'SCRIPT' | sudo tee /usr/local/bin/spot-interruption-handler.sh
#!/bin/bash
# Check for spot interruption notice (2 minutes warning)
while true; do
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)

  if [ "$RESPONSE" -eq 200 ]; then
    echo "$(date): Spot interruption notice received!"

    # Cordon the node (prevent new pods)
    kubectl cordon $(hostname)

    # Drain gracefully (respect PDBs)
    kubectl drain $(hostname) \
      --grace-period=60 \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --force

    echo "$(date): Node drained. Spot interruption in ~2 minutes."
  fi

  sleep 5
done
SCRIPT

sudo chmod +x /usr/local/bin/spot-interruption-handler.sh
```

```bash
# Create a systemd service for the handler
cat <<'SERVICE' | sudo tee /etc/systemd/system/spot-handler.service
[Unit]
Description=EC2 Spot Interruption Handler
After=k3s.service

[Service]
Type=simple
ExecStart=/usr/local/bin/spot-interruption-handler.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl enable spot-handler
sudo systemctl start spot-handler
```

---

## Step 6: Right-Sizing with VPA Recommendations

The Vertical Pod Autoscaler (VPA) analyzes actual resource usage and recommends right-sized
requests/limits.

```bash
# Install VPA (recommender only -- we do NOT want auto-updates on a learning cluster)
git clone https://github.com/kubernetes/autoscaler.git /tmp/autoscaler
cd /tmp/autoscaler/vertical-pod-autoscaler
./hack/vpa-up.sh

# Or via Helm
helm repo add cowboysysop https://cowboysysop.github.io/charts/
helm install vpa cowboysysop/vertical-pod-autoscaler \
  --namespace kube-system \
  --set recommender.resources.requests.cpu=10m \
  --set recommender.resources.requests.memory=32Mi \
  --set recommender.resources.limits.cpu=100m \
  --set recommender.resources.limits.memory=128Mi \
  --set updater.enabled=false \
  --set admissionController.enabled=false
```

### Create VPA Objects for Your Services

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api-service-vpa
  namespace: apps
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-service
  updatePolicy:
    updateMode: "Off"  # Only recommend, do not auto-update
  resourcePolicy:
    containerPolicies:
      - containerName: api-service
        minAllowed:
          cpu: 10m
          memory: 32Mi
        maxAllowed:
          cpu: 500m
          memory: 512Mi
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: frontend-vpa
  namespace: apps
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: frontend
  updatePolicy:
    updateMode: "Off"
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: worker-vpa
  namespace: apps
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: worker
  updatePolicy:
    updateMode: "Off"
EOF
```

### Read VPA Recommendations

```bash
# After 24 hours of running, check recommendations
kubectl get vpa -n apps -o yaml | grep -A20 "recommendation"
```

Example output:
```yaml
recommendation:
  containerRecommendations:
    - containerName: api-service
      lowerBound:
        cpu: 15m
        memory: 48Mi
      target:
        cpu: 25m
        memory: 64Mi
      uncappedTarget:
        cpu: 25m
        memory: 64Mi
      upperBound:
        cpu: 100m
        memory: 128Mi
```

Use the `target` values to update your deployment resource requests for optimal right-sizing.

---

## Step 7: Scale Down Non-Production at Night

Save 50%+ by stopping the cluster when you are not learning.

### Option A: Make Commands (Recommended)

```makefile
# Add to your project Makefile
.PHONY: sleep wake teardown

# Stop the EC2 instance (keeps EBS volume, ~$0.08/day for storage)
sleep:
	@echo "Putting devops lab to sleep..."
	aws ec2 stop-instances \
		--instance-ids $$(terraform -chdir=terraform output -raw instance_id)
	@echo "Instance stopped. EBS storage costs ~$0.08/day while sleeping."
	@echo "Run 'make wake' to resume."

# Start the EC2 instance
wake:
	@echo "Waking up devops lab..."
	aws ec2 start-instances \
		--instance-ids $$(terraform -chdir=terraform output -raw instance_id)
	@echo "Waiting for instance to be running..."
	aws ec2 wait instance-running \
		--instance-ids $$(terraform -chdir=terraform output -raw instance_id)
	@echo "Instance running. Getting new public IP..."
	@NEW_IP=$$(aws ec2 describe-instances \
		--instance-ids $$(terraform -chdir=terraform output -raw instance_id) \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text) && \
	echo "New IP: $$NEW_IP" && \
	echo "Update your kubeconfig: ssh -i ~/.ssh/devops-key.pem ubuntu@$$NEW_IP"

# Destroy EVERYTHING ($0/month when not in use)
teardown:
	@echo "WARNING: This destroys ALL resources. Type 'yes' to confirm:"
	@read confirm && [ "$$confirm" = "yes" ] || (echo "Aborted." && exit 1)
	terraform -chdir=terraform destroy -auto-approve
	@echo "All resources destroyed. Monthly cost: $0."
```

### Option B: Automated Schedule with Lambda

```python
# lambda_function.py — Auto-stop at 11 PM, auto-start at 8 AM
import boto3
import os

ec2 = boto3.client('ec2', region_name='us-east-1')
INSTANCE_ID = os.environ['INSTANCE_ID']

def lambda_handler(event, context):
    action = event.get('action', 'stop')

    if action == 'stop':
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        return {'status': 'stopped', 'instance': INSTANCE_ID}
    elif action == 'start':
        ec2.start_instances(InstanceIds=[INSTANCE_ID])
        return {'status': 'started', 'instance': INSTANCE_ID}
```

```hcl
# Terraform for Lambda + EventBridge schedule
resource "aws_lambda_function" "scheduler" {
  filename         = "lambda_function.zip"
  function_name    = "devops-lab-scheduler"
  role             = aws_iam_role.lambda_scheduler.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"

  environment {
    variables = {
      INSTANCE_ID = aws_spot_instance_request.devops_lab.spot_instance_id
    }
  }
}

# Stop at 11 PM UTC (6 PM EST)
resource "aws_cloudwatch_event_rule" "stop_schedule" {
  name                = "devops-lab-stop"
  schedule_expression = "cron(0 23 ? * MON-FRI *)"
}

resource "aws_cloudwatch_event_target" "stop_target" {
  rule  = aws_cloudwatch_event_rule.stop_schedule.name
  arn   = aws_lambda_function.scheduler.arn
  input = jsonencode({ action = "stop" })
}

# Start at 8 AM UTC (3 AM EST)
resource "aws_cloudwatch_event_rule" "start_schedule" {
  name                = "devops-lab-start"
  schedule_expression = "cron(0 8 ? * MON-FRI *)"
}

resource "aws_cloudwatch_event_target" "start_target" {
  rule  = aws_cloudwatch_event_rule.start_schedule.name
  arn   = aws_lambda_function.scheduler.arn
  input = jsonencode({ action = "start" })
}
```

---

## Step 8: ECR Lifecycle Policies

Container images accumulate fast. Set lifecycle policies to auto-delete old ones.

```bash
# Apply lifecycle policy to ECR repository
aws ecr put-lifecycle-policy \
  --repository-name devops-lab/api-service \
  --lifecycle-policy-text '{
    "rules": [
      {
        "rulePriority": 1,
        "description": "Keep only last 5 tagged images",
        "selection": {
          "tagStatus": "tagged",
          "tagPrefixList": ["v"],
          "countType": "imageCountMoreThan",
          "countNumber": 5
        },
        "action": {
          "type": "expire"
        }
      },
      {
        "rulePriority": 2,
        "description": "Delete untagged images older than 1 day",
        "selection": {
          "tagStatus": "untagged",
          "countType": "sinceImagePushed",
          "countUnit": "days",
          "countNumber": 1
        },
        "action": {
          "type": "expire"
        }
      }
    ]
  }'
```

Apply to all repositories:
```bash
# Loop through all ECR repos
for repo in $(aws ecr describe-repositories --query 'repositories[].repositoryName' --output text); do
  echo "Applying lifecycle policy to $repo"
  aws ecr put-lifecycle-policy \
    --repository-name "$repo" \
    --lifecycle-policy-text file://ecr-lifecycle-policy.json
done
```

---

## Step 9: S3 Lifecycle Policies

Keep Terraform state versioned but clean up old versions.

```bash
# Apply lifecycle policy to Terraform state bucket
aws s3api put-bucket-lifecycle-configuration \
  --bucket devops-lab-terraform-state \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "CleanOldVersions",
        "Status": "Enabled",
        "NoncurrentVersionExpiration": {
          "NoncurrentDays": 30,
          "NewerNoncurrentVersions": 5
        },
        "Filter": {
          "Prefix": ""
        }
      },
      {
        "ID": "AbortIncompleteUploads",
        "Status": "Enabled",
        "AbortIncompleteMultipartUpload": {
          "DaysAfterInitiation": 1
        },
        "Filter": {
          "Prefix": ""
        }
      }
    ]
  }'
```

---

## Step 10: Cost Monitoring Dashboard in Grafana

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cost-grafana-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  cost-overview.json: |
    {
      "title": "Cost Overview",
      "uid": "cost-overview",
      "panels": [
        {
          "title": "Monthly Cost Estimate",
          "type": "stat",
          "targets": [
            {
              "expr": "sum(node_total_hourly_cost) * 730",
              "legendFormat": "Monthly EC2 Cost"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "currencyUSD",
              "thresholds": {
                "steps": [
                  { "color": "green", "value": 0 },
                  { "color": "yellow", "value": 30 },
                  { "color": "red", "value": 50 }
                ]
              }
            }
          },
          "gridPos": { "h": 6, "w": 6, "x": 0, "y": 0 }
        },
        {
          "title": "Cost by Namespace (Daily)",
          "type": "piechart",
          "targets": [
            {
              "expr": "sum by (namespace) (container_cpu_usage_seconds_total{namespace!=\"\"}) / scalar(sum(container_cpu_usage_seconds_total{namespace!=\"\"})) * sum(node_total_hourly_cost) * 24",
              "legendFormat": "{{ namespace }}"
            }
          ],
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 }
        },
        {
          "title": "RAM Utilization (Higher = Better Value)",
          "type": "gauge",
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{namespace!=\"\"}) / sum(machine_memory_bytes) * 100",
              "legendFormat": "RAM Usage %"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "min": 0,
              "max": 100,
              "thresholds": {
                "steps": [
                  { "color": "red", "value": 0 },
                  { "color": "yellow", "value": 50 },
                  { "color": "green", "value": 70 },
                  { "color": "red", "value": 90 }
                ]
              }
            }
          },
          "gridPos": { "h": 6, "w": 6, "x": 6, "y": 0 }
        },
        {
          "title": "CPU Utilization (Higher = Better Value)",
          "type": "gauge",
          "targets": [
            {
              "expr": "sum(rate(container_cpu_usage_seconds_total{namespace!=\"\"}[5m])) / sum(machine_cpu_cores) * 100",
              "legendFormat": "CPU Usage %"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "min": 0,
              "max": 100,
              "thresholds": {
                "steps": [
                  { "color": "red", "value": 0 },
                  { "color": "yellow", "value": 40 },
                  { "color": "green", "value": 60 },
                  { "color": "red", "value": 90 }
                ]
              }
            }
          },
          "gridPos": { "h": 6, "w": 6, "x": 12, "y": 0 }
        },
        {
          "title": "Top 10 Pods by Memory Cost",
          "type": "table",
          "targets": [
            {
              "expr": "topk(10, sum by (pod, namespace) (container_memory_working_set_bytes{namespace!=\"\"}) / 1024 / 1024)",
              "legendFormat": "{{ namespace }}/{{ pod }}",
              "format": "table",
              "instant": true
            }
          ],
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 }
        }
      ]
    }
EOF
```

---

## Step 11: Budget Alerts

### AWS Budget Alert (Account Level)

```bash
# Create a $50/month budget alert
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "DevOps-Lab-Monthly",
    "BudgetLimit": {
      "Amount": "50",
      "Unit": "USD"
    },
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[
    {
      "Notification": {
        "NotificationType": "ACTUAL",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 80,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [
        {
          "SubscriptionType": "EMAIL",
          "Address": "your-email@example.com"
        }
      ]
    },
    {
      "Notification": {
        "NotificationType": "FORECASTED",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 100,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [
        {
          "SubscriptionType": "EMAIL",
          "Address": "your-email@example.com"
        }
      ]
    }
  ]'
```

### Prometheus Alert for Resource Waste

```yaml
# Add to PrometheusRule
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cost-alerts
  namespace: monitoring
spec:
  groups:
    - name: cost.rules
      rules:
        - alert: HighCPUOverProvisioning
          expr: |
            (
              sum(kube_pod_container_resource_requests{resource="cpu", namespace="apps"})
              -
              sum(rate(container_cpu_usage_seconds_total{namespace="apps"}[1h]))
            )
            /
            sum(kube_pod_container_resource_requests{resource="cpu", namespace="apps"})
            > 0.7
          for: 24h
          labels:
            severity: info
          annotations:
            summary: "CPU over-provisioned by >70% in apps namespace"
            description: "Consider reducing CPU requests. Wasting {{ $value | humanizePercentage }} of requested CPU."

        - alert: HighMemoryOverProvisioning
          expr: |
            (
              sum(kube_pod_container_resource_requests{resource="memory", namespace="apps"})
              -
              sum(container_memory_working_set_bytes{namespace="apps"})
            )
            /
            sum(kube_pod_container_resource_requests{resource="memory", namespace="apps"})
            > 0.5
          for: 24h
          labels:
            severity: info
          annotations:
            summary: "Memory over-provisioned by >50% in apps namespace"

        - alert: ClusterIdleTooLong
          expr: |
            avg_over_time(
              (sum(rate(container_cpu_usage_seconds_total[5m])) / sum(machine_cpu_cores))[6h:]
            ) < 0.05
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Cluster has been <5% CPU usage for 6+ hours"
            description: "Consider running 'make sleep' to stop the instance and save money."
```

---

## Step 12: The Nuclear Option — make teardown

When you are done learning for a period, destroy everything. Your Terraform state is in S3,
so you can rebuild in 15 minutes.

```bash
# The full teardown command
make teardown
```

This runs `terraform destroy` which removes:
- EC2 instance ($0)
- EBS volumes ($0)
- Security groups ($0)
- Route53 records ($0)

What remains (pennies/month):
- S3 bucket with Terraform state (~$0.02/month)
- Route53 hosted zone ($0.50/month)
- ECR images (first 500MB free)

### Rebuild from scratch

```bash
# Recreate everything
make infra     # terraform apply
make setup     # configure EC2
make cluster   # install k3s
make deploy    # install all tools via ArgoCD
```

Total rebuild time: ~15 minutes. Total cost while idle: ~$0.52/month.

---

## Verify

```bash
# 1. OpenCost pods running
kubectl get pods -n opencost

# 2. OpenCost UI accessible
kubectl port-forward svc/opencost -n opencost 9090:9090 &
curl -s -o /dev/null -w "%{http_code}" http://localhost:9090
# Should return 200

# 3. Cost API returning data
curl -s "http://localhost:9003/allocation/compute?window=1h&aggregate=namespace" | jq '.data | length'
# Should be > 0

# 4. VPA installed and recommending
kubectl get vpa -n apps

# 5. ECR lifecycle policy applied
aws ecr get-lifecycle-policy --repository-name devops-lab/api-service --query 'lifecyclePolicyText' --output text | jq .

# 6. AWS Budget created
aws budgets describe-budgets --account-id $(aws sts get-caller-identity --query Account --output text) --query 'Budgets[].BudgetName'

# 7. Grafana cost dashboard available
# Open Grafana > Dashboards > Cost Overview

# 8. Resource usage
kubectl top pods -n opencost
```

---

## Troubleshooting

### OpenCost Shows $0 for Everything

```bash
# Check if OpenCost can reach Prometheus
kubectl logs -n opencost -l app=opencost --tail=50 | grep -i "prometheus\|error"

# Verify Prometheus endpoint
kubectl exec -n opencost -it deploy/opencost -- wget -qO- http://prometheus-kube-prometheus-prometheus.monitoring:9090/api/v1/query?query=up | head -5

# Check custom pricing is applied
kubectl get configmap -n opencost opencost-custom-pricing -o yaml
```

### VPA Not Showing Recommendations

```bash
# VPA needs 24+ hours of metrics
kubectl describe vpa -n apps api-service-vpa | grep -A20 "Status"

# Check VPA recommender logs
kubectl logs -n kube-system -l app=vpa-recommender --tail=30
```

### Spot Instance Interrupted

```bash
# Check instance state
aws ec2 describe-spot-instance-requests --query 'SpotInstanceRequests[].{ID:InstanceId,Status:Status.Code,State:State}'

# If terminated, the persistent request will launch a new one
# You may need to update kubeconfig with new IP
aws ec2 describe-instances --filters "Name=tag:Name,Values=devops-lab" --query 'Reservations[].Instances[].PublicIpAddress' --output text
```

### AWS Budget Not Sending Alerts

```bash
# Verify budget exists
aws budgets describe-budgets --account-id $(aws sts get-caller-identity --query Account --output text)

# Check subscriber email is verified (check spam folder)
# Budgets require email confirmation before sending
```

---

## Checklist

- [ ] OpenCost installed in opencost namespace
- [ ] Custom pricing configured for spot instance rates
- [ ] OpenCost UI accessible and showing data
- [ ] Cost API returning allocation data
- [ ] Resources labeled with team/cost-center
- [ ] Spot instance configured in Terraform
- [ ] Spot interruption handler installed and running
- [ ] VPA installed in recommendation-only mode
- [ ] VPA objects created for all microservices
- [ ] ECR lifecycle policies applied to all repositories
- [ ] S3 lifecycle policy for Terraform state bucket
- [ ] make sleep/wake/teardown commands working
- [ ] Grafana cost dashboard imported
- [ ] AWS Budget alert created ($50/month)
- [ ] Prometheus cost-waste alerts configured
- [ ] Understand the $0 idle cost path (make teardown)

---

## What's Next?
With cost visibility and optimization strategies in place, you know exactly where every dollar
goes and have automated strategies to keep costs minimal. The combination of spot instances,
right-sizing, and the ability to destroy/rebuild in 15 minutes means you never pay for idle
resources.

Next, proceed to **Guide 29 -- AI Tools Setup** where we will add AI-powered cluster
diagnostics with k8sgpt, connect to AWS Bedrock for LLM capabilities, and build DevOps AI
agents with LangChain and LangGraph.
