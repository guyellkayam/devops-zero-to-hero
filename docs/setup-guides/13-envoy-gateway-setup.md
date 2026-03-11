# 13 — Envoy Gateway Setup (API Gateway & Traffic Management)

## Why This Matters

Every request from the outside world needs a single entry point into your cluster.
An API Gateway handles TLS termination, routing, rate limiting, and load balancing
in one place. Without it, you would expose each microservice individually, duplicate
TLS configuration everywhere, and have no centralized traffic control.

### Why Envoy Gateway over Traefik or Nginx?

| Criteria | Envoy Gateway | Traefik | Nginx Ingress |
|----------|---------------|---------|---------------|
| **Standard** | Gateway API (native) | Gateway API (add-on) | Ingress (legacy) |
| **Foundation** | Envoy Proxy (CNCF graduated) | Custom proxy | Nginx |
| **Used in production by** | Google, Lyft, Stripe, Salesforce | Smaller orgs | Many legacy systems |
| **Rate limiting** | Built-in BackendTrafficPolicy | Enterprise feature | Annotation-based |
| **Observability** | Native Prometheus + tracing | Good | Basic |
| **Learning value** | Matches production stacks | Less common at scale | Being replaced |

Envoy is the data plane behind Istio, AWS App Mesh, and most service meshes.
Learning Envoy Gateway teaches you patterns used across the industry. It uses the
Kubernetes Gateway API, which is the future replacement for the Ingress resource.

On our cluster it uses about **150MB RAM** (Envoy proxy + controller).

---

## Prerequisites

| Requirement | How to Verify |
|-------------|---------------|
| k3s cluster running | `kubectl get nodes` shows Ready |
| Helm installed | `helm version --short` |
| cert-manager installed (Guide 12) | `kubectl get pods -n cert-manager` all Running |
| MetalLB configured | `kubectl get pods -n metallb-system` |
| DNS (for TLS) | `dig yourdomain.com` returns your EC2 public IP |

---

## Step 1: Install Envoy Gateway with Helm

```bash
# Add the Envoy Gateway Helm repository
helm repo add envoy-gateway https://gateway.envoyproxy.io/charts
helm repo update

# Create the namespace
kubectl create namespace envoy-gateway-system

# Install Envoy Gateway
helm install envoy-gateway envoy-gateway/gateway-helm \
  --namespace envoy-gateway-system \
  --version v1.2.6 \
  --set deployment.envoyGateway.resources.requests.cpu=100m \
  --set deployment.envoyGateway.resources.requests.memory=128Mi \
  --set deployment.envoyGateway.resources.limits.memory=256Mi \
  --wait
```

### Verify installation:

```bash
# Controller pod should be Running
kubectl get pods -n envoy-gateway-system

# Expected:
# NAME                                         READY   STATUS    RESTARTS   AGE
# envoy-gateway-xxxxxxxxx-xxxxx                1/1     Running   0          60s

# Check the GatewayClass was automatically created
kubectl get gatewayclass

# Expected:
# NAME    CONTROLLER                                      ACCEPTED   AGE
# eg      gateway.envoyproxy.io/gatewayclass-controller   True       60s
```

---

## Step 2: Create the Gateway Resource

The Gateway is the actual listener that accepts incoming traffic. Think of it as
the "load balancer" definition. It creates an Envoy proxy deployment behind the scenes.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: devops-gateway
  namespace: envoy-gateway-system
  annotations:
    # cert-manager will provision certificates for TLS listeners
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  gatewayClassName: eg
  listeners:
    # HTTP listener — redirects to HTTPS
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All

    # HTTPS listener with TLS termination
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: devops-gateway-tls
            namespace: envoy-gateway-system
      allowedRoutes:
        namespaces:
          from: All
EOF
```

### Wait for the Gateway to be Programmed:

```bash
# Check Gateway status
kubectl get gateway -n envoy-gateway-system

# Expected:
# NAME             CLASS   ADDRESS         PROGRAMMED   AGE
# devops-gateway   eg      10.x.x.x       True         30s

# An Envoy proxy deployment was created automatically
kubectl get pods -n envoy-gateway-system

# You should now see an additional envoy proxy pod:
# envoy-envoy-gateway-system-devops-gateway-xxxxxxxxx-xxxxx

# Check the LoadBalancer service created by MetalLB
kubectl get svc -n envoy-gateway-system

# The envoy service should have an EXTERNAL-IP from MetalLB
```

---

## Step 3: Configure HTTP-to-HTTPS Redirect

Force all HTTP traffic to redirect to HTTPS:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: envoy-gateway-system
spec:
  parentRefs:
    - name: devops-gateway
      namespace: envoy-gateway-system
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
EOF
```

---

## Step 4: Create HTTPRoutes for Microservices

Each microservice gets its own HTTPRoute that maps URL paths to backend services.

### API Gateway Service Route

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-gateway-route
  namespace: default
spec:
  parentRefs:
    - name: devops-gateway
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - "api.yourdomain.com"       # <-- REPLACE with your domain
  rules:
    # Route /api/v1/users/* to user-service
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1/users
      backendRefs:
        - name: user-service
          port: 8080

    # Route /api/v1/orders/* to order-service
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1/orders
      backendRefs:
        - name: order-service
          port: 8080

    # Route everything else to api-gateway
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: api-gateway
          port: 8080
EOF
```

### Header-Based Routing (Canary Deployments)

Route requests with a specific header to a canary version:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: user-service-canary
  namespace: default
spec:
  parentRefs:
    - name: devops-gateway
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - "api.yourdomain.com"       # <-- REPLACE with your domain
  rules:
    # Canary: requests with header x-canary: true go to v2
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1/users
          headers:
            - name: x-canary
              value: "true"
      backendRefs:
        - name: user-service-v2
          port: 8080

    # Default: all other traffic goes to v1
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1/users
      backendRefs:
        - name: user-service
          port: 8080
EOF
```

---

## Step 5: Configure Rate Limiting

Envoy Gateway uses BackendTrafficPolicy for rate limiting. This protects your
services from abuse and ensures fair resource usage.

### Global rate limit (per client IP):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: global-rate-limit
  namespace: envoy-gateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: devops-gateway
  rateLimit:
    type: Global
    global:
      rules:
        # 100 requests per minute per client IP
        - clientSelectors:
            - headers: []
          limit:
            requests: 100
            unit: Minute
EOF
```

### Per-route rate limit (stricter for sensitive endpoints):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: auth-rate-limit
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: api-gateway-route
  rateLimit:
    type: Global
    global:
      rules:
        # 20 requests per minute for auth endpoints
        - clientSelectors:
            - headers:
                - name: ":path"
                  value: "/api/v1/users/login"
          limit:
            requests: 20
            unit: Minute
        # 5 requests per minute for registration
        - clientSelectors:
            - headers:
                - name: ":path"
                  value: "/api/v1/users/register"
          limit:
            requests: 5
            unit: Minute
EOF
```

---

## Step 6: Add Timeouts and Retries

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: service-resilience
  namespace: default
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: api-gateway-route
  timeout:
    http:
      connectionIdleTimeout: 60s
      maxConnectionDuration: 300s
    tcp:
      connectTimeout: 5s
  retry:
    numRetries: 3
    perRetry:
      timeout: 2s
    retryOn:
      httpStatusCodes:
        - 502
        - 503
        - 504
      triggers:
        - connect-failure
        - retriable-status-codes
EOF
```

---

## Step 7: Deploy a Test Service

Create a real test to verify everything works end-to-end:

```bash
cat <<'EOF' | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-service
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-service
  template:
    metadata:
      labels:
        app: echo-service
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:0.2.3
          args:
            - "-text=Hello from Envoy Gateway!"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: default
spec:
  selector:
    app: echo-service
  ports:
    - port: 80
      targetPort: 5678
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-route
  namespace: default
spec:
  parentRefs:
    - name: devops-gateway
      namespace: envoy-gateway-system
      sectionName: http     # Use HTTP for quick testing
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /echo
      backendRefs:
        - name: echo-service
          port: 80
EOF

# Get the Gateway's external IP
GATEWAY_IP=$(kubectl get gateway devops-gateway -n envoy-gateway-system \
  -o jsonpath='{.status.addresses[0].value}')

echo "Gateway IP: $GATEWAY_IP"

# Test the route
curl -v http://$GATEWAY_IP/echo
# Should return: Hello from Envoy Gateway!
```

---

## Verify

```bash
#!/bin/bash
echo "=== Envoy Gateway Verification ==="

echo ""
echo "--- Controller Pod ---"
kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway
echo ""

echo "--- Envoy Proxy Pods ---"
kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/component=proxy
echo ""

echo "--- GatewayClass ---"
kubectl get gatewayclass
echo ""

echo "--- Gateway ---"
kubectl get gateway -n envoy-gateway-system
echo ""

echo "--- HTTPRoutes (all namespaces) ---"
kubectl get httproutes -A
echo ""

echo "--- BackendTrafficPolicies ---"
kubectl get backendtrafficpolicies -A 2>/dev/null || echo "No policies configured"
echo ""

echo "--- Services (LoadBalancer) ---"
kubectl get svc -n envoy-gateway-system -l app.kubernetes.io/component=proxy
echo ""

echo "--- Resource Usage ---"
kubectl top pods -n envoy-gateway-system 2>/dev/null || \
  echo "Metrics server not available"
echo ""

# Functional test
GATEWAY_IP=$(kubectl get gateway devops-gateway -n envoy-gateway-system \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
if [ -n "$GATEWAY_IP" ]; then
  echo "--- Connectivity Test ---"
  echo "Gateway IP: $GATEWAY_IP"
  curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://$GATEWAY_IP/echo 2>/dev/null || \
    echo "Could not connect to gateway"
fi

echo ""
echo "=== Verification Complete ==="
```

---

## Troubleshooting

### Gateway not getting an IP address

```bash
# Check if MetalLB is running
kubectl get pods -n metallb-system

# Check the LoadBalancer service
kubectl get svc -n envoy-gateway-system
# If EXTERNAL-IP is <pending>, MetalLB isn't assigning IPs

# Check MetalLB IPAddressPool
kubectl get ipaddresspools -n metallb-system
kubectl get l2advertisements -n metallb-system
```

### HTTPRoute not routing traffic

```bash
# Check the route status
kubectl describe httproute <route-name> -n <namespace>

# Look for the "Accepted" condition
# Common issue: the parentRef doesn't match the Gateway name/namespace

# Check Envoy proxy logs
kubectl logs -n envoy-gateway-system \
  -l app.kubernetes.io/component=proxy --tail=50
```

### Common errors and fixes:

| Error | Cause | Fix |
|-------|-------|-----|
| Gateway stuck in `NotProgrammed` | Envoy proxy pod not starting | Check events: `kubectl describe gateway devops-gateway -n envoy-gateway-system` |
| HTTPRoute `NotAccepted` | Wrong parentRef or namespace mismatch | Verify Gateway name and `allowedRoutes.namespaces` |
| `502 Bad Gateway` | Backend service not running | Check `kubectl get svc` and `kubectl get endpoints` |
| `503 Service Unavailable` | No healthy backends | Check pod readiness probes |
| Rate limit not working | Policy targetRef mismatch | Verify the targetRef matches your Gateway or HTTPRoute exactly |

### Debug Envoy configuration:

```bash
# Get the Envoy proxy pod name
ENVOY_POD=$(kubectl get pods -n envoy-gateway-system \
  -l app.kubernetes.io/component=proxy -o jsonpath='{.items[0].metadata.name}')

# View Envoy listeners
kubectl exec -n envoy-gateway-system $ENVOY_POD -- \
  curl -s localhost:19000/config_dump | jq '.configs[2].dynamic_listeners' | head -50

# View Envoy routes
kubectl exec -n envoy-gateway-system $ENVOY_POD -- \
  curl -s localhost:19000/config_dump | jq '.configs[4].dynamic_route_configs' | head -50

# View Envoy clusters (backends)
kubectl exec -n envoy-gateway-system $ENVOY_POD -- \
  curl -s localhost:19000/clusters | head -30
```

---

## Clean Up Test Resources

```bash
kubectl delete deployment echo-service -n default
kubectl delete service echo-service -n default
kubectl delete httproute echo-route -n default
```

---

## Checklist

- [ ] Envoy Gateway Helm chart installed in `envoy-gateway-system` namespace
- [ ] Controller pod running
- [ ] GatewayClass `eg` is Accepted
- [ ] Gateway `devops-gateway` created with HTTP and HTTPS listeners
- [ ] Gateway has an external IP from MetalLB
- [ ] Envoy proxy pod running (auto-created by Gateway)
- [ ] HTTP-to-HTTPS redirect configured
- [ ] HTTPRoutes created for microservices (path-based routing)
- [ ] Header-based routing configured for canary deployments
- [ ] Rate limiting configured (global + per-route)
- [ ] Test echo service reachable through the Gateway
- [ ] Total memory usage under 150MB

---

## What's Next?

With Envoy Gateway routing traffic and cert-manager providing TLS, you now have a
production-grade ingress layer. Next steps:

- **Guide 14 — Harbor Setup**: Container registry accessible through Envoy Gateway
  with TLS, so you can push and pull images securely
- **Guide 15 — PostgreSQL Operator**: Database backend for your microservices, with
  connections routed through the internal network

You will revisit this Gateway configuration as you add more services. Each new
microservice only needs an HTTPRoute resource to become accessible.
