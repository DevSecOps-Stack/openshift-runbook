# LLM Inference Autoscaling on OpenShift with vLLM & KEDA — Interview Cheat Sheet

A comprehensive, high-yield architectural guide to event-driven GPU/LLM autoscaling using vLLM, OpenShift User-Workload Monitoring, Thanos, and KEDA.

---

## ⚡ The 30-Second Elevator Pitch

> *"Standard Kubernetes autoscaling based on CPU or Memory fails completely for LLMs because vLLM pre-allocates up to 95% of GPU VRAM at boot for KV caching, and GPU matrix multiplication does not stress the host CPU. To scale LLM inference reliably, we scale on **Queue Depth** (`vllm:num_requests_waiting`). We scrape inference metrics into OpenShift User-Workload Monitoring, query Thanos via an authenticated ServiceAccount token, and let **KEDA** drive native Kubernetes HPA scaling with custom stabilization windows to eliminate pod flapping."*

---

## 🚨 Why CPU and Memory HPA Fails for LLMs

| Metric | Traditional Web App | LLM Inference (vLLM / TensorRT-LLM) | Why It Fails for LLM Autoscaling |
| :--- | :--- | :--- | :--- |
| **Memory (VRAM)** | Scales proportionally with user traffic | **Pre-allocated immediately (90–95%)** at startup for KV cache | Memory is permanently pegged at 95% even when **0 requests** are queued. HPA would scale to max replicas instantly and stay stuck there forever. |
| **Host CPU** | High CPU indicates high request traffic | Math runs on **GPU Tensor Cores**; host CPU only runs the Python web wrapper | CPU sits at **5%–15%** even while the GPU is completely saturated and users are waiting in line. HPA never triggers. |
| **Queue Depth** | Secondary metric | **The Gold Standard Signal** (`vllm:num_requests_waiting`) | Directly measures user contention. If requests exceed GPU batch capacity, queue spikes immediately $\rightarrow$ trigger instant horizontal scale. |

---

## 🏛️ The 3-Plane System Architecture

```
[ User Prompt Requests ]
           │
           ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 1. WORKLOAD PLANE (ai-platform namespace)                              │
│                                                                        │
│   ┌────────────────────┐          Scraped every 5s                     │
│   │ Pod: vllm-server   │ ──/metrics (vllm:num_requests_waiting) ──┐    │
│   └─────────▲──────────┘                                          │    │
│             │ Scales spec.replicas (1 -> 5)                       │    │
│   ┌─────────┴──────────┐                                          │    │
│   │ Native K8s HPA     │ ◄── Auto-managed by KEDA Operator        │    │
│   └─────────▲──────────┘                                          │    │
│             │ Queries external.metrics.k8s.io                     │    │
│   ┌─────────┴──────────┐                                          │    │
│   │ ScaledObject (CR)  │ ── PromQL: sum(vllm:num_requests_waiting)│    │
│   │ TriggerAuth (CR)   │ ── ServiceAccount Bearer Token           │    │
│   └────────────────────┘                                          │    │
└───────────────────────────────────────────────────────────────────┼────┘
                                                                    │
┌───────────────────────────────────────────────────────────────────┼────┐
│ 2. TELEMETRY PLANE (openshift-user-workload-monitoring)           │    │
│                                                                   │    │
│   ServiceMonitor (in ai-platform) configures Prometheus ──────────┘    │
│   ┌───────────────────────────────┐                                    │
│   │ Prometheus Engine             │ Scrapes and stores time-series data│
│   └───────────────┬───────────────┘                                    │
│                   ▼                                                    │
│   ┌───────────────────────────────┐                                    │
│   │ Thanos Querier (Port 9091)    │ Unified PromQL query endpoint      │
│   └───────────────▲───────────────┘                                    │
└───────────────────┼────────────────────────────────────────────────────┘
                    │ Authenticated PromQL Query
┌───────────────────┼────────────────────────────────────────────────────┐
│ 3. KEDA AUTOSCALING PLANE (keda namespace)                             │
│                                                                        │
│   ┌───────────────┴───────────────┐                                    │
│   │ KEDA External Metrics Server  │ Queries Thanos, translates to HPA  │
│   └───────────────▲───────────────┘                                    │
│                   │                                                    │
│   ┌───────────────┴───────────────┐                                    │
│   │ KEDA Operator                 │ Watches ScaledObject, configures   │
│   │                               │ HPA & stabilization behavior       │
│   └───────────────────────────────┘                                    │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 🔐 Wire-Level Authentication & Security Mechanics

1. **Thanos Querier Security:**
   * OpenShift protects Thanos Querier (`https://thanos-querier.openshift-monitoring.svc:9091`) with an internal OAuth/RBAC proxy.
   * Unauthenticated queries return `403 Forbidden`.
2. **Dedicated ServiceAccount & RBAC:**
   * Create a ServiceAccount (e.g. `keda-thanos-sa`) in `ai-platform`.
   * Bind it to OpenShift's cluster role:
     ```bash
     oc adm policy add-cluster-role-to-user cluster-monitoring-view -z keda-thanos-sa -n ai-platform
     ```
3. **KEDA TriggerAuthentication:**
   * Reads the SA secret/token and injects it as a Bearer Authorization header into KEDA's HTTPS requests to Thanos:
     ```yaml
     apiVersion: keda.sh/v1alpha1
     kind: TriggerAuthentication
     metadata:
       name: keda-thanos-auth
       namespace: ai-platform
     spec:
       secretTargetRef:
       - parameter: bearerToken
         name: keda-thanos-sa-token
         key: token
     ```

---

## 🧮 Autoscaling Math & Flapping Prevention

### 1. Scale-Up Calculation
The native Kubernetes HPA calculates desired replicas using:
$$\text{Desired Replicas} = \left\lceil \frac{\text{Current Metric Value}}{\text{Target Metric Value}} \right\rceil$$

* **Example:**
  * Target threshold per pod: `4` queued requests
  * Traffic surge causes: `58` queued requests
  * Desired pods: $\lceil 58 / 4 \rceil = 15 \text{ pods}$
  * Clamped to `maxReplicaCount: 5`.

### 2. Preventing Pod Thrashing (Scale-Down Stabilization)
* **The Problem:** LLM pods take 30–90 seconds to download model weights and allocate GPU VRAM. If traffic drops to 0 for 5 seconds and HPA immediately terminates 4 pods, an incoming burst 10 seconds later causes catastrophic latency (cold starts).
* **The Solution:** Configure `behavior.scaleDown.stabilizationWindowSeconds` inside the `ScaledObject`:
  ```yaml
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300   # 5-minute cool-down window
  ```
* HPA evaluates the peak metric over the past 300 seconds before executing any replica termination.

---

## 🎯 High-Yield Interview Q&A

### Q1: Why use KEDA instead of Prometheus Adapter?
> **Answer:** Prometheus Adapter requires complex, brittle configuration maps to transform Prometheus metrics into the custom metrics API, does not support scale-to-zero out of the box, and is complex to maintain. KEDA is native, modular, supports over 60+ scalers, automatically provisions and configures the underlying HPA object, and supports declarative `TriggerAuthentication`.

### Q2: What metric would you use for scale-to-zero in GPU inference?
> **Answer:** Scale-to-zero is driven by **active connections + queue depth**. When both `vllm:num_requests_waiting == 0` and `vllm:num_requests_running == 0` for a defined cooldown period, KEDA scales the deployment down to `minReplicaCount: 0`, completely freeing expensive GPU hardware for other batch/training workloads.

### Q3: How do you handle cold-start latency when scaling GPU pods?
> **Answer:** Three enterprise techniques:
> 1. **Local Model Caching:** Mount high-speed PVCs or node-local NVMe caches so pods load weights from disk rather than pulling from HuggingFace/S3 over the network.
> 2. **Pre-warmed Standby / `minReplicaCount: 1`:** Keep 1 standing replica active to absorb initial prompt bursts.
> 3. **Scale-Down Dampening:** Set `stabilizationWindowSeconds: 300` to prevent rapid teardown of initialized GPU contexts.
