# Resource Governance, LimitRanges & QoS Classes — Platform Engineering Runbook & Interview Cheat Sheet

A comprehensive, production-grade architectural guide and interview cheat sheet covering Kubernetes Resource Governance, CPU Completely Fair Scheduler (CFS) throttling, Memory OOMKilled mechanics (Exit Code 137), Quality of Service (QoS) classes, and the tactical partnership between `LimitRange` and `ResourceQuota`.

---

## ⚡ The 30-Second Elevator Pitch

> *"In Kubernetes, resource governance splits into two distinct layers: **Planning vs. Runtime Enforcement**. `requests` acts as the scheduling **floor**, evaluated solely by `kube-scheduler` for placement, while `limits` acts as the runtime **ceiling**, enforced strictly by the Linux Kernel via **cgroups**. When a pod exceeds its CPU limit, the Completely Fair Scheduler (CFS) enforces quota periods (`cpu.cfs_quota_us`), resulting in **CPU throttling** where the pod stays running but experiences severe API latency. Conversely, exceeding memory limits triggers the Linux Kernel OOM Killer, terminating the process with **Exit Code 137 (`SIGKILL`)**. At the namespace layer, platform teams deploy **`LimitRange`** (to enforce individual container boundaries, max/min sizes, and surgical default injections) alongside **`ResourceQuota`** (to cap the aggregate team compute, storage, and pod budget)."*

---

## 📊 1. Core Mechanics: Requests (Floor) vs. Limits (Ceiling)

```
  ┌────────────────────────────────────────────────────────┐
  │  LIMITS (The Ceiling / Roof)                           │
  │  • Enforced at runtime by the Linux Kernel (cgroups)   │
  │  • CPU: Kernel throttles execution (slow motion)       │
  │  • Memory: Kernel shoots the container (Exit Code 137) │
  ├────────────────────────────────────────────────────────┤
  │                                                        │
  │             (Application Bounces in Between)           │
  │                                                        │
  ├────────────────────────────────────────────────────────┤
  │  REQUESTS (The Floor / The Foundation)                 │
  │  • Evaluated ONLY by the Kube-Scheduler               │
  │  • Guaranteed physical reservation on the worker node  │
  │  • Node is marked full when sum(requests) == capacity  │
  └────────────────────────────────────────────────────────┘
```

### Sidecar Resource Summation Rule
In pods running sidecars (e.g., Envoy/Istio-proxy, Vault-agent, Dynatrace OneAgent):
$$\text{Total Pod Request} = \text{Main App Request} + \sum \text{Sidecar Requests}$$
$$\text{Total Pod Limit} = \text{Main App Limit} + \sum \text{Sidecar Limits}$$
* The scheduler evaluates the **combined sum** when filtering worker nodes.

---

## ⚔️ 2. The Battle of the Ceilings: CPU Throttling vs. Memory OOMKilled

| Dimension | **CPU (Compressible Resource)** | **Memory (Incompressible Resource)** |
| :--- | :--- | :--- |
| **Linux Kernel Mechanism** | Completely Fair Scheduler (CFS) Quotas | Out-Of-Memory (OOM) Killer (`oom_score_adj`) |
| **Kernel Parameters** | `cpu.cfs_period_us` (100ms), `cpu.cfs_quota_us` | `memory.limit_in_bytes` / `memory.max` |
| **Action Taken** | Kernel freezes container threads for the remainder of the 100ms window | Kernel delivers `SIGKILL` (Signal 9) immediately |
| **Container Status** | Stays `Running (1/1)` | Crashes with `OOMKilled` (`Exit Code 137`) |
| **Symptom Observed** | Sudden latency spikes (50ms $\rightarrow$ 2000ms), thread pool exhaustion | Sudden pod restart, crash loop, broken user sessions |
| **Prometheus Metric** | `container_cpu_cfs_throttled_periods_total` | `container_oom_events_total` |

---

## 🛡️ 3. The 3 Quality of Service (QoS) Classes

When a worker node experiences node-level memory pressure, Kubelet sorts pods by **eviction priority**:

```
        WHO DIES FIRST DURING NODE MEMORY EXHAUSTION?

 ┌─────────────────────────────────────────────────────────────────┐
 │ 1. BestEffort (KILLED FIRST! 💀 - oom_score_adj = 1000)         │
 │    • Criteria: ZERO requests and ZERO limits specified.         │
 │    • Use Case: Temporary batch jobs, non-critical utilities.    │
 ├─────────────────────────────────────────────────────────────────┤
 │ 2. Burstable (KILLED SECOND! ⚠️ - oom_score_adj = 2 to 999)     │
 │    • Criteria: requests < limits (e.g. req: 500m, lim: 1000m).  │
 │    • Use Case: General microservices, web apps with spikes.     │
 ├─────────────────────────────────────────────────────────────────┤
 │ 3. Guaranteed (THE VIPs - PROTECTED TO THE END! 🛡️ - score = -997│
 │    • Criteria: requests == limits for BOTH CPU and Memory.      │
 │    • Use Case: Core Banking databases, Kafka brokers, payments. │
 └─────────────────────────────────────────────────────────────────┘
```

---

## 🤼 4. LimitRange vs. ResourceQuota: The Strategic Partnership

| Capability | **`LimitRange`** (The Container Guardrail) | **`ResourceQuota`** (The Namespace Budget) |
| :--- | :--- | :--- |
| **Analogy** | **Daily Single-Transaction Limit** (Max $500 per swipe) | **Monthly Credit Card Ceiling** (Max $10,000 total) |
| **Target Scope** | **Individual Containers, Pods, and PVCs** | **Aggregate Namespace Sum** |
| **Auto-Inject Defaults?** | **YES ✅** (`defaultRequest`, `default`) | **NO ❌** (Strictly validates and rejects) |
| **Prevents Single Hog?** | **YES ✅** (`max: 4 vCPU` per container) | **NO ❌** (Allows 1 container to eat 100% of quota) |
| **Prevents Infinite Pods?**| **NO ❌** (1,000 small compliant pods allowed) | **YES ✅** (Caps total vCPUs, RAM, and Pod count) |
| **Mutual Dependency** | Supplies the required requests/limits so pods pass the Quota gate | Mandates that requests/limits exist before admission |


---

### 🧮 The Replica Multiplier Rule: Per-Pod vs. Per-Deployment Reservation

A critical conceptual trap for developers and engineers:

> **The `resources.requests` block in a Deployment is NOT shared across the deployment! It applies to EACH INDIVIDUAL REPLICA POD!**

$$\textbf{Namespace Quota Impact} = \textbf{Deployment Replicas} \times \sum \textbf{Container Requests}$$

#### The Classic Production Scenario:
* **Namespace ResourceQuota:** `requests.cpu: "10"` (Total budget: 10 vCPUs)
* **Developer Deployment:**
  ```yaml
  spec:
    replicas: 10          # 10 Replicas
    template:
      spec:
        containers:
        - name: payment-api
          resources:
            requests:
              cpu: "1"    # ◄── NOT 1 CPU shared by all 10! EACH pod gets 1 CPU!
  ```

#### What Happens Under the Hood:
1. **The Math:** $10 \text{ replicas} \times 1 \text{ vCPU request} = \mathbf{10 \text{ vCPUs}}$ total quota claimed.
2. **Quota Admission Gate (APPROVED ✅):**
   * $\text{Current Used } (0) + \text{Requested } (10) \le 10\text{ (Hard Quota)}$.
   * The `ResourceQuota` marks the namespace as **10/10 (100% EXHAUSTED)**!
3. **Physical Scheduling Reality Check:**
   * The `kube-scheduler` must find physical worker nodes with 1 free vCPU for each of the 10 pods.
   * If physical hardware is available, all 10 pods run. If cluster nodes lack CPU, extra pods wait in `Pending`.
4. **The "Locked Door" Effect:**
   * Because the namespace quota is now **10/10 (100% full)**, **NO OTHER POD can start in this namespace!**
   * Scaling to 11 replicas or launching even a tiny `50m` helper pod is instantly blocked at admission by the `ResourceQuota`!

---


### Master Side-by-Side Mapping Table

```yaml
# ===============================================       # ===============================================
# FILE 1: THE GUARDRAILS (Platform Team)                # FILE 2: THE APPLICATION (Development Team)
# kind: LimitRange                                      # kind: Deployment
# ===============================================       # ===============================================

apiVersion: v1                                          apiVersion: apps/v1
kind: LimitRange                                        kind: Deployment
metadata:                                               metadata:
  name: dev-guardrails                                    name: payment-service
  namespace: payment-apps      ◄── MUST MATCH! ──►        namespace: payment-apps
spec:                                                   spec:
  limits:                                                 replicas: 2
  - type: Container                                       template:
                                                            spec:
    # ── THE BOUNDARIES ──                                    containers:
    min:                                                      - name: api-container
      cpu: "50m"       ────────── (Must be >=) ──────────────►  image: payment-api:v2
      memory: "64Mi"   ────────── (Must be >=) ──────────┐      resources:
                                                         │        requests:
    max:                                                 └────────► cpu: "250m"      # Valid (between 50m & 4)
      cpu: "4"         ────────── (Must be <=) ──────────┐          memory: "512Mi"  # Valid (between 64Mi & 8Gi)
      memory: "8Gi"    ────────── (Must be <=) ──────────┼────►   limits:
                                                         └────────► cpu: "1"         # Valid (between 50m & 4)
    # ── THE SAFETY NET ──                                          memory: "2Gi"    # Valid (between 64Mi & 8Gi)
    defaultRequest:    # Injected ONLY if dev omits 'requests'
      cpu: "100m"
      memory: "256Mi"

    default:           # Injected ONLY if dev omits 'limits'
      cpu: "500m"
      memory: "1Gi"
```

---

### Surgical Autocomplete Matrix (Field-by-Field Injection)

`LimitRange` acts as an intelligent field-level autocomplete without altering valid developer inputs:

| What Developer Wrote in Deployment | What LimitRange Injects | Final Pod Result in OpenShift |
| :--- | :--- | :--- |
| **Nothing** (omitted `resources:`) | `defaultRequest` + `default` | `req: 100m / 256Mi`<br>`lim: 500m / 1Gi` |
| **Requests only** (`req: 250m / 512Mi`) | Injects missing `default` limits | `req: 250m / 512Mi` (Dev)<br>`lim: 500m / 1Gi` (LimitRange) |
| **Limits only** (`lim: 2 / 4Gi`) | Injects missing `defaultRequest` | `req: 100m / 256Mi` (LimitRange)<br>`lim: 2 / 4Gi` (Dev) |
| **CPU specified, Memory omitted** | Injects missing Memory only | `CPU: Dev values`<br>`Memory: 256Mi req / 1Gi lim` |
| **Exceeds Max** (`cpu: 8` with `max: 4`) | None (Blocks creation) | **REJECTED AT ADMISSION** |

---

## 🔍 6. Production War Room: The "Ghost Pod" Mystery

### The Incident:
A developer applies a Deployment:
```bash
oc apply -f payment-deployment.yaml
# Output: deployment.apps/payment-service configured (Exit Code 0)
```
Five minutes later, `oc get pods` returns **`No resources found`**, and `oc get deployment` shows **`0/3 ready`**.

### The Root Cause:
* The `Deployment` object was saved in `etcd`.
* The `Deployment` controller created the `ReplicaSet`.
* The `ReplicaSet` attempted to create Pods.
* The API Server's **`LimitRanger` admission controller intercepted and rejected the Pods** (e.g. requested `cpu: 8` exceeding `max: 4`).
* The Pods were never admitted to `etcd`, so they do not show up in `oc get pods`.

### Pro Troubleshooting Protocol:
```bash
# Step 1: Identify the underlying ReplicaSet
oc get rs -n payment-apps

# Step 2: Inspect the ReplicaSet events (The Smoking Gun!)
oc describe rs <replicaset-name> -n payment-apps
```

**Smoking Gun Event Output:**
```text
Events:
  Type     Reason        Age   From                   Message
  ----     ------        ----  ----                   -------
  Warning  FailedCreate  20s   replicaset-controller  Error creating: pods "payment-service-xxx" is forbidden: 
                                                      maximum cpu usage per Container is 4, but limit is 8!
```

---

## 🎯 7. Senior Platform Engineer Interview Q&A

### Q1: What is the architectural difference between `requests` and `limits` in the Linux kernel?
> **Answer:** 
> `requests` is an accounting abstraction used exclusively by `kube-scheduler` during the scoring and filtering phases to select an eligible worker node. It has zero runtime enforcement in the Linux kernel. In contrast, `limits` is directly enforced by the Linux kernel using **cgroups** (`cpu.cfs_quota_us` for CFS CPU throttling, and `memory.limit_in_bytes` / `memory.max` for OOM enforcement).

### Q2: Why does exceeding CPU cause application slowness while exceeding Memory causes an instant crash?
> **Answer:** 
> CPU is a **compressible resource**. When a container consumes its quota within a 100ms CFS period, the Linux kernel simply puts the container threads to sleep for the remaining milliseconds and wakes them up in the next period. The process never dies, but latency skyrockets. Memory is **incompressible**. If RAM limits are breached, the kernel cannot compress physical memory without risking kernel panics, so the OOM Killer immediately dispatches `SIGKILL` (Signal 9), resulting in **Exit Code 137**.

### Q3: Why is having a `ResourceQuota` without a `LimitRange` dangerous?
> **Answer:** 
> If a namespace defines a `ResourceQuota` tracking CPU/Memory requests, Kubernetes strictly rejects any pod submitted without explicit requests. Without a `LimitRange` to auto-inject safe defaults, developers omitting `resources` will experience immediate admission failures. Furthermore, a `ResourceQuota` only regulates the sum: a single rogue container could request 100% of the namespace quota, starving all other workloads. `LimitRange` prevents this by capping the maximum size of individual containers.

### Q4: How does Kubernetes calculate QoS classes, and why is `Guaranteed` preferred for transactional banking databases?
> **Answer:** 
> * **Guaranteed:** `requests == limits` for both CPU and Memory.
> * **Burstable:** `requests < limits`.
> * **BestEffort:** No requests or limits set.
> When a worker node experiences severe memory pressure, Kubelet evicts `BestEffort` pods first, followed by `Burstable` pods exceeding their requests. `Guaranteed` pods are assigned an `oom_score_adj` of `-997`, making them practically immune to eviction unless the entire host node runs out of kernel memory.
