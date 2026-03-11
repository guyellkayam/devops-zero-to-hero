# 27 — Chaos Engineering Setup with LitmusChaos

## Why This Matters
Your monitoring says everything is healthy. Your alerts are configured. Your mesh is encrypting
traffic. But do any of those actually work when something breaks? The only way to know is to
break things intentionally, in a controlled way, and observe the results.

Chaos engineering is the discipline of experimenting on a system to build confidence in its
ability to withstand turbulent conditions in production. Netflix invented the practice with
Chaos Monkey. Today, LitmusChaos brings it to Kubernetes as a CNCF incubating project.

Here is why we chose LitmusChaos over alternatives:

| Feature | LitmusChaos | Chaos Mesh | Gremlin |
|---------|-------------|------------|---------|
| **RAM usage** | ~200MB | ~800MB | Agent-based |
| **License** | Apache 2.0 | Apache 2.0 | Commercial |
| **CNCF status** | Incubating | Incubating | N/A |
| **ChaosCenter UI** | Yes | Dashboard | Web app |
| **Experiment library** | 50+ built-in | 30+ built-in | 100+ |
| **Scheduling** | CronWorkflow | Schedule | Schedule |
| **Cost** | Free | Free | $10K+/yr |

LitmusChaos uses 4x less RAM than Chaos Mesh while providing a visual ChaosCenter for
designing and observing experiments. For our 8GB learning platform, 200MB is the right budget
for chaos tooling.

---

## Prerequisites
- k3s cluster running (guide 07)
- kubectl and Helm installed (guide 02)
- Prometheus + Grafana running (guide 14/15)
- At least one microservice deployed (guide 17+)
- Linkerd or service mesh running (guide 26) -- optional but recommended
- ~200MB RAM available
- Basic understanding of what your services do and how they connect

---

## RAM Budget Impact

| Component | RAM Usage | Notes |
|-----------|-----------|-------|
| **litmus-server** | ~80MB | API server + auth |
| **litmus-frontend** | ~40MB | ChaosCenter UI |
| **mongodb** | ~60MB | Experiment state storage |
| **workflow-controller** | ~20MB | Argo Workflows (lite) |
| **Total** | ~200MB | Plus ~10MB per running experiment |

---

## Step 1: Create the Litmus Namespace

```bash
# Create dedicated namespace
kubectl create namespace litmus

# Label it for identification
kubectl label namespace litmus purpose=chaos-engineering
```

---

## Step 2: Install LitmusChaos via Helm

```bash
# Add the Litmus Helm repository
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm repo update

# Install LitmusChaos with resource constraints for t3.large
helm install litmus litmuschaos/litmus \
  --namespace litmus \
  --set portal.server.replicas=1 \
  --set portal.frontend.replicas=1 \
  --set mongodb.replicas=1 \
  --set portal.server.resources.requests.memory=64Mi \
  --set portal.server.resources.requests.cpu=50m \
  --set portal.server.resources.limits.memory=128Mi \
  --set portal.server.resources.limits.cpu=200m \
  --set portal.frontend.resources.requests.memory=32Mi \
  --set portal.frontend.resources.requests.cpu=25m \
  --set portal.frontend.resources.limits.memory=64Mi \
  --set portal.frontend.resources.limits.cpu=100m \
  --set mongodb.resources.requests.memory=64Mi \
  --set mongodb.resources.requests.cpu=50m \
  --set mongodb.resources.limits.memory=128Mi \
  --set mongodb.resources.limits.cpu=200m
```

Wait for all pods to be ready:
```bash
kubectl get pods -n litmus -w
```

Expected output (all Running):
```
NAME                                    READY   STATUS    RESTARTS   AGE
litmus-server-0                         1/1     Running   0          60s
litmus-frontend-abc123                  1/1     Running   0          60s
litmus-mongodb-0                        1/1     Running   0          60s
litmus-workflow-controller-def456       1/1     Running   0          60s
```

---

## Step 3: Access the ChaosCenter UI

```bash
# Port-forward the ChaosCenter frontend
kubectl port-forward svc/litmus-frontend -n litmus 9091:9091
```

Open http://localhost:9091 in your browser.

**Default credentials:**
- Username: `admin`
- Password: `litmus`

> **IMPORTANT**: Change the default password immediately after first login.

### Initial Setup in ChaosCenter

1. Log in with default credentials
2. Change password when prompted
3. You will see the "Litmus" project already created
4. Navigate to "Chaos Environments" and create one called `dev-cluster`

---

## Step 4: Install ChaosExperiment CRDs

The experiment CRDs define the chaos experiments available in your cluster.

```bash
# Install Litmus chaos experiment CRDs
kubectl apply -f https://hub.litmuschaos.io/api/chaos/3.0.0?file=charts/generic/experiments.yaml -n litmus
```

Verify experiments are available:
```bash
kubectl get chaosexperiments -n litmus
```

Expected output includes experiments like:
```
NAME                   AGE
pod-delete             30s
container-kill         30s
pod-network-loss       30s
node-drain             30s
disk-fill              30s
pod-cpu-hog            30s
pod-memory-hog         30s
```

---

## Step 5: Create the RBAC for Chaos Experiments

Chaos experiments need permissions to kill pods, drain nodes, and manipulate network. Create
a dedicated service account with scoped permissions.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: litmus-chaos-sa
  namespace: apps
  labels:
    app.kubernetes.io/part-of: litmus
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: litmus-chaos-role
  namespace: apps
spec:
  rules:
    - apiGroups: [""]
      resources: ["pods", "pods/log", "events", "replicationcontrollers"]
      verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
    - apiGroups: ["apps"]
      resources: ["deployments", "statefulsets", "replicasets", "daemonsets"]
      verbs: ["get", "list", "watch", "update", "patch"]
    - apiGroups: ["batch"]
      resources: ["jobs"]
      verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
    - apiGroups: ["litmuschaos.io"]
      resources: ["chaosengines", "chaosexperiments", "chaosresults"]
      verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: litmus-chaos-binding
  namespace: apps
spec:
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: Role
    name: litmus-chaos-role
  subjects:
    - kind: ServiceAccount
      name: litmus-chaos-sa
      namespace: apps
EOF
```

For node-level experiments (node-drain), we need a ClusterRole:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: litmus-chaos-cluster-role
spec:
  rules:
    - apiGroups: [""]
      resources: ["nodes"]
      verbs: ["get", "list", "watch", "patch", "update"]
    - apiGroups: [""]
      resources: ["pods/eviction"]
      verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: litmus-chaos-cluster-binding
spec:
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: litmus-chaos-cluster-role
  subjects:
    - kind: ServiceAccount
      name: litmus-chaos-sa
      namespace: apps
EOF
```

---

## Step 6: Experiment 1 — Pod Delete (Kill Random Pods)

This is the most fundamental chaos experiment: kill a pod and verify Kubernetes brings it back.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: pod-delete-chaos
  namespace: apps
spec:
  engineState: active
  appinfo:
    appns: apps
    applabel: app=api-service
    appkind: deployment
  chaosServiceAccount: litmus-chaos-sa
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            # Kill 1 pod at a time
            - name: TOTAL_CHAOS_DURATION
              value: "30"
            # Time between kills
            - name: CHAOS_INTERVAL
              value: "10"
            # Force delete (no graceful shutdown)
            - name: FORCE
              value: "false"
            # Number of pods to kill
            - name: PODS_AFFECTED_PERC
              value: "50"
EOF
```

### Watch the experiment:

```bash
# Terminal 1: Watch pods
kubectl get pods -n apps -w

# Terminal 2: Watch the chaos result
kubectl get chaosresult -n apps -w

# Terminal 3: Watch your service (should stay available if replicas > 1)
while true; do
  curl -s -o /dev/null -w "%{http_code}" http://api-service.apps.svc.cluster.local:8080/api/health
  echo " $(date +%H:%M:%S)"
  sleep 1
done
```

### Check Results

```bash
# Get the chaos result
kubectl get chaosresult pod-delete-chaos-pod-delete -n apps -o yaml

# Look for verdict
kubectl get chaosresult -n apps -o jsonpath='{.items[*].status.experimentStatus.verdict}'
```

Expected: `Pass` -- meaning the application survived the chaos.

---

## Step 7: Experiment 2 — Network Loss

Simulate network packet loss between services to test timeout handling and retries.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: network-loss-chaos
  namespace: apps
spec:
  engineState: active
  appinfo:
    appns: apps
    applabel: app=api-service
    appkind: deployment
  chaosServiceAccount: litmus-chaos-sa
  experiments:
    - name: pod-network-loss
      spec:
        components:
          env:
            # Duration of network loss
            - name: TOTAL_CHAOS_DURATION
              value: "60"
            # Percentage of packets to drop
            - name: NETWORK_PACKET_LOSS_PERCENTAGE
              value: "50"
            # Target specific destination (optional)
            - name: DESTINATION_IPS
              value: ""
            # Network interface
            - name: NETWORK_INTERFACE
              value: "eth0"
            # Container to target
            - name: TARGET_CONTAINER
              value: "api-service"
EOF
```

### What to Watch During Network Chaos

Open Grafana during this experiment. You should see:

1. **Linkerd dashboard**: Error rate spikes, latency increases
2. **API latency panel**: P95/P99 latency shoots up
3. **Alerts**: Your alerting rules should fire within 2-5 minutes

```bash
# Watch Linkerd metrics in real time
linkerd viz stat deploy -n apps --to deploy/api-service

# Check for alert firing
kubectl get prometheusrule -n monitoring -o yaml | grep -A5 "LinkerdHighErrorRate"
```

---

## Step 8: Experiment 3 — Disk Fill

Test what happens when storage fills up. Your monitoring should detect this before it causes
outages.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: disk-fill-chaos
  namespace: apps
spec:
  engineState: active
  appinfo:
    appns: apps
    applabel: app=api-service
    appkind: deployment
  chaosServiceAccount: litmus-chaos-sa
  experiments:
    - name: disk-fill
      spec:
        components:
          env:
            # Duration of disk fill
            - name: TOTAL_CHAOS_DURATION
              value: "60"
            # Fill 80% of the ephemeral storage
            - name: FILL_PERCENTAGE
              value: "80"
            # Size to fill (alternative to percentage)
            - name: EPHEMERAL_STORAGE_MEBIBYTES
              value: ""
            # Target container
            - name: TARGET_CONTAINER
              value: "api-service"
EOF
```

### Expected Observations

1. **Prometheus alert**: `KubePodNotReady` or custom disk alert should fire
2. **Grafana**: Disk usage panel shows spike
3. **Logs**: Application may log write errors
4. **After chaos ends**: Disk usage returns to normal, pod recovers

---

## Step 9: Experiment 4 — Node Drain

Simulate a node failure by cordoning and draining the node. On our single-node k3s, this
tests pod rescheduling behavior.

> **WARNING**: On a single-node cluster, node-drain will make pods unschedulable until the
> node is uncordoned. Only run this if you understand the implications.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: node-drain-chaos
  namespace: apps
spec:
  engineState: active
  appinfo:
    appns: apps
    applabel: app=api-service
    appkind: deployment
  chaosServiceAccount: litmus-chaos-sa
  experiments:
    - name: node-drain
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "30"
            # The node to drain (get with: kubectl get nodes)
            - name: TARGET_NODE
              value: ""
          nodeSelector:
            kubernetes.io/os: linux
EOF
```

### Safer Alternative: Pod CPU/Memory Hog

If node-drain is too aggressive for your single-node cluster, stress-test resources instead:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: cpu-hog-chaos
  namespace: apps
spec:
  engineState: active
  appinfo:
    appns: apps
    applabel: app=api-service
    appkind: deployment
  chaosServiceAccount: litmus-chaos-sa
  experiments:
    - name: pod-cpu-hog
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "30"
            # Number of CPU cores to hog
            - name: CPU_CORES
              value: "1"
            # CPU load percentage
            - name: CPU_LOAD
              value: "80"
            - name: TARGET_CONTAINER
              value: "api-service"
EOF
```

---

## Step 10: Chaos Schedules (Automated Periodic Tests)

Run chaos experiments on a schedule to continuously validate resilience.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosSchedule
metadata:
  name: weekly-pod-delete
  namespace: apps
spec:
  schedule:
    # Run every Monday at 10:00 UTC
    type: repeat
    repeat:
      properties:
        minChaosInterval: "2h"
      workDays:
        includedDays: "Mon"
      startTime:
        hour: 10
        minute: 0
  engineTemplateSpec:
    engineState: active
    appinfo:
      appns: apps
      applabel: app=api-service
      appkind: deployment
    chaosServiceAccount: litmus-chaos-sa
    experiments:
      - name: pod-delete
        spec:
          components:
            env:
              - name: TOTAL_CHAOS_DURATION
                value: "30"
              - name: CHAOS_INTERVAL
                value: "10"
              - name: FORCE
                value: "false"
---
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosSchedule
metadata:
  name: daily-network-chaos
  namespace: apps
spec:
  schedule:
    type: repeat
    repeat:
      properties:
        minChaosInterval: "4h"
      workDays:
        includedDays: "Mon,Wed,Fri"
      startTime:
        hour: 14
        minute: 0
  engineTemplateSpec:
    engineState: active
    appinfo:
      appns: apps
      applabel: app=api-service
      appkind: deployment
    chaosServiceAccount: litmus-chaos-sa
    experiments:
      - name: pod-network-loss
        spec:
          components:
            env:
              - name: TOTAL_CHAOS_DURATION
                value: "30"
              - name: NETWORK_PACKET_LOSS_PERCENTAGE
                value: "30"
              - name: NETWORK_INTERFACE
                value: "eth0"
EOF
```

---

## Step 11: GameDay — Structured Chaos Testing Sessions

A GameDay is a planned session where the team runs chaos experiments while watching monitoring.
Create a GameDay workflow that combines multiple experiments.

```bash
cat <<'EOF' > /tmp/gameday-workflow.yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: gameday-q1-2026
  namespace: litmus
spec:
  entrypoint: gameday
  templates:
    - name: gameday
      steps:
        # Phase 1: Baseline metrics (5 minutes)
        - - name: baseline
            template: collect-baseline
        # Phase 2: Pod chaos (2 minutes)
        - - name: pod-chaos
            template: run-pod-delete
        # Phase 3: Recovery check (3 minutes)
        - - name: recovery-check-1
            template: verify-recovery
        # Phase 4: Network chaos (2 minutes)
        - - name: network-chaos
            template: run-network-loss
        # Phase 5: Final recovery check (3 minutes)
        - - name: recovery-check-2
            template: verify-recovery

    - name: collect-baseline
      container:
        image: curlimages/curl:latest
        command: [sh, -c]
        args:
          - |
            echo "=== GameDay Baseline Metrics ==="
            echo "Time: $(date -u)"
            echo "--- Service Health ---"
            for svc in api-service frontend worker; do
              status=$(curl -s -o /dev/null -w "%{http_code}" http://$svc.apps.svc.cluster.local:8080/health || echo "FAILED")
              echo "$svc: $status"
            done
            echo "--- Pod Count ---"
            echo "Waiting 300s for baseline collection..."
            sleep 300

    - name: run-pod-delete
      container:
        image: litmuschaos/litmus-checker:latest
        command: [sh, -c]
        args:
          - |
            echo "Running pod-delete experiment..."
            # The actual experiment is triggered via ChaosEngine
            sleep 120

    - name: run-network-loss
      container:
        image: litmuschaos/litmus-checker:latest
        command: [sh, -c]
        args:
          - |
            echo "Running network-loss experiment..."
            sleep 120

    - name: verify-recovery
      container:
        image: curlimages/curl:latest
        command: [sh, -c]
        args:
          - |
            echo "=== Recovery Verification ==="
            FAILURES=0
            for i in $(seq 1 30); do
              for svc in api-service frontend worker; do
                status=$(curl -s -o /dev/null -w "%{http_code}" http://$svc.apps.svc.cluster.local:8080/health 2>/dev/null)
                if [ "$status" != "200" ]; then
                  echo "WARN: $svc returned $status at check $i"
                  FAILURES=$((FAILURES + 1))
                fi
              done
              sleep 6
            done
            echo "Total failures during recovery: $FAILURES"
            if [ $FAILURES -gt 5 ]; then
              echo "FAIL: Too many failures during recovery"
              exit 1
            fi
            echo "PASS: Services recovered successfully"
EOF

kubectl apply -f /tmp/gameday-workflow.yaml
```

### GameDay Checklist Template

Use this checklist for each GameDay session:

```markdown
## GameDay Checklist — [DATE]

### Before
- [ ] All services healthy (check Grafana)
- [ ] Alert channels open (Slack/Discord)
- [ ] Team notified of GameDay window
- [ ] Baseline metrics captured (latency, error rate, throughput)
- [ ] Rollback plan ready

### During
- [ ] Experiment 1: Pod Delete — started at ___
  - [ ] Grafana shows impact
  - [ ] Alerts fired: Yes/No
  - [ ] Recovery time: ___ seconds
- [ ] Experiment 2: Network Loss — started at ___
  - [ ] Grafana shows impact
  - [ ] Alerts fired: Yes/No
  - [ ] Recovery time: ___ seconds

### After
- [ ] All services recovered
- [ ] Document findings
- [ ] File issues for gaps found
- [ ] Update runbooks if needed
- [ ] Schedule next GameDay
```

---

## Step 12: Observability Integration

### Grafana Dashboard for Chaos Experiments

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: chaos-grafana-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  chaos-engineering.json: |
    {
      "title": "Chaos Engineering Overview",
      "uid": "chaos-overview",
      "panels": [
        {
          "title": "Active Chaos Experiments",
          "type": "stat",
          "targets": [
            {
              "expr": "count(kube_pod_labels{label_chaosUID=~\".+\", namespace=\"apps\"})",
              "legendFormat": "Active Experiments"
            }
          ],
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 }
        },
        {
          "title": "Service Success Rate During Chaos",
          "type": "timeseries",
          "targets": [
            {
              "expr": "sum(rate(response_total{classification=\"success\", namespace=\"apps\"}[1m])) by (deployment) / sum(rate(response_total{namespace=\"apps\"}[1m])) by (deployment) * 100",
              "legendFormat": "{{ deployment }}"
            }
          ],
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 }
        },
        {
          "title": "P99 Latency During Chaos",
          "type": "timeseries",
          "targets": [
            {
              "expr": "histogram_quantile(0.99, sum(rate(response_latency_ms_bucket{namespace=\"apps\"}[1m])) by (le, deployment))",
              "legendFormat": "{{ deployment }}"
            }
          ],
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 }
        },
        {
          "title": "Pod Restarts (Chaos Impact)",
          "type": "timeseries",
          "targets": [
            {
              "expr": "sum(increase(kube_pod_container_status_restarts_total{namespace=\"apps\"}[5m])) by (pod)",
              "legendFormat": "{{ pod }}"
            }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 }
        }
      ]
    }
EOF
```

---

## Verify

```bash
# 1. Check LitmusChaos pods are running
kubectl get pods -n litmus

# 2. Verify ChaosCenter is accessible
kubectl port-forward svc/litmus-frontend -n litmus 9091:9091 &
curl -s -o /dev/null -w "%{http_code}" http://localhost:9091
# Should return 200

# 3. Check experiment CRDs are installed
kubectl get chaosexperiments -n litmus | wc -l
# Should be > 5

# 4. Verify RBAC
kubectl auth can-i delete pods --as=system:serviceaccount:apps:litmus-chaos-sa -n apps
# Should return: yes

# 5. Check chaos results from completed experiments
kubectl get chaosresult -n apps

# 6. Verify schedules
kubectl get chaosschedule -n apps

# 7. Check resource usage
kubectl top pods -n litmus
```

---

## Troubleshooting

### ChaosEngine Stuck in "Initialized"

```bash
# Check the chaos runner pod
kubectl get pods -n apps | grep chaos

# Check runner logs
kubectl logs -n apps -l name=pod-delete-chaos-runner

# Common fix: RBAC issues
kubectl describe chaosengine pod-delete-chaos -n apps | tail -20
```

### Experiment Shows "Fail" Verdict

```bash
# Get detailed result
kubectl get chaosresult -n apps -o yaml

# Check the experiment pod logs
kubectl logs -n apps -l chaosUID=<chaos-uid>

# Verify target exists
kubectl get deploy -n apps -l app=api-service
```

### MongoDB Not Starting (PVC Issues)

```bash
# Check PVC
kubectl get pvc -n litmus

# If Longhorn storage is full
kubectl get nodes -o custom-columns=NAME:.metadata.name,STORAGE:.status.allocatable.ephemeral-storage

# Delete and recreate with emptyDir if needed
helm upgrade litmus litmuschaos/litmus \
  --namespace litmus \
  --set mongodb.persistence.enabled=false
```

### ChaosCenter UI Shows "Environment Not Connected"

```bash
# Check subscriber pod
kubectl get pods -n litmus -l app=subscriber

# Restart subscriber
kubectl rollout restart deployment -n litmus subscriber

# Check subscriber logs
kubectl logs -n litmus -l app=subscriber
```

### Experiments Not Cleaning Up

```bash
# Manually clean up chaos resources
kubectl delete chaosengine --all -n apps
kubectl delete chaosresult --all -n apps

# Remove any leftover chaos pods
kubectl delete pods -n apps -l chaosUID
```

---

## Checklist

- [ ] Litmus namespace created
- [ ] LitmusChaos installed via Helm with resource limits
- [ ] All Litmus pods running in litmus namespace
- [ ] ChaosCenter UI accessible (port 9091)
- [ ] Default password changed
- [ ] ChaosExperiment CRDs installed
- [ ] RBAC service account created in apps namespace
- [ ] ClusterRole created for node-level experiments
- [ ] Experiment 1 (pod-delete) executed successfully
- [ ] Experiment 2 (network-loss) executed and observed in Grafana
- [ ] Experiment 3 (disk-fill) executed and alerts verified
- [ ] Experiment 4 (node-drain or cpu-hog) executed
- [ ] Chaos schedule created for automated testing
- [ ] GameDay workflow template created
- [ ] Grafana dashboard for chaos experiments imported
- [ ] Total RAM usage under ~200MB (litmus namespace)

---

## What's Next?
Now that you can intentionally break things and measure how your system responds, you have
the foundation for production-grade resilience. Chaos experiments should be part of every
release cycle.

Next, proceed to **Guide 28 -- Cost Optimization** where we will install OpenCost to track
exactly how much each service costs and implement strategies to keep your AWS bill at
$25-45/month.
