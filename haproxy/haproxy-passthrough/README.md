# HAProxy Pass-Through Termination — Hands-on Lab & Manifest Guide

In **Pass-Through Termination**, the OpenShift HAProxy router does **not** decrypt the traffic. It operates as a pure **Layer 4 TCP proxy**, inspecting only the unencrypted **SNI (Server Name Indication)** field in the TLS `ClientHello` packet to route raw encrypted TCP packets straight to the backend pod.

```
[ Browser / Client ] ────(HTTPS / Port 443)────► [ HAProxy Router ] ────(Raw Encrypted TLS)────► [ Backend Pod ]
                                                   (L4 SNI Proxy)                                 (TLS Terminates Here)
```

---

## 📋 Lab File Layout

| File | Purpose |
| :--- | :--- |
| [`00-namespace.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/00-namespace.yaml) | Dedicated `demo-passthrough` project namespace |
| [`01-tls-secret.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/01-tls-secret.yaml) | Template for creating the application TLS Secret in the app namespace |
| [`02-deployment.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/02-deployment.yaml) | Python HTTPS server listening on 8443 and mounting the TLS secret |
| [`03-service.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/03-service.yaml) | Service targeting port 8443 (`protocol: TCP`) |
| [`04-route.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/04-route.yaml) | Pass-Through route (**holds zero certificates**) |

---

## 🛠️ Step 1: OpenSSL Certificate Generation for the Pod

Since the pod terminates TLS, the certificate must be signed for the pod's route domain: `passthrough-app.apps.okd-sno.brainybots.cloud`.

### 1.1 Generate Pod Private Key and CSR
```bash
openssl req -new -nodes -newkey rsa:2048 \
  -keyout passthrough.key \
  -out passthrough.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=passthrough-app.apps.okd-sno.brainybots.cloud"
```

### 1.2 Sign the Pod Cert with your Root CA
```bash
cat <<EOF > passthrough-san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = passthrough-app.apps.okd-sno.brainybots.cloud
EOF

openssl x509 -req -in passthrough.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out passthrough.crt -days 365 -extfile passthrough-san.cnf
```

---

## 🚀 Step 2: Deploy Workload Manifests

### 2.1 Create the Namespace
```bash
oc apply -f 00-namespace.yaml
```

### 2.2 Create the TLS Secret inside `demo-passthrough`
The router does **not** get this secret; it is mounted directly into the backend pod:
```bash
oc create secret tls passthrough-tls-secret \
  --cert=passthrough.crt \
  --key=passthrough.key \
  -n demo-passthrough
```

### 2.3 Deploy the HTTPS Backend & Route
```bash
oc apply -f 02-deployment.yaml
oc apply -f 03-service.yaml
oc apply -f 04-route.yaml
```

---

## 🔍 Step 3: Verification & Diagnostics

### 3.1 Test HTTPS with cURL
```bash
curl -v https://passthrough-app.apps.okd-sno.brainybots.cloud
```
*Expected Output:*
* Returns `Hello from Pass-Through Secure Backend Pod!`
* Notice the TLS handshake: the certificate returned is the **pod's own certificate**, not the router's wildcard cert!

### 3.2 Verify SNI Routing with OpenSSL `s_client`
To prove that HAProxy routes purely on the SNI header:
```bash
openssl s_client -connect <router-ip>:443 \
  -servername passthrough-app.apps.okd-sno.brainybots.cloud \
  -CAfile root-ca.crt
```

---

## 🚨 Step 4: The Signature Failure Mode Drill (`ERR_SSL_PROTOCOL_ERROR`)

Want to see what happens when a Pass-Through route points to a pod that only speaks plain HTTP?

1. Update `02-deployment.yaml` to run a plain HTTP server on port 8080 (or edit `04-route.yaml` targetPort to an HTTP port).
2. Curl the route:
   ```bash
   curl -v https://passthrough-app.apps.okd-sno.brainybots.cloud
   ```
3. **Observation:** Browser throws:
   `ERR_SSL_PROTOCOL_ERROR`
4. **Why:** Browser sent a TLS `ClientHello`. The plain HTTP pod tried to parse binary TLS bytes as an HTTP GET string, crashed or closed the socket, and reset the TCP connection.
