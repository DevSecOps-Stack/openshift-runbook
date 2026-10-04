# ⏱️ OpenShift & Cloud Platform Mastery — Preparation Timetable & Progress Tracker

*A persistent, daily-resumable study dashboard. Every study session begins here and updates the active bookmark so we pick up seamlessly without friction.*

**Last Updated:** 05-Oct-2026  
**Current Active Bookmark:** 👉 **Topic 1: Ingress (Interview Drill & Verification)** OR **Topic 2: Storage (PowerMax & Trident)**  
**Target Completion:** Comprehensive Enterprise Interview Readiness across all 7 core modules.

---

## 📊 Master Syllabus & Progress Board

| # | Domain / Topic | Status | Runbook / Cheat-Sheet | Key Architectural Deliverables | Next Step |
|---|---|---|---|---|---|
| **1** | **Ingress & Traffic Management** | 🔄 **In Review** | [`interview/haproxy-ingress.md`](interview/haproxy-ingress.md)<br>[`interview/ingress-tls-certificates.md`](interview/ingress-tls-certificates.md) | • Ingress Operator vs. Router Pod<br>• UNIX Socket dynamic updates (`<10ms`)<br>• Master-Worker `SIGUSR1` reloads<br>• 3 TLS Archetypes: Edge / Pass-Through / Re-encrypt<br>• Router sharding (`routeSelector`, `namespaceSelector`) | Rapid interview drill or mark mastered |
| **2** | **Storage: Dell PowerMax & NetApp Trident** | ⏳ **Ready for Drill** | [`interview/storage-pmax-trident.md`](interview/storage-pmax-trident.md) | • PowerMax (Tier-0 Block/FC/RWO) vs. Trident (NFS/RWX)<br>• Linux Host: FC, WWNs, `multipathd` (`round-robin 0`)<br>• NetApp: SVM, FlexVols, Export Policies, FlexClones<br>• 4-Step Stale Lock recovery (`VolumeAttachment`)<br>• 6-broker Kafka production case study | Interview practice & wire-level review |
| **3** | **Observability: Prometheus, Grafana & Alerts** | 📋 **To Draft & Drill** | *Pending Runbook Creation*<br>(Drafting in `interview/alerts-prometheus-grafana.md`) | • CMO vs User Workload Monitoring (UWM)<br>• `cluster-monitoring-config` & Thanos Querier<br>• `PrometheusRule` CRD & Prometheus Operator<br>• Alert lifecycle: Inactive $\rightarrow$ Pending $\rightarrow$ Firing<br>• Alertmanager routing trees, grouping & inhibition | Draft interview cheat-sheet & drill |
| **4** | **Identity & Governance: LDAP + RBAC** | 📋 **To Draft & Drill** | *Pending Runbook Creation*<br>(Drafting in `interview/ldap-rbac-auth.md`) | • Built-in OAuth server (`oauth-openshift`)<br>• `LDAPIdentityProvider` (`ldaps://:636`, bind DN, filters)<br>• `ldap-group-sync` CronJob & automated user pruning<br>• Roles, ClusterRoles, RoleBindings & SCC mapping | Draft interview cheat-sheet & drill |
| **5** | **Resource Governance: Quotas, Limits & LimitRanges** | ⏳ **Ready for Drill** | [`interview/resource-governance-limitranges-qos.md`](interview/resource-governance-limitranges-qos.md) | • Requests (Scheduler floor) vs Limits (Kernel ceiling)<br>• CPU CFS throttling vs Memory OOMKilled (Exit 137)<br>• 3 QoS Classes (Guaranteed, Burstable, BestEffort)<br>• `LimitRange` pod defaults vs `ResourceQuota` ceilings | Interview practice & CFS deep dive |
| **6** | **OLM, Operators, CRD & CR** | ✅ **COMPLETED** | [`interview/operator-crd-cr.md`](interview/operator-crd-cr.md)<br>[`automated_olm_process.md`](automated_olm_process.md) | • Operator Pattern: CRD + Controller reconcile loop<br>• Reconcile mechanics (`Reconcile(Request)` idempotent)<br>• Status subresource, generation vs observedGeneration<br>• Finalizers & deadlock recovery | Covered & Mastered ✅ |
| **7** | **GitOps Deep Dive w.r.t ROSA HCP** | ⏳ **Ready for Drill** | [`interview/rosa/README.md`](interview/rosa/README.md)<br>• [`interview/rosa/rosa-hcp-architecture.md`](interview/rosa/rosa-hcp-architecture.md)<br>• [`interview/rosa/rosa-sts-gitops-secrets.md`](interview/rosa/rosa-sts-gitops-secrets.md)<br>• [`interview/rosa/rosa-gitops-argocd.md`](interview/rosa/rosa-gitops-argocd.md) | • Classic ROSA vs ROSA HCP (HyperShift)<br>• Konnectivity reverse proxy tunnel via AWS PrivateLink<br>• Zero-Trust STS / OIDC Web Identity Federation (IRSA)<br>• ArgoCD App-of-Apps + CMP Sidecar (AVP / Secrets Mgr) | Multi-cluster GitOps drill |

---

## 🎯 Daily Study & Progress Log

*Each study day, we log our session here and set the pointer for the next day.*

### 📅 Session 1: 05-Oct-2026 (Mon)
* **Goal:** Initialize Master Timetable & determine start line.
* **Covered So Far:**
  * OLM / Operators / CRD / CR is officially **marked Complete** ✅.
  * Ingress, Storage, Resource Governance, and ROSA HCP cheat-sheets already prepared in `openshift-runbook`.
  * Observability (Prometheus/Grafana/Alerts) and LDAP+RBAC scheduled for cheat-sheet creation and drill.
* **Next Session Resume Point:** 👉 **Topic 1 (Ingress)** or **Topic 2 (Storage: PowerMax & Trident)** based on Rakesh's preference.

---

## 🧭 How to Use This Dashboard

1. **Starting a session:** Open this file or ask *"Where did we leave off on OpenShift?"*
2. **Execution loop:**
   - Review the 30-Second Elevator Pitch.
   - Drill the Wire-Level Mechanics & Architecture.
   - Run rapid-fire interview Q&A (one question at a time).
3. **Closing a session:** Update the `Status` and `Current Active Bookmark` in this timetable so tomorrow's kickoff is instantaneous.
