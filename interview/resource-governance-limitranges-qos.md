# 🎯 Resource Governance, LimitRanges & QoS — Rapid Interview Cheat Sheet

*Concise, high-yield bullet notes for Platform Engineers and SREs. No fluff, scan in 2 minutes.*

---

## ⚡ 1. Requests vs. Limits (Floor vs. Ceiling)

* **`requests` (The Scheduler Floor):**
  * **Who uses it:** Evaluated ONLY by `kube-scheduler` at deploy time for node placement.
  * **Physical reality:** Not an exclusive hardware reservation; sets relative CPU weight under contention.
  * **Runtime impact:** Zero runtime enforcement by Linux kernel.

* **`limits` (The Runtime Ceiling):**
  * **Who uses it:** Enforced at runtime by the Linux Kernel via **cgroups**.
  * **CPU Overuse (Compressible):** Throttled by Linux CFS (Completely Fair Scheduler). Pod stays **`Running (1/1)`**, never crashes, but API latency spikes (20ms $\rightarrow$ 2000ms).
  * **Memory Overuse (Incompressible):** Terminated by Linux OOM Killer. Pod crashes with **`OOMKilled` (Exit Code 137 / SIGKILL)**.

* **Sidecar Summation Rule:**
  * $\text{Total Pod Request} = \text{Main Container} + \sum \text{Sidecars}$
  * $\text{Total Pod Limit} = \text{Main Container} + \sum \text{Sidecars}$
  * Scheduler evaluates the combined sum against node allocatable capacity.

---

## 🚢 2. The 3 QoS Classes (The Lifeboat Analogy)

When a node hits 96% RAM (`MemoryPressure`), Kubelet evicts pods like throwing passengers off a sinking lifeboat:

| QoS Class | Pod Spec Definition | Eviction Order | Kernel Score (`/proc/<pid>/oom_score_adj`) | Enterprise Rule |
| :--- | :--- | :--- | :--- | :--- |
| **💀 BestEffort** | **Zero requests, Zero limits** | **1st to DIE** | `oom_score_adj = 1000` *(Max kill priority)* | Non-critical batch jobs only |
| **⚠️ Burstable** | `requests < limits` | **2nd to DIE** | `oom_score_adj = 2 to 999` *(Dynamic score)* | Standard web APIs & microservices |
| **🛡️ Guaranteed** | `requests == limits` *(Both CPU & RAM)* | **Evicted LAST** | `oom_score_adj = -997` *(High resistance)* | **Mandatory for Kafka, Oracle DB, Payments** |

* **Key Takeaway:** Always set `requests == limits` for critical databases to give them `Guaranteed` QoS and minimize eviction risk during node spikes.

---

## 🤼 3. LimitRange vs. ResourceQuota (The Partnership)

* **`LimitRange` (Individual Container Guardrail):**
  * **Scope:** Single containers and pods inside a namespace.
  * **Analogy:** Daily ATM single-swipe cap ($500 per transaction).
  * **Auto-injects defaults:** **YES ✅** (`defaultRequest`, `default`).
  * **Key Controls:** `min`, `max`, and `maxLimitRequestRatio` per container.

* **`ResourceQuota` (Namespace Budget Ceiling):**
  * **Scope:** Aggregate sum of all workloads in the namespace.
  * **Analogy:** Monthly credit card ceiling ($10,000 total credit line).
  * **Auto-injects defaults:** **NO ❌** (Strictly validates and rejects non-compliant pods).
  * **Key Controls:** Caps total `requests.cpu`, `limits.cpu`, `requests.memory`, `limits.memory`, storage, and pod counts.

* **The Partnership:** A `ResourceQuota` mandates that all pods specify requests/limits. A `LimitRange` automatically supplies default values so developer pods pass admission smoothly.

---

## 🧮 4. The Complete Policy YAML (The Single Source of Truth)

### A. The Master Platform Policy Manifests
```yaml
# ========================================================
# 1. CONTAINER GUARDRAILS & DEFAULTS
# ========================================================
apiVersion: v1
kind: LimitRange
metadata:
  name: container-guardrails
  namespace: payment-apps
spec:
  limits:
  - type: Container
    # ── REQUESTS FAMILY (The Floor) ──
    min:
      cpu: "50m"                  # [RULE 1] Validation: Request must be >= 50m
      memory: "64Mi"
    defaultRequest:
      cpu: "100m"                 # [RULE 2] Auto-Fill: Injected if 'requests' omitted
      memory: "256Mi"

    # ── LIMITS FAMILY (The Ceiling) ──
    max:
      cpu: "4"                    # [RULE 3] Validation: Limit must be <= 4
      memory: "8Gi"
    default:
      cpu: "500m"                 # [RULE 4] Auto-Fill: Injected if 'limits' omitted
      memory: "1Gi"

    # ── BURST RATIO (The Gap) ──
    maxLimitRequestRatio:
      cpu: "2"                    # [RULE 5] Validation: Limit/Request gap <= 2x!

---
# ========================================================
# 2. NAMESPACE AGGREGATE BUDGET CEILING
# ========================================================
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-budget
  namespace: payment-apps
spec:
  hard:
    requests.cpu: "20"            # Max 20 vCPUs total requested in namespace
    limits.cpu: "50"              # Max 50 vCPUs total limited in namespace
    requests.memory: "32Gi"       # Max 32 GiB total requested in namespace
    limits.memory: "64Gi"         # Max 64 GiB total limited in namespace
```

---

### B. How the Master Policy Evaluates 4 Real-World Developer Scenarios:

| Scenario | What Developer Submits in Deployment | What Happens (Mapped to Master Policy) | Final Admitted Pod Values |
| :--- | :--- | :--- | :--- |
| **1. Dev Omitted Everything** | `resources: {}` (forgot requests & limits) | `LimitRange` auto-fills `[RULE 2]` & `[RULE 4]`. Passes `ResourceQuota` gate! | `req: 100m / 256Mi`<br>`lim: 500m / 1Gi` |
| **2. Dev Specified Requests Only** | `resources: { requests: { cpu: "250m" } }` | `LimitRange` keeps 250m request, auto-injects `[RULE 4]` for limits. | `req: 250m`<br>`lim: 500m` |
| **3. Dev Below Minimum** | `resources: { requests: { cpu: "10m" } }` | **REJECTED at Admission!** Violates `[RULE 1]` (`10m < 50m min`). | Pod not created ❌ |
| **4. Dev 10-Replica Multiplier** | `replicas: 10`, `req: 1 CPU`, `lim: 10 CPU` | **REJECTED at Admission!** Breaks 3 separate gates (see Section 5 below). | Pod not created ❌ |

---

## 🚪 5. The 2 Admission Gates: The 10-Replica Breakdown

When the developer applies **Scenario 4**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payment-apps
spec:
  replicas: 10                    # ◄── Multiplier: 10 Pods!
  template:
    spec:
      containers:
      - name: payment-api
        resources:
          requests:
            cpu: "1"              # ◄── Total: 10 x 1 = 10 vCPUs requested
          limits:
            cpu: "10"             # ◄── Total: 10 x 10 = 100 vCPUs limited!
```

### The Step-by-Step Gate Evaluation:

```
DEVELOPER APPLIES DEPLOYMENT: (replicas: 10, req: 1 CPU, lim: 10 CPU)
  │
  ▼
GATE 1: LimitRange (Evaluates SINGLE container: req: 1, lim: 10)
  • Is 1 CPU >= min (50m) [RULE 1]?                    ──► ✅ Pass (1000m >= 50m)
  • Is 10 CPU <= max (4 CPU) [RULE 3]?                 ──► ❌ REJECTED! (10 > 4 max)
  • Is Ratio (10/1 = 10x) <= maxLimitRequestRatio [RULE 5]? ──► ❌ REJECTED! (10x > 2x gap)
  │
  ▼ (If Gate 1 were to pass...)
GATE 2: ResourceQuota (Evaluates MULTIPLIED SUM: 10 replicas)
  • Total Requests: 10 pods x 1 CPU = 10 vCPUs <= hard: 20? ──► ✅ Pass (10 <= 20)
  • Total Limits: 10 pods x 10 CPU = 100 vCPUs <= hard: 50? ──► ❌ REJECTED! (100 > 50)
  │
  ▼ (If Gate 2 passes...)
GATE 3: Kube-Scheduler (Physical Node Placement)
  • Finds worker nodes with at least 1 vCPU unallocated per pod.
```

### The 4 Layers Under the Hood:
1. **Quota Admission Gate:** Rejected because total limits ($100\text{ CPUs}$) exceeds `hard.limits.cpu: 50`.
2. **QoS Class Assignment:** Assigned **`Burstable`** (`requests < limits`, `oom_score_adj = 2 to 999`).
3. **Linux Kernel CFS Behavior:** If admitted, container bursts up to 10 CPU cores if idle. If threads attempt $>10$ cores within 100ms, the kernel **throttles execution** (`cpu.cfs_quota_us`). Pod stays `Running`, but latency spikes.
4. **The 10x Noisy Neighbor Trap:** The scheduler only checks the 1 CPU request and packs 12 pods onto a single 16-core node. If all burst to 10 cores, they starve each other. Fixed by `maxLimitRequestRatio: 2` in `LimitRange`.

---

## 🛠️ 6. Production Troubleshooting Playbook

* **Symptom:** Deployment configured, but `oc get pods` shows `0/3` or `No resources found`.
* **Root Cause:** Pod rejected at admission gate by `LimitRange` or `ResourceQuota`. The Pod was never saved to `etcd`.
* **3-Step Triage Commands:**
  ```bash
  # Step 1: Identify underlying ReplicaSet
  oc get rs -n <namespace>

  # Step 2: Check ReplicaSet events for "FailedCreate" (The Smoking Gun!)
  oc describe rs <replicaset-name> -n <namespace>

  # Step 3: Inspect active Quotas and LimitRanges
  oc describe resourcequota -n <namespace>
  oc describe limitrange -n <namespace>
  ```
* **Verify OOMKilled vs Other Exit 137:**
  ```bash
  oc get pod <pod-name> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'
  # Look for "OOMKilled" vs generic SIGKILL
  ```

---

## ⚡ 7. 30-Second Interview Flashcards

* **Q: Difference between requests and limits?**  
  *A:* `requests` is the scheduler floor for node placement; `limits` is the Linux cgroup ceiling (CFS throttle for CPU, OOM kill for Memory).

* **Q: Why does exceeding CPU slow down a pod while exceeding Memory kills it?**  
  *A:* CPU is compressible (kernel freezes threads until next 100ms time slice); memory is incompressible (kernel cannot compress physical RAM, sends `SIGKILL`).

* **Q: Why combine `LimitRange` with `ResourceQuota`?**  
  *A:* `ResourceQuota` caps team budget but cannot prevent 1 giant container from consuming 100% of it; `LimitRange` caps container size and auto-injects defaults so pods pass quota admission.

* **Q: How to protect Kafka brokers and databases from node eviction?**  
  *A:* Set `requests == limits` for both CPU and Memory. OpenShift assigns **`Guaranteed`** QoS (`oom_score_adj = -997`), protecting it from eviction during memory pressure.
