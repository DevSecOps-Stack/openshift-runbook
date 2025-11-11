# Key Differences Summary

## stringData vs data Approach

| Step | stringData (Case 1) ✅ | data (Case 2) ⚠️ |
|------|------------------------|-------------------|
| **AWS Secrets Manager** | **Plain text**<br><br>```json<br>{<br>  "CLOUDABILITY_API_KEY": "abc123xyz",<br>  "cloudability_outbound_proxy": "http://proxy:8080"<br>}<br>``` | **Base64-encoded (manual)**<br><br>```json<br>{<br>  "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6",<br>  "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw"<br>}<br>``` |
| **ArgoCD Values** | **Passes plain text**<br><br>```yaml<br>apiKey: "abc123xyz"<br>proxy:<br>  outboundProxy: "http://proxy:8080"<br>``` | **Passes base64**<br><br>```yaml<br>apiKey: "YWJjMTIzeHl6"<br>proxy:<br>  outboundProxy: "aHR0cDovL3Byb3h5Ojo4MDgw"<br>``` |
| **Helm Template** | **Uses `stringData:`**<br><br>```yaml<br>apiVersion: v1<br>kind: Secret<br>type: Opaque<br>stringData:<br>  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}<br>  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}<br>``` | **Uses `data:`**<br><br>```yaml<br>apiVersion: v1<br>kind: Secret<br>type: Opaque<br>data:<br>  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}<br>  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}<br>``` |
| **K8s API Processing** | ✅ Auto-converts `stringData` → `data` (base64) | ⚠️ Validates base64 format (errors if invalid) |
| **Stored in etcd** | **Base64-encoded**<br><br>```yaml<br>data:<br>  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"<br>  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"<br>``` | **Base64-encoded**<br><br>```yaml<br>data:<br>  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"<br>  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"<br>``` |
| **Pod Environment** | **Plain text (auto-decoded)**<br><br>```bash<br>$ echo $CLOUDABILITY_API_KEY<br>abc123xyz<br><br>$ echo $cloudability_outbound_proxy<br>http://proxy:8080<br>``` | **Plain text (auto-decoded)**<br><br>```bash<br>$ echo $CLOUDABILITY_API_KEY<br>abc123xyz<br><br>$ echo $cloudability_outbound_proxy<br>http://proxy:8080<br>``` |
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

## YAML Examples

### ✅ Case 1 — Using `stringData` (Recommended)

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

---

### ⚠️ Case 2 — Using `data` (Not Recommended)

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

**AWS Secrets Manager (Base64-Encoded - Manual):**
```json
{
  "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6",
  "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw"
}
```

**Note:** You must manually encode values before storing in AWS:
```bash
echo -n "abc123xyz" | base64
# Output: YWJjMTIzeHl6
```

---

## Flow Comparison

### Case 1 Flow (stringData)
```
AWS Secrets Manager (plain) 
  → ArgoCD (plain) 
  → Helm stringData (plain) 
  → K8s API (auto-encodes) 
  → etcd (base64) 
  → Pod (auto-decodes to plain)
```

### Case 2 Flow (data)
```
AWS Secrets Manager (base64) 
  → ArgoCD (base64) 
  → Helm data (base64) 
  → K8s API (validates) 
  → etcd (base64) 
  → Pod (auto-decodes to plain)
```

---

## ✅ Conclusion

Use **`stringData`** for production deployments with ArgoCD and AWS Secrets Manager:
- Lower operational risk
- Simpler maintenance
- Human-readable secrets
- Same security level as `data` approach

Both approaches result in the same encrypted storage in etcd, but `stringData` eliminates manual encoding errors.
