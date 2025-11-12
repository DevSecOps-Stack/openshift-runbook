%%{init: {"theme":"default","flowchart":{"curve":"basis"}} }%%
flowchart TD
    classDef node fill:#eef7ff,stroke:#0077cc,stroke-width:1px,color:#000,font-weight:bold
    classDef step fill:#e6f4ea,stroke:#008000,stroke-width:1px,color:#000,font-weight:normal
    classDef sub fill:#fff9e6,stroke:#b38f00,stroke-width:1px,color:#000,font-weight:normal

    A["Subscription Created"]:::node --> B["OLM Creates InstallPlan"]:::node
    B --> C["InstallPlan Approved<br>(Manual or Automatic)"]:::node
    C --> D["OLM Executes InstallPlan"]:::node
    D --> E["CSV Installation<br>(ClusterServiceVersion)"]:::node
    
    E --> F1["Creates CRDs<br>(CustomResourceDefinitions)"]:::sub
    E --> F2["Creates RBAC Objects<br>(Roles, RoleBindings, ServiceAccounts)"]:::sub
    E --> F3["Creates ConfigMaps<br>(Controller Config)"]:::sub
    E --> F4["Creates Deployment<br>(Operator Controller Manager)"]:::sub
    E --> F5["(Optional) Services / Webhooks / PodMonitors"]:::sub
    
    F4 --> G["Operator Pod Created"]:::step
    G --> H["Pod Mounts ConfigMap<br>and Starts Successfully"]:::step
    H --> I["Operator Becomes Active"]:::step
    I --> J["Operator Watches<br>Owned CRDs (e.g. LokiStack)"]:::step
    J --> K["User or ArgoCD Creates<br>Custom Resource (CR)"]:::step
    K --> L["Operator Reconciles CR<br>→ Deploys Workloads"]:::node
