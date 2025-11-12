
✅ When you push this to GitHub, it’ll render as a clean **visual flow diagram** with boxes and arrows — exactly like your text flow but fully formatted.

---

## 🧩 **Option 2 — Use Bullet Lists with Emoji Arrows (Good for Markdown-only Docs)**

If you want it to stay pure Markdown (no Mermaid rendering), you can use emoji arrows and indentation — this renders correctly across all Markdown viewers:

```markdown
# 🧩 Operator Lifecycle Flow (OLM Installation Sequence)

- **Subscription created**
  ⬇️
- **OLM creates InstallPlan**
  ⬇️
- **InstallPlan approved (Manual or Auto)**
  ⬇️
- **OLM executes InstallPlan**
  ⬇️
- **CSV (ClusterServiceVersion) installation starts**
  - Defines the operator version and manifests to deploy
  - Creates or updates the following resources:
    - **CRDs (CustomResourceDefinitions)**
      - Example: `lokistacks.loki.grafana.com`
      - Extends Kubernetes API so you can create LokiStack CRs
    - **RBAC objects**
      - ClusterRoles, ClusterRoleBindings, RoleBindings, ServiceAccounts
    - **ConfigMaps**
      - e.g. `loki-operator-manager-config` (controller runtime config)
    - **Deployments**
      - e.g. `loki-operator-controller-manager`
      - Manages operator pods
    - *(Optional)* Services, Webhooks, PodMonitors (depends on design)
  ⬇️
- **Deployment creates Operator Pod(s)**
  ⬇️
- **Pod mounts ConfigMap and starts successfully**
  ⬇️
- **Operator becomes active**
  ⬇️
- **Operator watches for CRDs it owns (e.g. LokiStack)**
  ⬇️
- **User or another component creates a Custom Resource (CR)**
  ⬇️
- **Operator reconciles the CR → creates real workloads (e.g. Loki pods)**
