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

## 🔌 7. Ingress Port Binding & Port Remapping Architecture

When deploying an `IngressController` with `endpointPublishingStrategy`, choosing how ports bind to infrastructure is critical:

### 7.1 Publishing Strategies Overview

| Strategy | Network Model | Cloud Infrastructure | Typical Use Case |
| :--- | :--- | :--- | :--- |
| **`HostNetwork`** | Binds directly to node host ports (`80`, `443`, `1936`) | Uses host VM public/private IP | Single-Node OKD (SNO), Bare-metal, Edge |
| **`LoadBalancerService`** | Router runs in pod network; exposed via K8s `LoadBalancer` Service | Provisions dedicated Cloud LB (AWS NLB / GCP Forwarding Rule) with unique external IP | Enterprise AWS ROSA, GCP OKD/OCP, Azure ARO |
| **`NodePortService`** | Exposes router on high host ports (`30000-32767`) | External LB routes to NodePorts | On-prem F5 / NetScaler integrations |
| **`Private`** | Router accessible only within cluster SDN | No external ingress | Internal-only platform routing |

---

### 7.2 HostNetwork Default Ports vs. The SNO Port Conflict Trap

In `HostNetwork` mode, an IngressController defines its listening ports under `spec.endpointPublishingStrategy.hostNetwork`:

```yaml
endpointPublishingStrategy:
  type: HostNetwork
  hostNetwork:
    httpPort: 80         # Standard HTTP web port
    httpsPort: 443       # Standard HTTPS TLS port
    statsPort: 1936      # HAProxy internal metrics & socket port
```

> [!CAUTION]
> **The SNO Port Conflict Trap:**
> On a Single-Node OKD cluster, the default ingress controller (`router-default`) is **already running with `HostNetwork: true` and bound to host ports `80`, `443`, and `1936`**.
> 
> If you deploy a secondary IngressController (`edge-app-ingress`) requesting host ports `80` and `443` on that **same single VM**, the Linux kernel rejects the bind:
> ```text
> listen tcp 0.0.0.0:80: bind: address already in use
> ```
> The second router pod crashes and enters `CrashLoopBackOff`.

---

### 7.3 The Port Remapping Pattern (For Secondary Routers on SNO)

To co-locate multiple IngressControllers on a single host or SNO cluster without collision, **remap the host ports**:

```yaml
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
    hostNetwork:
      httpPort: 8080       # Remapped from 80
      httpsPort: 8443      # Remapped from 443
      statsPort: 1937      # Remapped from 1936
  defaultCertificate:
    name: custom-wildcard-tls
  namespaceSelector:
    matchLabels:
      ingress: edge-app
```

Clients then connect directly via the remapped port:
```bash
curl -vI https://edge-app.apps.okd-sno.brainybots.cloud:8443
```

---

### 7.4 The Enterprise Multi-Node Standard (Cloud Load Balancer)

In production multi-node clusters (AWS ROSA, GCP OCP), enterprises **never remap ports**. Instead, they declare:

```yaml
endpointPublishingStrategy:
  type: LoadBalancerService
```

* The OpenShift Ingress Operator automatically creates a Kubernetes `Service` of `type: LoadBalancer`.
* AWS or GCP provisions a **brand-new Network Load Balancer (NLB) with its own dedicated public IP**.
* Both ingress controllers listen on standard ports `80` and `443` simultaneously with zero conflict!

---

## 🧪 8. Post-Deployment Experiments, Tweaks & Live Socket Drills

Once your IngressController and Routes are running, use these hands-on drills to master deep HAProxy runtime behaviors:

### 🧪 Experiment 1: Live Zero-Reload Scaling Verification

Prove that scaling application pods updates HAProxy in under 1ms with **zero config reloads**:

1. **Scale your application deployment:**
   ```bash
   oc scale deployment edge-app --replicas=8 -n edge-app
   ```
2. **Inspect the router pod's dynamic backend slots via the UNIX socket:**
   ```bash
   ROUTER_POD=$(oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o jsonpath='{.items[0].metadata.name}')
   echo "show servers state" | oc exec -i -n openshift-ingress $ROUTER_POD -c router -- socat - /var/lib/haproxy/run/haproxy.sock | grep edge-app
   ```
3. **Check the router pod restart count and uptime:**
   ```bash
   oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default
   # RESTARTS stays 0; Uptime stays continuous. No packet loss!
   ```

---

### 🧪 Experiment 2: Master-Worker Process Tree & Graceful Reload Inspection

Inspect how HAProxy Master (PID 1) reloads workers during certificate changes:

1. **Inspect the active in-pod processes:**
   ```bash
   oc exec -it -n openshift-ingress $ROUTER_POD -c router -- ps -ef
   ```
   * **PID 1:** `haproxy -W -db -f /var/lib/haproxy/conf/haproxy.config` (The Master process).
   * **PID X:** `haproxy -Ws ...` (The active Worker process handling client connections).
   * **PID Y:** `/usr/bin/openshift-router` (The Go controller listening to `kube-apiserver`).

2. **Trigger a reload (update a certificate secret or add an annotation):**
   ```bash
   oc annotate route edge-app-route -n edge-app test-reload=$(date +%s) --overwrite
   ```

3. **Check `ps -ef` immediately:**
   * Master (PID 1) forks a **new Worker PID**.
   * Old Worker PID receives `SIGUSR1`, finishes in-flight requests, and cleanly exits.
   * Container uptime remains 100% untouched.

---

### 🧪 Experiment 3: Direct HAProxy UNIX Domain Socket Querying (`socat`)

OpenShift router mounts the runtime socket at `/var/lib/haproxy/run/haproxy.sock`. Run interactive diagnostics:

```bash
# 1. Query HAProxy engine status, uptime, and process limits:
echo "show info" | oc exec -i -n openshift-ingress $ROUTER_POD -c router -- socat - /var/lib/haproxy/run/haproxy.sock

# 2. Query real-time connection counters and traffic statistics:
echo "show stat" | oc exec -i -n openshift-ingress $ROUTER_POD -c router -- socat - /var/lib/haproxy/run/haproxy.sock | cut -d',' -f1,2,5,18,34

# 3. Manually place a backend pod in maintenance mode (zero traffic without pod deletion):
echo "set server <backend-name>/<server-id> state maint" | oc exec -i -n openshift-ingress $ROUTER_POD -c router -- socat - /var/lib/haproxy/run/haproxy.sock
```

---

### 🧪 Experiment 4: Enterprise Production Tweaks via Route Annotations

Fine-tune HAProxy traffic handling declaratively on the Route object:

```yaml
apiVersion: route.route.openshift.io/v1
kind: Route
metadata:
  name: edge-app-route
  namespace: edge-app
  annotations:
    # 1. Increase Gateway Timeout for LLM streaming / long jobs (Default: 30s)
    haproxy.router.openshift.io/timeout: 120s

    # 2. Session Stickiness / Sticky Cookies (pins user to same backend pod)
    haproxy.router.openshift.io/cookie-name: "APP_SESSION_ID"

    # 3. Enable Gzip / Deflate Compression on responses
    haproxy.router.openshift.io/enable-compression: "true"

    # 4. IP Whitelisting / Security Geo-Fencing
    haproxy.router.openshift.io/ip_whitelist: "192.168.1.0/24 10.0.0.0/8"

    # 5. Connection Throttling / DDoS Protection
    haproxy.router.openshift.io/rate-limit-connections: "true"
    haproxy.router.openshift.io/rate-limit-connections.concurrent-tcp: "100"
spec:
  host: edge-app.apps.okd-sno.brainybots.cloud
  to:
    kind: Service
    name: edge-app-svc
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

---

### 🧪 Experiment 5: Live Port Remapping Migration

If testing multiple ingress controllers on an SNO cluster, patch the ports dynamically:

```bash
# Dynamically remap ports to avoid 80/443 conflict on SNO:
oc patch ingresscontroller/edge-app-ingress -n openshift-ingress-operator --type=merge -p '{
  "spec": {
    "endpointPublishingStrategy": {
      "type": "HostNetwork",
      "hostNetwork": {
        "httpPort": 8080,
        "httpsPort": 8443,
        "statsPort": 1937
      }
    }
  }
}'

# Verify the router pod restarts and binds to 8443:
oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=edge-app-ingress
curl -kI https://edge-app.apps.okd-sno.brainybots.cloud:8443
```

---

## 🗺️ 9. Hands-on Demo Suites (Pure Declarative Manifests)

All overarching concepts, port binding rules, and runtime experiments documented above apply across our self-contained hands-on demo suites.

Each directory below is focused strictly on executing that specific termination demo using 100% pure declarative YAML manifests (`00` $\rightarrow$ `05`):

| Lab Suite | Documentation & Manifests | Focus Area |
| :--- | :--- | :--- |
| **[`haproxy-edge/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/)** | [`haproxy-edge/README.md`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/README.md) | **Edge Termination:** Dedicated `IngressController` CR, wildcard Secret, OpenSSL SAN certs, and simulated terminal outputs. |
| **[`haproxy-passthrough/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/)** | [`haproxy-passthrough/README.md`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/README.md) | **Pass-Through Termination:** Pure Layer 4 SNI proxying, pod-mounted secrets, and `ERR_SSL_PROTOCOL_ERROR` drill. |
| **[`haproxy-reencrypt/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/)** | [`haproxy-reencrypt/README.md`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/README.md) | **Re-encrypt Termination:** OpenShift Service CA auto-generation, dual-leg encryption, and `503 L6RSP` failure mode drill. |

