# Key Differences Summary

## stringData vs data Approach

### AWS Secrets Manager

**stringData (Case 1)**

```json
{
  "CLOUDABILITY_API_KEY": "abc123xyz",
  "cloudability_outbound_proxy": "http://proxy:8080"
}
```

**data (Case 2)**

```json
{
  "CLOUDABILITY_API_KEY": "YWJjMTIzeHl6",
  "cloudability_outbound_proxy": "aHR0cDovL3Byb3h5Ojo4MDgw"
}
```

### ArgoCD Values

**stringData (Case 1)**

```yaml
apiKey: "abc123xyz"
proxy:
  outboundProxy: "http://proxy:8080"
```

**data (Case 2)**

```yaml
apiKey: "YWJjMTIzeHl6"
proxy:
  outboundProxy: "aHR0cDovL3Byb3h5Ojo4MDgw"
```

### Helm Template

**stringData (Case 1)**

```yaml
apiVersion: v1
kind: Secret
type: Opaque
stringData:
  CLOUDABILITY_API_KEY: {{ .Values.apiKey | quote }}
  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy | quote }}
```

**data (Case 2)**

```yaml
apiVersion: v1
kind: Secret
type: Opaque
data:
  CLOUDABILITY_API_KEY: {{ .Values.apiKey | quote }}
  cloudability_outbound_proxy: {{ .Values.proxy.outboundProxy | quote }}
```

### K8s API Processing

* **stringData:** ✅ Auto-converts `stringData` to `data` (base64)
* **data:** ⚠️ Validates base64 format (errors if invalid)

### Stored in etcd

Both are stored as base64-encoded:

```yaml
data:
  CLOUDABILITY_API_KEY: "YWJjMTIzeHl6"
  cloudability_outbound_proxy: "aHR0cDovL3Byb3h5Ojo4MDgw"
```

### Pod Environment

**Plain text (auto-decoded):**

```bash
$ echo $CLOUDABILITY_API_KEY
abc123xyz

$ echo $cloudability_outbound_proxy
http://proxy:8080
```

### Error Risk & Maintainability

| Aspect           | stringData (Case 1)            | data (Case 2)                    |
| ---------------- | ------------------------------ | -------------------------------- |
| Error Risk       | ✅ Low - No manual encoding     | ⚠️ High - Manual encoding errors |
| Maintainability  | ✅ Easy - Human-readable in AWS | ⚠️ Hard - Must decode to read    |
| Production Ready | ✅ Recommended                  | ⚠️ Not recommended               |

---

## Recommendation

### ✅ Use Case 1: `stringData` with plain text in AWS Secrets Manager

#### Why?

* Simpler workflow
* Less error-prone
* Human-readable secrets in AWS Console
* Easier to audit and rotate
* Same security posture (both stored as base64 in etcd)
* Kubernetes handles encoding automatically

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
```

---

✅ **Conclusion:** Use `stringData` for readability and automation safety. Kubernetes will handle base64 conversion securely and transparently.
