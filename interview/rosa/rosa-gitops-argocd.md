# Enterprise GitOps Fleet Management with Argo CD & AVP on ROSA

A production platform engineering guide covering multi-cluster fleet management across 6 AWS ROSA HCP clusters using the **Application-of-Apps pattern**, **Argo CD Vault Plugin (AVP)** with AWS Secrets Manager, and declarative environment promotion.

---

## ⚡ The 30-Second Elevator Pitch

> *"Managing a multi-cluster enterprise fleet (e.g. 6 ROSA HCP clusters across non-prod and prod) requires a strict GitOps foundation where Git is the single source of truth. Using **Red Hat OpenShift GitOps (Argo CD)** and the **Application-of-Apps pattern**, a central management hub declaratively orchestrates cluster add-ons, storage drivers, networking policies, and banking microservices across all target spoke clusters. To comply with banking security standards without committing sensitive credentials to Git, we integrate the **Argo CD Vault Plugin (AVP)** with **AWS Secrets Manager**. At sync time, the `argocd-repo-server` pod uses AWS STS IRSA to dynamically fetch and inject secrets into Kubernetes manifests in-memory, ensuring zero plaintext secrets exist in Git repositories while maintaining automated, drift-free fleet synchronization."*

---

## 🏛️ 1. Multi-Cluster Fleet Architecture: Hub & Spoke

```
                                  GIT REPOSITORY (Single Source of Truth)
                                 ┌────────────────────────────────────────┐
                                 │  git@github.com:enterprise/fleet.git   │
                                 │  • /bootstrap (App-of-Apps)            │
                                 │  • /clusters/rosa-dev                  │
                                 │  • /clusters/rosa-stage                │
                                 │  • /clusters/rosa-prod-01              │
                                 └───────────────────┬────────────────────┘
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                 THE GITOPS HUB CLUSTER (Management Plane)                              │
│                                                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │ Argo CD Control Plane (OpenShift GitOps)                                                        │   │
│   │                                                                                                 │   │
│   │ [ Master Application-of-Apps ]                                                                  │   │
│   │   ├── Application: rosa-dev-infra       ──► Syncs to Spoke 1                                    │   │
│   │   ├── Application: rosa-stage-infra     ──► Syncs to Spoke 2                                    │   │
│   │   ├── Application: rosa-prod-01-infra   ──► Syncs to Spoke 3                                    │   │
│   │   └── Application: rosa-prod-02-infra   ──► Syncs to Spoke 4                                    │   │
│   └────────────────────────────────────────────────┬────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────┼────────────────────────────────────────────────────┘
                                                     │
              ┌──────────────────────────────────────┼──────────────────────────────────────┐
              │ Mutual TLS / Kubeconfig              │ Mutual TLS / Kubeconfig              │ Mutual TLS / Kubeconfig
              ▼                                      ▼                                      ▼
┌───────────────────────────┐          ┌───────────────────────────┐          ┌───────────────────────────┐
│   ROSA HCP Cluster: DEV   │          │  ROSA HCP Cluster: STAGE  │          │  ROSA HCP Cluster: PROD   │
│  (Customer AWS VPC 1)     │          │  (Customer AWS VPC 2)     │          │  (Customer AWS VPC 3)     │
│                           │          │                           │          │                           │
│ • Cert-Manager            │          │ • Cert-Manager            │          │ • Cert-Manager            │
│ • Ingress Controllers     │          │ • Ingress Controllers     │          │ • Ingress Controllers     │
│ • Kafka Event Mesh        │          │ • Kafka Event Mesh        │          │ • Kafka Event Mesh        │
│ • Banking Microservices   │          │ • Banking Microservices   │          │ • Banking Microservices   │
└───────────────────────────┘          └───────────────────────────┘          └───────────────────────────┘
```

---

## 📦 2. The Application-of-Apps Pattern

Instead of manually deploying 50 individual Argo CD applications, we deploy **one single Root Application** (The App-of-Apps):

```yaml
# root-application.yaml (The Master Key)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-cluster-fleet
  namespace: openshift-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'https://github.com/enterprise/rosa-gitops-fleet.git'
    targetRevision: HEAD
    path: bootstrap/overlays/production
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true     # Automatically deletes resources removed from Git
      selfHeal: true  # Automatically reverts manual cluster drift
```

Inside that Git directory (`bootstrap/overlays/production`), Git contains a list of sub-Applications:
* `app-ingress-controllers.yaml`
* `app-cert-manager.yaml`
* `app-kafka-eventmesh.yaml`
* `app-banking-ledger.yaml`

Argo CD recursively syncs the entire fleet in dependency order!

---

## 🔒 3. Secret Management with Argo CD Vault Plugin (AVP)

### The Problem:
You need to deploy a database password or API token, but **you can NEVER commit passwords to Git**.

### The Solution:
We store the actual secret in **AWS Secrets Manager**, and commit a **Template** in Git with placeholders.

```
1. Developer commits placeholder in Git:
   password: <path:enterprise/prod/db#password>
                        │
                        ▼
2. Argo CD fetches Git commit
                        │
                        ▼
3. AVP Sidecar Plugin runs inside 'argocd-repo-server':
   • Uses AWS STS IRSA to assume IAM Role
   • Calls AWS Secrets Manager API over private network
   • Fetches: "MySuperSecretBankPassword123!"
   • Replaces placeholder in-memory in RAM
                        │
                        ▼
4. Argo CD pushes raw Kubernetes Secret into target ROSA cluster!
   (Zero plaintext secrets ever entered GitHub!)
```

#### Manifest Example in Git:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: database-credentials
  namespace: banking-core
  annotations:
    avp.kubernetes.io/path: "enterprise/banking/db"
stringData:
  DB_USERNAME: <path:enterprise/banking/db#username>
  DB_PASSWORD: <path:enterprise/banking/db#password>
```

---

## ⚡ 4. 15-Minute Disaster Recovery (The ROSA + GitOps Superpower)

If an entire AWS availability zone burns down or a cluster is compromised:

1. **Step 1 (Infrastructure):** Run Terraform to spin up a fresh ROSA HCP cluster:
   ```bash
   terraform apply -auto-approve
   # Complete in < 12 minutes!
   ```
2. **Step 2 (Bootstrap GitOps):** Apply the single Root Application:
   ```bash
   oc apply -f root-application.yaml
   ```
3. **Step 3 (Automated Hydration):**
   * Argo CD connects to Git.
   * AVP pulls secrets from AWS Secrets Manager.
   * All 50 applications, ingress routes, Kafka brokers, and storage claims are automatically redeployed and restored to healthy state in **3 minutes**!

---

## 🎯 5. Senior Platform Engineer Interview Q&A

### Q1: How do you prevent configuration drift across a fleet of multiple ROSA clusters?
> **Answer:** 
> We enforce declarative GitOps using **Red Hat OpenShift GitOps (Argo CD)** configured with `selfHeal: true` and `prune: true`. If an engineer manually alters a manifest or route via `oc edit`, Argo CD detects the divergence within seconds and automatically overwrites the live state to match Git. All cluster modifications must go through peer-reviewed Pull Requests in Git.

### Q2: How does Argo CD Vault Plugin (AVP) differ from Sealed Secrets or External Secrets Operator (ESO)?
> **Answer:** 
> * **Sealed Secrets / ESO:** Require controller pods running on *every target spoke cluster*, generating native Secrets locally.
> * **AVP (Argo CD Vault Plugin):** Executes **centrally on the GitOps hub** inside the `argocd-repo-server` during manifest generation. It intercepts manifests containing `<path:...>` placeholders, queries the secret store (AWS Secrets Manager or HashiCorp Vault) using temporary IAM credentials, injects the values in-memory, and sends standard Kubernetes Secrets to the target cluster. This reduces target cluster footprint and centralizes secret fetching logic.
