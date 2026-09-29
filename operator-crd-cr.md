# Kubernetes Operators, CRDs, and Custom Resources (CR) — Interview Cheat Sheet

A concise, high-yield reference guide for explaining the Kubernetes Operator Pattern, CustomResourceDefinitions (CRDs), and Custom Resources (CRs) in enterprise platform engineering interviews.

---

## ⚡ The 30-Second Elevator Pitch

> *"In Kubernetes, a **CRD** extends the API server by registering a new custom noun and enforcing its OpenAPI schema. A **CR** is the specific YAML instance where a developer declares their desired state. An **Operator** is a custom controller running an active reconciliation loop in Go or Python that observes the CR, compares desired vs actual state, and automates human domain knowledge to manage underlying pods, services, or cloud infrastructure."*

---

## 🏗️ The Architectural Trinity: Blueprint vs Data vs Brain

| Component | What It Is | Real-World Analogy | Code / DB Analogy | Scope |
| :--- | :--- | :--- | :--- | :--- |
| **CRD** *(CustomResourceDefinition)* | The **Schema & Registration** | Blank application form | `class` definition / `CREATE TABLE` | **Always Cluster-Scoped** |
| **CR** *(Custom Resource)* | The **Instance / User Input** | Filled-out application form | Object instance / `INSERT INTO` row | **Namespaced** *(90%)* or **Cluster** |
| **Operator** *(Controller)* | The **Active Worker / Logic** | Processing officer | Running reconciliation loop / event handler | Pod runs in a namespace; watches based on RBAC |

---

## 🔄 The Operator Reconciliation Loop

An Operator is not passive. It continuously executes the reconciliation loop:

$$\mathbf{Observe} \longrightarrow \mathbf{Diff} \text{ (Desired vs Actual)} \longrightarrow \mathbf{Act} \longrightarrow \mathbf{Repeat}$$

1. **Observe:** Subscribes to Kubernetes API watch events (Informers/Reflectors) for its target CRs.
2. **Diff:** Compares what the user requested in `cr.spec` with what is actually running in the cluster.
3. **Act:** Creates, updates, patches, or deletes downstream Kubernetes resources (Deployments, HPAs, Routes, Secrets).
4. **Self-Healing:** If someone accidentally modifies or deletes the downstream resource, the operator immediately detects the drift and recreates it.

---

## 🔍 The 4 Key Jobs of a CRD

1. **API Server Registration:** Teaches `kube-apiserver` the new REST endpoint (`/apis/<group>/<version>/namespaces/{ns}/<plural>`). Without the CRD, applying a CR returns `no matches for kind`.
2. **Schema & Data Validation:** Enforces OpenAPI v3 validation rules (required fields, string/integer types, regex patterns, enum values). Malformed YAML is rejected at the API server before hitting `etcd`.
3. **CLI & Tooling Integration:** Defines `shortNames` (e.g. `oc get ws` instead of `websites`), terminal display columns (`additionalPrinterColumns`), and CLI help (`oc explain <kind>.spec`).
4. **Dynamic UI Rendering:** Allows the OpenShift Web Console to automatically render interactive forms and status badges without custom frontend code.

---

## 🌐 Scope: Namespaced vs Cluster-Scoped

### CRD Scope (`spec.scope` inside the CRD)
* **`Namespaced` (Standard):** The resource belongs to a specific project. Multiple teams can use the same resource name in different namespaces (e.g. `ScaledObject`, `ServiceMonitor`, `Route`).
* **`Cluster` (Global):** The resource has no namespace. Visible cluster-wide, typically reserved for platform admins (e.g. `ClusterTriggerAuthentication`, `ClusterIssuer`, `MachineSet`).

### Operator Scope (Controlled by RBAC)
* **Cluster-Wide Operator:** Sits in one namespace (e.g. `openshift-operators` or `keda`), bound via a `ClusterRoleBinding`. Watches and manages CRs across **all namespaces**.
* **Namespaced Operator:** Sits in a namespace, bound via a standard `RoleBinding`. Strictly locked to managing CRs within its **own namespace** (isolated multi-tenancy).

---

## 🏢 Real-World Production Examples

| System | The CRD (The Blueprint) | The CR (What Developer Writes) | The Operator (The Pod) | Downstream Resource Created |
| :--- | :--- | :--- | :--- | :--- |
| **Ingress** | `ingresscontrollers.operator.openshift.io` | `IngressController/default` in `openshift-ingress-operator` | Pod in `openshift-ingress-operator` | HAProxy router pods, Services, and Cloud LBs in `openshift-ingress` |
| **KEDA** | `scaledobjects.keda.sh` | `ScaledObject/vllm-scaler` in `ai-platform` | Pod in `keda` | Kubernetes `HorizontalPodAutoscaler` (HPA) in `ai-platform` |
| **Prometheus** | `servicemonitors.monitoring.coreos.com` | `ServiceMonitor/vllm-mock` in `ai-platform` | Prometheus Operator in `openshift-monitoring` | Dynamically updates Prometheus scrape configurations |
| **Cert-Manager** | `certificates.cert-manager.io` | `Certificate/wildcard-tls` in `app-ns` | Cert-Manager controller in `cert-manager` | Kubernetes TLS `Secret` containing cert and private key |

---

## 🎯 High-Yield Interview Q&A

### Q1: What happens if you apply a Custom Resource (CR) without having the Operator running?
> **Answer:** If the CRD exists, the API server accepts the YAML and stores it cleanly into `etcd`. However, **nothing happens**. The CR remains dead data until an Operator starts up, lists the existing CRs, and begins the reconciliation loop.

### Q2: What happens if you apply a CR without the CRD installed?
> **Answer:** The Kubernetes API server rejects the request immediately with an HTTP 404 / `error: unable to recognize: no matches for kind "<Kind>" in version "<Group/Version>"`.

### Q3: Why does KEDA create an HPA instead of scaling the deployment directly?
> **Answer:** KEDA respects Kubernetes separation of concerns. Kubernetes already has a battle-tested pod scaling engine (`HorizontalPodAutoscaler` in `kube-controller-manager`) with rate limiting and scaling algorithms. KEDA acts as an **External Metrics Adapter**, translating external event sources (Prometheus, Kafka, AWS SQS) into metrics that native HPA can consume.

### Q4: How does an Operator maintain high availability without running duplicate actions?
> **Answer:** Multi-replica operators use **Kubernetes Leader Election** (via a `Lease` or `ConfigMap` lock in the API server). All replicas run, but only the active leader executes the reconciliation loop. If the leader pod crashes, standby replicas immediately acquire the lease and take over reconciliation with zero state loss.
