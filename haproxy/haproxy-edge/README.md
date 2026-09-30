# HAProxy Edge Termination (Dedicated IngressController) — Hands-on Lab & Runbook

In **Edge Termination**, client TLS encryption terminates at the OpenShift HAProxy router. Traffic between the router and the backend pod flows over the internal cluster SDN as unencrypted HTTP.

In this enterprise pattern, we deploy a **dedicated `IngressController` Custom Resource** scoped to our application via `namespaceSelector: matchLabels: ingress: edge-app`. The namespace is labeled `ingress=edge-app`, and the dedicated router handles all routes inside that namespace automatically.

```
1. USER / BROWSER
   Types: https://edge-app.apps.okd-sno.brainybots.cloud
         │
         ▼
2. DNS RESOLUTION (Google Cloud DNS / AWS Route 53)
   *.apps.okd-sno.brainybots.cloud  ──►  Resolves to Load Balancer External IP (e.g. 34.68.120.45)
         │
         ▼
3. CLOUD INFRASTRUCTURE (GCP Forwarding Rule / AWS Network Load Balancer)
   Listens on Port 80 / 443  ──►  Forwards raw TCP stream to Ingress Node
         │
         ▼
4. DATA PLANE: OPENSHIFT INGRESS (openshift-ingress namespace)
┌────────────────────────────────────────────────────────────────────────┐
│ Ingress Node (Host Port 80 / 443)                                      │
│   │                                                                    │
│   ▼                                                                    │
│ HAProxy Router Pod (router-edge-app-ingress-xxxx)                      │
│   • Terminates TLS using 'custom-wildcard-tls' Secret                  │
│   • Matches Host Header: edge-app.apps.okd-sno.brainybots.cloud        │
│   • In-pod Go controller watches EndpointSlices via UNIX socket        │
│                                                                        │
│   (Bypasses kube-proxy; routes directly to pod IP for ultra-low latency)│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼ (Over OVN-Kubernetes SDN)
5. SERVICE ABSTRACTION & BACKEND POD (edge-app namespace)
┌────────────────────────────────────────────────────────────────────────┐
│ Kubernetes Service: edge-app-svc                                       │
│   (Logical selector template: selects pods with label app=edge-app)    │
│                                                                        │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ Application Pod: edge-app-xxxx (Pod IP: 10.128.2.45:8080)    │     │
│   │ Container receives plain HTTP request                        │     │
│   │ Responds: HTTP/1.1 200 OK ("Hello OpenShift!")               │     │
│   └──────────────────────────────────────────────────────────────┘     │
└───────────────────────────────────▲────────────────────────────────────┘
                                    │
                                    │ Managed & Reconciled By
┌───────────────────────────────────┴────────────────────────────────────┐
│ CONTROL PLANE (openshift-ingress-operator namespace)                   │
│   • Ingress Operator Pod: ingress-operator-xxxx                        │
│   • IngressController CR: edge-app-ingress                             │
│     (Selects namespace labeled: ingress=edge-app)                      │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 Manifest Directory

All resources are deployed using purely declarative YAML manifests:

| File | Purpose |
| :--- | :--- |
| [`00-namespace.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/00-namespace.yaml) | Project namespace `edge-app` labeled `ingress: edge-app` |
| [`01-tls-secret.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/01-tls-secret.yaml) | Declarative Wildcard TLS secret manifest for `openshift-ingress` |
| [`02-ingresscontroller.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/02-ingresscontroller.yaml) | **Dedicated IngressController CR** with `namespaceSelector: matchLabels: ingress: edge-app` |
| [`03-deployment.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/03-deployment.yaml) | 2-replica HTTP application pod (`quay.io/openshift/origin-hello-openshift`) |
| [`04-service.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/04-service.yaml) | ClusterIP service targeting container port 8080 |
| [`05-route.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/05-route.yaml) | Clean Edge route for `edge-app.apps.okd-sno.brainybots.cloud` |

---

> [!NOTE]
> **Port Mapping & SNO Architecture Reference:**
> For the deep architectural theory on Ingress HostNetwork port bindings, resolving SNO port collisions via port remapping (`8080`/`8443`), and multi-node Cloud Load Balancer design, refer to the master manual:
> 👉 [`haproxy/README.md#7-ingress-port-binding--port-remapping-architecture`](../README.md#7-ingress-port-binding--port-remapping-architecture)

---

## 🛠️ Step 1: OpenSSL Certificate Generation

Generate a private Root CA and a wildcard certificate with Subject Alternative Name (SAN) extensions covering both the primary apps domain and the dedicated application subdomain.

> [!TIP]
> **One-Command Shortcut:** Run `./generate-certs.sh` to generate the CA, server certificates, bundle `fullchain.crt`, and populate `01-tls-secret.yaml` in one step.

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

### 1.3 Create Multi-SAN Config and Sign the Certificate
Wildcards in TLS (RFC 6125) do NOT cross dot boundaries (e.g. `*.apps...` does not match `app.edge-app.apps...`). We must explicitly include the nested subdomain in SAN:

```bash
cat <<EOF > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.apps.okd-sno.brainybots.cloud
DNS.2 = apps.okd-sno.brainybots.cloud
DNS.3 = *.edge-app.apps.okd-sno.brainybots.cloud
DNS.4 = app.edge-app.apps.okd-sno.brainybots.cloud
EOF

openssl x509 -req -in server.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.cnf

# Bundle complete verification chain
cat server.crt root-ca.crt > fullchain.crt
```

### 1.4 Add Root CA to macOS Keychain (One Command for 🔒 Green Padlock)
```bash
sudo security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain root-ca.crt
```

> [!IMPORTANT]
> **Clear Browser TLS Cache:** After running the command above, **fully Quit Google Chrome / Safari (`Cmd + Q`)** and relaunch it. Browsers cache existing TLS trust evaluations in their active socket pool.

---

## 🚀 Step 2: Pure Declarative YAML Apply Sequence

### 2.1 Prepare the Secret YAML
Base64 encode the complete certificate chain and key into `01-tls-secret.yaml`:
```bash
# Populate 01-tls-secret.yaml with fullchain and key:
sed -i '' "s|tls.crt: \"\"|tls.crt: \"$(cat fullchain.crt | base64 | tr -d '\n')\"|g" 01-tls-secret.yaml
sed -i '' "s|tls.key: \"\"|tls.key: \"$(cat server.key | base64 | tr -d '\n')\"|g" 01-tls-secret.yaml
```

### 2.2 Apply Manifests in Sequence
Apply all manifests declaratively:
```bash
# 1. Create Application Namespace
oc apply -f 00-namespace.yaml

# 2. Deploy Wildcard TLS Secret in openshift-ingress
oc apply -f 01-tls-secret.yaml

# 3. Deploy Dedicated IngressController Custom Resource
oc apply -f 02-ingresscontroller.yaml

# 4. Deploy Application Workload, Service & Route
oc apply -f 03-deployment.yaml
oc apply -f 04-service.yaml
oc apply -f 05-route.yaml
```

---

## 🖥️ Simulated Terminal Outputs & Under-the-Hood Mechanics

Here is what happens on the cluster at each stage:

### 1. Applying the Dedicated IngressController CR

When you apply `02-ingresscontroller.yaml`, the **Ingress Operator** immediately reacts:

```text
$ oc apply -f 02-ingresscontroller.yaml
ingresscontroller.operator.openshift.io/edge-app-ingress created

# --- What happens under the hood ---
# 1. Ingress Operator reconciles the CR
# 2. Operator creates a dedicated Deployment in openshift-ingress:
$ oc get deployment -n openshift-ingress
NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
router-default           1/1     1            1           5d
router-edge-app-ingress  1/1     1            1           12s

# 3. Router pod starts and mounts custom-wildcard-tls secret:
$ oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=edge-app-ingress
NAME                                       READY   STATUS    RESTARTS   AGE
router-edge-app-ingress-7b49cf5d77-kx98m   1/1     Running   0          25s

# 4. Ingress Operator publishes Cloud DNS / HostNetwork bindings:
$ dig edge-app.apps.okd-sno.brainybots.cloud +short
34.68.120.45
```

---

### 2. Applying the Application Stack & Route

```text
$ oc apply -f 03-deployment.yaml
deployment.apps/edge-app created

$ oc apply -f 04-service.yaml
service/edge-app-svc created

$ oc apply -f 05-route.yaml
route.route.openshift.io/edge-app-route created

# Verify workload and route status:
$ oc get pods,svc,route -n edge-app
NAME                            READY   STATUS    RESTARTS   AGE
pod/edge-app-6c9f697486-l49wq   1/1     Running   0          18s
pod/edge-app-6c9f697486-x28vp   1/1     Running   0          18s

NAME                   TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
service/edge-app-svc   ClusterIP   172.30.142.88    <none>        8080/TCP   18s

NAME                                     HOST/PORT                                PATH   SERVICES       PORT   TERMINATION   WILDCARD
route.route.openshift.io/edge-app-route   edge-app.apps.okd-sno.brainybots.cloud          edge-app-svc   http   edge/Redirect None
```

---

### 3. Live cURL Verification & TLS Handshake Trace

Running `curl -vI` proves the certificate is served by HAProxy and terminates cleanly at the edge:

```text
$ curl -vI https://edge-app.apps.okd-sno.brainybots.cloud

* Connected to edge-app.apps.okd-sno.brainybots.cloud (34.68.120.45) port 443
* ALPN: offers h2,http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* Server certificate:
*  subject: C=AU; O=BrainyBots Enterprise; CN=*.apps.okd-sno.brainybots.cloud
*  start date: Sep 29 10:00:00 2026 GMT
*  expire date: Sep 29 10:00:00 2027 GMT
*  subjectAltName: host "edge-app.apps.okd-sno.brainybots.cloud" matched cert's "*.apps.okd-sno.brainybots.cloud"
*  issuer: C=AU; O=BrainyBots Enterprise; OU=Security; CN=BrainyBots Enterprise Root CA
*  SSL certificate verify ok.
* TLSv1.3 (IN), TLS handshake, Finished (20):
* Using HTTP2, server supports multiplexing
> HEAD / HTTP/2
> Host: edge-app.apps.okd-sno.brainybots.cloud
> User-Agent: curl/8.4.0
> Accept: */*
> 
< HTTP/2 200 
< content-type: text/plain; charset=utf-8
< date: Tue, 29 Sep 2026 11:22:45 GMT
< set-cookie: 8c12a76f23=9701a5dc; path=/; HttpOnly; Secure; SameSite=None
< 
* Connection #0 to host edge-app.apps.okd-sno.brainybots.cloud left intact
```

---

### 4. Chrome Browser Verification

Open in Google Chrome:  
`https://edge-app.apps.okd-sno.brainybots.cloud`

* **Page Content:** Displays `Hello OpenShift!`.
* **Security Status:** **Green Padlock 🔒 Connection is secure**.
* **Certificate Viewer:**
  * Common Name: `*.apps.okd-sno.brainybots.cloud`
  * Issuer: `BrainyBots Enterprise Root CA`
  * Validity: 1 Year

---

## 🧪 Next Steps & Production Experiments

Now that your Edge deployment is running and verified, proceed to the master guide to test live runtime scaling, process tree inspection, and route tweaks:
👉 [**Master Guide: Post-Deployment Experiments, Tweaks & Live Socket Drills**](../README.md#8-post-deployment-experiments-tweaks--live-socket-drills)

