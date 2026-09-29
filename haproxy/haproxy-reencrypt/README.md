# HAProxy Re-encrypt Termination (Sharded Ingress) — Hands-on Lab & Manifest Guide

In **Re-encrypt Termination**, the OpenShift HAProxy router maintains **two independent TLS connections**:
1. **Connection 1 (Client $\leftrightarrow$ HAProxy):** Encrypted using the cluster's public/wildcard certificate. Decrypted in HAProxy RAM to allow Layer 7 URL path routing (`/api`), cookie session stickiness, and header injection.
2. **Connection 2 (HAProxy $\leftrightarrow$ Backend Pod):** HAProxy acts as a TLS client and initiates a *second* internal TLS handshake to the backend pod on port 8443 over the internal SDN.

In this enterprise pattern, we deploy a **dedicated sharded `IngressController` CR** that isolates and routes traffic **only** for namespaces matching `ingress.traffic.type: reencrypt` and routes matching `type: reencrypt`.

```
[ Browser / Client ] ────(TLS 1: Public Wildcard)────► [ Sharded Ingress: reencrypt-ingress ] ────(TLS 2: Service CA)────► [ Backend Pod ]
                     (Terminates Connection 1)             (Matches: ingress.traffic.type=reencrypt)                  (Terminates Connection 2)
```

---

## 📋 Lab File Layout

| File | Purpose |
| :--- | :--- |
| [`00-namespace.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/00-namespace.yaml) | Dedicated namespace with label `ingress.traffic.type: reencrypt` |
| [`01-ingresscontroller.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/01-ingresscontroller.yaml) | **Full standalone IngressController CR** with `namespaceSelector` and `defaultCertificate` |
| [`02-service.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/02-service.yaml) | Service with OpenShift Service CA annotation to auto-issue internal certs |
| [`03-deployment.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/03-deployment.yaml) | Backend HTTPS container listening on 8443 and mounting internal certs |
| [`04-route.yaml`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/04-route.yaml) | Re-encrypt route with label `type: reencrypt` and Service CA trust anchor |

---

## 🚀 Step 1: Deploy Namespace & IngressController

### 1.1 Create the Namespace
```bash
oc apply -f 00-namespace.yaml
```

### 1.2 Deploy the Sharded IngressController CR
```bash
oc apply -f 01-ingresscontroller.yaml
```
*The Ingress Operator automatically creates a dedicated secondary router deployment (`router-reencrypt-ingress`) in `openshift-ingress`.*

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
oc get secrets -n demo-reencrypt
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
curl -v https://reencrypt-app.apps.okd-sno.brainybots.cloud
```
*Expected Output:*
* Returns `Hello from Re-encrypt Secure Pod (Encrypted over internal SDN)!`
* Browser leg is verified via `BrainyBots Enterprise Root CA`.
* Internal pod leg is verified via OpenShift Service CA.

### 3.2 Test in Chrome
Open `https://reencrypt-app.apps.okd-sno.brainybots.cloud`:
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
   curl -I https://reencrypt-app.apps.okd-sno.brainybots.cloud
   ```
4. **Observation:**
   * Browser displays:
     **`503 Service Unavailable / Application is not available`**
   * Padlock in browser is still **GREEN 🔒**! (Because Leg 1 to HAProxy succeeded).
   * HAProxy pod logs show:
     `L6RSP` (Layer 6 Response Error during backend SSL handshake).
5. **Fix:** Revert `04-route.yaml` to trust the authentic OpenShift Service CA.
