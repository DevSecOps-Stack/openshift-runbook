# HAProxy Pass-Through Termination (Dedicated IngressController) — Hands-on Lab & Manifest Guide

In **Pass-Through Termination**, the OpenShift HAProxy router does **not** decrypt the traffic. It operates as a pure **Layer 4 TCP proxy**, inspecting only the unencrypted **SNI (Server Name Indication)** field in the TLS `ClientHello` packet to route raw encrypted TCP packets straight to the backend pod.

In this enterprise pattern, we deploy a **dedicated `IngressController` CR** scoped to the application via `namespaceSelector: matchLabels: ingress: testapp-passthrough`. The namespace is labeled `ingress=testapp-passthrough`, and the router forwards raw TCP packets directly to the HTTPS backend pod without decrypting.

```
[ Browser / Client ] ────(HTTPS / Port 443)────► [ Dedicated Ingress: testapp-passthrough-ingress ] ────(Raw Encrypted TLS)────► [ Backend Pod ]
                                                   (Matches namespace label: ingress=testapp-passthrough)                  (TLS Terminates Here)
```

---

## 📋 Lab File Layout

| File | Purpose |
| :--- | :--- |
| [`00-namespace.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/00-namespace.yaml) | Application namespace labeled `ingress: testapp-passthrough` |
| [`01-tls-secret.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/01-tls-secret.yaml) | Template for application TLS Secret in the app namespace |
| [`02-ingresscontroller.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/02-ingresscontroller.yaml) | **Dedicated IngressController CR** with `namespaceSelector: matchLabels: ingress: testapp-passthrough` |
| [`03-deployment.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/03-deployment.yaml) | Python HTTPS server listening on 8443 and mounting the TLS secret |
| [`04-service.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/04-service.yaml) | ClusterIP service targeting port 8443 (`protocol: TCP`) |
| [`05-route.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/05-route.yaml) | Pass-Through route (**holds zero certificates**) |

---

## 🛠️ Step 1: Certificate Generation for the Pod

Since the pod terminates TLS directly, the certificate must be signed for the pod's route domain: `passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud`.

> [!TIP]
> **One-Command Shortcut:** Run `./generate-certs.sh` to generate the pod key, CSR, sign it with `root-ca.crt`, and automatically populate `01-tls-secret.yaml`.

### 1.1 Generate Pod Private Key and CSR
```bash
openssl req -new -nodes -newkey rsa:2048 \
  -keyout passthrough.key \
  -out passthrough.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud"
```

### 1.2 Sign the Pod Cert with your Root CA
```bash
cat <<EOF > passthrough-san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud
DNS.2 = *.testapp-passthrough.apps.okd-sno.brainybots.cloud
EOF

openssl x509 -req -in passthrough.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out passthrough.crt -days 365 -extfile passthrough-san.cnf
```

---

## 🚀 Step 2: Pure Declarative Deployment Sequence

> [!IMPORTANT]
> **SNO Ingress Architecture (LoadBalancerService vs HostNetwork):**
> On Single-Node OpenShift (SNO), using `endpointPublishingStrategy: type: HostNetwork` will cause an instant port collision on 80/443 with `router-default`. We configure `type: LoadBalancerService` with `scope: External` so GCP provisions a dedicated Cloud Network Load Balancer IP and automatically updates Cloud DNS.

### 2.1 Create the Namespace
```bash
oc apply -f 00-namespace.yaml
```

### 2.2 Create the TLS Secret inside `demo-testapp-passthrough`
The router does **not** get this secret; it is mounted directly into the backend pod:
```bash
oc apply -f 01-tls-secret.yaml
```

### 2.3 Deploy the Dedicated IngressController CR
```bash
oc apply -f 02-ingresscontroller.yaml
```
*The Ingress Operator provisions a dedicated router deployment (`router-testapp-passthrough-ingress`) in `openshift-ingress` and GCP provisions an external forwarding rule.*

### 2.4 Deploy the HTTPS Backend & Route
```bash
oc apply -f 03-deployment.yaml
oc apply -f 04-service.yaml
oc apply -f 05-route.yaml
```

---

## 🔍 Step 3: Verification & Diagnostics

### 3.1 Test HTTPS with cURL
```bash
curl -v --cacert certs/root-ca.crt https://passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud
```
*Expected Output:*
* Returns `Hello from Pass-Through Secure Backend Pod!`
* Notice the TLS handshake: the certificate returned is the **pod's own certificate**, not the router's wildcard cert!

### 3.2 Verify SNI Routing with OpenSSL `s_client`
To prove that HAProxy routes purely on the SNI header:
```bash
echo | openssl s_client -connect passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud:443 \
  -servername passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud \
  -CAfile certs/root-ca.crt 2>/dev/null | openssl x509 -noout -subject -issuer
```
*Expected Output:*
* `subject=C=AU, O=BrainyBots Enterprise, CN=passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud`
* `issuer=C=AU, O=BrainyBots Enterprise, OU=Security, CN=BrainyBots Enterprise Root CA`

---

## 🚨 Step 4: The Signature Failure Mode Drill (`ERR_SSL_PROTOCOL_ERROR`)

Want to see what happens when a Pass-Through route points to a pod that only speaks plain HTTP?

1. Update `03-deployment.yaml` to run a plain HTTP server on port 8080.
2. Curl the route:
   ```bash
   curl -v https://passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud
   ```
3. **Observation:** Browser throws:
   `ERR_SSL_PROTOCOL_ERROR`
4. **Why:** Browser sent a TLS `ClientHello`. The plain HTTP pod tried to parse binary TLS bytes as an HTTP GET string, failed, and reset the TCP connection.
