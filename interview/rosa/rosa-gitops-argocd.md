# 🚀 Enterprise GitOps Fleet Management with Argo CD: The Application-of-Apps Pattern

A production platform engineering guide covering multi-cluster fleet management across 6 AWS ROSA HCP clusters using the **Application-of-Apps pattern**, declarative environment promotions, and automated drift reconciliation.

---

## ⚡ The 30-Second Elevator Pitch

> *"Managing a distributed enterprise fleet across 6 ROSA HCP clusters (Dev, Test, Pre-Prod, and multi-region Production) demands a unified control plane where Git is the absolute single source of truth. Rather than configuring hundreds of individual applications manually or through disparate pipelines, we implement the **Argo CD Application-of-Apps pattern** on a dedicated GitOps Management Hub. A single root `Application` CR points to a repository directory containing child `Application` manifests. Each child application targets a specific spoke cluster and workload domain, orchestrating cluster add-ons, ingress routes, Kafka event meshes, and banking microservices. By combining **Sync Waves (`argocd.argoproj.io/sync-wave`)** for deterministic dependency ordering with **automated self-healing (`selfHeal: true`)**, any out-of-band cluster drift is instantly corrected within seconds, and a completely destroyed cluster can be rehydrated from scratch in under 3 minutes."*

---

## 🏛️ 1. Multi-Cluster Fleet Architecture: Hub & Spoke

```text
                                  GIT REPOSITORY (Single Source of Truth)
                                 ┌────────────────────────────────────────┐
                                 │  git@github.com:enterprise/fleet.git   │
                                 │  • /bootstrap (Root App-of-Apps)       │
                                 │  • /clusters/rosa-dev                  │
                                 │  • /clusters/rosa-nonprod              │
                                 │  • /clusters/rosa-prod-syd             │
                                 │  • /clusters/rosa-prod-mel             │
                                 └───────────────────┬────────────────────┘
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                 THE GITOPS HUB CLUSTER (Management Plane)                              │
│                                                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │ Red Hat OpenShift GitOps Control Plane (Argo CD)                                                │   │
│   │                                                                                                 │   │
│   │ [ Master Root Application: "root-cluster-fleet" ]                                              │   │
│   │   ├── Child Application: rosa-dev-workloads       ──► Syncs to Spoke Cluster 1 (Dev)            │   │
│   │   ├── Child Application: rosa-nonprod-workloads   ──► Syncs to Spoke Cluster 2 (Non-Prod)       │   │
│   │   ├── Child Application: rosa-prod-syd-workloads  ──► Syncs to Spoke Cluster 3 (Prod Sydney)    │   │
│   │   └── Child Application: rosa-prod-mel-workloads  ──► Syncs to Spoke Cluster 4 (Prod Melbourne) │   │
│   └────────────────────────────────────────────────┬────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────┼────────────────────────────────────────────────────┘
                                                     │
               ┌─────────────────────────────────────┼─────────────────────────────────────┐
               │ Mutual TLS / Secret Credentials     │ Mutual TLS / Secret Credentials     │ Mutual TLS / Secret Credentials
               ▼                                     ▼                                     ▼
┌───────────────────────────┐         ┌───────────────────────────┐         ┌───────────────────────────┐
│   ROSA HCP: DEV SPOKE     │         │ ROSA HCP: NON-PROD SPOKE  │         │   ROSA HCP: PROD SPOKE    │
│  (Customer AWS VPC 1)     │         │  (Customer AWS VPC 2)     │         │  (Customer AWS VPC 3)     │
│                           │         │                           │         │                           │
│ • Namespaces & RBAC       │         │ • Namespaces & RBAC       │         │ • Namespaces & RBAC       │
│ • Cert-Manager & Operators│         │ • Cert-Manager & Operators│         │ • Cert-Manager & Operators│
│ • Ingress Controllers     │         │ • Ingress Controllers     │         │ • Ingress Controllers     │
│ • Kafka Event Mesh        │         │ • Kafka Event Mesh        │         │ • Kafka Event Mesh        │
│ • Banking Core APIs       │         │ • Banking Core APIs       │         │ • Banking Core APIs       │
└───────────────────────────┘         └───────────────────────────┘         └───────────────────────────┘
```

---

## 📂 2. Production Git Repository Layout

To make Application-of-Apps scalable across environments without duplicate code, we structure the repository into **bootstrap**, **clusters**, and reusable **workload components**:

```text
fleet-gitops-repo/
├── bootstrap/
│   ├── root-app.yaml                     # The single entrypoint applied to Hub
│   └── fleet-apps/                       # Child Application CRs tracked by root-app
│       ├── app-rosa-dev.yaml
│       ├── app-rosa-nonprod.yaml
│       ├── app-rosa-prod-syd.yaml
│       └── app-rosa-prod-mel.yaml
│
├── clusters/                             # Target cluster specific manifests
│   ├── rosa-dev/
│   │   ├── kustomization.yaml
│   │   ├── cluster-addons.yaml           # Ingress, cert-manager, logging
│   │   └── banking-workloads.yaml
│   ├── rosa-nonprod/
│   └── rosa-prod-syd/
│
└── workloads/                            # Base microservices and Helm charts
    ├── banking-ledger/
    │   ├── base/
    │   └── overlays/
    └── payment-gateway/
```

---

## 📦 3. Manifest Deep-Dive: Root vs. Child Applications

### Step 1: The Master Root Application (`root-app.yaml`)
Applied **only once** to the central GitOps hub cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-cluster-fleet
  namespace: openshift-gitops
  finalizers:
    # ◄── Cascading delete: removing an app from Git deletes it from cluster
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'https://github.com/enterprise/rosa-gitops-fleet.git'
    targetRevision: HEAD
    path: bootstrap/fleet-apps            # Watches folder containing Child Apps
  destination:
    server: 'https://kubernetes.default.svc' # Deploys Child Apps locally on Hub
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true                         # Prune child apps removed from Git
      selfHeal: true                      # Auto-revert manual edits
    syncOptions:
      - CreateNamespace=true
```

---

### Step 2: The Child Application (`app-rosa-prod-syd.yaml`)
Stored inside `bootstrap/fleet-apps/` in Git:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rosa-prod-syd-workloads
  namespace: openshift-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'https://github.com/enterprise/rosa-gitops-fleet.git'
    targetRevision: HEAD
    path: clusters/rosa-prod-syd
  destination:
    # ◄── POINTS DIRECTLY TO REMOTE SPOKE CLUSTER IN AWS:
    name: rosa-prod-sydney-cluster
    namespace: banking-production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true           # Performance: only apply changed resources
```

---

## 🌊 4. Sync Waves & Sync Phases: Deterministic Startup

When deploying complex banking stacks (CRDs $\rightarrow$ Operators $\rightarrow$ Storage $\rightarrow$ Apps), deploying everything simultaneously causes race conditions and pod crash loops.

We enforce strict deployment ordering using **Argo CD Sync Waves** via the `argocd.argoproj.io/sync-wave` annotation:

| Wave Number | Resource Type | Purpose & Guarantee |
| :---: | :--- | :--- |
| **Wave `-5`** | `Namespace`, `CustomResourceDefinition` (CRD) | Cluster primitives established before resources exist. |
| **Wave `-3`** | `OperatorGroup`, `Subscription`, `ServiceAccount` | Operators (Cert-Manager, Strimzi Kafka) install and initialize. |
| **Wave `-1`** | `Secret` (AVP Templates), `ConfigMap`, RBAC | Credentials and configurations hydrated before pods request them. |
| **Wave `0`** | `PersistentVolumeClaim`, Database StatefulSets | Persistent storage binds and schemas mount. |
| **Wave `5`** | `Deployment`, `Service`, OpenShift `Route` | Application pods start, pass readiness probes, and bind to ingress. |

```yaml
# Example: Operator Subscription deploying in Wave -3
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cert-manager-operator
  namespace: openshift-operators
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cert-manager
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

---

## 🔄 5. Multi-Environment Promotion Strategy

In enterprise banking, code and configuration are promoted across environments declaratively via Git:

```text
 ┌──────────────────────┐         ┌──────────────────────┐         ┌──────────────────────┐
 │      DEV CLUSTER     │         │   NON-PROD CLUSTER   │         │     PROD CLUSTER     │
 │                      │         │                      │         │                      │
 │ Image: v2.4.1-rc1    │ ──────► │ Image: v2.4.1-rc1    │ ──────► │ Image: v2.4.1 (Tag)  │
 │ Auto-Sync: ENABLED   │   PR    │ Auto-Sync: ENABLED   │   PR    │ Auto-Sync: MANUAL or │
 │ Replicas: 2          │ Merged  │ Replicas: 4          │ Approved│            MAINT-WINDOW│
 └──────────────────────┘         └──────────────────────┘         └──────────────────────┘
```

1. **Development (`rosa-dev`):**
   * Automatically tracks `HEAD` of the development branch or image tag `latest-dev`.
   * Continuous deployment with auto-sync and self-healing.
2. **Non-Production (`rosa-nonprod`):**
   * Promoted via Git Pull Request updating the target revision / image tag to a release candidate (e.g. `v2.4.1-rc1`).
   * Runs automated integration, regression, and performance tests.
3. **Production (`rosa-prod-syd` / `rosa-prod-mel`):**
   * Promoted via strict, peer-reviewed Pull Request approved by platform leads.
   * `syncPolicy.automated` can be configured with manual approval gates or restricted maintenance windows.

---

## ⚡ 6. 15-Minute Disaster Recovery (The Fleet GitOps Superpower)

If an entire AWS availability zone fails or a ROSA cluster is destroyed:

1. **Phase 1: Cluster Provisioning (< 12 minutes)**
   * Terraform re-creates the ROSA HCP cluster and worker node pool in customer AWS VPC:
     ```bash
     terraform apply -auto-approve
     ```
2. **Phase 2: Hub Registration (< 30 seconds)**
   * Register the new spoke cluster to the central Argo CD Hub:
     ```bash
     argocd cluster add <new-cluster-context> --name rosa-prod-sydney-cluster
     ```
3. **Phase 3: Fleet Hydration (< 2.5 minutes)**
   * Apply the single Root Application manifest:
     ```bash
     oc apply -f bootstrap/root-app.yaml
     ```
   * Argo CD syncs the Application-of-Apps tree.
   * Sync waves ensure namespaces, operators, and storage mount first.
   * Argo CD Vault Plugin (AVP) dynamically fetches secrets from AWS Secrets Manager.
   * Entire enterprise fleet restored to clean running state in under **15 minutes total**.

---

## 🎯 7. Senior Platform Engineer Rapid Q&A

### Q1: What is the primary operational advantage of the Application-of-Apps pattern over individual application management?
> **Answer:**
> It solves **orchestration scalability**. Instead of managing lifecycle, sync policies, and status for 50+ disparate applications individually, platform teams manage a single root application. Adding a new service or target cluster requires only committing a single child `Application` YAML to Git. Argo CD automatically discovers, provisions, and manages it without requiring administrative access to the Argo CD UI or cluster API.

### Q2: Why is the `resources-finalizer.argocd.argoproj.io` finalizer essential on Application CRs?
> **Answer:**
> By default, if an `Application` CR is deleted, Argo CD simply deletes the application metadata but leaves all deployed child resources (Deployments, Services, Routes) running in the cluster as orphans. Adding `resources-finalizer.argocd.argoproj.io` guarantees **cascading deletion**: removing an application manifest from Git causes Argo CD to gracefully delete all live Kubernetes resources associated with it.

### Q3: How do Sync Waves differ from Kubernetes dependency managers?
> **Answer:**
> Sync Waves are native to Argo CD (`argocd.argoproj.io/sync-wave`). Argo CD sorts all manifests in an application by their wave integer (e.g., `-5` to `+5`). It applies wave `n`, waits until all resources in wave `n` report a **`Healthy`** status (e.g., pods pass readiness checks, CRDs register), and only then begins deploying wave `n+1`. This eliminates race conditions during cold cluster bootstraps.
