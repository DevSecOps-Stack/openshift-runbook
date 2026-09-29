# OpenShift 4 HAProxy Ingress Lab Suites

A hands-on, runnable collection of declarative Kubernetes manifests and operational guides for all three OpenShift Route TLS termination models.

---

## 🗺️ Hands-on Demo Suites

| Lab Directory | Traffic Model | Where TLS Terminates | Primary Enterprise Use Case |
| :--- | :--- | :--- | :--- |
| **[`haproxy-edge/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-edge/)** | Client $\rightarrow$ HAProxy (HTTPS) $\rightarrow$ Pod (HTTP) | HAProxy Router | Standard microservices, public web apps, centralized wildcard certs |
| **[`haproxy-passthrough/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-passthrough/)** | Client $\rightarrow$ HAProxy (L4 SNI) $\rightarrow$ Pod (HTTPS) | Backend Pod | PCI-DSS banking data, client mTLS, custom protocols |
| **[`haproxy-reencrypt/`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy/haproxy-reencrypt/)** | Client $\rightarrow$ HAProxy (TLS 1) $\rightarrow$ Pod (TLS 2) | Router **and** Pod | Zero-trust compliance + Layer 7 routing (paths, cookies) |

---

## 🚀 Quick Start Guide

Each subfolder is completely self-contained with:
1. `00-namespace.yaml` — Dedicated isolated project namespace.
2. Complete application `Deployment`, `Service`, and `Route` manifests (no inline certificate mess!).
3. Step-by-step `README.md` containing exact OpenSSL generation commands, `oc apply` sequence, and verification curls.

### Architectural & Theory Reference
For the deep theoretical breakdown of in-pod Go controllers, `/var/lib/haproxy/run/haproxy.sock` zero-reload scaling, and interview Q&A flashcards, refer to:
* 📄 [`haproxy-ingress.md`](file:///Users/rakeshsharmapandyala/projects/openshift-runbook/haproxy-ingress.md)
