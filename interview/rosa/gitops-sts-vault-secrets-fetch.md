# Zero-Trust AWS STS & OIDC Web Identity Federation in ROSA

A platform engineering guide to IAM Roles for Service Accounts (IRSA), OpenID Connect (OIDC) identity provider federation, temporary cryptographic credential rotation, and production troubleshooting for ROSA clusters.

---

## ⚡ The 30-Second Elevator Pitch

> *"In regulated enterprise banking, hardcoding static `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` inside Kubernetes Secrets is strictly prohibited due to key sprawl, lack of automatic rotation, and severe credential leak risks. **ROSA enforces Zero-Trust security using AWS Security Token Service (STS) and OpenID Connect (OIDC) Web Identity Federation (IRSA)**. Each OpenShift cluster acts as an OIDC Identity Provider (IdP) publishing a public JSON Web Key Set (JWKS). When a pod needs to access AWS resources (like AWS Secrets Manager or EFS), it mounts a short-lived cryptographic JSON Web Token (JWT) issued by OpenShift. The AWS SDK exchanges this token with AWS STS via `AssumeRoleWithWebIdentity`, which verifies the token signature against OpenShift's JWKS and returns temporary, auto-rotated 1-hour IAM session credentials. Static secrets are 100% eliminated."*

---

## 🔐 1. Why Static AWS Secrets are Forbidden in Banking

```
THE DANGEROUS OLD WAY (Static IAM User Keys):
[ Developer ] ──► Stores AWS_ACCESS_KEY_ID & AWS_SECRET_ACCESS_KEY in K8s Secret
                    │
                    ├── ❌ Keys never expire (valid until manually deleted)
                    ├── ❌ If secret leaks, attacker has permanent backdoor into AWS
                    └── ❌ No automated rotation, fails enterprise compliance audits

THE ZERO-TRUST CLOUD-NATIVE WAY (AWS STS + OIDC):
[ Pod ] ──(Mounts 1-Hour JWT Token)──► [ AWS STS ] ──► Assumes IAM Role (Temporary Keys)
                    │
                    ├── ✅ Zero static secrets stored in Kubernetes etcd
                    ├── ✅ Tokens auto-expire and rotate every 60 minutes
                    └── ✅ Least-privilege IAM policies bound directly to ServiceAccount
```

---

## 🔄 2. The Cryptographic Handshake (Step-by-Step Flow)

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                               OpenShift Worker Node                                    │
│                                                                                        │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │ Application Pod (e.g. argocd-repo-server / avp)                                │   │
│   │                                                                                │   │
│   │ 1. Mounts projected ServiceAccount token (JWT) at:                             │   │
│   │    /var/run/secrets/eks.amazonaws.com/serviceaccount/token                     │   │
│   │                                                                                │   │
│   │ 2. Reads Environment Variables:                                                │   │
│   │    AWS_ROLE_ARN=arn:aws:iam::123456789:role/ROSA-SecretsManager-Role           │   │
│   │    AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/.../token                      │   │
│   └───────────────────────────────────┬────────────────────────────────────────────┘   │
└───────────────────────────────────────┼────────────────────────────────────────────────┘
                                        │
                                        │ 3. Calls AWS STS API:
                                        │    AssumeRoleWithWebIdentity(RoleArn, JWT)
                                        ▼
                        ┌───────────────────────────────┐
                        │    AWS STS (Token Service)    │
                        └───────────────┬───────────────┘
                                        │
                                        │ 4. "Did OpenShift actually sign this JWT?"
                                        │    Fetches Public Keys from OIDC Provider:
                                        ▼    https://<rh-oidc-endpoint>/.well-known/jwks.json
                        ┌───────────────────────────────┐
                        │   OpenShift OIDC Provider     │
                        │   (Hosted in S3 / CloudFront) │
                        └───────────────┬───────────────┘
                                        │
                                        │ 5. Validates cryptographic signature & audience:
                                        │    Audience: 'sts.amazonaws.com'
                                        │    Subject: 'system:serviceaccount:<ns>:<sa-name>'
                                        ▼
                        ┌───────────────────────────────┐
                        │    AWS STS (Token Service)    │
                        └───────────────┬───────────────┘
                                        │
                                        │ 6. Issues Temporary 1-Hour AWS Credentials:
                                        │    • AWS_ACCESS_KEY_ID (Starts with ASIA...)
                                        │    • AWS_SECRET_ACCESS_KEY
                                        │    • AWS_SESSION_TOKEN
                                        ▼
                        ┌───────────────────────────────┐
                        │       Application Pod         │
                        │ (Accesses AWS Secrets Manager)│
                        └───────────────────────────────┘
```

---

## 🛠️ 3. How to Configure IRSA in OpenShift Manifests

### Step 1: Create the AWS IAM Role with OIDC Trust Policy
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/cluster-xxxx"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "rh-oidc.s3.us-east-1.amazonaws.com/cluster-xxxx:sub": "system:serviceaccount:openshift-gitops:vplugin",
          "rh-oidc.s3.us-east-1.amazonaws.com/cluster-xxxx:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### Step 2: Annotate the Kubernetes ServiceAccount
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vplugin
  namespace: openshift-gitops
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/ROSA-SecretsManager-VaultPlugin-Role"
```

---

## 💥 4. Production War Room: The Infamous IMDS Error

### The Incident:
Your Argo CD repo-server or application pod fails with this exact error:
```text
failed to generate manifest: error generating manifests: 
failed to refresh cached credentials, no EC2 IMDS role found
```

### Why Did This Happen? (The Root Cause):
1. The container attempted to contact AWS Secrets Manager.
2. The pod did **NOT** receive the injected AWS STS environment variables (`AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`).
3. As a desperate fallback, the AWS SDK looked for an old-school **EC2 Instance Metadata Service (IMDS)** role (`169.254.169.254`).
4. In modern enterprise Kubernetes (and ROSA), IMDS access from containers is strictly disabled/blocked for security.
5. Result: The AWS SDK crashed with `no EC2 IMDS role found`!

### The Pro Troubleshooting Protocol:
```bash
# Step 1: Check if AWS environment variables exist inside the running pod:
oc -n openshift-gitops exec <pod-name> -- env | grep AWS

# If output is empty -> The OIDC webhook did NOT inject credentials!

# Step 2: Identify which ServiceAccount the pod is using:
oc -n openshift-gitops get deploy <deployment-name> -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'

# Step 3: Check if the ServiceAccount has the AWS Role ARN annotation:
oc -n openshift-gitops get sa <sa-name> -o yaml | grep role-arn

# Step 4: The Fix: Annotate the ServiceAccount with the correct IAM Role:
oc -n openshift-gitops annotate sa <sa-name> \
  eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/<role-name> --overwrite

# Step 5: Restart the Deployment to trigger pod recreation and token injection:
oc -n openshift-gitops rollout restart deploy/<deployment-name>
```

---

## 🎯 5. Senior Platform Engineer Interview Q&A

### Q1: How does AWS STS determine that a request from an OpenShift pod is legitimate?
> **Answer:** 
> When ROSA is provisioned, an OIDC Identity Provider (IdP) is registered in AWS IAM containing the cluster’s public OIDC issuer URL. When an application pod calls `sts:AssumeRoleWithWebIdentity`, it supplies a signed JSON Web Token (JWT) issued by the OpenShift ServiceAccount token signer. AWS STS retrieves the cluster's public signing keys from OpenShift's public JWKS endpoint (`/.well-known/jwks.json`), cryptographically verifies the token signature, checks that the token audience matches `sts.amazonaws.com`, and confirms the `sub` claim matches the authorized `system:serviceaccount:<namespace>:<name>` condition in the IAM Role's trust policy.

### Q2: What causes the error "no EC2 IMDS role found" in a container running on ROSA?
> **Answer:** 
> That error indicates that the AWS SDK failed all primary authentication mechanisms (environment variables, web identity tokens) and fell back to querying the EC2 Instance Metadata Service (`http://169.254.169.254`) on the underlying worker node. In enterprise ROSA clusters, worker nodes either have IMDSv2 enforced with a hop limit of 1 (blocking pods) or have IMDS access blocked via network policies. The root cause is almost always a missing or misconfigured `eks.amazonaws.com/role-arn` annotation on the pod's `ServiceAccount`, or an un-restarted pod that hasn't received the projected token volume.
