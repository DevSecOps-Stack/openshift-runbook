# HAProxy Edge Termination — Hands-on Lab & Manifest Guide

In **Edge Termination**, client TLS encryption terminates at the OpenShift HAProxy router. Traffic between the router and the backend pod flows over the internal cluster SDN as unencrypted HTTP.

```
[ Browser / Client ] ────(HTTPS / Port 443)────► [ HAProxy Router ] ────(Plain HTTP / Port 8080)────► [ Backend Pod ]
                     (TLS Terminates Here)
```

---

## 📋 Lab File Layout

| File | Purpose |
| :--- | :--- |
| [`00-namespace.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/00-namespace.yaml) | Dedicated `demo-edge` project namespace |
| [`01-ingresscontroller-wildcard.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/01-ingresscontroller-wildcard.yaml) | Attaches centralized wildcard TLS secret to HAProxy |
| [`02-deployment.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/02-deployment.yaml) | 2-replica HTTP application pod (`quay.io/openshift/origin-hello-openshift`) |
| [`03-service.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/03-service.yaml) | Service targeting container port 8080 |
| [`04-route.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/04-route.yaml) | Edge route inheriting cluster wildcard certificate |

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

## 🚀 Step 2: Deploy Platform & Workload Manifests

### 2.1 Create the Centralized Wildcard Secret in `openshift-ingress`
```bash
oc create secret tls custom-wildcard-tls \
  --cert=server.crt \
  --key=server.key \
  -n openshift-ingress
```

### 2.2 Patch the IngressController
Apply [`01-ingresscontroller-wildcard.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/01-ingresscontroller-wildcard.yaml):
```bash
oc patch ingresscontroller/default -n openshift-ingress-operator \
  --type=merge --patch-file 01-ingresscontroller-wildcard.yaml
```
*The Ingress Operator updates the HAProxy deployment in `openshift-ingress` to mount and serve this certificate for all Edge routes.*

### 2.3 Deploy the Edge Application Stack
Apply the namespace, deployment, service, and route:
```bash
oc apply -f 00-namespace.yaml
oc apply -f 02-deployment.yaml
oc apply -f 03-service.yaml
oc apply -f 04-route.yaml
```

---

## 🔍 Step 3: Verification & Diagnostics

### 3.1 Verify Route and Pod Readiness
```bash
oc get pods -n demo-edge
oc get route edge-app-route -n demo-edge
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
