# OpenShift 4 HAProxy Ingress Architecture & TLS Termination — Interview Cheat Sheet

A comprehensive, high-yield guide to OpenShift Ingress internals, HAProxy zero-reload socket updates, and the 3 TLS termination models (Edge, Pass-Through, Re-encrypt).

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

## 🔒 The 3 TLS Termination Modes (Side-by-Side Comparison)

| Mode | Traffic: Client $\rightarrow$ Router | Traffic: Router $\rightarrow$ Pod | Certificate Location | Can Router Inspect HTTP Headers? | Primary Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Edge** | **HTTPS** (Encrypted) | **HTTP** (Plain text) | On the **Router / Route** (centralized secret) | **YES** (Path routing, cookie stickiness, header injection) | Standard internal microservices & public web apps |
| **Pass-Through** | **HTTPS** (Encrypted) | **HTTPS** (Encrypted) | Strictly inside the **Backend Pod** | **NO** (L4 SNI TCP inspection only) | PCI-DSS banking data, mTLS between client & pod, custom protocols |
| **Re-encrypt** | **HTTPS** (Encrypted) | **HTTPS** (Encrypted) | **Router** (Edge cert) + **Pod** (Internal cert & CA) | **YES** (Decrypts at router, inspects/modifies headers, re-encrypts) | Strict zero-trust enterprise compliance requiring end-to-end encryption + WAF/L7 features |

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
