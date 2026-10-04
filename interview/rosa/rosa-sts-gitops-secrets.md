# 🔐 ROSA Zero-Trust AWS STS & OIDC Web Identity Federation: The Complete Lock-and-Key Flow

A concise, copy-ready reference guide illustrating the exact cryptographic handshake and configuration manifests linking an OpenShift `ServiceAccount` to an AWS IAM Role via **IAM Roles for Service Accounts (IRSA)** for dynamic secret retrieval.

---

## ⚡ The 30-Second Soundbite

> *"In enterprise banking on ROSA, storing static AWS credentials (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) inside Kubernetes Secrets or Git repositories is strictly prohibited by security and compliance. Instead, we implement **Zero-Trust AWS STS and OIDC Web Identity Federation (IRSA)**. The OpenShift cluster's OIDC provider is registered with AWS IAM. When a pod like the Argo CD `repo-server` starts, OpenShift automatically projects a cryptographically signed, short-lived JSON Web Token (JWT) into the pod. The Argo CD Vault Plugin (AVP) presents this token to AWS STS via `AssumeRoleWithWebIdentity`. AWS STS validates the token's signature against the cluster's public keys on S3 and evaluates the IAM Role's trust policy conditions (`sub` and `aud`). Upon successful validation, STS issues temporary 1-hour credentials (`ASIA...`), enabling AVP to fetch runtime secrets directly from AWS Secrets Manager in-memory with zero plaintext passwords persisted anywhere."*

---

## 🏛️ 1. The Core Components & Exact Names

| Component | Location | Exact Name / Identifier | Purpose |
| :--- | :--- | :--- | :--- |
| **AWS IAM Role** | AWS IAM | `ROSA-SecretsManager-VaultPlugin-Role` | The cloud role holding permissions to read AWS Secrets Manager. |
| **OIDC Provider** | AWS IAM | `rh-oidc.s3.us-east-1.amazonaws.com/cluster-xxxx` | The registered Identity Provider (IdP) for your ROSA cluster. |
| **ServiceAccount** | OpenShift | `vplugin` (in namespace `openshift-gitops`) | The Kubernetes identity authorized to assume the AWS IAM Role. |
| **Workload Pod** | OpenShift | `cluster-gitops-repo-server-xxx` | The Argo CD repo-server pod executing the Vault Plugin. |
| **Secret Store** | AWS | AWS Secrets Manager (`enterprise/banking/*`) | Centralized encrypted secret store in the customer AWS account. |

---

## 📄 2. The Essential Manifests (The Lock & Key)

### A. AWS IAM Role Trust Policy (The "Who Can Assume Me?" Gate)
*In AWS IAM Console $\rightarrow$ Roles $\rightarrow$ `ROSA-SecretsManager-VaultPlugin-Role` $\rightarrow$ **Trust Relationships**:*

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

> [!IMPORTANT]
> The condition enforces **strict least privilege**:
> * `...:sub` ensures that **only** the `vplugin` ServiceAccount in the `openshift-gitops` namespace can assume this role. No other pod or namespace on the cluster can hijack it.
> * `...:aud` validates that the token audience was explicitly generated for AWS STS (`sts.amazonaws.com`).

---

### B. AWS IAM Permissions Policy (The "What Can I Do?" Policy)
*Attached to `ROSA-SecretsManager-VaultPlugin-Role` in AWS IAM:*

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSecretsManagerRead",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:enterprise/banking/*"
    }
  ]
}
```

---

### C. OpenShift `vplugin` ServiceAccount (The "Key")
*In OpenShift namespace `openshift-gitops`:*

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vplugin
  namespace: openshift-gitops
  annotations:
    # ◄── POINTS DIRECTLY TO THE AWS IAM ROLE ARN:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/ROSA-SecretsManager-VaultPlugin-Role"
```

---

### D. OpenShift Deployment Binding (The Workload Pod)
*In OpenShift namespace `openshift-gitops`:*

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-gitops-repo-server
  namespace: openshift-gitops
spec:
  replicas: 1
  template:
    spec:
      # ◄── POD USES THE ANNOTATED SERVICEACCOUNT:
      serviceAccountName: vplugin
      containers:
      - name: argocd-repo-server
        image: registry.redhat.io/openshift-gitops-1/argocd-rhel8:latest
```

---

### E. Manifest Template in Git (Zero Plaintext Secrets)
*In your application Git repository:*

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: payment-gateway-secret
  namespace: banking-payments
  annotations:
    avp.kubernetes.io/path: "enterprise/banking/payments"
type: Opaque
stringData:
  API_KEY: <path:enterprise/banking/payments#api_key>
  DB_PASSWORD: <path:enterprise/banking/payments#db_password>
```

---

## 🔄 3. The 5-Step Wire-Level Handshake & Secrets Fetch

```text
┌────────────────────────────────────────────────────────────────────────┐
│ 1. POD STARTUP & TOKEN PROJECTION                                      │
│    • 'cluster-gitops-repo-server' pod starts with 'vplugin' account.   │
│    • OpenShift OIDC webhook reads 'role-arn' annotation and mounts     │
│      an auto-rotated 1-hour cryptographic JSON Web Token (JWT) at:     │
│      /var/run/secrets/eks.amazonaws.com/serviceaccount/token           │
│    • Injects environment variables:                                    │
│      AWS_ROLE_ARN & AWS_WEB_IDENTITY_TOKEN_FILE                        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    │ 2. AssumeRoleWithWebIdentity Call
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 2. AWS STS INTERACTION                                                 │
│    • AWS SDK inside the pod calls AWS STS endpoint:                    │
│      AssumeRoleWithWebIdentity(                                        │
│        RoleArn="arn:aws:iam::...:role/ROSA-SecretsManager-VaultPlugin",│
│        WebIdentityToken="<JWT-Token-Content>"                          │
│      )                                                                 │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    │ 3. Cryptographic Verification
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 3. TOKEN SIGNATURE CHECK                                               │
│    • AWS STS contacts OpenShift's public JWKS endpoint (keys.json).    │
│    • Verifies that OpenShift's private key actually signed this token. │
│    • Verifies Audience == 'sts.amazonaws.com'.                         │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    │ 4. Trust Policy Match
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 4. IAM TRUST POLICY EVALUATION                                         │
│    • STS evaluates condition in IAM Role Trust Relationship:           │
│      "Does token Subject match                                         │
│       system:serviceaccount:openshift-gitops:vplugin?"                 │
│    • MATCH CONFIRMED! ✅                                               │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    │ 5. Temporary Credentials & In-Memory Hydration
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 5. REPO-SERVER FETCHES SECRETS                                         │
│    • STS returns temporary 1-hour credentials (starting with 'ASIA...').│
│    • Pod calls AWS Secrets Manager over private VPC endpoint.          │
│    • Argo CD Vault Plugin (AVP) replaces <path:...> placeholders       │
│      directly in-memory in RAM.                                        │
│    • Hydrated Secret manifest pushed to target cluster. Zero plaintext │
│      passwords ever enter Git or etcd unencrypted!                    │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 🚨 4. Production War Room: The `no EC2 IMDS role found` Fix

### Root Cause
If the ServiceAccount is missing the `eks.amazonaws.com/role-arn` annotation, or the webhook fails to project the token, the pod receives no JWT file. The AWS SDK falls back down its standard credentials chain to querying the worker node's **EC2 Instance Metadata Service (IMDS)** at `http://169.254.169.254`.

In an enterprise banking environment, container access to node IMDS is strictly blocked via `iptables` and AWS `http-tokens=required` (IMDSv2 hop limit = 1). The connection times out, throwing:

```text
EC2MetadataError: failed to refresh cached credentials, no EC2 IMDS role found
```

### Fast Remediation Sequence

```bash
# 1. Annotate the ServiceAccount with the IAM Role ARN
oc -n openshift-gitops annotate sa vplugin \
  eks.amazonaws.com/role-arn="arn:aws:iam::123456789012:role/ROSA-SecretsManager-VaultPlugin-Role" \
  --overwrite

# 2. Restart the deployment to trigger the OIDC webhook token injection
oc -n openshift-gitops rollout restart deploy/cluster-gitops-repo-server

# 3. Verify injected environment variables inside the new pod
oc -n openshift-gitops exec deploy/cluster-gitops-repo-server -- env | grep AWS
# Expected output:
# AWS_ROLE_ARN=arn:aws:iam::123456789012:role/ROSA-SecretsManager-VaultPlugin-Role
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token

# 4. Verify token presence and expiration claim
oc -n openshift-gitops exec deploy/cluster-gitops-repo-server -- \
  head -c 50 /var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

---

## 🎯 5. Senior Platform Engineer Rapid Q&A

### Q1: Why do we use OIDC Web Identity Federation instead of IAM Instance Profiles on worker nodes?
> **Answer:** 
> IAM Instance Profiles grant permissions to the **entire EC2 node**. Any pod scheduled on that node could potentially query the metadata service and assume those high-privilege credentials (violating multi-tenant isolation). OIDC Web Identity Federation (IRSA) provides **pod-level least privilege**: only the specific container mounting the projected `ServiceAccount` token can assume the role, preventing cross-tenant credential theft.

### Q2: How does token rotation work with STS IRSA?
> **Answer:**
> OpenShift's `kube-apiserver` projects the JWT token with a default lifespan (typically 1 hour). The `kubelet` automatically rotates this token on disk before it expires. The AWS SDK natively watches the token file path specified by `AWS_WEB_IDENTITY_TOKEN_FILE` and automatically calls `AssumeRoleWithWebIdentity` to refresh temporary AWS credentials before expiry, requiring zero application restarts.

### Q3: What happens if someone creates a ServiceAccount named `vplugin` in their personal namespace?
> **Answer:**
> The role assumption will be **denied by AWS STS**. The IAM Trust Policy condition strictly evaluates the full subject claim:
> `"rh-oidc...:sub": "system:serviceaccount:openshift-gitops:vplugin"`
> A ServiceAccount in `developer-sandbox` would have a subject of `system:serviceaccount:developer-sandbox:vplugin`, which fails string equality and is rejected immediately.
