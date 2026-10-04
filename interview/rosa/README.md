# ☁️ Red Hat OpenShift on AWS (ROSA) HCP & GitOps Architecture Hub

A comprehensive platform engineering study guide, wire-level architectural manual, and senior interview defense playbook covering **ROSA Hosted Control Planes (HCP)**, **AWS PrivateLink & Konnectivity Networking**, **Zero-Trust AWS STS / OIDC Security (IRSA)**, and **Multi-Cluster GitOps with Argo CD & Argo CD Vault Plugin (AVP)**.

---

## 🗺️ Master Curriculum Overview

| Guide | Core Architecture & Topics Covered | Direct Link |
| :--- | :--- | :--- |
| **1. ROSA HCP Architecture & Networking** | Classic ROSA vs. ROSA HCP (HyperShift), Customer VPC vs. Red Hat Management VPC, AWS PrivateLink plumbing, The Konnectivity Reverse Proxy Tunnel, provisioning velocity (45m $\rightarrow$ 12m), and AWS EC2 cost elimination. | [`rosa-hcp-architecture.md`](rosa-hcp-architecture.md) |
| **2. Zero-Trust Security: AWS STS & OIDC Secrets** | Keyless IAM authentication, Why static AWS Secret Keys are forbidden in banking, OIDC Web Identity Federation, IAM Roles for Service Accounts (IRSA), JWT token lifecycle, AWS Secrets Manager in-memory fetch via AVP, and the infamous `no EC2 IMDS role found` production war room fix. | [`rosa-sts-gitops-secrets.md`](rosa-sts-gitops-secrets.md) |
| **3. Enterprise GitOps Fleet & App-of-Apps** | Managing a 6-cluster ROSA HCP fleet, The Application-of-Apps pattern, Argo CD Sync Waves (`argocd.argoproj.io/sync-wave`), declarative multi-environment promotions (Dev $\rightarrow$ Non-Prod $\rightarrow$ Prod), and 15-minute disaster recovery. | [`rosa-gitops-argocd.md`](rosa-gitops-argocd.md) |

---

## ⚡ The 30-Second Elevator Pitch for ROSA HCP

> *"ROSA with Hosted Control Planes (HCP) revolutionizes enterprise cloud economics and security by decoupling the OpenShift control plane from customer infrastructure. Leveraging **HyperShift and KubeVirt**, Red Hat hosts the control plane components (`etcd`, `kube-apiserver`, `kube-controller-manager`) as isolated container pods inside Red Hat-owned AWS accounts, **eliminating customer EC2 compute costs for dedicated master and infra nodes**. Worker nodes reside inside the customer's private AWS VPC, establishing secure, high-throughput communication with the hosted API server via an encrypted **AWS PrivateLink** connection running the **Konnectivity reverse-tunnel protocol**. For enterprise security, ROSA completely eliminates static AWS access keys, utilizing **AWS STS and OIDC Web Identity Federation (IRSA)** so container workloads dynamically assume least-privilege IAM roles via cryptographic JSON Web Tokens (JWT)."*
