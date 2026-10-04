# OpenShift 4 HAProxy Ingress Architecture & TLS Mastery — Runbook & Interview Cheat Sheet

A comprehensive, end-to-end operational guide and interview cheat sheet covering OpenSSL certificate generation, TLS bundle anatomy, clean YAML configurations for Edge, Pass-Through, and Re-encrypt, and HAProxy in-pod process mechanics.

---

## ⚡ The 30-Second Elevator Pitch

> *"OpenShift Ingress separates the Control Plane (`openshift-ingress-operator`) from the Data Plane (`openshift-ingress`). The router runs an in-pod Go controller alongside an HAProxy Master-Worker engine. For pod scaling, it performs zero-reload dynamic updates in under 1ms using the `/var/lib/haproxy/run/haproxy.sock` UNIX domain socket against pre-allocated standby slots. For structural cert and route changes, the HAProxy Master process forks a new worker and gracefully drains the old worker via `SIGUSR1`. It supports three distinct TLS architectures: **Edge** (centralized wildcard on IngressController), **Pass-Through** (L4 SNI passthrough to pod), and **Re-encrypt** (dual-leg encryption with Service CA validation)."*

---

## 🛠️ Phase 1: OpenSSL Certificate Generation & Trust Setup

Before configuring OpenShift ingress, we generate the 3 essential cryptographic files and configure client trust.

### 1. Generate the Root CA (The Trust Anchor)
```bash
# Generate private key and self-signed Root CA (valid for 10 years)
openssl req -x509 -new -nodes -newkey rsa:4096 \
  -keyout root-ca.key \
  -out root-ca.crt \
  -days 3650 \
  -subj "/C=AU/O=BrainyBots Enterprise/OU=Security/CN=BrainyBots Enterprise Root CA"
```

### 2. Generate Server Private Key & CSR
```bash
# Generate 2048-bit server key and Certificate Signing Request
openssl req -new -nodes -newkey rsa:2048 \
  -keyout server.key \
  -out server.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=*.apps.okd-sno.brainybots.cloud"
```

### 3. Sign the Certificate with Modern SAN (Subject Alternative Name)
Modern browsers reject certificates that only use `CN`. They strictly mandate modern SAN extensions:

```bash
# Create SAN extension configuration
cat <<EOF > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.apps.okd-sno.brainybots.cloud
DNS.2 = apps.okd-sno.brainybots.cloud
EOF

# Sign the server certificate using the Root CA
openssl x509 -req -in server.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.cnf
```

### 4. Install Root CA into macOS Keychain (Green Padlock 🔒)
To establish trust on a client Mac machine (simulating enterprise MDM rollout), run this single command:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root-ca.crt
```

---

## 🔐 Phase 2: The 3 Essential TLS Bundle Files

| File Name | Standard K8s Key | Purpose & Contents | Sent to Browser? |
| :--- | :--- | :--- | :--- |
| **`server.crt`** | `tls.crt` | **Public Identity & Cert Chain:** Contains public key, Subject, Validity, Issuer signature, and SAN list. | **YES** (Sent across wire during `ServerHello`) |
| **`private.key`** | `tls.key` | **Cryptographic Secret:** The server's private key. Used to decrypt session pre-master secrets and sign handshakes. | **NO — NEVER!** Stored strictly on server inside Secret. |
| **`root-ca.crt`** | `ca.crt` | **The Trust Anchor:** Root Certificate Authority used by clients to verify that `server.crt` was signed by a trusted issuer. | **NO** (Pre-installed in OS / Keychain / Route trust anchor) |

---

## 📦 Phase 3: The 3 TLS Termination Types & Clean YAML Configurations

Instead of messy inline certificate blobs on developer routes, enterprise OpenShift uses clean decoupled manifests.

```
1. EDGE:        Client ──[TLS: Public Cert]──► HAProxy ──[Plain HTTP]────────► Pod
2. PASS-THROUGH:Client ──[TLS (Untouched Stream via SNI)]─────────────────────► Pod
3. RE-ENCRYPT:  Client ──[TLS 1: Public Cert]─► HAProxy ──[TLS 2: Service CA]─► Pod
```

---

### Type 1: EDGE Termination (Enterprise IngressController Pattern)

* In production, developers **never** paste certificates into their Route YAMLs.
* The Platform Team mounts one centralized wildcard certificate on the `IngressController`. All dev Edge routes automatically inherit the certificate and the green padlock.

#### Manifest 1: Centralized Wildcard Secret (`openshift-ingress` namespace)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: custom-wildcard-tls
  namespace: openshift-ingress
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-server.crt>
  tls.key: <base64-encoded-server.key>
```

#### Manifest 2: IngressController CR Snippet (`openshift-ingress-operator` namespace)
```yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  defaultCertificate:
    name: custom-wildcard-tls    # Points to Secret in openshift-ingress
```

#### Manifest 3: Clean Developer Edge Route (Zero Cert Blobs)
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: payment-service
  namespace: payments
spec:
  to:
    kind: Service
    name: payment-svc
  port:
    targetPort: 8080
  tls:
    termination: edge            # Automatically inherits cluster wildcard cert!
```

---

### Type 2: PASS-THROUGH Termination

* HAProxy acts as a pure **Layer 4 TCP proxy** using SNI. It does not decrypt.
* The TLS bundle is mounted **directly into the Backend Pod**. The Route holds zero certificates.

#### Manifest 1: Application TLS Secret (`payments` namespace)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-tls-secret
  namespace: payments
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-server.crt>
  tls.key: <base64-encoded-server.key>
```

#### Manifest 2: Application Pod Deployment (Mounting TLS Bundle)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-banking-api
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: secure-banking-api
  template:
    metadata:
      labels:
        app: secure-banking-api
    spec:
      containers:
      - name: api
        image: secure-banking-api:v1
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: cert-volume
          mountPath: /etc/tls/certs
          readOnly: true
      volumes:
      - name: cert-volume
        secret:
          secretName: app-tls-secret   # Mounts tls.crt and tls.key into pod
```

#### Manifest 3: Pass-Through Route (Pure L4 SNI)
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: secure-banking-route
  namespace: payments
spec:
  to:
    kind: Service
    name: secure-banking-svc
  port:
    targetPort: 8443
  tls:
    termination: passthrough          # HAProxy tunnels raw TLS stream via SNI
```

---

### Type 3: RE-ENCRYPT Termination (Banking Zero-Trust Standard)

* **Leg 1 (Client $\rightarrow$ HAProxy):** Encrypted with the cluster wildcard certificate.
* **HAProxy RAM:** Decrypted to read L7 URL paths (`/api`) and session cookies.
* **Leg 2 (HAProxy $\rightarrow$ Pod):** Re-encrypted with an internal certificate auto-generated by the OpenShift Service CA.

#### Manifest 1: Service Annotation (Auto-Issues Backend Pod Cert)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: reencrypt-svc
  namespace: payments
  annotations:
    # OpenShift Service CA automatically generates and populates this Secret!
    service.beta.openshift.io/serving-cert-secret-name: backend-internal-tls
spec:
  ports:
  - name: https
    port: 8443
    targetPort: 8443
  selector:
    app: backend-app
```

#### Manifest 2: Backend Pod Deployment (Mounting Auto-Generated Cert)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-app
  namespace: payments
spec:
  template:
    spec:
      containers:
      - name: app
        image: backend-app:v1
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: internal-certs
          mountPath: /var/run/secrets/tls
          readOnly: true
      volumes:
      - name: internal-certs
        secret:
          secretName: backend-internal-tls  # Auto-created by Service CA
```

#### Manifest 3: Re-encrypt Route with `destinationCACertificate`
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: reencrypt-route
  namespace: payments
spec:
  to:
    kind: Service
    name: reencrypt-svc
  port:
    targetPort: https
  tls:
    termination: reencrypt
    # Destination CA: Tells HAProxy to trust the pod's internal Service CA certificate
    destinationCACertificate: |-
      -----BEGIN CERTIFICATE-----
      MIIC... (Contents of /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt)
      -----END CERTIFICATE-----
```

---

## ⚙️ Phase 4: Inside the Router Pod: Controller, Processes & Sockets

A common senior-level interview question: *"What processes live inside the router pod, and how does it achieve zero downtime?"*

Inside every running `router-default-xxxx` container, three processes work as a coordinated team:

```
                      Inside the Router Container:
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│   [ openshift-router ] (In-Pod Go Controller)                          │
│        │                                                               │
│        ├─ 1. Watches kube-apiserver for Endpoints & Routes             │
│        ├─ 2. Writes dynamic updates to UNIX Socket:                    │
│        │    /var/lib/haproxy/run/haproxy.sock                          │
│        └─ 3. Writes config/certs to disk & triggers reload             │
│                                                                        │
│   [ haproxy -W ] (HAProxy Master Process - PID 1)                      │
│        │                                                               │
│        ├── Spawns ──► [ haproxy ] (New Worker Process - PID 28)        │
│        │              - Binds ports 80/443, handles all new traffic    │
│        │                                                               │
│        └── Signals ─► [ haproxy ] (Old Worker Process - PID 15)        │
│                       - Receives SIGUSR1                               │
│                       - Finishes in-flight requests, then exits        │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### The Two Scaling Tiers:

| Event Type | What Happens Under the Hood | Reload Required? | Packet Drop? |
| :--- | :--- | :--- | :--- |
| **Pod Scaling (e.g. 2 $\rightarrow$ 30 pods)** | Go controller sends plain-text commands across `/var/lib/haproxy/run/haproxy.sock` to enable pre-allocated standby slots. Updates in **< 1ms**. | **NO** | **Zero Packet Drop** |
| **Structural Change (New Route, Cert Update)** | Go controller updates config on disk. HAProxy Master (`PID 1`) forks a new worker (`PID 28`) and sends `SIGUSR1` to drain old worker (`PID 15`). | **Graceful Process Reload** (Pod stays Running) | **Zero Packet Drop** |

---

## 🚨 Phase 5: Wire-Level Failure Modes & Diagnostics

### 1. `ERR_SSL_PROTOCOL_ERROR` (Browser Error)
* **Root Cause:** Route is configured as **Pass-Through**, but the backend pod is speaking **plain HTTP (port 8080)**.
* **Diagnosis:** Browser sends an unencrypted `ClientHello` directly to the pod. The pod tries to parse binary TLS bytes as an HTTP GET request, encounters invalid syntax, and resets the TCP connection.

### 2. `503 Service Unavailable / Application is not available` (`L6RSP`)
* **Root Cause:** Route is configured as **Re-encrypt**, but HAProxy failed its internal TLS handshake to the pod.
* **Diagnosis:** HAProxy terminates client TLS, but fails when trying to connect to the pod on port 8443 (e.g., pod cert expired, SAN mismatch, or `destinationCACertificate` missing). HAProxy logs `L6RSP` (Layer 6 Response Error).

### 3. `NET::ERR_CERT_COMMON_NAME_INVALID`
* **Root Cause:** Hostname mismatch.
* **Diagnosis:** The certificate served by HAProxy lacks the route domain in its `subjectAltName` (SAN) list. Modern browsers ignore Common Name (`CN`) and strictly enforce SAN extensions.

---

## 🎯 Phase 6: High-Yield Senior Interview Q&A

### Q1: In Pass-Through mode, how does HAProxy route traffic without decrypting the payload?
> **Answer:** HAProxy operates as a Layer 4 TCP proxy. It inspects the very first packet of the connection—the unencrypted **TLS `ClientHello`**—and extracts the **SNI (Server Name Indication)** extension. It matches the domain against its in-memory routing table and forwards the raw TCP stream directly to the target pod IP and port without decrypting.

### Q2: Why would you choose Re-encrypt over Pass-Through?
> **Answer:** In strict regulatory environments (banking/PCI-DSS), unencrypted traffic cannot cross the internal pod SDN (ruling out Edge). However, if the platform requires Layer 7 ingress features—such as path-based URL routing (`/api` vs `/web`), cookie session stickiness, or injecting `X-Forwarded-For`—Pass-Through cannot be used because it is blind to Layer 7. Re-encrypt bridges this: it decrypts at HAProxy for L7 inspection, then immediately establishes a second TLS connection to the pod.

### Q3: How do you verify that a private key matches a certificate before deploying it?
> **Answer:** Extract the public modulus of both the certificate and the private key and compute their MD5 hash:
> ```bash
> openssl x509 -noout -modulus -in server.crt | openssl md5
> openssl rsa -noout -modulus -in server.key  | openssl md5
> ```
> If the two checksum hashes match, the private key mathematically matches the certificate.
