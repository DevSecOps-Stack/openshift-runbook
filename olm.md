# 🧩 Operator Lifecycle Flow (OLM Installation Sequence)

```mermaid
flowchart TD
    A[Subscription created] --> B[OLM creates InstallPlan]
    B --> C[InstallPlan approved (Manual or Auto)]
    C --> D[OLM executes InstallPlan]
    D --> E[CSV (ClusterServiceVersion) installation starts]
    
    E --> F1[CRDs (CustomResourceDefinitions)\n• Example: lokistacks.loki.grafana.com\n• Extends Kubernetes API]
    E --> F2[RBAC objects\n• ClusterRoles, RoleBindings, ServiceAccounts]
    E --> F3[ConfigMaps\n• e.g. loki-operator-manager-config]
    E --> F4[Deployments\n• e.g. loki-operator-controller-manager]
    E --> F5[(Optional) Services / Webhooks / PodMonitors]
    
    F4 --> G[Deployment creates Operator Pod(s)]
    G --> H[Pod mounts ConfigMap and starts successfully]
    H --> I[Operator becomes active]
    I --> J[Operator watches for CRDs it owns (e.g. LokiStack)]
    J --> K[User or another component creates a Custom Resource (CR)]
    K --> L[Operator reconciles CR → creates real workloads (e.g. Loki pods)]
