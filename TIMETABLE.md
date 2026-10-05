# ⏱️ OpenShift & Cloud Platform Mastery — Preparation Timetable & Progress Tracker

*A persistent, daily-resumable study dashboard. Every study session begins here and updates the active bookmark so we pick up seamlessly without friction.*

**Last Updated:** 06-Oct-2026  
**Current Active Bookmark:** 👉 **Topic 3: Observability (Prometheus, Grafana & Alerts)** — *Currently Drilling*  
**Target Completion:** Comprehensive Enterprise Interview Readiness across all 7 core modules.

---

## 📊 Master Syllabus & Progress Board

| # | Domain / Topic | Status | Runbook / Cheat-Sheet | Key Architectural Deliverables | Next Step |
|---|---|---|---|---|---|
| **1** | **Ingress & Traffic Management** | ✅ **COMPLETED** | [`interview/haproxy-ingress.md`](interview/haproxy-ingress.md)<br>[`interview/ingress-tls-certificates.md`](interview/ingress-tls-certificates.md) | • Ingress Operator vs. Router Pod<br>• UNIX Socket dynamic updates (`<10ms`)<br>• Master-Worker `SIGUSR1` reloads<br>• 3 TLS Archetypes: Edge / Pass-Through / Re-encrypt<br>• Router sharding & `L6RSP` backend SSL triage | Mastered & Drilled ✅ |
| **2** | **Storage: Dell PowerMax & NetApp Trident** | ✅ **COMPLETED** | [`interview/storage-pmax-trident.md`](interview/storage-pmax-trident.md) | • PowerMax (Tier-0 Block/FC/RWO) vs. Trident (NFS/RWX)<br>• Linux Host: FC, WWNs, `multipathd` (`round-robin 0`)<br>• NetApp: SVM, FlexVols, Export Policies, FlexClones<br>• 4-Step Stale Lock recovery (`VolumeAttachment`)<br>• 6-broker Kafka production case study | Mastered & Drilled ✅ |
| **3** | **Observability: Prometheus, Grafana & Alerts** | 🟡 **IN PROGRESS** | [`interview/alerts-prometheus-grafana.md`](interview/alerts-prometheus-grafana.md) | • CMO vs User Workload Monitoring (UWM)<br>• `cluster-monitoring-config` & Thanos Querier<br>• `PrometheusRule` CRD & Prometheus Operator<br>• Alert lifecycle: Inactive $\rightarrow$ Pending $\rightarrow$ Firing<br>• Alertmanager routing trees, grouping & inhibition | Interactive Drill & Mastery |
| **4** | **Identity & Governance: LDAP + RBAC** | 📋 **To Draft & Drill** | *Pending Runbook Creation*<br>(Drafting in `interview/ldap-rbac-auth.md`) | • Built-in OAuth server (`oauth-openshift`)<br>• `LDAPIdentityProvider` (`ldaps://:636`, bind DN, filters)<br>• `ldap-group-sync` CronJob & automated user pruning<br>• Roles, ClusterRoles, RoleBindings & SCC mapping | Next on Deck |
| **5** | **Resource Governance: Quotas, Limits & LimitRanges** | ✅ **COMPLETED** | [`interview/resource-governance-limitranges-qos.md`](interview/resource-governance-limitranges-qos.md)<br>[`simulators/K8s_Resource_Governance_Simulator.html`](simulators/K8s_Resource_Governance_Simulator.html) | • The Lifeboat Analogy & `oom_score_adj`<br>• The 10-replica multiplier 4-layer breakdown<br>• Requests (Scheduler floor) vs Limits (Kernel ceiling)<br>• CPU CFS throttling vs Memory OOMKilled<br>• `LimitRange` guardrails vs `ResourceQuota` budget | Mastered & Simulator Built ✅ |
| **6** | **OLM, Operators, CRD & CR** | ✅ **COMPLETED** | [`interview/operator-crd-cr.md`](interview/operator-crd-cr.md)<br>[`automated_olm_process.md`](automated_olm_process.md) | • Operator Pattern: CRD + Controller reconcile loop<br>• Reconcile mechanics (`Reconcile(Request)` idempotent)<br>• Status subresource, generation vs observedGeneration<br>• Finalizers & deadlock recovery | Covered & Mastered ✅ |
| **7** | **GitOps Deep Dive w.r.t ROSA HCP** | ⏳ **Ready for Drill** | [`interview/rosa/README.md`](interview/rosa/README.md)<br>• [`interview/rosa/rosa-hcp-architecture.md`](interview/rosa/rosa-hcp-architecture.md)<br>• [`interview/rosa/rosa-sts-gitops-secrets.md`](interview/rosa/rosa-sts-gitops-secrets.md)<br>• [`interview/rosa/rosa-gitops-argocd.md`](interview/rosa/rosa-gitops-argocd.md) | • Classic ROSA vs ROSA HCP (HyperShift)<br>• Konnectivity reverse proxy tunnel via AWS PrivateLink<br>• Zero-Trust STS / OIDC Web Identity Federation (IRSA)<br>• ArgoCD App-of-Apps + CMP Sidecar (AVP / Secrets Mgr) | Multi-cluster GitOps drill |

---

## 🎯 Daily Study & Progress Log

*Each study day, we log our session here and set the pointer for the next day.*

### 📅 Session 2: 06-Oct-2026 (Tue)
* **Goal:** Master Topic 3 (Observability, Prometheus, Grafana & Alerts) and proceed to Topic 4 (Identity & Governance: LDAP + RBAC).
* **Current Score:** 4 of 7 Modules Mastered (57%). Observability in progress.

### 📅 Session 1: 05-Oct-2026 (Mon)
* **Goal:** Initialize Master Timetable & complete Ingress, Storage, and Resource Governance deep drills.
* **Accomplished:**
  * ✅ **Topic 1 (Ingress):** Mastered dynamic UNIX domain socket update flow (`<10ms`), standby slots, master-worker `haproxy -W` graceful `SIGUSR1` reloads, and Re-encrypt `L6RSP` backend SSL handshake failure root cause analysis.
  * ✅ **Topic 2 (Storage: PowerMax vs Trident):** Clarified block (FC/RWO) vs file (NFS/RWX) kernel cache mechanics, why standard block corrupts on multi-node write, NetApp SVM/FlexVol/Export Policies, and the 4-step stale lock recovery sequence (Cordon $\rightarrow$ Locate $\rightarrow$ Force Clear Pod $\rightarrow$ Delete `VolumeAttachment`).
  * ✅ **Topic 5 (Resource Governance):** Revised and updated runbook with the Lifeboat Analogy, `/proc/<pid>/oom_score_adj`, the 10-replica multiplier 4-layer breakdown, and built the standalone interactive HTML simulator.
  * ✅ **Topic 6 (OLM & Operators):** Confirmed completed & mastered.
* **Score:** 4 of 7 Modules Complete.

---

## 🧭 How to Use This Dashboard

1. **Starting a session:** Open this file or ask *"Where did we leave off on OpenShift?"*
2. **Execution loop:**
   - Review the 30-Second Elevator Pitch.
   - Drill the Wire-Level Mechanics & Architecture.
   - Run rapid-fire interview Q&A (one question at a time).
3. **Closing a session:** Update the `Status` and `Current Active Bookmark` in this timetable so tomorrow's kickoff is instantaneous.
