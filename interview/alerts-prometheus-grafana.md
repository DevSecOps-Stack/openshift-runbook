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
