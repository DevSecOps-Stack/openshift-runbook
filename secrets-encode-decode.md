# Key Differences Summary

## stringData vs data Approach

| Step | stringData (Case 1) ✅ | data (Case 2) ⚠️ |
|------|------------------------|-------------------|
| **AWS Secrets Manager** | **Plain text** | **Base64-encoded (manual)** |
| | `{ "CLOUDABILITY_API_KEY": "abc123xyz", "cloudability_outbound_proxy": "http://proxy:8080" }` | `{ "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6", "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw" }` |
| **ArgoCD Values** | **Passes plain text** | **Passes base64** |
| | `apiKey: "abc123xyz"` | `apiKey: "YWJjMTIzeHl6"` |
| | `proxy:` | `proxy:` |
| | `  outboundProxy: "http://proxy:8080"` | `  outboundProxy: "aHR0cDovL3Byb3h5Ojo4MDgw"` |
| **Helm Template** | **Uses stringData field** | **Uses data field** |
| | `apiVersion: v1` | `apiVersion: v1` |
| | `kind: Secret` | `kind: Secret` |
| | `type: Opaque` | `type: Opaque` |
| | `stringData:` | `data:` |
| | `  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}` | `  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}` |
| | `  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}` | `  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}` |
| **K8s API Processing** | ✅ Auto-converts stringData to data (base64) | ⚠️ Validates base64 format (errors if invalid) |
| **Stored in etcd** | **Base64-encoded** | **Base64-encoded** |
| | `data:` | `data:` |
| | `  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"` | `  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"` |
| | `  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"` | `  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"` |
| **Pod Environment** | **Plain text (auto-decoded)** | **Plain text (auto-decoded)** |
| | `$ echo $CLOUDABILITY_API_KEY` | `$ echo $CLOUDABILITY_API_KEY` |
| | `abc123xyz` | `abc123xyz` |
| | `$ echo $cloudability_outbound_proxy` | `$ echo $cloudability_outbound_proxy` |
| | `http://proxy:8080` | `http://proxy:8080` |
| **Error Risk** | ✅ Low (auto-encoding handled by K8s) | ⚠️ High (manual encoding prone to error) |
| **Maintainability** | ✅ Easy, human-readable | ⚠️ Hard, must decode to verify |
| **Production Ready** | ✅ **Recommended** | ⚠️ Not recommended |

---

## Recommendation

**Use Case 1: `stringData` with plain text in AWS Secrets Manager**

### Why?

- ✅ Simpler workflow
- ✅ Less error-prone
- ✅ Human-readable secrets in AWS Console
- ✅ Easier to audit and rotate
- ✅ Same security posture (base64 in etcd)
- ✅ Kubernetes handles encoding automatically

---

## Complete YAML Examples

## Complete YAML Examples

<table>
<tr>
<th>✅ Case 1 — Using <code>stringData</code> (Recommended)</th>
<th>⚠️ Case 2 — Using <code>data</code> (Not Recommended)</th>
</tr>
<tr>
<td valign="top">

**Helm Template:**

```yaml
{{- if .Values.secret.create }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.secretName | quote }}
  labels:
    {{- include "metrics-agent.labels" . | nindent 4 }}
    {{- with .Values.secret.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
type: Opaque
stringData:
  {{- with .Values.apiKey }}
  CLOUDABILITY_API_KEY: {{ . | quote }}
  {{- end }}
  {{- with .Values.proxy.outboundProxy }}
  cloudability_outbound_proxy: {{ . | quote }}
  {{- end }}
{{- end }}
```

**AWS Secrets Manager (Plain Text):**

```json
{
  "CLOUDABILITY_API_KEY": "abc123xyz",
  "cloudability_outbound_proxy": "http://proxy:8080"
}
```

</td>
<td valign="top">

**Helm Template:**

```yaml
{{- if .Values.secret.create }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.secretName | quote }}
  labels:
    {{- include "metrics-agent.labels" . | nindent 4 }}
    {{- with .Values.secret.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
type: Opaque
data:
  {{- with .Values.apiKey }}
  CLOUDABILITY_API_KEY: {{ . | quote }}
  {{- end }}
  {{- with .Values.proxy.outboundProxy }}
  cloudability_outbound_proxy: {{ . | quote }}
  {{- end }}
{{- end }}
```

**AWS Secrets Manager (Base64-Encoded):**

```json
{
  "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6",
  "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw"
}
```

**Manual Encoding Required:**

```bash
echo -n "abc123xyz" | base64
# Output: YWJjMTIzeHl6

echo -n "http://proxy:8080" | base64
# Output: aHR0cDovL3Byb3h5Ojo4MDgw
```

</td>
</tr>
</table>

---

## Flow Comparison

| Case 1 Flow (stringData) ✅ | Case 2 Flow (data) ⚠️ |
|------------------------------|------------------------|
| `AWS Secrets Manager (plain text)` | `AWS Secrets Manager (base64 - manually encoded)` |
| ↓ | ↓ |
| `ArgoCD (plain text)` | `ArgoCD (base64)` |
| ↓ | ↓ |
| `Helm stringData (plain text)` | `Helm data (base64)` |
| ↓ | ↓ |
| `K8s API (auto-encodes to base64)` | `K8s API (validates base64 format)` |
| ↓ | ↓ |
| `etcd storage (base64 encrypted)` | `etcd storage (base64 encrypted)` |
| ↓ | ↓ |
| `Pod reads (auto-decodes to plain text)` | `Pod reads (auto-decodes to plain text)` |

**Key Difference:** Case 1 (stringData) handles encoding automatically at K8s API level, while Case 2 (data) requires manual base64 encoding before storing in AWS Secrets Manager.

---

## ✅ Conclusion

**Use `stringData` for production deployments with ArgoCD and AWS Secrets Manager:**

- Lower operational risk
- Simpler maintenance
- Human-readable secrets in AWS Console
- Same security level as `data` approach
- Eliminates manual encoding errors

Both approaches result in the same encrypted storage in etcd, but `stringData` is the production-grade choice.
