# 12 — Cert-Manager Setup (Automated TLS Certificates)

## Why This Matters

Every production service needs TLS (HTTPS). Without cert-manager, you would manually
generate certificates, track expiration dates, and scramble to renew them before they
expire. Cert-manager automates this entire lifecycle: it requests certificates from
Let's Encrypt (free), installs them into Kubernetes Secrets, and renews them
automatically 30 days before expiry. You configure it once, and TLS just works.

On our single-node k3s cluster, cert-manager uses about **100MB RAM** and handles
certificates for every service exposed through Envoy Gateway.

---

## Prerequisites

| Requirement | How to Verify |
|-------------|---------------|
| k3s cluster running | `kubectl get nodes` shows Ready |
| Helm installed | `helm version --short` |
| kubectl configured | `kubectl cluster-info` |
| DNS pointing to your EC2 | `dig your-domain.com` shows your EC2 public IP |
| Vault running (optional) | `kubectl get pods -n vault` |

> **NOTE**: For Let's Encrypt production certificates, you MUST have a real domain
> pointing to your cluster. For learning with self-signed certs, no domain is needed.

---

## Step 1: Install Cert-Manager with Helm

Cert-manager uses Custom Resource Definitions (CRDs) to extend Kubernetes with
Certificate, Issuer, and ClusterIssuer resources. We install CRDs together with
the Helm chart for simplicity.

```bash
# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Create the namespace
kubectl create namespace cert-manager

# Install cert-manager with CRDs
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.16.3 \
  --set crds.enabled=true \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.memory=128Mi \
  --set webhook.resources.requests.cpu=25m \
  --set webhook.resources.requests.memory=32Mi \
  --set webhook.resources.limits.memory=64Mi \
  --set cainjector.resources.requests.cpu=25m \
  --set cainjector.resources.requests.memory=64Mi \
  --set cainjector.resources.limits.memory=128Mi \
  --wait
```

> **What just happened?** Three deployments were created:
> - `cert-manager` — the main controller that watches for Certificate resources
> - `cert-manager-webhook` — validates cert-manager CRDs
> - `cert-manager-cainjector` — injects CA bundles into webhook configurations

### Verify the installation:

```bash
# All three pods should be Running
kubectl get pods -n cert-manager

# Expected output:
# NAME                                       READY   STATUS    RESTARTS   AGE
# cert-manager-xxxxxxxxx-xxxxx               1/1     Running   0          60s
# cert-manager-cainjector-xxxxxxxxx-xxxxx    1/1     Running   0          60s
# cert-manager-webhook-xxxxxxxxx-xxxxx       1/1     Running   0          60s

# Check CRDs were installed
kubectl get crds | grep cert-manager

# Expected:
# certificaterequests.cert-manager.io
# certificates.cert-manager.io
# challenges.acme.cert-manager.io
# clusterissuers.cert-manager.io
# issuers.cert-manager.io
# orders.acme.cert-manager.io
```

---

## Step 2: Create a Self-Signed ClusterIssuer (For Internal Services)

Self-signed certificates are perfect for internal service-to-service communication
and for testing your setup before configuring Let's Encrypt.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
```

### Create a CA (Certificate Authority) for internal services:

This is a two-step pattern: a self-signed issuer creates a CA certificate, and then
a CA issuer uses that certificate to sign other certificates.

```bash
cat <<'EOF' | kubectl apply -f -
---
# Step 1: CA certificate signed by the self-signed issuer
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: devops-zero-to-hero-ca
  secretName: internal-ca-secret
  duration: 87600h    # 10 years
  renewBefore: 8760h  # Renew 1 year before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
# Step 2: ClusterIssuer that uses the CA certificate
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca-issuer
spec:
  ca:
    secretName: internal-ca-secret
EOF
```

### Verify:

```bash
# Check the CA certificate was created
kubectl get certificate -n cert-manager
# STATUS should be True (Ready)

# Check both ClusterIssuers are ready
kubectl get clusterissuers
# Both should show READY = True
```

---

## Step 3: Create Let's Encrypt ClusterIssuers

Let's Encrypt provides free TLS certificates trusted by all browsers. We create two
issuers: staging (for testing, no rate limits) and production (for real certificates).

> **IMPORTANT**: Always test with staging first. Let's Encrypt production has
> [rate limits](https://letsencrypt.org/docs/rate-limits/) — 50 certificates per
> registered domain per week. Staging has much higher limits.

```bash
# Replace with your real email address
export ACME_EMAIL="your-email@example.com"

cat <<EOF | kubectl apply -f -
---
# Staging issuer (for testing — certificates are NOT trusted by browsers)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: envoy
---
# Production issuer (for real — certificates ARE trusted by browsers)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-production-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: envoy
EOF
```

> **How ACME HTTP-01 works:**
> 1. Cert-manager asks Let's Encrypt for a certificate for `app.yourdomain.com`
> 2. Let's Encrypt responds with a challenge token
> 3. Cert-manager creates a temporary pod and Ingress that serves the token at
>    `http://app.yourdomain.com/.well-known/acme-challenge/<token>`
> 4. Let's Encrypt checks that URL, confirms you control the domain
> 5. Let's Encrypt issues the certificate
> 6. Cert-manager stores it as a Kubernetes Secret

### Verify:

```bash
kubectl get clusterissuers

# Expected output:
# NAME                      READY   AGE
# internal-ca-issuer        True    5m
# letsencrypt-production    True    30s
# letsencrypt-staging       True    30s
# selfsigned-issuer         True    6m
```

> **NOTE**: If READY shows False, check the issuer status:
> ```bash
> kubectl describe clusterissuer letsencrypt-staging
> ```
> The ACME issuers need to register with Let's Encrypt, which takes a few seconds.

---

## Step 4: Create a Test Certificate

Test the internal CA issuer by creating a certificate for an internal service.

```bash
# Create a test namespace
kubectl create namespace cert-test

cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-internal-cert
  namespace: cert-test
spec:
  secretName: test-internal-tls
  duration: 2160h    # 90 days
  renewBefore: 720h  # Renew 30 days before expiry
  isCA: false
  privateKey:
    algorithm: ECDSA
    size: 256
  dnsNames:
    - test-service.cert-test.svc.cluster.local
    - test-service.cert-test.svc
  issuerRef:
    name: internal-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF
```

### Verify the certificate was issued:

```bash
# Check certificate status
kubectl get certificate -n cert-test
# READY should be True

# Inspect the certificate details
kubectl describe certificate test-internal-cert -n cert-test

# Check the TLS secret was created
kubectl get secret test-internal-tls -n cert-test
# TYPE should be kubernetes.io/tls

# Decode and inspect the certificate
kubectl get secret test-internal-tls -n cert-test \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -text | head -20
```

---

## Step 5: Test with a Sample HTTPRoute (Staging Let's Encrypt)

This example assumes Envoy Gateway is installed (Guide 13). If you haven't set it
up yet, skip this step and return after completing Guide 13.

```bash
cat <<'EOF' | kubectl apply -f -
---
# Request a staging certificate for your domain
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-tls-staging
  namespace: default
spec:
  secretName: demo-tls-staging-secret
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - demo.yourdomain.com   # <-- REPLACE with your real domain
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
---
# Simple test deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: demo
          image: hashicorp/http-echo:0.2.3
          args:
            - "-text=Hello from devops-zero-to-hero!"
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
  name: demo-app
  namespace: default
spec:
  selector:
    app: demo-app
  ports:
    - port: 80
      targetPort: 5678
---
# HTTPRoute referencing the TLS secret (Envoy Gateway)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo-route
  namespace: default
spec:
  parentRefs:
    - name: devops-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "demo.yourdomain.com"   # <-- REPLACE with your real domain
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: demo-app
          port: 80
EOF
```

### Watch the certificate being issued:

```bash
# Watch cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager -f

# Check certificate progress
kubectl get certificate demo-tls-staging -n default -w

# Once READY=True, check the challenge completed
kubectl get challenges -A
# Should be empty (challenges are cleaned up after completion)
```

---

## Step 6: Switch to Production Let's Encrypt

Once staging works, switch to production. The only change is the issuerRef.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-tls-production
  namespace: default
spec:
  secretName: demo-tls-production-secret
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - demo.yourdomain.com   # <-- REPLACE with your real domain
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
EOF
```

Then update your Gateway to use the production secret:

```bash
# Verify production certificate
kubectl get certificate demo-tls-production -n default
# READY should be True

# Inspect — the issuer should be "Let's Encrypt" (not "Fake LE")
kubectl get secret demo-tls-production-secret -n default \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -issuer
```

---

## Verify

Run this full verification script:

```bash
#!/bin/bash
echo "=== Cert-Manager Verification ==="

echo ""
echo "--- Pods ---"
kubectl get pods -n cert-manager
echo ""

echo "--- CRDs ---"
kubectl get crds | grep cert-manager | wc -l
echo "CRDs installed (should be 6)"
echo ""

echo "--- ClusterIssuers ---"
kubectl get clusterissuers
echo ""

echo "--- Certificates (all namespaces) ---"
kubectl get certificates -A
echo ""

echo "--- Certificate Secrets ---"
kubectl get secrets -A -l "controller.cert-manager.io/fqdn" 2>/dev/null || \
  echo "No ACME certificates yet"
echo ""

echo "--- Resource Usage ---"
kubectl top pods -n cert-manager 2>/dev/null || \
  echo "Metrics server not available — check with: kubectl get pods -n cert-manager"
echo ""

echo "--- Cert-Manager Version ---"
kubectl get deployment cert-manager -n cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""
echo ""
echo "=== Verification Complete ==="
```

---

## Troubleshooting

### Certificate stuck in "Not Ready"

```bash
# Check the certificate status
kubectl describe certificate <cert-name> -n <namespace>

# Look at the CertificateRequest
kubectl get certificaterequest -n <namespace>
kubectl describe certificaterequest <request-name> -n <namespace>

# For ACME (Let's Encrypt), check challenges
kubectl get challenges -A
kubectl describe challenge <challenge-name> -n <namespace>

# Check cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=50
```

### Common errors and fixes:

| Error | Cause | Fix |
|-------|-------|-----|
| `dial tcp: lookup ... no such host` | DNS not pointing to your cluster | Verify `dig yourdomain.com` returns your EC2 IP |
| `connection refused` on port 80 | Ingress not routing ACME challenges | Check your Gateway/Ingress allows HTTP on port 80 |
| `too many certificates already issued` | Let's Encrypt rate limit hit | Wait a week, or use staging issuer |
| `webhook not ready` | Webhook pod starting up | Wait 60s, check `kubectl get pods -n cert-manager` |
| `failed to determine a]uthoritative nameservers` | DNS propagation | Wait for DNS to propagate, check with `dig` |

### Webhook issues after install:

```bash
# The webhook needs a few seconds to start. If you get webhook errors:
kubectl rollout status deployment cert-manager-webhook -n cert-manager --timeout=120s

# If it stays broken, delete and recreate the webhook
kubectl delete mutatingwebhookconfigurations cert-manager-webhook
kubectl delete validatingwebhookconfigurations cert-manager-webhook
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true \
  --wait
```

### Check certificate expiration:

```bash
# List all certificates with expiry dates
for cert in $(kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  ns=$(echo $cert | cut -d/ -f1)
  name=$(echo $cert | cut -d/ -f2)
  echo "Certificate: $cert"
  kubectl get certificate $name -n $ns \
    -o jsonpath='  Ready: {.status.conditions[0].status} | Expiry: {.status.notAfter}{"\n"}'
done
```

---

## Clean Up Test Resources

```bash
# Remove test resources (keep cert-manager and issuers)
kubectl delete namespace cert-test
kubectl delete certificate demo-tls-staging demo-tls-production -n default 2>/dev/null
kubectl delete deployment demo-app -n default 2>/dev/null
kubectl delete service demo-app -n default 2>/dev/null
kubectl delete httproute demo-route -n default 2>/dev/null
```

---

## Checklist

- [ ] Cert-manager Helm chart installed in `cert-manager` namespace
- [ ] All 3 pods running (controller, webhook, cainjector)
- [ ] 6 CRDs installed
- [ ] Self-signed ClusterIssuer created and Ready
- [ ] Internal CA ClusterIssuer created and Ready
- [ ] Let's Encrypt staging ClusterIssuer created and Ready
- [ ] Let's Encrypt production ClusterIssuer created and Ready
- [ ] Test certificate issued successfully with internal CA
- [ ] (Optional) Staging certificate issued via ACME HTTP-01 challenge
- [ ] Total memory usage under 100MB

---

## What's Next?

With cert-manager handling TLS certificates automatically, you are ready for:

- **Guide 13 — Envoy Gateway Setup**: API Gateway that terminates TLS using
  cert-manager certificates and routes traffic to your microservices
- **Guide 14 — Harbor Setup**: Harbor registry with TLS enabled through cert-manager
- **Guide 15 — PostgreSQL Operator**: Internal certs for encrypted database connections

Cert-manager is a "set and forget" component. Once your ClusterIssuers are
configured, any service that needs TLS simply references them, and certificates
appear automatically.
