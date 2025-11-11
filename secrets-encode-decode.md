# Key Differences Summary

## stringData vs data Approach

| Step | stringData (Case 1) ✅ | data (Case 2) ⚠️ |
|------|------------------------|-------------------|
| **AWS Secrets Manager** | **Plain text** | **Base64-encoded (manual)** |
| | ```json<br/>{<br/>  "CLOUDABILITY_API_KEY": "abc123xyz",<br/>  "cloudability_outbound_proxy": "http://proxy:8080"<br/>}<br/>``` | ```json<br/>{<br/>  "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6",<br/>  "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw"<br/>}<br/>``` |
| **ArgoCD Values** | **Passes plain text** | **Passes base64** |
| | ```yaml<br/>apiKey: "abc123xyz"<br/>proxy:<br/>  outboundProxy: "http://proxy:8080"<br/>``` | ```yaml<br/>apiKey: "YWJjMTIzeHl6"<br/>proxy:<br/>  outboundProxy: "aHR0cDovL3Byb3h5Ojo4MDgw"<br/>``` |
| **Helm Template** | **`stringData:` field** | **`data:` field** |
| | ```yaml<br/>apiVersion: v1<br/>kind: Secret<br/>type: Opaque<br/>stringData:<br/>  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}<br/>  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}<br/>``` | ```yaml<br/>apiVersion: v1<br/>kind: Secret<br/>type: Opaque<br/>data:<br/>  CLOUDABILITY_API_KEY: {{ .Values.apiKey \| quote }}<br/>  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy \| quote }}<br/>``` |
| **K8s API Processing** | ✅ Auto-converts `stringData` to `data` (base64) | ⚠️ Validates base64 format (errors if invalid) |
| **Stored in etcd** | **Base64-encoded** | **Base64-encoded** |
| | ```yaml<br/>data:<br/>  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"<br/>  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"<br/>``` | ```yaml<br/>data:<br/>  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"<br/>  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"<br/>``` |
| **Pod Environment** | **Plain text (auto-decoded)** | **Plain text (auto-decoded)** |
| | ```bash<br/>$ echo $CLOUDABILITY_API_KEY<br/>abc123xyz<br/><br/>$ echo $cloudability_outbound_proxy<br/>http://proxy:8080<br/>``` | ```bash<br/>$ echo $CLOUDABILITY_API_KEY<br/>abc123xyz<br/><br/>$ echo $cloudability_outbound_proxy<br/>http://proxy:8080<br/>``` |
| **Error Risk** | ✅ **Low** - No manual encoding | ⚠️ **High** - Manual encoding errors |
| **Maintainability** | ✅ **Easy** - Human-readable in AWS | ⚠️ **Hard** - Must decode to read |
| **Production Ready** | ✅ **Recommended** | ⚠️ **Not recommended** |

## Recommendation

**Use Case 1: `stringData` with plain text in AWS Secrets Manager**

### Why?
- ✅ Simpler workflow
- ✅ Less error-prone
- ✅ Human-readable secrets in AWS Console
- ✅ Easier to audit and rotate
- ✅ Same security posture (both stored as base64 in etcd)
- ✅ Kubernetes handles encoding automatically

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
```
