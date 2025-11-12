# 🧩 Operator Lifecycle Flow (OLM Installation Sequence)

```mermaid
flowchart TD
    A["Subscription Created"] --> B["OLM Creates InstallPlan"]
    B --> C["InstallPlan Approved<br>(Manual or Auto)"]
    C --> D["OLM Executes InstallPlan"]
    D --> E["CSV Installation<br>(ClusterServiceVersion)"]
    E --> F1["Creates CRDs<br>(CustomResourceDefinitions)"]
    E --> F2["Creates RBAC Objects<br>(Roles, RoleBindings, ServiceAccounts)"]
    E --> F3["Creates ConfigMaps<br>(Controller Config)"]
    E --> F4["Creates Deployment<br>(Operator Controller Manager)"]
    E --> F5["(Optional) Services / Webhooks / PodMonitors"]
    F4 --> G["Operator Pod Created"]
    G --> H["Pod Mounts ConfigMap<br>and Starts Successfully"]
    H --> I["Operator Becomes Active"]
    I --> J["Operator Watches for CRDs<br>(e.g. LokiStack)"]
    J --> K["User or ArgoCD Creates<br>Custom Resource (CR)"]
    K --> L["Operator Reconciles CR<br>→ Deploys Workloads"]
