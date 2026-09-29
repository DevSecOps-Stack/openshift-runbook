# OpenShift 4 & Cloud-Native Systems Engineering Runbook

A production-grade, battle-tested runbook repository housing deep architectural guides, rapid interview cheat-sheets, wire-level packet traces, and purely declarative hands-on lab suites for OpenShift 4, Kubernetes Operators, and AI Infrastructure.

---

## 🗺️ Master Runbook Index

### 🌐 1. Ingress & HAProxy Traffic Architecture
* **[HAProxy Ingress Architecture & Master Lab Guide](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/README.md)**
  * Control Plane (`openshift-ingress-operator`) vs. Data Plane (`openshift-ingress`)
  * The 3 Resident Processes (In-pod Go Controller, HAProxy Master PID 1, HAProxy Worker)
  * Zero-Reload Dynamic Scaling (< 1ms via UNIX socket)
  * Master-Worker Graceful Reloads (`SIGUSR1`)
  * Ingress Port Binding, SNO Port Collisions & Port Remapping (`8080`/`8443`)
  * Post-Deployment Experiments, Route Annotations & Live Socket Drills
  * **Hands-on Labs:**
    * [HAProxy Edge Termination Lab](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/README.md)
    * [HAProxy Pass-Through Termination Lab](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/README.md)
    * [HAProxy Re-encrypt Termination Lab](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/README.md)

---

### ⚙️ 2. Core Architecture & High-Yield Interview Cheat-Sheets
* **[Operator, CRD & CR Architecture Guide](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/operator-crd-cr.md)**: Reconcile loops, OpenAPI schemas, CR validation, status subresources, and failure modes.
* **[vLLM & KEDA AI Autoscaling Runbook](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/vllm-keda-autoscaling.md)**: GPU token metrics, `vllm:num_requests_waiting`, scaled objects, and HPA interaction.
* **[HAProxy Ingress Quick Cheat-Sheet](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy-ingress.md)**: High-yield 15-minute pre-interview review soundbites.

---

### 🛠️ 3. Operations & Tooling Modules
* **[ACM (Advanced Cluster Management)](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/acm.md)**
* **[Cert-Manager PKI Automation](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/certmanager.md)**
* **[LokiStack Observability](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/lokistack.md)**
* **[Dynatrace Monitoring Integration](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/dynatrace.md)**
* **[AVP (Argocd Vault Plugin)](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/avp.md)**
* **[Automated OLM & Operator Lifecycle Flows](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/automated_olm_process.md)**

---

## 🔒 Enterprise & Privacy Standards
* All manifests and certificate subjects use neutral, fictitious enterprise identities (`BrainyBots Enterprise`, `CloudOps Systems`, `Global Core Corp`).
* All labs are 100% declarative (`oc apply -f <manifest.yaml>`) with zero imperative state leaks.
