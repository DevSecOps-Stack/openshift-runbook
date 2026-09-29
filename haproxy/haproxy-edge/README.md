# HAProxy Edge Termination (Sharded Ingress) — Hands-on Lab & Manifest Guide

In **Edge Termination**, client TLS encryption terminates at the OpenShift HAProxy router. Traffic between the router and the backend pod flows over the internal cluster SDN as unencrypted HTTP.

In this enterprise pattern, we deploy a **custom sharded `IngressController` Custom Resource** that automatically isolates and routes traffic **only** for namespaces matching `ingress.traffic.type: edge` and routes matching `type: edge`, attaching the custom wildcard certificate automatically.

```
[ Browser / Client ] ────(HTTPS / Port 443)────► [ Sharded Ingress: edge-ingress ] ────(Plain HTTP / Port 8080)────► [ Backend Pod ]
                     (TLS Terminates Here)          (Matches: ingress.traffic.type=edge)
```

---

## 📋 Lab File Layout

| File | Purpose |
| :--- | :--- |
| [`00-namespace.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/00-namespace.yaml) | Project namespace with label `ingress.traffic.type: edge` |
| [`01-tls-secret.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/01-tls-secret.yaml) | Template for wildcard TLS secret in `openshift-ingress` |
| [`02-ingresscontroller.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/02-ingresscontroller.yaml) | **Full standalone IngressController CR** with `namespaceSelector`, `routeSelector`, and `defaultCertificate` |
| [`03-deployment.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/03-deployment.yaml) | 2-replica HTTP application pod (`quay.io/openshift/origin-hello-openshift`) |
| [`04-service.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/04-service.yaml) | Service targeting container port 8080 |
| [`05-route.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/05-route.yaml) | Clean Edge route with label `type: edge` (inherits wildcard cert) |

---

## 🛠️ Step 1: OpenSSL Certificate Generation

Generate a private Root CA and a wildcard certificate with Subject Alternative Name (SAN) extensions.

### 1.1 Generate Root CA (The Trust Anchor)
```bash
openssl req -x509 -new -nodes -newkey rsa:4096 \
  -keyout root-ca.key \
  -out root-ca.crt \
  -days 3650 \
  -subj "/C=AU/O=BrainyBots Enterprise/OU=Security/CN=BrainyBots Enterprise Root CA"
```

### 1.2 Generate Server Key and CSR
```bash
openssl req -new -nodes -newkey rsa:2048 \
  -keyout server.key \
  -out server.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=*.apps.okd-sno.brainybots.cloud"
```

### 1.3 Create SAN Config and Sign the Certificate
```bash
cat <<EOF > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.apps.okd-sno.brainybots.cloud
DNS.2 = apps.okd-sno.brainybots.cloud
EOF

openssl x509 -req -in server.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.cnf
```

### 1.4 Add Root CA to macOS Keychain (One Command for 🔒 Green Padlock)
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root-ca.crt
```

---

## 🚀 Step 2: Pure Declarative Deployment Sequence

No CLI patch commands required. Apply all manifests declaratively:

### 2.1 Create the Wildcard Secret in `openshift-ingress`
```bash
oc create secret tls custom-wildcard-tls \
  --cert=server.crt \
  --key=server.key \
  -n openshift-ingress
```
*(Or populate base64 strings into `01-tls-secret.yaml` and run `oc apply -f 01-tls-secret.yaml`)*

### 2.2 Deploy the Sharded IngressController CR
```bash
oc apply -f 02-ingresscontroller.yaml
```
*The Ingress Operator automatically provisions a dedicated secondary HAProxy router deployment (`router-edge-ingress`) in `openshift-ingress`.*

### 2.3 Deploy the Edge Application Stack
```bash
oc apply -f 00-namespace.yaml
oc apply -f 03-deployment.yaml
oc apply -f 04-service.yaml
oc apply -f 05-route.yaml
```

---

## 🔍 Step 3: Verification & Diagnostics

### 3.1 Verify Sharded Router and Route Readiness
```bash
# Check the dedicated router deployment
oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=edge-ingress

# Check the application pods and route
oc get pods,route -n demo-edge
```

### 3.2 Test HTTPS with cURL
```bash
curl -vI https://edge-app.apps.okd-sno.brainybots.cloud
```
*Expected Output:*
* Returns `HTTP/1.1 200 OK`
* TLS handshake negotiates using the `BrainyBots Enterprise Root CA`
* `server certificate:` `CN=*.apps.okd-sno.brainybots.cloud`

### 3.3 Verify in Browser
Open in Chrome:
`https://edge-app.apps.okd-sno.brainybots.cloud`
* Shows "Hello OpenShift!" with the **green padlock 🔒**.
* Click the padlock $\rightarrow$ Certificate is Valid $\rightarrow$ Issued by *BrainyBots Enterprise Root CA*.
