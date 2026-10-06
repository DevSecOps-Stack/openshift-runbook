# 🎯 OpenShift Observability, Prometheus & Alerts — Rapid Interview Cheat Sheet

*Concise, high-yield bullet notes for Platform Engineers and SREs. No fluff, scan in 2 minutes.*

---

## ⚡ 1. Elevator Soundbite & The Fire Alarm Analogy

* **Elevator Soundbite:** OpenShift decouples platform infrastructure monitoring from application metrics using two isolated Prometheus stacks (**CMO** vs. **UWM**) unified under **Thanos Querier**, while **Alertmanager** eliminates alert storms through label-based routing, grouping, and inhibition trees.
* **The Fire Alarm Analogy:**
  * **CMO (Platform):** The building's structural fire alarm (sprinklers, elevators, power mains in `openshift-*` namespaces).
  * **UWM (User Workload):** Individual tenant smoke detectors inside private leased offices (custom business apps).
  * **Thanos Querier:** The central security lobby desk that has visibility across all floors with strict badge access (RBAC).
  * **Alertmanager:** The 911 dispatch switchboard that deduplicates 100 simultaneous panic calls into a single dispatch ticket.

---

## 📑 2. Complete Master Architecture & Policy Manifests (Single Source of Truth)

### A. Enable User Workload Monitoring (UWM) — Platform Config
ConfigMap applied in `openshift-monitoring` to spin up the secondary tenant stack:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    # [RULE 1] Enable the secondary User Workload Prometheus stack
    enableUserWorkload: true
    prometheusK8s:
      retention: 15d               # [RULE 2] Platform metrics retention
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 100Gi       # [RULE 3] Dedicated PV for platform TSDB
```

---

### B. Master `PrometheusRule` Manifest (Tenant App Monitoring)
Production alert rule CR applied in application namespace `payments-prod`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payment-api-alerts
  namespace: payments-prod
  labels:
    role: alert-rules              # [RULE 4] Discovered by Prometheus Operator
spec:
  groups:
  - name: payment-gateway.rules
    rules:
    # ── RULE A: High Error Rate Alert ──────────────────────────────
    - alert: PaymentApiHighHttp5xx
      # [RULE 5] PromQL Condition: 5xx rate > 5% over 5m
      expr: |
        sum(rate(http_requests_total{job="payment-service", status=~"5.."}[5m]))
        /
        sum(rate(http_requests_total{job="payment-service"}[5m])) * 100 > 5
      for: 2m                      # [RULE 6] Flap dampener: Must persist 2 mins
      labels:
        severity: critical         # [RULE 7] Routes to PagerDuty high-priority
        team: payments-sre
      annotations:
        summary: "Payment API 5xx error rate > 5%"
        description: "Pod error rate spiked to {{ $value | printf \"%.2f\" }}%."
        runbook_url: "https://wiki.brainybots.internal/ops/payments-5xx"

    # ── RULE B: Pod CrashLooping Alert ──────────────────────────────
    - alert: PaymentPodCrashLooping
      # [RULE 8] Detects container restarts > 3 in 15 mins
      expr: rate(kube_pod_container_status_restarts_total{namespace="payments-prod"}[15m]) * 60 > 3
      for: 5m                      # [RULE 9] Prevents alerting on 1-off transient restarts
      labels:
        severity: warning          # [RULE 10] Routes to Slack/Email
        team: payments-sre
      annotations:
        summary: "Container restarting frequently"
        description: "Pod {{ $labels.pod }} restarted {{ $value }} times."
```

---

### C. Master Alertmanager Routing & Inhibition Config
Applied in `alertmanager-main` Secret within `openshift-monitoring`:

```yaml
global:
  resolve_timeout: 5m
route:
  receiver: "default-slack"
  group_by: ['namespace', 'alertname']  # [RULE 11] Group by namespace to stop storms
  group_wait: 30s                       # [RULE 12] Wait 30s for sibling alerts before firing
  group_interval: 5m                    # [RULE 13] Wait 5m before sending new batch
  repeat_interval: 4h                   # [RULE 14] Re-notify every 4h if still firing
  routes:
  - match:
      severity: critical                # [RULE 15] Critical matches go to PagerDuty
    receiver: "pagerduty-oncall"
    continue: false

inhibit_rules:
# [RULE 16] If Node is Down, SUPPRESS all Pod-level alerts from that node!
- source_match:
    alertname: 'NodeNetworkDown'
    severity: 'critical'
  target_match:
    alertname: 'PaymentPodCrashLooping'
  equal: ['node']
```

---

## 📊 3. SRE / Developer Scenario Matrix

| # | Trigger Event | Metric Evaluated | Rule & Gate Triggered | Alert State Flow | Final Action / Notification |
|---|---|---|---|---|---|
| **1** | **Transient 30s Spike** | 5xx rate jumps to 12% for 30s, then normalizes | `[RULE 5] expr > 5%`<br>`[RULE 6] for: 2m` | `Inactive` $\rightarrow$ `Pending` $\rightarrow$ `Inactive` | **Silent (No alert)**. `for: 2m` prevented false alarm flap. |
| **2** | **Sustained Outage** | 5xx rate remains at 15% for 4 minutes | `[RULE 5] expr > 5%`<br>`[RULE 6] for: 2m`<br>`[RULE 7] severity: critical` | `Inactive` $\rightarrow$ `Pending` (at 2m) $\rightarrow$ `Firing` | **PagerDuty Triggered**. Sent after `group_wait: 30s`. |
| **3** | **Worker Node Crash** | Worker node network dies; 15 pods crash simultaneously | `[RULE 16] inhibit_rules`<br>`NodeNetworkDown` fires | `NodeNetworkDown` = `Firing`<br>`PaymentPodCrash` = `Suppressed` | **1 PagerDuty for Node**. 15 pod alerts **inhibited**; zero alert fatigue! |
| **4** | **Dev Omitted UWM Config** | Dev creates `ServiceMonitor` in `payments-dev`, but UWM not enabled in cluster | `[RULE 1] enableUserWorkload` is `false` | Scrape target never created | **Silent Failure**. UWM Prometheus pods don't exist; targets stay unmonitored. |

---

## 🚪 4. Wire-Level Architecture & Alert Lifecycle State Machine

```
[ App Pod (:8080/metrics) ]
       │
       ▼ (1. Scraped every 30s by ServiceMonitor)
[ User Workload Prometheus (TSDB) ] ◄── (Reconciled by Prometheus Operator)
       │
       ▼ (2. Evaluates PrometheusRule every evaluation_interval)
┌────────────────────────────────────────────────────────────────────────┐
│                   ALERT LIFECYCLE STATE MACHINE                        │
│                                                                        │
│   [ INACTIVE ] ──(expr == true)──► [ PENDING ]                         │
│         ▲                              │                               │
│         │ (condition drops             │ (condition holds for          │
│         │  before 'for: 2m')           │  full 'for: 2m' duration)     │
│         │                              ▼                               │
│         └──────────────────────── [ FIRING ]                           │
│                                        │                               │
└────────────────────────────────────────┼───────────────────────────────┘
                                         ▼ (3. Dispatched to Alertmanager API)
┌────────────────────────────────────────────────────────────────────────┐
│                         ALERTMANAGER PIPELINE                          │
│                                                                        │
│  [ Dedup & Grouping ] ──► [ Inhibition Tree ] ──► [ Routing Tree ]     │
│  (group_by: namespace)     (NodeDown silences      (severity: critical │
│                             PodDown)                -> PagerDuty)      │
└────────────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
                               [ PagerDuty / Slack ]
```

---

## 🛠️ 5. Top 3 Production Triage Commands

```bash
# 1. Verify Platform (CMO) and User Workload (UWM) Monitoring Pods
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus
oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus

# 2. Check Firing & Pending Alerts directly via Thanos Querier Route
export THANOS_URL=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
curl -k -H "Authorization: Bearer $(oc whoami -t)" "https://${THANOS_URL}/api/v1/alerts" | jq '.data.alerts[] | {alert: .labels.alertname, state: .state, activeAt: .activeAt}'

# 3. Query Alertmanager for Active Silences & Inhibitions
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- amtool alert --alertmanager.url=http://localhost:9093
```


---

---

## 📈 5.1 Enterprise Grafana & Metric Source Architecture

In production enterprise setups (e.g. `BrainyBots Enterprise` / `CloudOps Systems`), Grafana dashboards are filtered by namespace (e.g., `namespace="payments-prod"`). Even though developers see namespace-filtered views, **these infrastructure metrics originate from `openshift-monitoring`**:

### A. The 3 Platform Metric Collectors (Wire-Level Deep Dive)

| Collector Agent | How It Physically Harvests Data | Underlying Linux / K8s Source | Core Prometheus Metrics |
| :--- | :--- | :--- | :--- |
| **`cAdvisor`** *(Container Advisor)* | Built directly into the host **Kubelet** daemon. Samples container cgroup directories every 10–15s and exposes them at `https://<node-ip>:10250/metrics/cadvisor`. | Linux `/sys/fs/cgroup/cpu/` & `/sys/fs/cgroup/memory/`.<br>Measures actual kernel accounting slices. | `container_cpu_usage_seconds_total`<br>`container_memory_working_set_bytes`<br>`container_cpu_cfs_throttled_periods_total` |
| **`node-exporter`** *(Node OS Agent)* | Deployed as a **DaemonSet** with `hostPID: true` and `hostNetwork: true`. Queries Linux kernel pseudo-filesystems. | Linux `/proc/stat` (CPU mode ticks)<br>`/proc/meminfo` (RAM breakdown)<br>`/proc/net/dev` (NIC bytes) | `node_cpu_seconds_total`<br>`node_memory_MemTotal_bytes`<br>`node_filesystem_free_bytes` |
| **`kube-state-metrics`** *(API Informer)* | Runs as a **Deployment** in `openshift-monitoring`. Connects to `kube-apiserver` via Client-Go **Informer (`ListWatch`)**. Generates in-memory metrics with **zero database/etcd load**. | Live Kubernetes Object states declared in `etcd` (Pods, Quotas, Deployments, Nodes). | `kube_resourcequota`<br>`kube_pod_container_resource_requests`<br>`kube_pod_container_resource_limits`<br>`kube_pod_status_phase` |
| **`User Workload Prometheus`** | Scrapes tenant application pods via `ServiceMonitor` or `PodMonitor` CRDs reconciled by Prometheus Operator. | Application HTTP endpoint (e.g. `http://pod:8080/metrics`). | `http_requests_total`<br>`payment_transactions_total`<br>`jvm_memory_used_bytes` |

---

### B. Thanos Querier: The HA gRPC Deduplication Pipeline

```
┌─────────────────────────────────┐       ┌─────────────────────────────────┐
│     prometheus-k8s-0 (Pod)      │       │     prometheus-k8s-1 (Pod)      │
│  [TSDB] ◄── [thanos-sidecar]    │       │  [TSDB] ◄── [thanos-sidecar]    │
│             (gRPC :10901)       │       │             (gRPC :10901)       │
└────────────────┬────────────────┘       └────────────────┬────────────────┘
                 │                                         │
                 └────────────────────┬────────────────────┘
                                      │ gRPC (Federated Fetch)
                                      ▼
                        ┌───────────────────────────┐
                        │      Thanos Querier       │
                        │ 1. Deduplicates HA samples│
                        │ 2. Merges CMO + UWM data  │
                        │ 3. Enforces tenant RBAC   │
                        └─────────────┬─────────────┘
                                      │ HTTP PromQL (:9091)
                                      ▼
                        ┌───────────────────────────┐
                        │  kube-rbac-proxy / OAuth  │
                        └─────────────┬─────────────┘
                                      │
                                      ▼
                     [ Enterprise Grafana / SRE Cockpit ]
```

* **Deduplication Mechanics:** Both `prometheus-k8s-0` and `prometheus-k8s-1` scrape the identical targets simultaneously. Thanos Querier strips the `prometheus_replica` label and deduplicates overlapping timestamps so Grafana sees a clean, uninterrupted line with zero jitter.
* **Multi-Tenancy Guardrail:** Thanos Querier integrates with OpenShift OAuth. When an engineer queries `/api/v1/query`, the OAuth proxy validates their token and silently injects `{namespace="team-allowed"}` matchers so tenants cannot spy on other business units.

---

### C. Top 10 Enterprise PromQL Recipes (SRE Production Cockpit)

```promql
# 1. Container CFS CPU Throttling % (High = Pod latency spike!)
sum(rate(container_cpu_cfs_throttled_periods_total{namespace="payments-prod"}[5m])) by (pod)
/
sum(rate(container_cpu_cfs_periods_total{namespace="payments-prod"}[5m])) by (pod) * 100

# 2. Container Memory Working Set vs Limit % (At 95% = OOMKilled risk!)
sum(container_memory_working_set_bytes{namespace="payments-prod", container!=""}) by (pod)
/
sum(kube_pod_container_resource_limits{namespace="payments-prod", resource="memory"}) by (pod) * 100

# 3. Pod CPU Utilization (Instantaneous Core Usage)
sum(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate{namespace="payments-prod"}) by (pod)

# 4. Namespace CPU Quota Consumption %
sum(kube_pod_container_resource_requests{namespace="payments-prod", resource="cpu"}) 
/ 
sum(kube_resourcequota{namespace="payments-prod", resource="cpu", type="hard"}) * 100

# 5. Pod Restarts Burn Rate (CrashLoop detection over last 1 hour)
sum(increase(kube_pod_container_status_restarts_total{namespace="payments-prod"}[1h])) by (pod)

# 6. Cluster-Wide Node Memory Saturation %
(1 - (sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes))) * 100

# 7. Cluster-Wide Total Node CPU Saturation %
(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100

# 8. HAProxy Ingress HTTP 5xx Error Rate %
sum(rate(haproxy_backend_http_responses_total{code=~"5.."}[5m])) 
/ 
sum(rate(haproxy_backend_http_responses_total[5m])) * 100

# 9. Ingress P99 Response Latency (Milliseconds)
histogram_quantile(0.99, sum(rate(haproxy_backend_response_time_seconds_bucket[5m])) by (le, backend)) * 1000

# 10. PVC Storage Capacity Saturation %
(sum(kubelet_volume_stats_used_bytes{namespace="payments-prod"}) by (persistentvolumeclaim)
/
sum(kubelet_volume_stats_capacity_bytes{namespace="payments-prod"}) by (persistentvolumeclaim)) * 100
```

---

## ⚡ 6. 30-Second Interview Flashcards

* **Q: Difference between CMO and User Workload Monitoring (UWM)?**  
  *A:* CMO monitors core OpenShift control-plane and platform components (`openshift-*` namespaces). UWM is a dedicated, separate Prometheus instance dedicated to user applications, providing isolation so runaway developer metrics cannot crash cluster observability.
* **Q: Role of Thanos Querier in OpenShift?**  
  *A:* Thanos Querier sits on top of both CMO and UWM Prometheus instances, exposing a single unified PromQL endpoint that deduplicates metrics and enforces multitenant OpenShift RBAC (users only see metrics from namespaces they have access to).
* **Q: What is the difference between `Pending` and `Firing` alert states?**  
  *A:* `Pending` means the PromQL threshold is breached but the `for` timer has not elapsed yet (dampening transient spikes). `Firing` means the breach persisted beyond the `for` duration and was dispatched to Alertmanager.
* **Q: How does Alertmanager Inhibition prevent alert fatigue?**  
  *A:* An inhibition rule mutes a set of target alerts if a higher-order source alert is already firing (e.g., if `NodeDown` is firing, suppress all `PodDown` and `EndpointDown` alerts originating from that same node).
* **Q: How do you enable User Workload Monitoring in OpenShift?**  
  *A:* Create or edit the `cluster-monitoring-config` ConfigMap in `openshift-monitoring` and set `enableUserWorkload: true`. CMO will automatically deploy the Prometheus Operator and Prometheus pods into `openshift-user-workload-monitoring`.
