# OpenShift 4 HAProxy Ingress Architecture & TLS Termination — Interview Cheat Sheet

A comprehensive, high-yield guide to OpenShift Ingress internals, HAProxy zero-reload socket updates, TLS certificate anatomy, OpenSSL commands, and the 3 TLS termination models (Edge, Pass-Through, Re-encrypt).

---

## ⚡ The 30-Second Elevator Pitch

> *"OpenShift Ingress separates the Control Plane (`openshift-ingress-operator`) from the Data Plane (`openshift-ingress`). The router is a customized HAProxy instance that achieves zero-downtime scaling without process reloads by communicating with the HAProxy runtime socket (`/var/lib/haproxy/run/haproxy.sock`) over pre-allocated dynamic server slots. It supports three distinct TLS termination models: **Edge** (decrypted at router), **Pass-Through** (L4 SNI routing directly to the pod), and **Re-encrypt** (decrypted at router for header inspection, then re-encrypted over internal pod network)."*

---

## 🏛️ Control Plane vs Data Plane Architecture

```
Internet / Corporate Traffic
             │
             ▼
┌────────────────────────────────────────────────────────────────────────┐
│ GCP Forwarding Rule / AWS Network Load Balancer (Port 80/443)         │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│ DATA PLANE (openshift-ingress namespace)                               │
│                                                                        │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ HAProxy Router Pod (router-default-xxxx)                     │     │
│   │                                                              │     │
│   │   [ In-Pod Go Controller ]                                   │     │
│   │             │                                                │     │
│   │             ▼ (UNIX Domain Socket)                           │     │
│   │       /var/lib/haproxy/run/haproxy.sock                      │     │
│   │             │                                                │     │
│   │             ▼ (Dynamic slot update in <1ms)                  │     │
│   │   [ Running HAProxy 2.x Engine ]                             │     │
│   │     - Pre-allocated backend slots (server pod-1, server pod-2)│     │
│   │     - Zero process reload / Zero packet drop                 │     │
│   └──────────────────────────────┬───────────────────────────────┘     │
└──────────────────────────────────┼─────────────────────────────────────┘
                                   │
             ┌─────────────────────┼─────────────────────┐
             ▼                     ▼                     ▼
     [ Edge Backend ]     [ Pass-Through Backend ] [ Re-encrypt Backend ]
        HTTP (8080)             HTTPS (8443)            HTTPS (8443)
```

### Why Separate Namespaces?
* **`openshift-ingress-operator` (Control Plane):** Runs with cluster-admin privileges to interact with cloud provider APIs (GCP/AWS LBs), DNS, and create router daemonsets/deployments.
* **`openshift-ingress` (Data Plane):** HAProxy pods face the untrusted internet. They run with minimal, non-privileged security contexts to insulate the cluster from remote code execution vulnerabilities.

---

## ⚡ Zero-Reload Dynamic Scaling Internals

In traditional HAProxy setups, adding a new backend pod required modifying `haproxy.cfg` and sending `systemctl reload haproxy`. This dropped active TCP connections or spiked memory.

**How OpenShift Solves This:**
1. **Pre-allocated Dynamic Slots:** OpenShift generates configuration templates with empty standby server slots for each backend (e.g. `server-1` to `server-64` marked `disabled`).
2. **The In-Pod Go Watcher:** A Go binary running inside the router container continuously watches the OpenShift API for `Endpoints` and `EndpointSlices`.
3. **Runtime Socket Commands:** When a new pod starts, the Go watcher issues raw commands directly to `/var/lib/haproxy/run/haproxy.sock`:
   ```bash
   echo "set server backend_name/server-1 addr 10.128.2.45 port 8080" | socat - /var/lib/haproxy/run/haproxy.sock
   echo "enable server backend_name/server-1" | socat - /var/lib/haproxy/run/haproxy.sock
   ```
4. **Latency:** Endpoints are registered in **under 1 millisecond** with **zero process reloads** and zero dropped packets.

---

## 🔐 The 3 Essential TLS Bundle Files (The Holy Trinity)

To configure TLS anywhere in OpenShift or enterprise PKI, three files are required:

| File Name | Standard K8s Key | Purpose & Contents | Who Holds It? |
| :--- | :--- | :--- | :--- |
| **`server.crt`** | `tls.crt` | **Public Identity & Cert Chain:** Contains the server's public key, Subject, Validity, Issuer signature, and SAN list. If signed by an intermediate CA, it must include the intermediate certs in order. | Publicly presented to any client connecting over TLS. |
| **`private.key`** | `tls.key` | **Cryptographic Secret:** The server's private key (RSA 2048/4096 or ECDSA P-256). Proves ownership of the certificate and enables key exchange. | **Never shared!** Stored strictly in a secure K8s Secret. |
| **`root-ca.crt`** | `ca.crt` | **The Trust Anchor:** The Certificate Authority root certificate used to verify that the server certificate is authentic and untampered. | Installed in client OS/Keychain/MDM, or configured in Route `destinationCACertificate`. |

---

## 🛠️ OpenSSL Commands: Generation, Signing & Verification

### 1. Generate a Custom Root CA (Trust Anchor)
```bash
# Generate Root CA private key and self-signed certificate (valid 10 years)
openssl req -x509 -new -nodes -newkey rsa:4096 \
  -keyout root-ca.key \
  -out root-ca.crt \
  -days 3650 \
  -subj "/C=AU/O=BrainyBots Enterprise/OU=Security/CN=BrainyBots Enterprise Root CA"
```

### 2. Generate Server Private Key & Certificate Signing Request (CSR)
```bash
# Generate server private key and CSR for wildcard domain
openssl req -new -nodes -newkey rsa:2048 \
  -keyout server.key \
  -out server.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=*.apps.okd-sno.brainybots.cloud"
```

### 3. Sign the Certificate with Modern SAN (Subject Alternative Name)
Modern browsers (Chrome, Safari, Firefox) **reject** certificates that only use `CN`. You must provide an extension file with SAN:

```bash
# Create extensions file
cat <<EOF > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.apps.okd-sno.brainybots.cloud
DNS.2 = apps.okd-sno.brainybots.cloud
EOF

# Sign with Root CA
openssl x509 -req -in server.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.cnf
```

### 4. Critical Diagnostic & Verification Commands (Interview Gold)
```bash
# A. Verify SAN and Expiry on a certificate:
openssl x509 -in server.crt -text -noout | grep -A 2 "Subject Alternative Name"

# B. Verify Private Key matches Certificate (Modulus MD5 Match):
# If the MD5 hashes match, the private key belongs to the certificate!
openssl x509 -noout -modulus -in server.crt | openssl md5
openssl rsa -noout -modulus -in server.key  | openssl md5

# C. Test live TLS handshake over the network with SNI:
openssl s_client -connect router-ip:443 \
  -servername hello.apps.okd-sno.brainybots.cloud \
  -CAfile root-ca.crt
```

---

## 🔒 The 3 TLS Termination Modes (Side-by-Side Comparison)

| Mode | Traffic: Client $\rightarrow$ Router | Traffic: Router $\rightarrow$ Pod | Certificate Location | Can Router Inspect HTTP Headers? | Primary Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Edge** | **HTTPS** (Encrypted) | **HTTP** (Plain text) | On the **Router / Route** (centralized secret) | **YES** (Path routing, cookie stickiness, header injection) | Standard internal microservices & public web apps |
| **Pass-Through** | **HTTPS** (Encrypted) | **HTTPS** (Encrypted) | Strictly inside the **Backend Pod** | **NO** (L4 SNI TCP inspection only) | PCI-DSS banking data, mTLS between client & pod, custom protocols |
| **Re-encrypt** | **HTTPS** (Encrypted) | **HTTPS** (Encrypted) | **Router** (Edge cert) + **Pod** (Internal cert & CA) | **YES** (Decrypts at router, inspects/modifies headers, re-encrypts) | Strict zero-trust enterprise compliance requiring end-to-end encryption + WAF/L7 features |

---

## 📦 How to Add TLS Bundles to Each Termination Type

### 1. Adding TLS to EDGE Termination

There are two enterprise patterns:

#### Pattern A: Centralized Wildcard on IngressController (Enterprise Recommended)
Dev teams don't manage certs. The platform team configures one wildcard certificate on the router:
```bash
# 1. Create TLS secret in openshift-ingress namespace
oc create secret tls custom-wildcard-tls \
  --cert=server.crt --key=server.key -n openshift-ingress

# 2. Patch the IngressController CR
oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=merge -p '{"spec":{"defaultCertificate":{"name":"custom-wildcard-tls"}}}'
```
*Dev Route YAML (Zero cert configuration needed):*
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: edge-app
  namespace: my-app
spec:
  to:
    kind: Service
    name: edge-app-svc
  port:
    targetPort: 8080
  tls:
    termination: edge    # Automatically inherits cluster wildcard cert!
```

#### Pattern B: Dedicated Cert on Route Object
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: custom-edge-route
  namespace: my-app
spec:
  to:
    kind: Service
    name: edge-app-svc
  tls:
    termination: edge
    certificate: |-
      -----BEGIN CERTIFICATE-----
      MIID... (Contents of server.crt)
      -----END CERTIFICATE-----
    key: |-
      -----BEGIN PRIVATE KEY-----
      MIIE... (Contents of server.key)
      -----END PRIVATE KEY-----
    caCertificate: |-
      -----BEGIN CERTIFICATE-----
      MIIC... (Contents of root-ca.crt)
      -----END CERTIFICATE-----
```

---

### 2. Adding TLS to PASS-THROUGH Termination

In Pass-Through, **the Route holds NO certificates**. The router acts as an L4 SNI pipe. The TLS bundle must be mounted directly into the **Backend Pod**.

#### Step 1: Create TLS Secret in Application Namespace
```bash
oc create secret tls backend-app-tls \
  --cert=server.crt --key=server.key -n my-app
```

#### Step 2: Mount Secret in Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: passthrough-app
  namespace: my-app
spec:
  template:
    spec:
      containers:
      - name: web
        image: my-secure-app:latest
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: tls-certs
          mountPath: /etc/tls/certs
          readOnly: true
      volumes:
      - name: tls-certs
        secret:
          secretName: backend-app-tls
```

#### Step 3: Create Pass-Through Route (No Certs on Route!)
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: passthrough-route
  namespace: my-app
spec:
  to:
    kind: Service
    name: passthrough-app-svc
  port:
    targetPort: 8443
  tls:
    termination: passthrough   # HAProxy forwards raw TLS stream via SNI
```

---

### 3. Adding TLS to RE-ENCRYPT Termination

Re-encrypt requires **two bundles**:
1. **Frontend Bundle:** Served to the browser by HAProxy (from IngressController default cert or Route `spec.tls.certificate`).
2. **Backend Bundle:** Served to HAProxy by the Pod on port 8443.

#### Step 1: Auto-Generate Backend Pod Cert using OpenShift Service CA
Add the Red Hat serving-cert annotation to your Service. OpenShift automatically issues an internal certificate and saves it into a Secret:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: reencrypt-svc
  namespace: my-app
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: reencrypt-backend-tls
spec:
  ports:
  - port: 8443
    targetPort: 8443
    name: https
  selector:
    app: reencrypt-app
```

#### Step 2: Mount `reencrypt-backend-tls` Secret in the Pod Deployment
The pod mounts `/etc/tls/certs` and listens on HTTPS port 8443.

#### Step 3: Create Re-encrypt Route with `destinationCACertificate`
To allow HAProxy to trust the backend pod's internal certificate, provide the OpenShift Service CA bundle in `destinationCACertificate`:
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: reencrypt-route
  namespace: my-app
spec:
  to:
    kind: Service
    name: reencrypt-svc
  port:
    targetPort: https
  tls:
    termination: reencrypt
    # Destination CA: Tells HAProxy to trust the pod's internal certificate
    destinationCACertificate: |-
      -----BEGIN CERTIFICATE-----
      MIIC... (Contents of OpenShift Service CA: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt)
      -----END CERTIFICATE-----
```

---

## 🔬 Wire-Level Cryptographic Mechanics: Re-encrypt Deep Dive

To speak about Re-encrypt with principal-level precision, avoid loose shorthand:

1. **Two Independent TCP/TLS Connections (Not "one connection terminated twice"):**
   * **Connection 1 (Client $\leftrightarrow$ HAProxy):** Handshake completes using the external/wildcard certificate. Terminated at HAProxy.
   * **Connection 2 (HAProxy $\leftrightarrow$ Pod):** HAProxy acts as a TLS client, initiating a separate TCP 3-way handshake and TLS handshake to the pod IP on port 8443, validating the pod's cert against `destinationCACertificate` (Service CA). Terminated at the Pod.
2. **Directional Traffic Keys (`client_write_key` vs `server_write_key`):**
   * In modern TLS (1.2 / 1.3), a handshake does not use a single symmetric key for both directions (which would risk reflection attacks).
   * It derives distinct **directional traffic keys**:
     * Request path: Encrypted with `client_write_key`.
     * Response path: Encrypted with `server_write_key`.
3. **HTTP Protocol Reconstruction (Layer 7 Reverse Proxying):**
   * HAProxy does not decrypt and re-encrypt raw packets.
   * It terminates the incoming TCP/TLS stream, parses the bytes into a **clean HTTP request object in RAM**, modifies it (injecting `X-Forwarded-For: <client-ip>`, `X-Forwarded-Proto: https`, rewriting cookies), and **synthesizes a brand-new HTTP request** over Connection 2.

---

## 🚨 Wire-Level Failure Modes & Signatures

### 1. `ERR_SSL_PROTOCOL_ERROR` (Browser Error)
* **What happened:** Route is configured as **Pass-Through**, but the backend pod is speaking **plain HTTP (port 8080)**.
* **Wire trace:** The browser sends a TLS `ClientHello` packet directly through HAProxy to the pod. The pod tries to parse it as an HTTP GET request, encounters binary TLS bytes, and resets the TCP connection.

### 2. `503 Service Unavailable / Application is not available` (`L6RSP`)
* **What happened:** Route is configured as **Re-encrypt**, but HAProxy failed its internal TLS handshake to the pod.
* **Wire trace:** The browser completes TLS with HAProxy successfully (green padlock appears). HAProxy then attempts a TLS handshake with the pod IP over port 8443. If the pod cert has expired, hostname doesn't match, or the Route's `destinationCACertificate` does not trust the pod's cert, HAProxy logs `L6RSP` (Layer 6 Response Error) and terminates the connection.

### 3. `NET::ERR_CERT_COMMON_NAME_INVALID`
* **What happened:** Hostname mismatch.
* **Wire trace:** The certificate served by HAProxy lacks the route domain in its **Subject Alternative Name (SAN)** list. Modern browsers ignore the Common Name (CN) and strictly enforce SAN extensions.

---

## 🎯 High-Yield Interview Q&A

### Q1: How does HAProxy route Pass-Through traffic without decrypting the payload?
> **Answer:** HAProxy acts as a Layer 4 TCP proxy. It inspects the very first packet of the TLS handshake—the unencrypted **TLS ClientHello**—and extracts the **SNI (Server Name Indication)** extension header (e.g. `api.brainybots.cloud`). HAProxy matches that hostname against its routing table and forwards the raw TCP stream directly to the target pod's IP and port without ever reading or decrypting the ciphertext.

### Q2: Why would you choose Re-encrypt over Pass-Through?
> **Answer:** In strict regulatory environments (banking/healthcare), data-in-transit must be encrypted across the internal SDN pod network (ruling out Edge). However, if the platform requires Layer 7 ingress features—such as path-based URL routing (`/api` vs `/static`), cookie-based session stickiness, or injecting security headers like `X-Forwarded-For`—Pass-Through cannot be used. Re-encrypt bridges this gap: it decrypts at the router for L7 inspection, then immediately re-encrypts before sending packets over the internal cluster network.

### Q3: How do you configure a default wildcard certificate across all routes?
> **Answer:** Instead of configuring certificates on individual developer routes, create a TLS secret in `openshift-ingress` and patch the `IngressController` CR in `openshift-ingress-operator`:
> ```bash
> oc patch ingresscontroller/default -n openshift-ingress-operator \
>   --type=merge -p '{"spec":{"defaultCertificate":{"name":"custom-wildcard-tls"}}}'
> ```
> The Ingress Operator mounts the secret across all router pods, securing all Edge and Re-encrypt routes automatically.

### Q4: How do you verify that a private key matches a certificate before deploying it?
> **Answer:** Extract the public modulus of both the certificate and the private key and compute their MD5 hash:
> `openssl x509 -noout -modulus -in tls.crt | openssl md5`
> `openssl rsa -noout -modulus -in tls.key | openssl md5`
> If the two checksum hashes match, the private key mathematically matches the certificate. If they differ, the deployment will fail with SSL handshake errors.
