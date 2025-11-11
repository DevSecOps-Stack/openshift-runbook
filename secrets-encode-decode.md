# Key Differences Summary

## stringData vs data Approach

| Step                    | stringData (Case 1) ✅                                                                                                                         | data (Case 2) ⚠️                                                                                                                       |           |                                                                                                                                   |                                                                             |           |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | --------- |
| **AWS Secrets Manager** | **Plain text**<br>`{ "CLOUDABILITY_API_KEY": "abc123xyz", "cloudability_outbound_proxy": "http://proxy:8080" }`                               | **Base64-encoded (manual)**<br>`{ "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6", "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw" }` |           |                                                                                                                                   |                                                                             |           |
| **ArgoCD Values**       | **Passes plain text**<br>`apiKey: "abc123xyz"`<br>`proxy:`<br>`  outboundProxy: "http://proxy:8080"`                                          | **Passes base64**<br>`apiKey: "YWJjMTIzeHl6"`<br>`proxy:`<br>`  outboundProxy: "aHR0cDovL3Byb3h5Ojo4MDgw"`                             |           |                                                                                                                                   |                                                                             |           |
| **Helm Template**       | **Uses `stringData:`**<br>`apiVersion: v1`<br>`kind: Secret`<br>`type: Opaque`<br>`stringData:`<br>`  CLOUDABILITY_API_KEY: {{ .Values.apiKey | quote }}`<br>`  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy                                                            | quote }}` | **Uses `data:`**<br>`apiVersion: v1`<br>`kind: Secret`<br>`type: Opaque`<br>`data:`<br>`  CLOUDABILITY_API_KEY: {{ .Values.apiKey | quote }}`<br>`  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy | quote }}` |
| **K8s API Processing**  | ✅ Auto-converts `stringData` → `data` (base64)                                                                                                | ⚠️ Validates base64 format (errors if invalid)                                                                                         |           |                                                                                                                                   |                                                                             |           |
| **Stored in etcd**      | Base64-encoded                                                                                                                                | Base64-encoded                                                                                                                         |           |                                                                                                                                   |                                                                             |           |
| **Pod Environment**     | Plain text (auto-decoded)<br>`$ echo $CLOUDABILITY_API_KEY → abc123xyz`<br>`$ echo $cloudability_outbound_proxy → http://proxy:8080`          | Plain text (auto-decoded)<br>`$ echo $CLOUDABILITY_API_KEY → abc123xyz`<br>`$ echo $cloudability_outbound_proxy → http://proxy:8080`   |           |                                                                                                                                   |                                                                             |           |
| **Error Risk**          | ✅ Low (auto-encoding handled by K8s)                                                                                                          | ⚠️ High (manual encoding prone to error)                                                                                               |           |                                                                                                                                   |                                                                             |           |
| **Maintainability**     | ✅ Easy, human-readable                                                                                                                        | ⚠️ Hard, must decode to verify                                                                                                         |           |                                                                                                                                   |                                                                             |           |
| **Production Ready**    | ✅ Recommended                                                                                                                                 | ⚠️ Not recommended                                                                                                                     |           |                                                                                                                                   |                                                                             |           |

---

## Recommendation

**Use Case 1: `stringData` with plain text in AWS Secrets Manager**

### Why?

* ✅ Simpler workflow
* ✅ Less error-prone
* ✅ Human-readable secrets in AWS Console
* ✅ Easier to audit and rotate
* ✅ Same security posture (base64 in etcd)
* ✅ Kubernetes handles encoding automatically

---

## YAML Examples

### ✅ Case 1 — Using `stringData`

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

### ⚠️ Case 2 — Using `data`

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
  CLOUDABILITY_API_KEY: {{ . | b64enc | quote }}
  {{- end }}
  {{- with .Values.proxy.outboundProxy }}
  cloudability_outbound_proxy: {{ . | b64enc | quote }}
  {{- end }}
{{- end }}
```

---

✅ **Conclusion:**
Use **`stringData`** whenever possible for simplicity, readability, and lower operational risk.
Both approaches are equally secure once stored, but `stringData` avoids manual encoding errors.
