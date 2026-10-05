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

## 🧮 4. The 10-Replica Scenario (Policy YAML vs. Dev YAML)

### A. The Platform Policy (Guardrails & Budget)
```yaml
# 1. CONTAINER GUARDRAILS
apiVersion: v1
kind: LimitRange
metadata:
  name: container-guardrails
  namespace: payment-apps
spec:
  limits:
  - type: Container
    min:
      cpu: "50m"                  # Min 50 millicores per container
    max:
      cpu: "4"                    # Max 4 CPUs per container
    maxLimitRequestRatio:
      cpu: "2"                    # Limit cannot exceed 2x the Request!

---
# 2. NAMESPACE AGGREGATE BUDGET
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-budget
  namespace: payment-apps
spec:
  hard:
    requests.cpu: "20"            # Max 20 vCPUs total requested
    limits.cpu: "50"              # Max 50 vCPUs total limited
```

### B. What the Developer Submits
```yaml
# 3. DEVELOPER DEPLOYMENT
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payment-apps
spec:
  replicas: 10                    # ◄── Multiplies everything by 10!
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

* **The Math:**
  * **Total Requests:** $10 \text{ replicas} \times 1\text{ CPU} = \mathbf{10\text{ vCPUs}}$ (claims 10 CPUs on cluster nodes).
  * **Total Limits:** $10 \text{ replicas} \times 10\text{ CPU} = \mathbf{100\text{ vCPUs}}$ (demands 100 CPUs against namespace limit quota).

---

## 🚪 5. The 2 Admission Gates: Is It "Within Range"?

```
DEVELOPER APPLIES DEPLOYMENT: (replicas: 10, req: 1 CPU, lim: 10 CPU)
  │
  ▼
GATE 1: LimitRange (Evaluates SINGLE container: req: 1, lim: 10)
  • Is 1 CPU >= min (50m)?                             ──► ✅ Pass (1000m >= 50m)
  • Is 10 CPU <= max (4 CPU)?                          ──► ❌ REJECTED! (10 > 4)
  • Is Ratio (10/1 = 10x) <= maxLimitRequestRatio (2x)? ──► ❌ REJECTED! (10x > 2x)
  │
  ▼ (If Gate 1 passes...)
GATE 2: ResourceQuota (Evaluates MULTIPLIED SUM: 10 replicas)
  • Total Requests (10 x 1 = 10) <= hard requests.cpu (20)?  ──► ✅ Pass (10 <= 20)
  • Total Limits (10 x 10 = 100) <= hard limits.cpu (50)?    ──► ❌ REJECTED! (100 > 50)
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
