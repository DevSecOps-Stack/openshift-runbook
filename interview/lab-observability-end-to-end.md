# 🧪 Production Lab: OpenShift Observability, Thanos & Custom Metrics End-to-End

*A practical, hands-on engineering lab to run on your GCP OKD cluster (`okd-sno-s9l6r-master-0`).*

---

## 🎯 Lab Objectives
1. Inspect live production collector daemons: `cAdvisor`, `node-exporter`, and `kube-state-metrics`.
2. Enable **User Workload Monitoring (UWM)** to launch the secondary tenant Prometheus stack.
3. Deploy an enterprise microservice exposing `/metrics` with a dedicated **`ServiceMonitor`**.
4. Query **Thanos Querier** via CLI / `curl` using OpenShift OAuth Bearer Tokens to see platform and custom metrics in a unified response.
5. Trigger a synthetic threshold breach and observe the alert state machine (`Inactive` $\rightarrow$ `Pending` $\rightarrow$ `Firing`).

---

## 🛠️ Step 1: Verify the 3 Platform Collectors Live

Run these commands in your terminal to see where OpenShift harvests infrastructure metrics:

```bash
# 1. Inspect node-exporter (Host Linux OS metrics)
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=node-exporter -o wide

# 2. Inspect kube-state-metrics (Kubernetes Object / etcd state)
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=kube-state-metrics

# 3. Verify cAdvisor port listening on the Kubelet (Requires cluster-admin token)
export NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
oc get --raw /api/v1/nodes/${NODE_NAME}/proxy/metrics/cadvisor | head -n 25
```
*Expected Output:* You will see raw Linux cgroup metrics like `container_cpu_usage_seconds_total` and `container_memory_working_set_bytes` streamed directly from the Kubelet.

---

## ⚙️ Step 2: Enable User Workload Monitoring (UWM)

By default in OpenShift, User Workload Monitoring is disabled to save cluster RAM. Let's enable it cleanly:

```bash
# Apply cluster-monitoring-config ConfigMap
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

### Verify UWM Rollout:
```bash
# Watch the Prometheus Operator deploy the tenant Prometheus stack
oc get pods -n openshift-user-workload-monitoring -w
```
*Expected Output:* Within ~60 seconds, you will see `prometheus-operator-user-workload-*`, `thanos-ruler-user-workload-*`, and `prometheus-user-workload-0` transition to `Running (2/2)`.

---

## 🚀 Step 3: Deploy Sample Microservice & `ServiceMonitor`

Create a dedicated enterprise application namespace `payments-prod`:

```bash
oc new-project payments-prod
```

### Deploy a Sample Microservice exposing `/metrics`:
```bash
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: payments-prod
  labels:
    app: payment-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
      - name: payment-api
        image: quay.io/brancz/prometheus-example-app:v0.5.0
        ports:
        - name: web
          containerPort: 8080
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: payments-prod
  labels:
    app: payment-service
spec:
  ports:
  - name: web
    port: 8080
    targetPort: 8080
  selector:
    app: payment-service
EOF
```

### Bind the `ServiceMonitor` CRD:
```bash
cat <<EOF | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payment-service-monitor
  namespace: payments-prod
  labels:
    team: payments-sre
spec:
  selector:
    matchLabels:
      app: payment-service
  endpoints:
  - port: web
    interval: 15s
    path: /metrics
EOF
```

---

## 🔍 Step 4: Query Thanos Querier via CLI / `curl`

Thanos Querier provides a unified PromQL endpoint for both platform and custom metrics.

```bash
# 1. Extract Thanos Querier host route
export THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
export TOKEN=$(oc whoami -t)

# 2. Query Custom App Metric via Thanos Querier:
curl -k -s -H "Authorization: Bearer ${TOKEN}" \
  "https://${THANOS_HOST}/api/v1/query?query=http_requests_total{namespace='payments-prod'}" | jq .

# 3. Query Platform cAdvisor Metric for the same Pod in the same endpoint:
curl -k -s -H "Authorization: Bearer ${TOKEN}" \
  "https://${THANOS_HOST}/api/v1/query?query=container_cpu_usage_seconds_total{namespace='payments-prod',container='payment-api'}" | jq .
```
*Insight:* Notice how Thanos Querier returned both the application's internal HTTP counter and the Linux kernel's cgroup CPU usage through the exact same PromQL API!

---

## 🚨 Step 5: Test Alert Lifecycle & Alertmanager Dispatch

Apply an alerting rule targeting the payment microservice:

```bash
cat <<EOF | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payment-alerts
  namespace: payments-prod
  labels:
    role: alert-rules
spec:
  groups:
  - name: payment.rules
    rules:
    - alert: PaymentHighTraffic
      expr: sum(rate(http_requests_total{job="payment-service"}[1m])) > 0.05
      for: 1m
      labels:
        severity: warning
        team: payments-sre
      annotations:
        summary: "Payment microservice traffic spiked"
EOF
```

### Watch the Alert State Transition:
```bash
# Check alert state via Thanos Querier API:
curl -k -s -H "Authorization: Bearer ${TOKEN}" \
  "https://${THANOS_HOST}/api/v1/alerts" | jq '.data.alerts[] | select(.labels.alertname=="PaymentHighTraffic")'
```

*Watch the cycle:*
1. State = **`pending`** (Traffic is generating, timer is counting down from 1m).
2. After 1 minute of sustained load: State = **`firing`**!
3. Check Alertmanager active queue:
   ```bash
   oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- amtool alert --alertmanager.url=http://localhost:9093
   ```

---

## 🧹 Cleanup
When finished with the lab:
```bash
oc delete project payments-prod
```
