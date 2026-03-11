# 29 — AI Tools Setup: k8sgpt, Bedrock, LangChain, and LangGraph

## Why This Matters
AI is transforming how we operate infrastructure. Instead of manually reading through 500 lines
of `kubectl describe` output to find why a pod is crashing, AI can analyze it in seconds and
tell you the root cause in plain English. Instead of building brittle bash scripts for
incident response, you can build intelligent agents that reason about your infrastructure.

This guide covers four layers of AI tooling:

| Tool | Purpose | Cost |
|------|---------|------|
| **k8sgpt** | AI-powered cluster diagnostics | Free (uses Bedrock) |
| **AWS Bedrock** | Managed LLM API | $5-20/mo usage-based |
| **LangChain** | Build DevOps AI agents | Free (library) |
| **LangGraph** | Stateful multi-step workflows | Free (library) |

**Why Bedrock over self-hosted Ollama?** Self-hosting an LLM on our t3.large would need a GPU
instance ($75+/month minimum) or consume all our RAM. Bedrock gives us access to Claude,
Titan, and Llama models at $0.25-15 per million tokens -- which means $5-20/month for a
learning platform with moderate usage. No GPU needed, no RAM consumed, and you get access to
state-of-the-art models.

---

## Prerequisites
- k3s cluster running (guide 07)
- kubectl and Helm installed (guide 02)
- Prometheus + Grafana + Loki running (guides 14/15/16)
- AWS account with Bedrock access enabled
- Python 3.11+ on your local machine
- pip or pipenv for Python dependency management
- Basic Python knowledge

---

## Part 1: k8sgpt — AI-Powered Cluster Diagnostics

### What k8sgpt Does

k8sgpt scans your cluster for issues (misconfigured pods, failing services, resource problems)
and uses an LLM to explain what is wrong and how to fix it. Think of it as an SRE that never
sleeps.

### Step 1.1: Install k8sgpt CLI

```bash
# macOS
brew install k8sgpt

# Linux
curl -LO https://github.com/k8sgpt-ai/k8sgpt/releases/latest/download/k8sgpt_Linux_x86_64.tar.gz
tar -xzf k8sgpt_Linux_x86_64.tar.gz
sudo mv k8sgpt /usr/local/bin/
rm k8sgpt_Linux_x86_64.tar.gz

# Verify
k8sgpt version
```

### Step 1.2: Configure k8sgpt with AWS Bedrock Backend

```bash
# Configure Bedrock as the AI backend
k8sgpt auth add \
  --backend amazonbedrock \
  --model anthropic.claude-3-haiku-20240307-v1:0 \
  --providerRegion us-east-1

# Set as default backend
k8sgpt auth default --backend amazonbedrock

# Verify configuration
k8sgpt auth list
```

> **Model choice**: Claude 3 Haiku is the cheapest Claude model on Bedrock at $0.25/million
> input tokens. For cluster diagnostics, Haiku is fast and more than capable. You can switch
> to Claude 3 Sonnet for more nuanced analysis if needed.

### Step 1.3: Run Your First Analysis

```bash
# Analyze the entire cluster
k8sgpt analyze

# Analyze with AI explanations (uses Bedrock)
k8sgpt analyze --explain

# Analyze a specific namespace
k8sgpt analyze --explain --namespace apps

# Filter by specific analyzer
k8sgpt analyze --explain --filter=Pod,Service,Ingress
```

Example output:
```
0: Pod apps/api-service-abc123
   - Error: Back-off restarting failed container

   AI Analysis:
   The api-service pod is crash-looping because the container is failing
   its liveness probe. The most likely causes are:

   1. The application is not listening on port 8080 (check your
      EXPOSE/PORT configuration)
   2. The liveness probe path /health returns a non-200 status
   3. The container runs out of memory before becoming ready

   Recommended fixes:
   - Check logs: kubectl logs -n apps api-service-abc123
   - Verify probe: kubectl describe pod -n apps api-service-abc123
   - Check resources: ensure memory limit >= 128Mi for this workload
```

### Step 1.4: Install k8sgpt Operator (In-Cluster)

Run k8sgpt continuously inside the cluster for automated analysis.

```bash
# Add k8sgpt Helm repo
helm repo add k8sgpt https://charts.k8sgpt.ai/
helm repo update

# Install the operator
helm install k8sgpt-operator k8sgpt/k8sgpt-operator \
  --namespace k8sgpt \
  --create-namespace \
  --set resources.requests.cpu=10m \
  --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=128Mi
```

Create a K8sGPT resource to configure the operator:
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: core.k8sgpt.ai/v1alpha1
kind: K8sGPT
metadata:
  name: k8sgpt
  namespace: k8sgpt
spec:
  ai:
    enabled: true
    model: anthropic.claude-3-haiku-20240307-v1:0
    backend: amazonbedrock
    region: us-east-1
  noCache: false
  version: v0.3.29
  filters:
    - Pod
    - Service
    - Ingress
    - StatefulSet
    - ReplicaSet
    - PersistentVolumeClaim
  sink:
    type: slack
    webhook: "https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
  extraOptions:
    backstage:
      enabled: false
EOF
```

### Step 1.5: View Results as Kubernetes Resources

```bash
# k8sgpt stores results as CRDs
kubectl get results -n k8sgpt

# Get details of a specific result
kubectl get results -n k8sgpt -o yaml
```

---

## Part 2: AWS Bedrock Setup

### Step 2.1: Enable Bedrock Model Access

```bash
# Check available models in your region
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query 'modelSummaries[?contains(modelId, `claude`) || contains(modelId, `titan`)].{ID:modelId,Name:modelName,Provider:providerName}' \
  --output table
```

> **IMPORTANT**: You must manually enable model access in the AWS Console:
> 1. Go to AWS Console > Amazon Bedrock > Model access
> 2. Click "Manage model access"
> 3. Enable: Anthropic Claude 3 Haiku, Claude 3 Sonnet, Amazon Titan Text
> 4. Submit the request (usually approved instantly)

### Step 2.2: IAM Permissions for Bedrock

```bash
# Create an IAM policy for Bedrock access
cat <<'EOF' > /tmp/bedrock-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel"
      ],
      "Resource": [
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-text-express-v1"
      ]
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name DevOpsLabBedrockAccess \
  --policy-document file:///tmp/bedrock-policy.json

# Attach to your user/role
aws iam attach-user-policy \
  --user-name devops-lab-user \
  --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/DevOpsLabBedrockAccess
```

### Step 2.3: Test Bedrock with Python SDK

```bash
# Install dependencies
pip install boto3 langchain langchain-aws langchain-community langgraph
```

```python
# test_bedrock.py — Verify Bedrock access
import boto3
import json

bedrock = boto3.client(
    service_name='bedrock-runtime',
    region_name='us-east-1'
)

# Test with Claude 3 Haiku
response = bedrock.invoke_model(
    modelId='anthropic.claude-3-haiku-20240307-v1:0',
    body=json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 256,
        "messages": [
            {
                "role": "user",
                "content": "Explain what a Kubernetes pod is in one sentence."
            }
        ]
    })
)

result = json.loads(response['body'].read())
print(result['content'][0]['text'])
```

```bash
python test_bedrock.py
```

---

## Part 3: LangChain DevOps AI Agents

### Step 3.1: Log Analysis Agent (Query Loki, Summarize Errors)

This agent connects to your Loki instance, queries for errors, and uses Claude to summarize
what is going wrong.

```python
# devops_agents/log_analyzer.py
import subprocess
import json
from langchain_aws import ChatBedrock
from langchain.agents import AgentExecutor, create_tool_calling_agent
from langchain.tools import tool
from langchain_core.prompts import ChatPromptTemplate


# Initialize the LLM
llm = ChatBedrock(
    model_id="anthropic.claude-3-haiku-20240307-v1:0",
    region_name="us-east-1",
    model_kwargs={"max_tokens": 1024}
)


@tool
def query_loki(query: str, hours: int = 1) -> str:
    """Query Loki for log lines matching a LogQL query.
    Args:
        query: LogQL query string, e.g. '{namespace="apps"} |= "error"'
        hours: How many hours back to search (default 1)
    """
    import requests
    loki_url = "http://loki.monitoring.svc.cluster.local:3100"

    # Use kubectl port-forward if running locally
    # kubectl port-forward svc/loki -n monitoring 3100:3100

    params = {
        "query": query,
        "limit": 100,
        "since": f"{hours}h"
    }

    try:
        resp = requests.get(f"{loki_url}/loki/api/v1/query_range", params=params)
        data = resp.json()
        results = data.get("data", {}).get("result", [])

        log_lines = []
        for stream in results:
            labels = stream.get("stream", {})
            for entry in stream.get("values", []):
                log_lines.append(f"[{labels.get('pod', 'unknown')}] {entry[1]}")

        return "\n".join(log_lines[:50]) if log_lines else "No matching logs found."
    except Exception as e:
        return f"Error querying Loki: {str(e)}"


@tool
def get_pod_status(namespace: str = "apps") -> str:
    """Get the status of all pods in a namespace.
    Args:
        namespace: Kubernetes namespace to check
    """
    result = subprocess.run(
        ["kubectl", "get", "pods", "-n", namespace, "-o", "json"],
        capture_output=True, text=True
    )
    pods = json.loads(result.stdout)
    summary = []
    for pod in pods.get("items", []):
        name = pod["metadata"]["name"]
        phase = pod["status"]["phase"]
        restarts = sum(
            cs.get("restartCount", 0)
            for cs in pod["status"].get("containerStatuses", [])
        )
        summary.append(f"{name}: {phase} (restarts: {restarts})")
    return "\n".join(summary) if summary else "No pods found."


@tool
def get_pod_events(pod_name: str, namespace: str = "apps") -> str:
    """Get recent events for a specific pod.
    Args:
        pod_name: Name of the pod
        namespace: Kubernetes namespace
    """
    result = subprocess.run(
        ["kubectl", "get", "events", "-n", namespace,
         "--field-selector", f"involvedObject.name={pod_name}",
         "--sort-by=.lastTimestamp", "-o", "json"],
        capture_output=True, text=True
    )
    events = json.loads(result.stdout)
    summary = []
    for event in events.get("items", [])[-10:]:
        summary.append(
            f"[{event['type']}] {event['reason']}: {event['message']}"
        )
    return "\n".join(summary) if summary else "No events found."


# Create the agent
prompt = ChatPromptTemplate.from_messages([
    ("system", """You are a DevOps SRE agent. Your job is to analyze Kubernetes
cluster issues by querying logs and pod status. When investigating:
1. First check pod status for the namespace
2. Look for error logs in Loki
3. Check events for any problematic pods
4. Provide a clear root cause analysis and recommended fix

Be concise and actionable. Focus on the root cause, not symptoms."""),
    ("human", "{input}"),
    ("placeholder", "{agent_scratchpad}")
])

tools = [query_loki, get_pod_status, get_pod_events]
agent = create_tool_calling_agent(llm, tools, prompt)
executor = AgentExecutor(agent=agent, tools=tools, verbose=True)


if __name__ == "__main__":
    # Example usage
    result = executor.invoke({
        "input": "Check the apps namespace for any issues. Look at pod status and recent error logs."
    })
    print("\n=== Analysis ===")
    print(result["output"])
```

### Step 3.2: Terraform Plan Reviewer Agent

```python
# devops_agents/terraform_reviewer.py
import subprocess
from langchain_aws import ChatBedrock
from langchain.tools import tool
from langchain_core.prompts import ChatPromptTemplate
from langchain.agents import AgentExecutor, create_tool_calling_agent


llm = ChatBedrock(
    model_id="anthropic.claude-3-sonnet-20240229-v1:0",
    region_name="us-east-1",
    model_kwargs={"max_tokens": 2048}
)


@tool
def run_terraform_plan(working_dir: str = "terraform") -> str:
    """Run terraform plan and return the output.
    Args:
        working_dir: Directory containing Terraform files
    """
    result = subprocess.run(
        ["terraform", "plan", "-no-color"],
        cwd=working_dir,
        capture_output=True, text=True
    )
    return result.stdout + result.stderr


@tool
def get_terraform_state(working_dir: str = "terraform") -> str:
    """Get current Terraform state summary.
    Args:
        working_dir: Directory containing Terraform files
    """
    result = subprocess.run(
        ["terraform", "state", "list"],
        cwd=working_dir,
        capture_output=True, text=True
    )
    return result.stdout


@tool
def estimate_cost_impact(plan_output: str) -> str:
    """Analyze a Terraform plan for cost implications.
    Args:
        plan_output: Output from terraform plan
    """
    # Parse for resource changes
    additions = plan_output.count("will be created")
    changes = plan_output.count("will be updated")
    deletions = plan_output.count("will be destroyed")

    cost_keywords = ["instance_type", "volume_size", "nat_gateway",
                     "load_balancer", "rds", "elasticache"]
    cost_items = []
    for line in plan_output.split("\n"):
        for keyword in cost_keywords:
            if keyword in line.lower():
                cost_items.append(line.strip())

    return f"""Plan Summary:
- Resources to create: {additions}
- Resources to update: {changes}
- Resources to destroy: {deletions}

Cost-relevant changes:
{chr(10).join(cost_items) if cost_items else 'No cost-relevant changes detected.'}"""


prompt = ChatPromptTemplate.from_messages([
    ("system", """You are a senior DevOps engineer reviewing Terraform plans.
Analyze the plan for:
1. Security risks (open security groups, public access, missing encryption)
2. Cost implications (expensive resources, missing spot configs)
3. Best practices (tagging, naming conventions, resource sizing)
4. Potential issues (dependency problems, state conflicts)

Rate the plan: APPROVE, APPROVE_WITH_NOTES, or BLOCK.
Be specific about any concerns."""),
    ("human", "{input}"),
    ("placeholder", "{agent_scratchpad}")
])

tools = [run_terraform_plan, get_terraform_state, estimate_cost_impact]
agent = create_tool_calling_agent(llm, tools, prompt)
executor = AgentExecutor(agent=agent, tools=tools, verbose=True)


if __name__ == "__main__":
    result = executor.invoke({
        "input": "Review the current Terraform plan for the devops-lab project in the ./terraform directory."
    })
    print("\n=== Review ===")
    print(result["output"])
```

---

## Part 4: LangGraph Stateful Multi-Step Workflows

LangGraph builds on LangChain to create stateful, multi-step agent workflows with human-in-the-loop
approval.

### Step 4.1: PR Review -> Security Scan -> Deploy Workflow

```python
# devops_agents/deploy_workflow.py
from typing import TypedDict, Literal, Annotated
from langgraph.graph import StateGraph, END
from langgraph.checkpoint.memory import MemorySaver
from langchain_aws import ChatBedrock
import subprocess
import json


# Define the workflow state
class DeployState(TypedDict):
    pr_number: str
    repo: str
    pr_review: str
    security_scan: str
    approval_status: Literal["pending", "approved", "rejected"]
    deploy_result: str
    messages: list[str]


# Initialize LLM
llm = ChatBedrock(
    model_id="anthropic.claude-3-haiku-20240307-v1:0",
    region_name="us-east-1",
    model_kwargs={"max_tokens": 1024}
)


def review_pr(state: DeployState) -> DeployState:
    """Step 1: AI reviews the pull request."""
    pr_number = state["pr_number"]
    repo = state["repo"]

    # Get PR diff
    result = subprocess.run(
        ["gh", "pr", "diff", pr_number, "--repo", repo],
        capture_output=True, text=True
    )
    diff = result.stdout[:3000]  # Truncate for token limits

    # Get PR description
    result = subprocess.run(
        ["gh", "pr", "view", pr_number, "--repo", repo, "--json",
         "title,body,files"],
        capture_output=True, text=True
    )
    pr_info = result.stdout

    # AI review
    review = llm.invoke(
        f"""Review this PR for a DevOps infrastructure project.
Check for: security issues, best practices, potential bugs, and cost impact.

PR Info: {pr_info}

Diff (truncated):
{diff}

Provide a brief review with: APPROVE, REQUEST_CHANGES, or BLOCK."""
    )

    state["pr_review"] = review.content
    state["messages"].append(f"PR Review complete: {review.content[:100]}...")
    return state


def security_scan(state: DeployState) -> DeployState:
    """Step 2: Run security scanning tools."""
    pr_number = state["pr_number"]
    repo = state["repo"]

    # Simulate security checks (replace with real tools)
    checks = {
        "trivy_scan": "No HIGH or CRITICAL vulnerabilities found",
        "checkov_scan": "3 LOW findings, 0 HIGH findings",
        "secret_scan": "No secrets detected in diff",
        "iac_scan": "Terraform configs pass security baseline"
    }

    scan_summary = "\n".join(f"- {k}: {v}" for k, v in checks.items())

    # AI analysis of security results
    analysis = llm.invoke(
        f"""Analyze these security scan results for a DevOps PR:

{scan_summary}

Previous PR review: {state['pr_review'][:200]}

Should this proceed to deployment? Respond with PASS or FAIL and brief reasoning."""
    )

    state["security_scan"] = analysis.content
    state["messages"].append(f"Security scan complete: {analysis.content[:100]}...")
    return state


def request_approval(state: DeployState) -> DeployState:
    """Step 3: Human-in-the-loop approval gate."""
    # In a real system, this would send a Slack message and wait
    print("\n" + "=" * 60)
    print("APPROVAL REQUIRED")
    print("=" * 60)
    print(f"PR: #{state['pr_number']} in {state['repo']}")
    print(f"\nReview: {state['pr_review'][:200]}")
    print(f"\nSecurity: {state['security_scan'][:200]}")
    print("=" * 60)

    # For automation, check if both review and security passed
    if "BLOCK" in state["pr_review"] or "FAIL" in state["security_scan"]:
        state["approval_status"] = "rejected"
        state["messages"].append("Auto-rejected: PR review or security scan failed")
    else:
        state["approval_status"] = "approved"
        state["messages"].append("Auto-approved: All checks passed")

    return state


def deploy(state: DeployState) -> DeployState:
    """Step 4: Deploy via ArgoCD."""
    if state["approval_status"] != "approved":
        state["deploy_result"] = "Skipped: not approved"
        return state

    # Trigger ArgoCD sync
    result = subprocess.run(
        ["kubectl", "exec", "-n", "argocd",
         "deploy/argocd-server", "--",
         "argocd", "app", "sync", "apps",
         "--force", "--prune"],
        capture_output=True, text=True
    )

    state["deploy_result"] = result.stdout or result.stderr
    state["messages"].append(f"Deploy result: {state['deploy_result'][:100]}")
    return state


def should_deploy(state: DeployState) -> Literal["deploy", "end"]:
    """Routing function: deploy or stop based on approval."""
    if state["approval_status"] == "approved":
        return "deploy"
    return "end"


# Build the workflow graph
workflow = StateGraph(DeployState)

# Add nodes
workflow.add_node("review_pr", review_pr)
workflow.add_node("security_scan", security_scan)
workflow.add_node("request_approval", request_approval)
workflow.add_node("deploy", deploy)

# Add edges (sequential flow with conditional routing)
workflow.set_entry_point("review_pr")
workflow.add_edge("review_pr", "security_scan")
workflow.add_edge("security_scan", "request_approval")
workflow.add_conditional_edges(
    "request_approval",
    should_deploy,
    {
        "deploy": "deploy",
        "end": END
    }
)
workflow.add_edge("deploy", END)

# Compile with memory for state persistence
memory = MemorySaver()
app = workflow.compile(checkpointer=memory)


if __name__ == "__main__":
    # Run the workflow
    config = {"configurable": {"thread_id": "deploy-1"}}
    initial_state = {
        "pr_number": "42",
        "repo": "your-org/devops-zero-to-hero",
        "pr_review": "",
        "security_scan": "",
        "approval_status": "pending",
        "deploy_result": "",
        "messages": []
    }

    result = app.invoke(initial_state, config)
    print("\n=== Workflow Complete ===")
    for msg in result["messages"]:
        print(f"  - {msg}")
    print(f"\nFinal status: {result['approval_status']}")
    print(f"Deploy result: {result['deploy_result']}")
```

---

## Part 5: ChatOps Bot Scaffold

### Slack Bot for DevOps Commands

```python
# devops_agents/chatops_bot.py
"""
ChatOps bot scaffold for Slack/Discord.
Handles commands like:
  /status - Cluster health summary
  /analyze - Run k8sgpt analysis
  /deploy <service> - Trigger deployment
  /cost - Show cost summary
"""
import os
import subprocess
import json
from langchain_aws import ChatBedrock

# Slack SDK (pip install slack-bolt)
# from slack_bolt import App
# app = App(token=os.environ["SLACK_BOT_TOKEN"])


llm = ChatBedrock(
    model_id="anthropic.claude-3-haiku-20240307-v1:0",
    region_name="us-east-1",
    model_kwargs={"max_tokens": 512}
)


def handle_status():
    """Get cluster health summary."""
    # Get node status
    nodes = subprocess.run(
        ["kubectl", "get", "nodes", "-o", "json"],
        capture_output=True, text=True
    )

    # Get pod summary
    pods = subprocess.run(
        ["kubectl", "get", "pods", "--all-namespaces", "-o", "json"],
        capture_output=True, text=True
    )
    pod_data = json.loads(pods.stdout)

    total = len(pod_data.get("items", []))
    running = sum(1 for p in pod_data.get("items", [])
                  if p["status"]["phase"] == "Running")
    failed = sum(1 for p in pod_data.get("items", [])
                 if p["status"]["phase"] == "Failed")

    return f"""Cluster Status:
- Pods: {running}/{total} running, {failed} failed
- Node: {'Ready' if 'Ready' in nodes.stdout else 'NotReady'}
"""


def handle_analyze(namespace="apps"):
    """Run k8sgpt analysis."""
    result = subprocess.run(
        ["k8sgpt", "analyze", "--explain", "--namespace", namespace,
         "--output", "json"],
        capture_output=True, text=True
    )
    try:
        analysis = json.loads(result.stdout)
        if not analysis.get("results"):
            return "No issues found in the cluster."

        summary = []
        for item in analysis["results"][:5]:
            summary.append(
                f"- **{item['name']}**: {item.get('error', [{}])[0].get('text', 'Unknown')}"
            )
        return "k8sgpt Analysis:\n" + "\n".join(summary)
    except json.JSONDecodeError:
        return f"Analysis output: {result.stdout[:500]}"


def handle_cost():
    """Get cost summary from OpenCost."""
    try:
        import requests
        resp = requests.get(
            "http://localhost:9003/allocation/compute",
            params={"window": "24h", "aggregate": "namespace"}
        )
        data = resp.json()
        summary = []
        for namespace_data in data.get("data", [{}]):
            for ns, costs in namespace_data.items():
                total = costs.get("totalCost", 0)
                if total > 0.01:
                    summary.append(f"- {ns}: ${total:.2f}/day")

        return "Cost Summary (last 24h):\n" + "\n".join(sorted(summary, reverse=True))
    except Exception as e:
        return f"Could not fetch cost data: {e}"


def handle_smart_query(question):
    """Use AI to answer arbitrary DevOps questions about the cluster."""
    # Gather context
    context = handle_status()

    response = llm.invoke(
        f"""You are a DevOps assistant for a k3s cluster running on AWS.
Current cluster status:
{context}

User question: {question}

Provide a concise, actionable answer. If you need more info, say what
kubectl command would help."""
    )
    return response.content


# Example Slack handler (uncomment with slack-bolt):
# @app.command("/devops")
# def devops_command(ack, say, command):
#     ack()
#     text = command["text"].strip()
#
#     if text == "status":
#         say(handle_status())
#     elif text == "analyze":
#         say(handle_analyze())
#     elif text == "cost":
#         say(handle_cost())
#     else:
#         say(handle_smart_query(text))


if __name__ == "__main__":
    print("=== Status ===")
    print(handle_status())
    print("\n=== Analysis ===")
    print(handle_analyze())
    print("\n=== Cost ===")
    print(handle_cost())
    print("\n=== Smart Query ===")
    print(handle_smart_query("Why might my api-service be slow?"))
```

### Project Structure

```
devops_agents/
  requirements.txt
  log_analyzer.py
  terraform_reviewer.py
  deploy_workflow.py
  chatops_bot.py
```

```
# requirements.txt
boto3>=1.34.0
langchain>=0.2.0
langchain-aws>=0.2.0
langchain-community>=0.2.0
langgraph>=0.2.0
requests>=2.31.0
# slack-bolt>=1.18.0  # Uncomment for Slack integration
```

---

## Verify

```bash
# 1. k8sgpt CLI works
k8sgpt version
k8sgpt auth list

# 2. k8sgpt can analyze (without AI first)
k8sgpt analyze

# 3. k8sgpt with AI explanations
k8sgpt analyze --explain --namespace apps

# 4. k8sgpt operator running (if installed)
kubectl get pods -n k8sgpt
kubectl get results -n k8sgpt

# 5. Bedrock access works
python -c "
import boto3, json
client = boto3.client('bedrock-runtime', region_name='us-east-1')
resp = client.invoke_model(
    modelId='anthropic.claude-3-haiku-20240307-v1:0',
    body=json.dumps({
        'anthropic_version': 'bedrock-2023-05-31',
        'max_tokens': 50,
        'messages': [{'role': 'user', 'content': 'Say hello'}]
    })
)
print(json.loads(resp['body'].read())['content'][0]['text'])
"

# 6. LangChain agent test
cd devops_agents && python log_analyzer.py

# 7. LangGraph workflow test
cd devops_agents && python deploy_workflow.py
```

---

## Troubleshooting

### k8sgpt "No backend configured"

```bash
# Re-add the backend
k8sgpt auth remove --backend amazonbedrock
k8sgpt auth add \
  --backend amazonbedrock \
  --model anthropic.claude-3-haiku-20240307-v1:0 \
  --providerRegion us-east-1

# Verify
k8sgpt auth list
```

### Bedrock "Access Denied"

```bash
# Check IAM permissions
aws bedrock list-foundation-models --region us-east-1 --query 'modelSummaries[0].modelId'

# If this fails, check your AWS credentials
aws sts get-caller-identity

# Verify model access is enabled in console
# AWS Console > Bedrock > Model access
```

### LangChain "Could not resolve model"

```bash
# Ensure langchain-aws is installed (not just langchain)
pip install langchain-aws

# Verify import works
python -c "from langchain_aws import ChatBedrock; print('OK')"
```

### k8sgpt Operator Not Producing Results

```bash
# Check operator logs
kubectl logs -n k8sgpt -l app.kubernetes.io/name=k8sgpt-operator --tail=50

# Check the K8sGPT resource status
kubectl describe k8sgpt -n k8sgpt

# Verify IRSA or node IAM role has Bedrock permissions
kubectl exec -n k8sgpt deploy/k8sgpt-operator -- env | grep AWS
```

### High Bedrock Costs

```bash
# Check Bedrock usage in AWS Console
# AWS Console > Bedrock > CloudWatch metrics

# Reduce costs:
# 1. Use Haiku ($0.25/M tokens) instead of Sonnet ($3/M tokens)
# 2. Add caching to k8sgpt (noCache: false in K8sGPT CR)
# 3. Reduce analysis frequency
# 4. Set token limits in LangChain (max_tokens=512)
```

---

## Checklist

- [ ] k8sgpt CLI installed and on PATH
- [ ] k8sgpt configured with Bedrock backend
- [ ] k8sgpt analyze works (no AI)
- [ ] k8sgpt analyze --explain works (with AI)
- [ ] k8sgpt operator installed (optional)
- [ ] AWS Bedrock model access enabled (Claude Haiku, Sonnet, Titan)
- [ ] IAM policy created for Bedrock
- [ ] Python SDK can invoke Bedrock models
- [ ] LangChain log analyzer agent working
- [ ] LangChain Terraform reviewer agent working
- [ ] LangGraph deploy workflow running end-to-end
- [ ] ChatOps bot scaffold created
- [ ] Requirements.txt up to date
- [ ] Bedrock costs monitored in CloudWatch

---

## What's Next?
With AI tools integrated into your DevOps workflow, you have intelligent diagnostics that catch
issues faster than manual investigation, AI-reviewed Terraform plans, and a multi-step deployment
workflow with human-in-the-loop approval.

Next, proceed to **Guide 30 -- Advanced GitOps Setup** where we will explore Flux v2 as an
alternative to ArgoCD, Crossplane for Kubernetes-native infrastructure as code, Kaniko for
secure in-cluster container builds, and platform engineering concepts.
