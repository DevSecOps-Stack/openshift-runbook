# 🎯 OpenShift 4 & Cloud Platform Engineering — Master Interview Guide

A curated, high-yield collection of architectural cheat-sheets, wire-level packet traces, failure recovery runbooks, and senior interview defense manuals.

> ⏱️ **Active Preparation Timetable & Progress Tracker:** [`TIMETABLE.md`](../TIMETABLE.md) — *Track daily progress and resume seamlessly across all 7 core topics.*

---

## 🗺️ Master Curriculum & Learning Path

| Module | Architectural Focus & Deep Dive | Direct Link |
| :--- | :--- | :--- |
| **Module 1: Ingress & Traffic Routing** | OpenShift HAProxy Ingress, Router Pod vs. Operator, UNIX Socket updates (<1ms), Master-Worker Graceful Reloads, Edge / Pass-Through / Re-encrypt TLS termination, Service CA in-pod PKI. | [`haproxy-ingress.md`](haproxy-ingress.md)<br>[`ingress-tls-certificates.md`](ingress-tls-certificates.md) |
| **Module 2: Operators & Custom Resources** | Kubernetes Operator Pattern, CRDs vs. CRs, Reconcile Loops (`Reconcile(Request)`), Controller-Runtime, Status Subresources, Finalizers, and failure modes. | [`operator-crd-cr.md`](operator-crd-cr.md) |
| **Module 3: Enterprise Banking Storage** | Container Storage Interface (CSI), Dell PowerMax (Tier-0 Block/SAN, Fibre Channel, Multipathing `multipathd`, Masking Views) vs. NetApp Trident (Unified NAS/SAN, NFS `ReadWriteMany`, Export Policies), 1-to-1 vs 1-to-Many models, Stale Lock (`VolumeAttachment`) 4-step recovery, 6-broker Kafka production case study. | [`storage-pmax-trident.md`](storage-pmax-trident.md) |
| **Module 4: Resource Governance & Kernel QoS** | Requests (Floor/Scheduler) vs. Limits (Ceiling/cgroups), CPU CFS Throttling (`cpu.cfs_quota_us`) vs. Memory OOMKilled (`Exit Code 137`), QoS Classes (Guaranteed, Burstable, BestEffort), `LimitRange` vs. `ResourceQuota` partnership, side-by-side YAML tables, and "Ghost Pod" troubleshooting. | [`resource-governance-limitranges-qos.md`](resource-governance-limitranges-qos.md) |
| **Module 5: Observability, Prometheus & Alerts** | Cluster Monitoring Operator (CMO) vs. User Workload Monitoring (UWM), Thanos Querier multi-tenant aggregation, `PrometheusRule` CRD lifecycle (Inactive $\rightarrow$ Pending $\rightarrow$ Firing), Alertmanager routing trees, grouping, deduplication & inhibition rules. | [`alerts-prometheus-grafana.md`](alerts-prometheus-grafana.md) |
| **Module 6: ROSA HCP Architecture & GitOps Fleet** | Classic ROSA vs. ROSA HCP (HyperShift), AWS PrivateLink, Konnectivity reverse tunnel, Zero-Trust AWS STS / OIDC Web Identity Federation (IRSA), Multi-Cluster GitOps with Argo CD (Application-of-Apps), and secrets retrieval via AVP + AWS Secrets Manager. | [**`rosa/` Directory Hub**](rosa/README.md)<br>• [`rosa-hcp-architecture.md`](rosa/rosa-hcp-architecture.md)<br>• [`rosa-sts-gitops-secrets.md`](rosa/rosa-sts-gitops-secrets.md)<br>• [`rosa-gitops-argocd.md`](rosa/rosa-gitops-argocd.md) |
| **Module 7: AI Infrastructure & Autoscaling** | vLLM GPU inference serving, Token Economics (`vllm:num_requests_waiting`), KEDA Prometheus ScaledObjects, HPA coordination, and CNCF `llm-d` distributed inference. | [`vllm-keda-autoscaling.md`](vllm-keda-autoscaling.md) |


---

## ⚡ Strict Style Mandate: Ultra-Brief Bullet Notes (The Gold Standard)

Every guide in this directory must be scannable in **under 2 minutes** before an interview. **ZERO text dumps or essay paragraphs.**

### The Mandatory 6-Part Structure:
1. **⚡ 1-Sentence Elevator Soundbite & Analogy:** Physical mental model (e.g. Lifeboat eviction, ATM swipe vs Credit limit).
2. **📑 Complete Master Policy YAML (Single Source of Truth):**
   * Must include ALL required fields (e.g. `min`, `max`, `defaultRequest`, `default`, `maxLimitRequestRatio`, `hard` quotas).
   * Tag every rule inline (e.g. `[RULE 1]`, `[RULE 2]`) so all scenarios trace directly back to code.
3. **📊 Developer Scenario Matrix (Table):**
   * 3–4 real-world developer inputs (e.g. omitted everything, partial requests, below min, burst multiplier).
   * Show what happens mapped directly to the tagged rules and final admitted pod values.
4. **🚪 Admission Gates & Flow:**
   * Clean ASCII step-by-step checks (Gate 1 Single Object $\rightarrow$ Gate 2 Multiplied Sum $\rightarrow$ Gate 3 Node Placement) with pass/fail markers.
5. **🛠️ Top 3 Triage Commands:** Direct shell commands (`oc get rs`, `FailedCreate`, etc.).
6. **⚡ 30-Second Interview Flashcards:** High-probability interview questions with direct 1-sentence answers.
