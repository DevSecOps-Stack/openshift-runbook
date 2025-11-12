Subscription created
    ↓
OLM creates InstallPlan
    ↓
InstallPlan approved (Manual or Auto)
    ↓
OLM executes InstallPlan
    ↓
CSV (ClusterServiceVersion) installation starts
    ├─ Defines the operator version and manifests to deploy
    ├─ Creates or updates the following resources:
    │
    ├─► CRDs (CustomResourceDefinitions)
    │     • Example: lokistacks.loki.grafana.com
    │     • Extends Kubernetes API so you can create LokiStack CRs
    │
    ├─► RBAC objects
    │     • ClusterRoles, ClusterRoleBindings, RoleBindings, ServiceAccounts
    │
    ├─► ConfigMaps
    │     • e.g. loki-operator-manager-config (contains controller runtime config)
    │
    ├─► Deployments
    │     • e.g. loki-operator-controller-manager
    │     • Manages operator pods
    │
    └─► (Optional) Services / Webhooks / PodMonitors (depends on operator design)
    ↓
Deployment creates Operator Pod(s)
    ↓
Pod mounts ConfigMap and starts successfully
    ↓
Operator becomes active
    ↓
Operator watches for CRDs it owns (e.g. LokiStack)
    ↓
User or another component creates a Custom Resource (CR)
    ↓
Operator reconciles the CR → creates real workloads (e.g. Loki pods)

