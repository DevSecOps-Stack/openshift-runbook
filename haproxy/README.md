# OpenShift 4 HAProxy Ingress Architecture & Master Lab Guide

A comprehensive, master reference manual on OpenShift Ingress internals, in-pod process mechanics, zero-reload socket scaling, master-worker graceful reloads, and hands-on declarative lab suites.

---

## ⚡ The 30-Second Elevator Pitch

> *"OpenShift Ingress separates the Control Plane (`openshift-ingress-operator`) from the Data Plane (`openshift-ingress`). The router is a customized HAProxy instance running an in-pod Go controller alongside an HAProxy Master-Worker engine. When pods scale up or down, HAProxy performs **zero-reload dynamic updates in under 1ms** by writing directly to the runtime socket (`/var/lib/haproxy/run/haproxy.sock`) against pre-allocated standby slots. When structural changes occur (such as certificate renewals or new routes), the HAProxy Master process forks a brand-new worker with the updated config and gracefully drains the old worker via `SIGUSR1`. The pod itself never restarts (`RESTARTS: 0`), ensuring zero dropped packets and zero connection churn."*

---

## 🏛️ 1. Control Plane vs. Data Plane: The Two-Namespace Split

In OpenShift, Ingress is cleanly decoupled into two separate namespaces:

```
1. USER / BROWSER
   Types: https://edge-app.apps.okd-sno.brainybots.cloud
         │
         ▼
2. DNS RESOLUTION (Google Cloud DNS / AWS Route 53)
   *.apps.okd-sno.brainybots.cloud  ──►  Resolves to Load Balancer External IP (e.g. 34.68.120.45)
         │
         ▼
3. CLOUD INFRASTRUCTURE (GCP Forwarding Rule / AWS Network Load Balancer)
   Listens on Port 80 / 443  ──►  Forwards raw TCP stream to Ingress Node
         │
         ▼
4. DATA PLANE: OPENSHIFT INGRESS (openshift-ingress namespace)
┌────────────────────────────────────────────────────────────────────────┐
│ Ingress Node (Host Port 80 / 443)                                      │
│   │                                                                    │
│   ▼                                                                    │
│ HAProxy Router Pod (router-edge-app-ingress-xxxx)                      │
│   • Terminates TLS using 'custom-wildcard-tls' Secret                  │
│   • Matches Host Header: edge-app.apps.okd-sno.brainybots.cloud        │
│   • In-pod Go controller watches EndpointSlices via UNIX socket        │
│                                                                        │
│   (Bypasses kube-proxy; routes directly to pod IP for ultra-low latency)│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼ (Over OVN-Kubernetes SDN)
5. SERVICE ABSTRACTION & BACKEND POD (edge-app namespace)
┌────────────────────────────────────────────────────────────────────────┐
│ Kubernetes Service: edge-app-svc                                       │
│   (Logical selector template: selects pods with label app=edge-app)    │
│                                                                        │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ Application Pod: edge-app-xxxx (Pod IP: 10.128.2.45:8080)    │     │
│   │ Container receives plain HTTP request                        │     │
│   │ Responds: HTTP/1.1 200 OK ("Hello OpenShift!")               │     │
│   └──────────────────────────────────────────────────────────────┘     │
└───────────────────────────────────▲────────────────────────────────────┘
                                    │
                                    │ Managed & Reconciled By
┌───────────────────────────────────┴────────────────────────────────────┐
│ CONTROL PLANE (openshift-ingress-operator namespace)                   │
│   • Ingress Operator Pod: ingress-operator-xxxx                        │
│   • IngressController CR: edge-app-ingress                             │
│     (Selects namespace labeled: ingress=edge-app)                      │
└────────────────────────────────────────────────────────────────────────┘
```


### Why Did Red Hat Split Them?
* **Security & Blast Radius:** If an attacker finds a zero-day remote code execution flaw in HAProxy from the public internet, they are trapped inside the unprivileged router container in `openshift-ingress`. They cannot access the cluster-admin credentials of the operator in `openshift-ingress-operator`.
* **RBAC Boundaries:** Platform admins manage `IngressController` CRs in `openshift-ingress-operator`. The actual traffic-routing workloads live in `openshift-ingress`.

---

## ⚙️ 2. Inside the Router Pod: The 3 Resident Processes

Inside every running `router-default-xxxx` container, three processes work as a tightly coordinated team:

```
                      Inside the Router Container:
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│   [ openshift-router ] (In-Pod Go Controller Process)                  │
│        │                                                               │
│        ├─ 1. Maintains real-time watch on kube-apiserver for           │
│        │     Routes, Services, and EndpointSlices.                     │
│        │                                                               │
│        ├─ 2. Writes instant dynamic slot updates to UNIX domain socket:│
│        │     /var/lib/haproxy/run/haproxy.sock                         │
│        │                                                               │
│        └─ 3. Writes config & certs to disk and triggers Master reload  │
│                                                                        │
│   [ haproxy -W ] (HAProxy Master Process - PID 1)                      │
│        │                                                               │
│        ├── Forks ──► [ haproxy ] (New Worker Process - PID 28)         │
│        │             - Reads new cert/config from RAM                  │
│        │             - Binds ports 80/443; accepts all new traffic     │
│        │                                                               │
│        └── Signals ─► [ haproxy ] (Old Worker Process - PID 15)        │
│                      - Receives SIGUSR1 signal from Master             │
│                      - Stops accepting new connections                 │
│                      - Drains active in-flight requests, then exits    │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## ⚡ 3. Scenario A: What Happens When Pods Scale? (Zero-Reload Dynamic Scaling)

Imagine an HPA scales your application deployment from **2 pods up to 30 pods** during a traffic surge:

```
HPA Scales Pods (2 -> 30) 
       │
       ▼
kube-apiserver generates EndpointSlice Event
       │
       ▼
Go Controller receives event via watch stream
       │
       ▼ (Sends plain-text commands over UNIX socket in < 1ms)
echo "set server backend/server-3 addr 10.128.2.55 port 8080" | socat /var/lib/haproxy/run/haproxy.sock
echo "enable server backend/server-3"                         | socat /var/lib/haproxy/run/haproxy.sock
       │
       ▼
HAProxy updates its in-memory C data structures in RAM
```

### The Wire-Level Facts:
1. **Pre-allocated Standby Slots:** In the backend configuration, OpenShift generates placeholder server slots (`server-1` through `server-64`) marked `disabled`.
2. **Zero Process Reload:** HAProxy does **NOT** reload or restart.
3. **Zero Packet Drops:** Latency of adding the new pod IP is **under 1 millisecond**. Active client connections continue without interruption.

---

## 🔄 4. Scenario B: What Happens When a Certificate or Route is Updated? (Master-Worker Graceful Reload)

When a developer creates a brand-new Route or the platform team updates a TLS certificate secret:

```
TLS Certificate Secret Updated (or new Route created)
       │
       ▼
Go Controller writes new certificate file to container disk:
/var/lib/haproxy/conf/certs/<route-name>.pem
       │
       ▼
Go Controller triggers HAProxy Master Process (PID 1)
       │
       ├── 1. Master forks a BRAND-NEW Worker Process (PID 28)
       │      - PID 28 reads the new certificate from disk into RAM.
       │      - PID 28 binds to ports 80 and 443.
       │      - All new incoming client handshakes route to PID 28!
       │
       └── 2. Master sends SIGUSR1 signal to OLD Worker Process (PID 15)
              - PID 15 stops accepting new handshakes.
              - PID 15 stays alive to finish processing in-flight bank requests.
              - As soon as existing connections close, PID 15 cleanly exits.
```

### The Wire-Level Facts:
* **The Pod NEVER Restarts:** The Kubernetes pod uptime remains untouched (`RESTARTS: 0`).
* **Zero Disconnections:** In-flight sessions are never terminated mid-stream.
* **Instant Green Padlock:** New clients immediately receive the updated certificate with zero downtime.

---

## 🏢 5. Enterprise Ingress Sharding (Namespace Selector)

In production, enterprises **never** shard ingress controllers by TLS type (Edge vs Pass-Through). 

Instead, an IngressController is dedicated to an **Application / Tenant / Security Domain** (e.g. `ingress: edge-app` or `ingress: payment-gateway`). 

```yaml
# 1. The Namespace is labeled with the tenant identifier:
apiVersion: v1
kind: Namespace
metadata:
  name: edge-app
  labels:
    ingress: edge-app

# 2. The dedicated IngressController CR isolates traffic via namespaceSelector:
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: edge-app-ingress
  namespace: openshift-ingress-operator
spec:
  domain: apps.okd-sno.brainybots.cloud
  replicas: 1
  endpointPublishingStrategy:
    type: HostNetwork
  defaultCertificate:
    name: custom-wildcard-tls
  namespaceSelector:
    matchLabels:
      ingress: edge-app    # <-- Dedicated strictly to this tenant!
```

---

## 🔒 6. The 3 TLS Termination Archetypes

| Mode | Traffic: Client $\rightarrow$ Router | Traffic: Router $\rightarrow$ Pod | Certificate Location | Can Router Inspect L7 Headers? | Primary Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Edge** | **HTTPS** (Encrypted) | **HTTP** (Plain text) | On the **Router** (centralized wildcard) | **YES** (Path routing, cookie stickiness, header injection) | Standard internal microservices & public web apps |
| **Pass-Through** | **HTTPS** (Encrypted) | **HTTPS** (Encrypted) | Strictly inside the **Backend Pod** | **NO** (Layer 4 SNI TCP proxy only) | PCI-DSS banking data, client mTLS, custom protocols |
| **Re-encrypt** | **HTTPS** (Encrypted) | **HTTPS** (Encrypted) | **Router** (Public cert) + **Pod** (Internal cert & CA) | **YES** (Decrypts at router, inspects/modifies headers, re-encrypts) | Strict zero-trust enterprise compliance requiring end-to-end encryption + L7 features |

---

## 🗺️ 7. Hands-on Demo Suites (Pure Declarative Manifests)

Each directory below is 100% self-contained with pure YAML manifests (`00` $\rightarrow$ `05`) and step-by-step verification guides:

| Lab Suite | Documentation & Manifests | Focus Area |
| :--- | :--- | :--- |
| **[`haproxy-edge/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/)** | [`haproxy-edge/README.md`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/README.md) | **Edge Termination:** Dedicated `IngressController` CR, wildcard Secret, OpenSSL SAN certs, and simulated terminal outputs. |
| **[`haproxy-passthrough/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/)** | [`haproxy-passthrough/README.md`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/README.md) | **Pass-Through Termination:** Pure Layer 4 SNI proxying, pod-mounted secrets, and `ERR_SSL_PROTOCOL_ERROR` drill. |
| **[`haproxy-reencrypt/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/)** | [`haproxy-reencrypt/README.md`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/README.md) | **Re-encrypt Termination:** OpenShift Service CA auto-generation, dual-leg encryption, and `503 L6RSP` failure mode drill. |
