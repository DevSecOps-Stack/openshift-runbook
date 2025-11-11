# Key Differences Summary

## stringData vs data Approach

| Step | stringData (Case 1) ✅ | data (Case 2) ⚠️ |
|------|------------------------|-------------------|
| **AWS Secrets Manager** | **Plain text**<br>`{ "CLOUDABILITY_API_KEY": "abc123xyz", "cloudability_outbound_proxy": "http://proxy:8080" }` | **Base64-encoded (manual)**<br>`{ "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6", "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw" }` |
| **ArgoCD Values** | **Passes plain text**<br>`apiKey: "abc123xyz"`<br>`proxy:`<br>`  outboundProxy: "http://proxy:8080"` | **Passes base64**<br>`apiKey: "YWJjMTIzeHl6"`<br>`proxy:`<br>`  outboundProxy: "aHR0cDovL3Byb3h5Ojo4MDgw"` |
| **Helm Template** | **Uses `stringData:`**<br>`apiVersion: v1`<br>`kind: Secret`<br>`type: Opaque`<br>`stringData:`<br>`  CLOUDABILITY_API_KEY: {{ .Values.apiKey | quote }}`<br>`  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy | quote }}` | **Uses `data:`**<br>`apiVersion: v1`<br>`kind: Secret`<br>`type: Opaque`<br>`data:`<br>`  CLOUDABILITY_API_KEY: {{ .Values.apiKey | quote }}`<br>`  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy | quote }}` |
| **K8s API Processing** | ✅ Auto-converts `stringData` to `data` (base64) | ⚠️ Validates base64 format (errors if invalid) |
| **Stored in etcd** | **Base64-encoded**<br>`data:`<br>`  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"`<br>`  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"` | **Base64-encoded**<br>`data:`<br>`  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"`<br>`  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"` |
| **Pod Environment** | **Plain text (auto-decoded)**<br>`$ echo $CLOUDABILITY_API_KEY → abc123xyz`<br>`$ echo $cloudability_outbound_proxy → http://proxy:8080` | **Plain text (auto-decoded)**<br>`$ echo $CLOUDABILITY_API_KEY → abc123xyz`<br>`$ echo $cloudability_outbound_proxy → http://proxy:8080` |
| **Error Risk** | ✅ **Low** - No manual encoding | ⚠️ **High** - Manual encoding errors |
| **Maintainability** | ✅ **Easy** - Human-readable in AWS | ⚠️ **Hard** - Must decode to read |
| **Production Ready** | ✅ **Recommended** | ⚠️ **Not recommended** |

---

## Recommendation

**Use Case 1: `stringData` with plain text in AWS Secrets Manager**

### Why?
- ✅ Simpler workflow  
- ✅ Less error-prone  
- ✅ Human-readable secrets in AWS Console  
- ✅ Easier to audit and rotate  
- ✅ Same security posture (both stored as base64 in etcd)  
- ✅ Kubernetes handles encoding automatically  

---

### Final Production Template

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
