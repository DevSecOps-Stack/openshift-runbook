🔐 ROSA Zero-Trust AWS STS & OIDC Web Identity Federation: The Complete Lock-and-Key Flow

A concise, copy-ready reference guide illustrating the exact cryptographic handshake and configuration manifests linking an OpenShift ServiceAccount to an AWS IAM Role via IAM Roles for Service Accounts (IRSA).

🏛️ 1. The Core Components & Exact Names
Component	Location	Exact Name	Purpose
AWS IAM Role	AWS IAM	ROSA-SecretsManager-VaultPlugin-Role	The cloud role holding permissions to read AWS Secrets Manager.
OIDC Provider	AWS IAM	rh-oidc.s3.us-east-1.amazonaws.com/cluster-xxxx	The registered Identity Provider (IdP) for your ROSA cluster.
ServiceAccount	OpenShift	vplugin (in openshift-gitops)	The Kubernetes identity authorized to assume the AWS IAM Role.
Workload Pod	OpenShift	cluster-gitops-repo-server-xxx	The Argo CD repo-server pod executing the Vault Plugin.
📄 2. The 3 Essential Manifests
A. AWS IAM Role Trust Policy (The "Who Can Assume Me?" Gate)

In AWS IAM Console 
→
→ Roles 
→
→ ROSA-SecretsManager-VaultPlugin-Role 
→
→ Trust Relationships:

json
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
B. AWS IAM Permissions Policy (The "What Can I Do?" Policy)

Attached to ROSA-SecretsManager-VaultPlugin-Role in AWS IAM:

json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:enterprise/banking/*"
    }
  ]
}
C. OpenShift vplugin ServiceAccount (The "Key")

In OpenShift namespace openshift-gitops:

yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vplugin
  namespace: openshift-gitops
  annotations:
    # ◄── POINTS DIRECTLY TO THE AWS IAM ROLE ARN:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/ROSA-SecretsManager-VaultPlugin-Role"
D. OpenShift Deployment Binding

In OpenShift namespace openshift-gitops:

yaml
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
        image: argocd:v2
🔄 3. The 5-Step Wire-Level Handshake
┌────────────────────────────────────────────────────────────────────────┐
│ 1. POD STARTUP:                                                        │
│    • 'cluster-gitops-repo-server' pod starts with 'vplugin' account.   │
│    • OpenShift OIDC webhook reads 'role-arn' annotation and mounts     │
│      an auto-rotated 1-hour cryptographic JSON Web Token (JWT) at:     │
│      /var/run/secrets/eks.amazonaws.com/serviceaccount/token           │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    │ 2. AssumeRoleWithWebIdentity Call
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 2. AWS STS INTERACTION:                                                │
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
│ 3. TOKEN SIGNATURE CHECK:                                              │
│    • AWS STS contacts OpenShift's public JWKS endpoint (keys.json).    │
│    • Verifies that OpenShift's private key actually signed this token. │
│    • Verifies Audience == 'sts.amazonaws.com'.                         │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    │ 4. Trust Policy Match
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 4. IAM TRUST POLICY EVALUATION:                                        │
│    • STS evaluates condition in IAM Role Trust Relationship:           │
│      "Does token Subject match                                         │
│       system:serviceaccount:openshift-gitops:vplugin?"                 │
│    • MATCH CONFIRMED! ✅                                               │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    │ 5. Temporary Credentials Issued
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ 5. REPO-SERVER FETCHES SECRETS:                                        │
│    • STS returns temporary 1-hour credentials (starting with 'ASIA...').│
│    • Pod uses credentials to read secret values from                   │
│      AWS Secrets Manager over AWS private network.                     │
│    • Zero static passwords exist anywhere in Git or etcd!             │
└────────────────────────────────────────────────────────────────────────┘
🚨 4. Production War Room: The no EC2 IMDS role found Fix
Root Cause

If the ServiceAccount is missing the eks.amazonaws.com/role-arn annotation, the pod receives no JWT token. The AWS SDK falls back to querying the worker node's EC2 Instance Metadata Service (IMDS) at http://169.254.169.254, which is strictly blocked for containers in enterprise banking, causing the crash.

Fast Remediation Sequence
bash
# 1. Annotate the ServiceAccount with the IAM Role ARN
oc -n openshift-gitops annotate sa vplugin \
  eks.amazonaws.com/role-arn="arn:aws:iam::123456789012:role/ROSA-SecretsManager-VaultPlugin-Role" \
  --overwrite
# 2. Restart the deployment to inject the projected JWT token
oc -n openshift-gitops rollout restart deploy/cluster-gitops-repo-server
# 3. Verify injected environment variables inside the new pod
oc -n openshift-gitops exec deploy/cluster-gitops-repo-server -- env | grep AWS
# Expected output:
# AWS_ROLE_ARN=arn:aws:iam::...:role/ROSA-SecretsManager-VaultPlugin-Role
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
