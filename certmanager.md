# Cert-Manager AWS PCA Integration - Incident Report & Resolution Guide

## Incident Summary

* **Date:** 06-Nov-2025
* **Environment:** ROSA (Red Hat OpenShift on AWS)
* **Namespaces Involved:**

  * `cert-manager`
  * `openshift-ingress`
* **Issue:** TLS certificate secret not created for the wildcard domain `*.apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com`
* **Root Cause:** `aws-privateca-issuer` pod failed to authenticate with AWS due to missing IAM token injection (IRSA not mounted properly).

---

## Initial Observation

* Certificate resource existed but status was **READY=False**.
* `oc describe certificate` showed:

  ```
  Message: The certificate request has failed to complete and will be retried: issuer is not ready
  Reason: Failed
  ```
* `AWSPCAClusterIssuer` existed but had no status section (not reconciled).
* `aws-privateca-issuer` logs showed authentication failure to AWS IMDS:

  ```
  failed to refresh cached credentials, no EC2 IMDS role found
  connect: connection refused (169.254.169.254)
  ```

---

## Root Cause Analysis

The `aws-privateca-issuer` pod could not assume the IAM role because:

* The ServiceAccount was not correctly annotated or mounted.
* The pod started before IRSA (IAM Role for Service Account) annotations were applied.
* Therefore, AWS environment variables (`AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`) were missing inside the container.

---

## Resolution Steps (with Commands)

### Step 1: Verify Cert-Manager Installation

```bash
oc get pods -n cert-manager
```

✅ All cert-manager components were running (`cert-manager`, `webhook`, `cainjector`, `aws-privateca-issuer`).

### Step 2: Verify Certificate Resource in `openshift-ingress`

```bash
oc get certificate -n openshift-ingress
oc describe certificate apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress
```

❌ Certificate existed but READY=False due to issuer not ready.

### Step 3: Verify AWSPCAClusterIssuer

```bash
oc get awspcaclusterissuer
oc describe awspcaclusterissuer np.au1.aws.anz.com
```

❌ No status section (controller not reconciling).

### Step 4: Check `aws-privateca-issuer` Pod Logs

```bash
oc logs -n cert-manager aws-privateca-issuer-xxxxx --tail=100
```

Error:

```
failed to refresh cached credentials, no EC2 IMDS role found
```

### Step 5: Check Pod’s ServiceAccount

```bash
oc get pod aws-privateca-issuer-xxxxx -n cert-manager -o jsonpath='{.spec.serviceAccountName}'
```

Output:

```
cert-manager
```

### Step 6: Verify ServiceAccount IAM Role Annotation

```bash
oc get serviceaccount cert-manager -n cert-manager -o yaml
```

✅ Annotation found:

```
eks.amazonaws.com/role-arn: arn:aws:iam::730335292448:role/cpaas-qc1004-rosa-cert-manager
```

### Step 7: Restart `aws-privateca-issuer` Pod

```bash
oc delete pod -n cert-manager -l app=aws-privateca-issuer
```

✅ New pod recreated with correct environment variables:

```bash
oc get pod -n cert-manager | grep aws-privateca-issuer
oc get pod <new-pod> -n cert-manager -o yaml | grep -A 10 "AWS_"
```

✅ Environment variables now visible:

```
AWS_ROLE_ARN: arn:aws:iam::730335292448:role/cpaas-qc1004-rosa-cert-manager
AWS_WEB_IDENTITY_TOKEN_FILE: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
AWS_REGION: ap-southeast-2
```

### Step 8: Confirm Successful Authentication

```bash
oc logs aws-privateca-issuer-xxxxx -n cert-manager --tail=50
```

✅ Output:

```
sts.GetCallerIdentity successful
account: 730335292448
```

### Step 9: Verify Issuer Readiness

```bash
oc describe awspcaclusterissuer np.au1.aws.anz.com
```

✅ Status:

```
Status:
  Conditions:
    Type: Ready
    Status: True
    Reason: Verified
    Message: Issuer verified
```

### Step 10: Reset Certificate Failure Backoff

Because cert-manager was backing off for 6 hours:

```bash
oc edit certificate apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress
```

Remove these fields:

```
failedIssuanceAttempts: 4
lastFailureTime: ...
```

If edit hangs, use:

```bash
oc patch certificate apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress --type=json -p='[{"op": "remove", "path": "/status/failedIssuanceAttempts"}]'
```

### Step 11: Force Reconciliation

```bash
oc annotate certificate apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress cert-manager.io/issue-temporary-certificate="true" --overwrite
oc annotate certificate apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress cert-manager.io/issue-temporary-certificate-
```

### Step 12: Delete and Recreate Certificate

If reconciliation didn’t trigger:

```bash
oc get certificate apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress -o yaml > /tmp/cert.yaml
oc delete certificate apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress
oc apply -f /tmp/cert.yaml
```

✅ New CertificateRequest created and succeeded:

```bash
oc get certificaterequest -n openshift-ingress
```

Output:

```
NAME                                           APPROVED   READY   ISSUER               AGE
apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com-1   True       True    np.au1.aws.anz.com   21s
```

✅ Secret automatically created:

```bash
oc get secret apps.cpaas-qc1004.cpaas.np.au1.aws.anz.com -n openshift-ingress
```

---

## Final Status

| Component            | Namespace         | Status                 |
| -------------------- | ----------------- | ---------------------- |
| cert-manager pods    | cert-manager      | ✅ Running              |
| aws-privateca-issuer | cert-manager      | ✅ Authenticated to AWS |
| AWSPCAClusterIssuer  | cluster-scope     | ✅ Ready: True          |
| Certificate          | openshift-ingress | ✅ Ready: True          |
| Secret               | openshift-ingress | ✅ Created              |

---

## Lessons Learned

1. Always confirm ServiceAccount IAM annotation exists before pod creation.
2. If the issuer is missing Status, check `aws-privateca-issuer` logs for authentication issues.
3. Restart the pod after updating IAM role annotations to refresh tokens.
4. If cert-manager enters backoff, delete and recreate the Certificate to reset the counter.

---

## Quick Recovery Checklist

```bash
oc project cert-manager
oc get pods -n cert-manager
oc logs -l app=aws-privateca-issuer -n cert-manager --tail=100
```

If AWS auth fails → Verify SA annotation and restart pod.

Then:

```bash
oc project openshift-ingress
oc get certificaterequest -n openshift-ingress
oc delete certificaterequest <name>
```

If Certificate is stuck → delete and recreate from backup YAML.

Verify final state:

```bash
oc get certificate -n openshift-ingress
oc get secret -n openshift-ingress
```

✅ **End of Report – Issue Resolved Successfully**
