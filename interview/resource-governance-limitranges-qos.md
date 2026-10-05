# Kubernetes Resource Governance: Requests, Limits, QoS, LimitRanges, and Quotas

Practical runbook for platform engineers and application teams working with Kubernetes and OpenShift.

> **Scope:** This guide explains CPU and memory requests and limits, Pod QoS classes, namespace `LimitRange` and `ResourceQuota` policies, and common troubleshooting steps. Exact behavior can vary with Kubernetes/OpenShift version, node configuration, and enabled features. Check the documentation for the cluster version when changing platform policy.

## Contents

- [Quick summary](#quick-summary)
- [Requests and limits](#requests-and-limits)
- [CPU throttling and memory OOM](#cpu-throttling-and-memory-oom)
- [Pod QoS classes and node pressure](#pod-qos-classes-and-node-pressure)
- [LimitRange and ResourceQuota](#limitrange-and-resourcequota)
- [Replica requests and quota usage](#replica-requests-and-quota-usage)
- [Example namespace policy](#example-namespace-policy)
- [Defaulting behavior](#defaulting-behavior)
- [Troubleshooting rejected Pods](#troubleshooting-rejected-pods)
- [Interview questions](#interview-questions)
- [Further reading](#further-reading)

## Quick summary: The 3 Core Mental Models

### 🚢 1. The Lifeboat Analogy (QoS Eviction & Kernel `oom_score_adj`)

When a worker node experiences severe memory pressure, Kubelet must evict pods to keep the node alive. Think of the node as a sinking lifeboat:

| QoS Class | Pod Spec | Eviction Order | Kernel Score (`/proc/<pid>/oom_score_adj`) | Practical Rule |
| :--- | :--- | :--- | :--- | :--- |
| **💀 BestEffort** | Zero requests, zero limits | **1st to be evicted** | `oom_score_adj = 1000` *(Max kill priority)* | Dev/testing batch jobs only |
| **⚠️ Burstable** | `requests < limits` | **2nd to be evicted** | `oom_score_adj = 2 to 999` *(Dynamic score)* | Standard web APIs & microservices |
| **🛡️ Guaranteed** | `requests == limits` (both CPU & RAM) | **Evicted last** | `oom_score_adj = -997` *(High resistance)* | Kafka, Oracle DB, transactional APIs |

> **Kernel Mechanism:** Kubelet writes to `/proc/<pid>/oom_score_adj`. Higher scores mean the Linux OOM Killer targets the process first. Setting `requests == limits` minimizes eviction risk during memory pressure.

---

### 🧮 2. The 10-Replica Multiplier Across 4 Layers

```yaml
spec:
  replicas: 10
  template:
    spec:
      containers:
      - name: api
        resources:
          requests:
            cpu: "1"     # ◄── Scheduler floor (per pod)
          limits:
            cpu: "10"    # ◄── Runtime ceiling (per pod)
```

* **The Math:**
  * **Total Requests:** $10 \text{ pods} \times 1\text{ CPU} = \mathbf{10\text{ vCPUs}}$ (evaluated by `kube-scheduler` & request quota).
  * **Total Limits:** $10 \text{ pods} \times 10\text{ CPU} = \mathbf{100\text{ vCPUs}}$ (evaluated by kernel cgroups & limit quota).

* **The 4 Layers Under the Hood:**
  1. **Quota Admission Shock:** If namespace `ResourceQuota` limits CPU to `50`, the Deployment is **rejected at admission** ($100 > 50$), even though requests ($10\text{ CPUs}$) fit!
  2. **QoS Class Assignment:** `requests < limits` assigns **`Burstable`** QoS.
  3. **Linux Kernel CFS Runtime Behavior:** Each container can burst up to 10 CPU cores if idle. Exceeding 10 cores within a 100ms CFS period throttles CPU execution. The pod stays `Running`, but API latency spikes.
  4. **The 10x Noisy Neighbor Trap:** The scheduler only checks the 1 CPU request and may pack 12 pods onto a 16-core node. If all pods burst simultaneously, they starve each other. **Fix:** Use `LimitRange` with `maxLimitRequestRatio: { cpu: "2" }` to cap burst gaps.

---

### 💳 3. `LimitRange` vs `ResourceQuota` in 3 Lines

* **`LimitRange` (Per-Object Guardrail):** Enforces min/max boundaries per container and **auto-injects default requests/limits** when omitted.
* **`ResourceQuota` (Namespace Budget):** Caps the **aggregate sum** of all vCPU, RAM, and Storage across the entire namespace. Rejects non-compliant pods; never auto-injects defaults.
* **The Partnership:** `LimitRange` provides defaults so pods satisfy `ResourceQuota` admission requirements.

## Requests and limits

| Field | Main purpose | What it means |
| --- | --- | --- |
| `requests.cpu` | Scheduling and CPU weight under contention | The scheduler accounts for this amount when selecting a node. |
| `requests.memory` | Scheduling and eviction comparisons | The scheduler accounts for this amount; it is not exclusive RAM. |
| `limits.cpu` | Runtime ceiling | CPU use is throttled when the cgroup reaches its allowed CPU time. |
| `limits.memory` | Runtime ceiling | The kernel may OOM-kill a process in the container when memory pressure reaches the cgroup limit. |

If a resource limit is supplied without a request, Kubernetes normally copies that limit into the request unless admission-time defaulting has supplied a request. A namespace `LimitRange` can also apply defaults, so inspect the admitted Pod to see the final values.

CPU quantities use cores: `1` is one CPU core and `250m` is one quarter of a core. Memory quantities use binary units such as `Mi` and `Gi` (`512Mi`, `2Gi`).

For ordinary Pods, the request or limit for a resource is generally the sum across the Pod's containers, including sidecars. Init containers and Pod overhead have additional scheduling-accounting rules; consult the Kubernetes resource management documentation for those cases.

## CPU throttling and memory OOM

| | CPU | Memory |
| --- | --- | --- |
| Resource behavior | Compressible: work can wait for CPU time | Incompressible: memory cannot be throttled in the same way |
| Limit behavior on Linux | Cgroup CPU quota can throttle execution | Cgroup memory limit can lead to an OOM kill |
| Common symptom | Increased latency or reduced throughput while the container stays running | Container termination/restart, potentially reported as `OOMKilled` |
| Diagnostic direction | Check CPU usage and throttling metrics | Check container termination reason, events, and memory usage |

The cgroup files and enforcement details differ between cgroups v1 and v2 and are implementation details; avoid relying on a specific file path such as `cpu.cfs_quota_us` in portable runbooks.

Exit code `137` commonly indicates termination by `SIGKILL` (`128 + 9`), but it does **not** prove that a memory limit caused the kill. Check the container's `lastState.terminated.reason`, Pod events, and node events for confirmation. A process can also be killed for other reasons.

Useful starting points:

```sh
oc describe pod <pod-name> -n <namespace>
oc get pod <pod-name> -n <namespace> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'
oc get events -n <namespace> --sort-by=.lastTimestamp
```

## Pod QoS classes and node pressure

Kubernetes assigns each Pod one QoS class based on its containers' CPU and memory requests and limits.

| Class | Simplified criteria | Typical use |
| --- | --- | --- |
| `BestEffort` | No CPU or memory requests or limits are set on any container. | Workloads with no resource guarantees; generally avoid for critical services. |
| `Burstable` | The Pod does not meet `Guaranteed` criteria and has at least one CPU or memory request or limit. | Most general-purpose services. |
| `Guaranteed` | Every container has CPU and memory requests and limits, and each request equals its corresponding limit. | Workloads needing tightly defined resource envelopes. |

QoS is **not a promise of survival** and does not replace Pod priority. During node-pressure eviction, kubelet considers whether usage exceeds requests, Pod priority, and usage relative to requests. QoS can help estimate risk, but kubelet does not simply evict every Pod in one QoS class before considering the next. A `Guaranteed` Pod can still be evicted to preserve node stability, and kernel-level OOM conditions can have different outcomes from kubelet eviction.

Do not describe `Guaranteed` workloads as “protected to the end.” Use suitable requests, limits, Pod priority where justified, capacity planning, and application-level resilience together.

## LimitRange and ResourceQuota

| Capability | `LimitRange` | `ResourceQuota` |
| --- | --- | --- |
| Scope | Individual containers, Pods, or PVCs in a namespace | Aggregate usage or object counts in a namespace |
| Typical controls | Per-object minimum/maximum, request-to-limit ratio, defaults | Total requested/limited CPU or memory, storage, PVC count, Pod count, and other supported quota keys |
| Injects resource defaults | Yes, when configured | No |
| Prevents one container from exceeding a per-container maximum | Yes, when configured | No; it only limits aggregate quota |
| Prevents aggregate namespace growth | No | Yes, for the resources and objects it tracks |

These policies complement each other, but neither requires the other. A `ResourceQuota` that tracks CPU or memory requests/limits can reject Pods that do not provide the tracked values; a `LimitRange` with `defaultRequest` and/or `default` can provide defaults. Confirm the actual quota keys and defaults in the namespace before diagnosing an admission failure.

`LimitRange` validation happens when an object is admitted. Changing a policy does not retroactively change existing Pods. Multiple `LimitRange` objects in one namespace can make which default is applied nondeterministic, so prefer a single clear defaulting policy per namespace.

## Replica requests and quota usage

Resource requests apply to **each Pod replica**. A Deployment does not share a single request among its replicas. For a steady-state workload with `R` replicas and a Pod request of `Q`, expected requested quota usage is approximately `R × Q`, subject to all containers, init-container accounting, other Pods, and the quota keys configured in the namespace.

For example, ten replicas with a `1` CPU request each account for about `10` CPUs of `requests.cpu` quota. If that uses the full quota, additional Pods that require CPU requests may be rejected by quota. Whether the admitted Pods can run is a separate scheduling question: they need suitable node capacity.

When quota blocks Pod creation, the Deployment object may still be accepted and show fewer ready replicas than desired. The ReplicaSet controller can then report `FailedCreate` events for rejected Pods.

## Example namespace policy

Create a `LimitRange` and a `ResourceQuota` in the same namespace. Adjust values to match the cluster's capacity and the team's workload profile.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: workload-guardrails
  namespace: payment-apps
spec:
  limits:
    - type: Container
      min:
        cpu: 50m
        memory: 64Mi
      max:
        cpu: "4"
        memory: 8Gi
      defaultRequest:
        cpu: 100m
        memory: 256Mi
      default:
        cpu: 500m
        memory: 1Gi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: workload-budget
  namespace: payment-apps
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
```

An application workload can then specify its own sizing:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: payment-apps
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
        - name: api
          image: example.invalid/payment-api:v2
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 2Gi
```

The `example.invalid` image is a placeholder. Replace it with an approved image reference before deploying. In this example, the explicit container values take precedence over `LimitRange` defaults and fit within the configured per-container bounds.

## Defaulting behavior

`LimitRange` defaults are applied to missing fields during Pod admission. They do not overwrite fields that the workload supplies.

| Workload fields supplied | Possible result with the example `LimitRange` |
| --- | --- |
| No CPU or memory resources | The configured default request and default limit are applied. |
| Requests only | Missing limits receive configured defaults; supplied requests remain. |
| Limits only | Missing requests receive configured default requests, subject to Kubernetes defaulting behavior. |
| CPU only | Memory fields can receive configured defaults. |
| A value outside `min` or `max` | Pod admission is rejected with a validation error. |

Keep defaults internally consistent. For example, do not configure a default CPU limit lower than a request that teams are likely to set: the API can reject the resulting Pod. Also check whether the namespace has multiple `LimitRange` objects.

## Troubleshooting rejected Pods

### Symptom: Deployment exists, but fewer Pods are created than requested

1. Check the Deployment and ReplicaSet status:

   ```sh
   oc get deployment,replicaset -n payment-apps
   oc describe deployment payment-service -n payment-apps
   ```

2. Inspect ReplicaSet events for `FailedCreate`, quota, or `LimitRange` errors:

   ```sh
   oc describe rs <replicaset-name> -n payment-apps
   oc get events -n payment-apps --sort-by=.lastTimestamp
   ```

3. Inspect namespace policies and current quota usage:

   ```sh
   oc get limitrange,resourcequota -n payment-apps
   oc describe resourcequota -n payment-apps
   ```

4. Check the submitted Pod template's effective resource values and compare them with `min`, `max`, defaults, and quota `hard`/`used` values.

A typical `LimitRange` failure may say that a requested CPU limit exceeds the maximum allowed per container. A quota failure may state that creating the Pod would exceed a namespace quota. If the Pod was admitted but remains `Pending`, inspect scheduling events and node allocatable capacity instead.

## Interview questions

### What is the difference between requests and limits?

Requests are used for scheduling and resource accounting; CPU requests also affect relative CPU shares under contention. Limits define runtime ceilings enforced through the container runtime and Linux cgroups. A request is not dedicated physical capacity.

### Why does CPU overuse usually slow a workload while memory overuse can terminate it?

CPU is throttled when the cgroup reaches its CPU quota, so work waits for a later scheduling period. Memory cannot be throttled equivalently. When a container crosses its memory limit under pressure, the kernel can OOM-kill a process. The timing and exact result depend on kernel and runtime behavior.

### Why combine `LimitRange` with `ResourceQuota`?

`LimitRange` controls individual object sizing and can default omitted values. `ResourceQuota` caps aggregate namespace usage. A quota alone does not prevent one Pod from claiming a large share of the budget; a `LimitRange` alone does not cap the namespace total.

### Does `Guaranteed` QoS make a Pod immune to eviction?

No. It affects QoS classification and can reduce eviction risk during certain node-pressure situations, but kubelet eviction also considers priority and usage relative to requests. Node stability, system-level resource pressure, and kernel OOM behavior still matter.

## Further reading

- [Kubernetes: Resource management for Pods and containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes: Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Kubernetes: Resource quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Kubernetes: Pod QoS classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)
- [Kubernetes: Node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Kubernetes: Pod priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
