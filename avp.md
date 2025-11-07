# 🧭 ArgoCD Vault Plugin (AVP) AWS SecretsManager Integration - Quick Fix Runbook

---

## 📋 Issue Summary

**Error seen in ArgoCD:**

```
failed to generate manifest for source 1 of 1: rpc error: code = Unknown desc = Manifest generation error: plugin sidecar failed.
error generating manifests: failed to refresh cached credentials, no EC2 IMDS role found
```

**Root Cause:**
The `argocd-repo-server` pod was missing AWS IRSA (IAM Role for Service Account) credentials. It could not access AWS Secrets Manager because the IAM role wasn’t reflected in the running pod.

---

## ⚙️ Step-by-Step Fix (What We Actually Did)

### 1️⃣ Identify the namespace

```bash
oc project
```

➡️ Output confirmed namespace: `openshift-gitops`

---

### 2️⃣ Identify repo-server pod

```bash
oc -n openshift-gitops get pods | grep repo-server
```

➡️ Found: `cluster-gitops-repo-server-b949bd5c5-xt82b`

---

### 3️⃣ Check AWS-related environment variables (none found)

```bash
oc -n openshift-gitops exec cluster-gitops-repo-server-b949bd5c5-xt82b -- env | grep AWS
```

➡️ No output → means no AWS credentials were injected.

---

### 4️⃣ Find which ServiceAccount the repo-server uses

```bash
oc -n openshift-gitops get deploy cluster-gitops-repo-server -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
```

➡️ Output: `vplugin`

---

### 5️⃣ Check if that ServiceAccount has the correct IAM role annotation

```bash
oc -n openshift-gitops get sa vplugin -o yaml | grep eks.amazonaws.com/role-arn
```

➡️ Output confirmed annotation:

```
eks.amazonaws.com/role-arn: arn:aws:iam::730335292448:role/cpaas-qc1004-rosa-cpaas-secretsmanager-role-iam
```

✅ So IRSA was configured correctly — just not applied to the running pod.

---

### 6️⃣ Restart the repo-server pod to refresh credentials

```bash
oc -n openshift-gitops delete pod cluster-gitops-repo-server-b949bd5c5-xt82b
```

➡️ OpenShift automatically recreated the pod.

Then confirm new pod:

```bash
oc -n openshift-gitops get pods | grep repo-server
```

➡️ New pod appeared (e.g., `cluster-gitops-repo-server-b949bd5c5-fdh6w`).

---

### 7️⃣ Verify AWS environment variables again (fixed)

```bash
oc -n openshift-gitops exec cluster-gitops-repo-server-b949bd5c5-fdh6w -- env | grep AWS
```

✅ Output:

```
AWS_DEFAULT_REGION=ap-southeast-2
AWS_REGION=ap-southeast-2
AWS_ROLE_ARN=arn:aws:iam::730335292448:role/cpaas-qc1004-rosa-cpaas-secretsmanager-role-iam
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

This confirmed the IAM role was applied correctly.

---

### 8️⃣ Re-sync ArgoCD application

Re-sync the application from the ArgoCD UI:

1. Open the failing application.
2. Click **Sync → Synchronize**.
3. Sync completed successfully — AVP could now pull secrets from AWS Secrets Manager.

---

## ✅ Final Outcome

* The issue was due to an **outdated repo-server pod** missing IRSA credentials.
* The **ServiceAccount was already configured correctly.**
* **Deleting the repo-server pod** forced it to restart with the correct IAM Role attached.
* After restart, `argocd-vault-plugin` authenticated successfully with AWS.

---

## 🧠 Quick Recap

| Step | Action                        | Result                       |
| ---- | ----------------------------- | ---------------------------- |
| 1    | Verified missing AWS env vars | Confirmed no creds           |
| 2    | Checked ServiceAccount        | Correct IAM role present     |
| 3    | Restarted pod                 | New pod picked up IRSA creds |
| 4    | Re-synced app                 | AVP worked successfully      |

---

**Author:** Rakesh Pandyala
**Date:** November 2025
