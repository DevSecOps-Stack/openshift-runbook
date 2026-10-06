# 📊 Enterprise Grafana Architecture & Dashboard Engineering

*How Grafana connects to OpenShift Thanos Querier, handles multi-tenancy, resolves template variables, and renders production SRE panels.*

---

## ⚡ 1. The Enterprise Grafana Pipeline

In production banking and enterprise clusters (e.g. `BrainyBots Enterprise` / `CloudOps Systems`), Grafana never connects directly to individual Prometheus instances. It connects to **Thanos Querier** to get unified visibility with multi-tenant security:

```
[ Grafana Dashboard ]
       │
       │ HTTP / HTTPS (PromQL Query)
       ▼
[ Grafana Prometheus Datasource ]
       │
       │ Headers: "Authorization: Bearer <service-account-token>"
       ▼
[ OpenShift OAuth Proxy / kube-rbac-proxy (:9091 / :9092) ]
       │
       │ Validates Bearer Token & checks SubjectAccessReview (SAR)
       ▼
[ Thanos Querier Engine ]
       │
       ├──► gRPC (:10901) ──► CMO Platform Prometheus (node-exporter, cAdvisor, kube-state-metrics)
       │
       └──► gRPC (:10901) ──► User Workload Prometheus (custom /metrics, Spring Boot, Go APIs)
```

---

## ⚙️ 2. Production Datasource Configuration

To configure an Enterprise Grafana instance to talk to Thanos Querier:

### A. Datasource Settings YAML
```yaml
apiVersion: 1
datasources:
- name: OpenShift-Thanos
  type: prometheus
  access: proxy
  orgId: 1
  # Internal Cluster Service URL:
  url: https://thanos-querier.openshift-monitoring.svc:9091
  isDefault: true
  version: 1
  editable: false
  jsonData:
    httpMethod: POST
    timeInterval: 15s
    tlsSkipVerify: false
    # Uses OpenShift Service CA bundle to verify Thanos Querier TLS:
    tlsCACert: "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
    httpHeaderName1: "Authorization"
  secureJsonData:
    httpHeaderValue1: "Bearer <SERVICE_ACCOUNT_TOKEN>"
```

> 🔒 **Enterprise RBAC:** The ServiceAccount bound to this token must possess the `cluster-monitoring-view` ClusterRole to query platform metrics, or `monitoring-rules-view` for tenant-scoped dashboards.

---

## 🎛️ 3. Dynamic Templating Variables (Cascading Dropdowns)

In production dashboards, you never hardcode namespace or pod names. You use cascading template variables so selecting a namespace automatically filters the pods:

### 1. Variable: `$namespace`
* **Type:** Query
* **Query:**
  ```promql
  label_values(kube_namespace_status_phase{phase="Active"}, namespace)
  ```
* **Regex:** `/^(?!openshift|kube-).*$/` *(Hides internal system namespaces from application developers)*

### 2. Variable: `$pod` (Cascades from `$namespace`)
* **Type:** Query
* **Query:**
  ```promql
  label_values(container_cpu_usage_seconds_total{namespace=~"$namespace"}, pod)
  ```

### 3. Variable: `$container` (Cascades from `$pod`)
* **Type:** Query
* **Query:**
  ```promql
  label_values(container_cpu_usage_seconds_total{namespace=~"$namespace", pod=~"$pod", container!="POD"}, container)
  ```

---

## 🧮 4. PromQL Mathematics: `rate()` vs. `irate()`

This is one of the most frequently asked questions in Senior SRE interviews:

| Dimension | `rate()` | `irate()` (Instant Rate) |
| :--- | :--- | :--- |
| **How It Calculates** | Averages per-second rate across the **entire time window** (e.g. `[5m]`). | Calculates per-second rate between the **last two data points** in the range. |
| **Spike Sensitivity** | Smooths out brief micro-bursts into an average. | Highly sensitive; captures momentary 1-second spikes instantly. |
| **Reset / Crash Handling** | Smoothly handles counter resets between scrapes. | Resets can cause minor graph volatility if scrape falls near reset. |
| **Production Use Case** | **Mandatory for Alerting Rules & SLOs** *(Prevents false alarm flap)*. | **Recommended for Grafana Graphs & Cockpits** *(Reveals exact real-time bursts)*. |

### Range Vectors vs. Instant Vectors:
* **Instant Vector:** `http_requests_total{namespace="payments-prod"}`
  * Evaluates to a **single number per series at the current timestamp**.
  * Can be rendered directly in a Stat or Table panel.
* **Range Vector:** `http_requests_total{namespace="payments-prod"}[5m]`
  * Evaluates to an **array of timestamps and values** over the last 5 minutes.
  * **Cannot be graphed directly!** Must be fed into a rate function: `rate(...[5m])`, `increase(...[5m])`, or `sum_over_time(...[5m])`.

---

## 📑 5. Ready-to-Import Production Dashboard Model

Save this minimal JSON template as `namespace-sre-dashboard.json` and import it into any Grafana instance:

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "liveNow": false,
  "panels": [
    {
      "title": "Pod CPU Utilization (Cores)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "datasource": "OpenShift-Thanos",
          "expr": "sum(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate{namespace=~\"$namespace\", pod=~\"$pod\"}) by (pod)",
          "legendFormat": "{{pod}} (Usage)"
        },
        {
          "datasource": "OpenShift-Thanos",
          "expr": "sum(kube_pod_container_resource_limits{namespace=~\"$namespace\", pod=~\"$pod\", resource=\"cpu\"}) by (pod)",
          "legendFormat": "{{pod}} (Limit)"
        }
      ]
    },
    {
      "title": "Container Memory Working Set (RAM)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        {
          "datasource": "OpenShift-Thanos",
          "expr": "sum(container_memory_working_set_bytes{namespace=~\"$namespace\", pod=~\"$pod\", container!=\"\"}) by (pod)",
          "legendFormat": "{{pod}} (RAM Usage)"
        },
        {
          "datasource": "OpenShift-Thanos",
          "expr": "sum(kube_pod_container_resource_limits{namespace=~\"$namespace\", pod=~\"$pod\", resource=\"memory\"}) by (pod)",
          "legendFormat": "{{pod}} (Limit)"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "bytes" }
      }
    },
    {
      "title": "Namespace CPU Quota Consumption (%)",
      "type": "gauge",
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 8 },
      "targets": [
        {
          "datasource": "OpenShift-Thanos",
          "expr": "sum(kube_pod_container_resource_requests{namespace=~\"$namespace\", resource=\"cpu\"}) / sum(kube_resourcequota{namespace=~\"$namespace\", resource=\"cpu\", type=\"hard\"}) * 100",
          "legendFormat": "Quota Used"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 75 },
              { "color": "red", "value": 90 }
            ]
          }
        }
      }
    },
    {
      "title": "Pod Restarts (Past 1 Hour)",
      "type": "stat",
      "gridPos": { "h": 6, "w": 6, "x": 6, "y": 8 },
      "targets": [
        {
          "datasource": "OpenShift-Thanos",
          "expr": "sum(increase(kube_pod_container_status_restarts_total{namespace=~\"$namespace\"}[1h]))",
          "legendFormat": "Restarts"
        }
      ]
    }
  ],
  "templating": {
    "list": [
      {
        "name": "namespace",
        "type": "query",
        "datasource": "OpenShift-Thanos",
        "query": "label_values(kube_namespace_status_phase{phase=\"Active\"}, namespace)",
        "refresh": 1
      },
      {
        "name": "pod",
        "type": "query",
        "datasource": "OpenShift-Thanos",
        "query": "label_values(container_cpu_usage_seconds_total{namespace=~\"$namespace\"}, pod)",
        "refresh": 1
      }
    ]
  },
  "title": "OpenShift SRE Namespace Performance & Quota Cockpit"
}
```
