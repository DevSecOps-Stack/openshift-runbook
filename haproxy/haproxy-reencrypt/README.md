# HAProxy Re-encrypt Termination (Dedicated IngressController) — Hands-on Lab & Manifest Guide

In **Re-encrypt Termination**, the OpenShift HAProxy router maintains **two independent TLS connections**:
1. **Connection 1 (Client $\leftrightarrow$ HAProxy):** Encrypted using the cluster's public/wildcard certificate. Decrypted in HAProxy RAM to allow Layer 7 URL path routing (`/api`), cookie session stickiness, and header injection.
2. **Connection 2 (HAProxy $\leftrightarrow$ Backend Pod):** HAProxy acts as a TLS client and initiates a *second* internal TLS handshake to the backend pod on port 8443 over the internal SDN.

In this enterprise pattern, we deploy a **dedicated `IngressController` CR** scoped to the application via `namespaceSelector: matchLabels: ingress: testapp-reencrypt`. The namespace is labeled `ingress=testapp-reencrypt`, and the dedicated router handles all routes inside that namespace automatically.

```
[ Browser / Client ] ────(TLS 1: Public Wildcard)────► [ Dedicated Ingress: testapp-reencrypt-ingress ] ────(TLS 2: Service CA)────► [ Backend Pod ]
                     (Terminates Connection 1)             (Matches namespace label: ingress=testapp-reencrypt)              (Terminates Connection 2)
```

---

## 📋 Lab File Layout

| File | Purpose |
| :--- | :--- |
| [`00-namespace.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/00-namespace.yaml) | Application namespace labeled `ingress: testapp-reencrypt` |
| [`01-tls-secret.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/01-tls-secret.yaml) | Ingress TLS secret manifest for Leg 1 public termination |
| [`01-ingresscontroller.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/01-ingresscontroller.yaml) | **Dedicated IngressController CR** with `namespaceSelector: matchLabels: ingress: testapp-reencrypt` |
| [`02-service.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/02-service.yaml) | Service with OpenShift Service CA annotation to auto-issue internal certs |
| [`03-deployment.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/03-deployment.yaml) | Backend HTTPS container listening on 8443 and mounting internal certs |
| [`04-route.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/04-route.yaml) | Re-encrypt route with Service CA trust anchor |

---

## 🛠️ Step 1: Generate Public Ingress Certificate (Leg 1)

In Re-encrypt, the router terminates Leg 1 using the public wildcard certificate. Run the automated script to generate the keys and populate `01-tls-secret.yaml`:

```bash
./generate-certs.sh
```

---

## 🚀 Step 2: Deploy Namespace, Secret & IngressController

> [!IMPORTANT]
> **SNO Ingress Architecture (LoadBalancerService):**
> On Single-Node OpenShift, the IngressController uses `endpointPublishingStrategy: type: LoadBalancerService` with `scope: External` to ensure GCP provisions a dedicated external IP and avoids port collisions with `router-default`.

### 2.1 Create Namespace & Apply Ingress Secret
```bash
oc apply -f 00-namespace.yaml
oc apply -f 01-tls-secret.yaml
```

### 2.2 Deploy Dedicated IngressController CR
```bash
oc apply -f 01-ingresscontroller.yaml
```
*The Ingress Operator creates the dedicated router deployment (`router-testapp-reencrypt-ingress`) in `openshift-ingress` and mounts `reencrypt-wildcard-tls`.*

---

## 🚀 Step 2: Deploy Workload & Trigger Auto-Cert Generation

### 2.1 Deploy the Service
```bash
oc apply -f 02-service.yaml
```

### 2.2 Verify Auto-Cert Generation by OpenShift Service CA
Because `02-service.yaml` has the annotation:
`service.beta.openshift.io/serving-cert-secret-name: reencrypt-backend-tls`

The internal OpenShift Service CA controller immediately creates a Secret containing `tls.crt` and `tls.key`:
```bash
oc get secrets -n demo-testapp-reencrypt
```

### 2.3 Deploy Backend Pod & Re-encrypt Route
The pod mounts `reencrypt-backend-tls` at `/var/run/secrets/tls` and listens on HTTPS port 8443:
```bash
oc apply -f 03-deployment.yaml
oc apply -f 04-route.yaml
```

---

## 🔍 Step 3: Verification & Diagnostics

### 3.1 Test HTTPS with cURL
```bash
curl -v https://reencrypt-app.testapp-reencrypt.apps.okd-sno.brainybots.cloud
```
*Expected Output:*
* Returns `Hello from Re-encrypt Secure Pod (Encrypted over internal SDN)!`
* Browser leg is verified via `BrainyBots Enterprise Root CA`.
* Internal pod leg is verified via OpenShift Service CA.

### 3.2 Test in Chrome
Open `https://reencrypt-app.testapp-reencrypt.apps.okd-sno.brainybots.cloud`:
* **Padlock is Green 🔒.**
* Traffic over the wire to HAProxy is encrypted.
* Traffic inside the cluster network between HAProxy and the pod is **100% encrypted** (satisfying PCI-DSS / banking zero-trust audits).

---

## 🚨 Step 4: The Signature Failure Mode Drill (`503 L6RSP`)

What happens when HAProxy's internal TLS handshake to the pod fails?

1. Edit `04-route.yaml` and inject an invalid/fake certificate into `spec.tls.destinationCACertificate`.
2. Apply the broken route:
   ```bash
   oc apply -f 04-route.yaml
   ```
3. Curl the route:
   ```bash
   curl -I https://reencrypt-app.testapp-reencrypt.apps.okd-sno.brainybots.cloud
   ```
4. **Observation:**
   * Browser displays:
     **`503 Service Unavailable / Application is not available`**
   * Padlock in browser is still **GREEN 🔒**! (Because Leg 1 to HAProxy succeeded).
   * HAProxy pod logs show:
     `L6RSP` (Layer 6 Response Error during backend SSL handshake).
5. **Fix:** Revert `04-route.yaml` to trust the authentic OpenShift Service CA.
