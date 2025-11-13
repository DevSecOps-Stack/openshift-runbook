# Runbook: Updating EFS ID for ArgoCD EFS Chart in ROSA Cluster Build

## Overview

During ROSA cluster provisioning with Terraform, an EFS filesystem is automatically created. In the subsequent **cluster components phase**, ArgoCD is deployed and attempts to sync the EFS Helm chart. However, the chart contains a **hardcoded EFS FileSystem ID**, which differs from the newly provisioned EFS resource. This mismatch results in ArgoCD sync failures.

A manual update is required to replace the incorrect EFS ID with the correct one from AWS.

---

## Symptoms

* ArgoCD application for EFS shows **OutOfSync** or **Sync Error**.
* Error message usually references an **invalid EFS FileSystem ID**.
* Terraform created EFS ID differs from the EFS ID hardcoded in Git.

---

## Root Cause

The EFS ID used in the Git repository's EFS chart values is static, while Terraform generates a **new EFS ID at runtime** during ROSA cluster creation.

---

## Resolution Steps

### 1. Retrieve the Correct EFS ID

From AWS Console:

* Navigate to **EFS**.
* Identify the EFS created as part of the ROSA cluster build.
* Copy the **FileSystem ID**.

### 2. Update the EFS ID in Git

Edit the Helm chart values file:

```yaml
# values.yaml
efsFileSystemId: <correct-filesystem-id>
```

Commit and raise a PR with the updated EFS ID.

### 3. Merge PR and Trigger ArgoCD Sync

* Merge the PR to the main branch.
* Let ArgoCD auto-sync or manually click **Sync**.
* ArgoCD should move to **Synced** and **Healthy**.

---

## Validation

Run:

```bash
oc get storageclass efs-sc -oyaml
```

Ensure efsFileSystemId: <correct-filesystem-id> changed accordingly

Check ArgoCD:

* App state should be: **Synced / Healthy**

---

## Future Improvement (Optional)

Automate EFS ID propagation by:

* Creating a Terraform output
* Injecting it into GitOps workflow pipeline
* Using templating (Kustomize/Helm) instead of static IDs

---

## Notes

* This step is required **for every new cluster build** until automation is implemented.
* Avoid hardcoding cloud resource IDs in Git wherever possible.

