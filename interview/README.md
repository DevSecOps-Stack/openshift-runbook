# 🎯 OpenShift 4 & Cloud Platform Engineering — Master Interview Guide

A curated, high-yield collection of architectural cheat-sheets, wire-level packet traces, failure recovery runbooks, and senior interview defense manuals.

---

## 🗺️ Master Curriculum & Learning Path

| Module | Architectural Focus & Deep Dive | Direct Link |
| :--- | :--- | :--- |
| **Module 1: Ingress & Traffic Routing** | OpenShift HAProxy Ingress, Router Pod vs. Operator, UNIX Socket updates (<1ms), Master-Worker Graceful Reloads, Edge / Pass-Through / Re-encrypt TLS termination, Service CA in-pod PKI. | [`haproxy-ingress.md`](haproxy-ingress.md)<br>[`ingress-tls-certificates.md`](ingress-tls-certificates.md) |
| **Module 2: Operators & Custom Resources** | Kubernetes Operator Pattern, CRDs vs. CRs, Reconcile Loops (`Reconcile(Request)`), Controller-Runtime, Status Subresources, Finalizers, and failure modes. | [`operator-crd-cr.md`](operator-crd-cr.md) |
| **Module 3: Enterprise Banking Storage** | Container Storage Interface (CSI), Dell PowerMax (Tier-0 Block/SAN, Fibre Channel, Multipathing `multipathd`, Masking Views) vs. NetApp Trident (Unified NAS/SAN, NFS `ReadWriteMany`, Export Policies), 1-to-1 vs 1-to-Many models, Stale Lock (`VolumeAttachment`) 4-step recovery, 6-broker Kafka production case study. | [`storage-pmax-trident.md`](storage-pmax-trident.md) |
| **Module 4: Resource Governance & Kernel QoS** | Requests (Floor/Scheduler) vs. Limits (Ceiling/cgroups), CPU CFS Throttling (`cpu.cfs_quota_us`) vs. Memory OOMKilled (`Exit Code 137`), QoS Classes (Guaranteed, Burstable, BestEffort), `LimitRange` vs. `ResourceQuota` partnership, side-by-side YAML tables, and "Ghost Pod" troubleshooting. | [`resource-governance-limitranges-qos.md`](resource-governance-limitranges-qos.md) |
| **Module 5: AI Infrastructure & Autoscaling** | vLLM GPU inference serving, Token Economics (`vllm:num_requests_waiting`), KEDA Prometheus ScaledObjects, HPA coordination, and CNCF `llm-d` distributed inference. | [`vllm-keda-autoscaling.md`](vllm-keda-autoscaling.md) |

---

## ⚡ The 15-Minute Pre-Interview Routine

Each guide in this directory follows a strict, repeatable senior architecture format:
1. **The 30-Second Elevator Pitch:** Memorize the exact opening soundbite to establish immediate authority.
2. **Core Components & Roles:** Crystal-clear separation of responsibilities (Control Plane vs. Data Plane).
3. **Wire-Level Mechanics & Flows:** Explaining what happens at the packet, socket, kernel, and hardware layer.
4. **Production War Stories:** Step-by-step diagnostic and remediation sequences for real P1 incidents.
5. **Rapid Q&A:** High-probability interview questions with direct, definitive answers.
