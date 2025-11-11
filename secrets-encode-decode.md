# Key Differences: `stringData` vs `data` in Kubernetes Secrets

This document summarizes the practical and technical differences between using the `stringData` and `data` fields in Kubernetes Secrets — especially when secrets are managed via **AWS Secrets Manager**, **ArgoCD**, and **Helm** pipelines.

---

## 🧩 Comparison Summary

| Step | **stringData (Case 1)** ✅ | **data (Case 2)** ⚠️ |
|------|-----------------------------|------------------------|
| **AWS Secrets Manager** | **Plain text** | **Base64-encoded (manual)** |
| | ```json<br>{<br>  "CLOUDABILITY_API_KEY": "abc123xyz",<br>  "cloudability_outbound_proxy": "http://proxy:8080"<br>}``` | ```json<br>{<br>  "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6",<br>  "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw"<br>}``` |
| **ArgoCD Values** | **Passes plain text** | **Passes base64** |
| | ```yaml<br>apiKey: "abc123xyz"<br>proxy:<br>  outboundProxy: "http://proxy:8080"``` | ```yaml<br>apiKey: "YWJjMTIzeHl6"<br>proxy:<br>  outboundProxy: "aHR0cDovL3Byb3h5Ojo4MDgw"``` |
| **Helm Template** | **Uses `stringData:`** | **Uses `data:`** |
| | ```yaml<br>apiVersion: v1<br>kind: Secret<br>type: Opaque<br>stringData:<br>  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}<br>  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}``` | ```yaml<br>apiVersion: v1<br>kind: Secret<br>type: Opaque<br>data:<br>  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}<br>  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}``` |
| **K8s API Processing** | ✅ Auto-converts `stringData` → `data` (base64) | ⚠️ Validates base64 input (fails if invalid) |
| **Stored in etcd** | Base64-encoded | Base64-encoded |
| | ```yaml<br>data:<br>  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"<br>  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"``` | ```yaml<br>data:<br>  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"<br>  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"``` |
| **Pod Environment** | Plain text (auto-decoded) | Plain text (auto-decoded) |
| | ```bash<br>$ echo $CLOUDABILITY_API_KEY<br>abc123xyz<br><br>$ echo $cloudability_outbound_proxy<br>http://proxy:8080``` | ```bash<br>$ echo $CLOUDABILITY_API_KEY<br>abc123xyz<br><br>$ echo $cloudability_outbound_proxy<br>http://proxy:8080``` |
| **Error Risk** | ✅ Low (auto-handled encoding) | ⚠️ High (manual base64 encoding) |
| **Maintainability** | ✅ Human-readable | ⚠️ Harder to debug and audit |
| **Production Ready** | ✅ Recommended | ⚠️ Not recommended |

---

## ✅ Recommended Approach

**Use Case 1: `stringData` with plain text in AWS Secrets Manager**

### Why It’s Better
- ✅ Simpler and less error-prone
- ✅ Human-readable in AWS Console
- ✅ Easier to audit and rotate
- ✅ Kubernetes handles encoding automatically
- ✅ Same security posture (both end up base64-encoded in etcd)

---

## 🧠 How Kubernetes Handles It Internally

1. When a Secret uses `stringData`, Kubernetes API server:
   - Accepts plain text.
   - Base64-encodes the values automatically.
   - Stores only the encoded form in `.data` (in etcd).

2. When a Pod reads the secret:
   - The Kubelet automatically **decodes** it back to plain text.
   - The application sees only the clear text value.

So, both `stringData` and `data` **store secrets securely**, but `stringData` simplifies your workflow.

---

## 🧩 Mixed Use Example

If you must mix both approaches (e.g., static + dynamic values):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mixed-secret
type: Opaque
data:
  preEncodedValue: YWJjMTIzeHl6
stringData:
  runtimeValue: {{ .Values.dynamicSecret | quote }}
