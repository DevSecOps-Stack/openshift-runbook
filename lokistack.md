# OpenShift Operator Installation Troubleshooting Runbook

## Document Information
- **Created By**: pandyalr_anz
- **Date**: 2025-11-07
- **Incident**: Loki and Cluster Logging Operator Installation Failure
- **Resolution Time**: ~4 hours of pod stuck + troubleshooting

---

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Understanding the Components](#understanding-the-components)
3. [Why Loki and Logging are Related](#why-loki-and-logging-are-related)
4. [Root Cause Analysis](#root-cause-analysis)
5. [Incident Timeline](#incident-timeline)
6. [Detailed Troubleshooting Steps](#detailed-troubleshooting-steps)
7. [Prevention and Best Practices](#prevention-and-best-practices)
8. [Quick Reference Commands](#quick-reference-commands)

---

## Executive Summary

### Problem Statement
- **Symptom**: Loki operator pod stuck in `ContainerCreating` state for over 4 hours
- **Impact**: Logging infrastructure unavailable, ArgoCD applications showing Degraded status
- **Root Cause**: Orphaned ClusterServiceVersions (CSVs) causing OLM constraint conflicts
- **Affected Applications**: 
  - `cpaas-d1-operator-loki`
  - `cpaas-d1-cluster-logging`

### Quick Fix (If you know the issue)
1. Identify orphaned CSV
2. Delete the orphaned CSV
3. Approve pending InstallPlan
4. Verify operator pods are running
5. Sync ArgoCD application

---

## Understanding the Components

### What is OLM (Operator Lifecycle Manager)?

**OLM** is a component of OpenShift/Kubernetes that manages the lifecycle of operators. Think of it as a "package manager for operators."

**Key Responsibilities:**
- Installing operators
- Managing operator upgrades
- Resolving dependencies between operators
- Ensuring only compatible versions run together

**OLM Workflow:**
```
Subscription → OLM → InstallPlan → CSV → Operator Deployment
```

### What is a CSV (ClusterServiceVersion)?

**CSV** is a YAML manifest that describes an operator installation.

**Key Information in CSV:**
- Operator version
- Required permissions (RBAC)
- Dependencies on other operators
- Deployment specifications
- CustomResourceDefinitions (CRDs) it provides

**Example CSV naming:**
```
loki-operator.v6.2.3
├── loki-operator = Operator name
└── v6.2.3 = Version
```

**CSV Lifecycle States:**
- `Pending`: Installation starting
- `Installing`: Resources being created
- `Succeeded`: Operator running successfully
- `Failed`: Installation failed
- `Replacing`: Being upgraded to newer version

### What is an InstallPlan?

**InstallPlan** is OLM's execution plan for installing or upgrading an operator.

**Key Information:**
- Which CSV to install
- Required resources (CRDs, deployments, etc.)
- Approval status (Manual vs Automatic)

**InstallPlan Approval Modes:**

**Automatic:**
```yaml
spec:
  installPlanApproval: Automatic
```
- OLM automatically approves and installs
- Good for: Non-production, testing environments
- Risk: Unexpected upgrades

**Manual:**
```yaml
spec:
  installPlanApproval: Manual
```
- Requires human approval before installation
- Good for: Production environments
- Benefit: Control over when operators upgrade

### What is a Subscription?

**Subscription** links an operator to a catalog source and declares the desired version.

**Key Fields:**
```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.0              # Update channel
  name: loki-operator               # Operator name
  source: redhat-operators          # Catalog source
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual       # Manual or Automatic
  startingCSV: loki-operator.v6.2.3 # Specific version
```

**Relationship Diagram:**
```
CatalogSource (redhat-operators)
    ↓
Subscription (declares desired operator)
    ↓
OLM (processes subscription)
    ↓
InstallPlan (execution plan)
    ↓ (after approval)
CSV (operator installation manifest)
    ↓
Operator Pods (running operator)
```

### What is ArgoCD and Its Role?

**ArgoCD** is a GitOps continuous delivery tool for Kubernetes.

**In Our Context:**
- Manages operator subscriptions as code
- Monitors operator health status
- Can automatically sync/approve InstallPlans (via jobs)
- Provides visibility into deployment status

**ArgoCD Application Components:**
- **Sync Status**: Whether cluster state matches Git
- **Health Status**: Whether resources are healthy
- **Sync Waves**: Order of resource deployment

---

## Why Loki and Logging are Related

### Architecture Overview

```
OpenShift Cluster
    ↓
Logging Collection (Vector/Fluentd)
    ↓
Log Storage (LokiStack)
    ↓
Log Querying (Loki Query Frontend)
    ↓
UI Visualization (OpenShift Console Plugin)
```

### Component Dependencies

**1. Loki Operator**
- **Purpose**: Manages LokiStack instances
- **Provides**: 
  - LokiStack CRD (Custom Resource Definition)
  - Loki deployment and configuration
  - Storage management
- **Namespace**: `openshift-operators-redhat` (cluster-scoped)

**2. Cluster Logging Operator**
- **Purpose**: Manages log collection and forwarding
- **Depends On**: 
  - Loki Operator (for LokiStack CRD)
  - LokiStack instance (for log storage)
- **Provides**:
  - ClusterLogForwarder CRD
  - Vector/Fluentd daemonset for log collection
  - Log routing configuration
- **Namespace**: `openshift-logging`

**3. LokiStack Custom Resource**
- **Created By**: Cluster Logging Operator
- **Managed By**: Loki Operator
- **Purpose**: Actual log storage backend

### Why Order Matters

**Correct Installation Order:**
```
1. Loki Operator (provides LokiStack CRD)
   ↓
2. Cluster Logging Operator (depends on LokiStack CRD)
   ↓
3. LokiStack CR (creates log storage)
   ↓
4. ClusterLogForwarder CR (configures log collection)
```

**What Happens if Order is Wrong:**
- Cluster Logging can't find LokiStack CRD → Installation fails
- No LokiStack → Logs can't be stored
- Log collectors have nowhere to send logs

---

## Root Cause Analysis

### The Problem: OLM Constraint Conflicts

**What is a Constraint Conflict?**

OLM enforces rules to prevent conflicts:
1. **One Active CSV per Operator**: Only one version of an operator can be active
2. **Subscription Ownership**: CSV must be managed by a subscription
3. **Upgrade Path**: New versions must properly replace old versions

**Our Specific Issue:**

**Loki Operator Conflict:**
```
Existing: CSV cluster-logging.v6.2.3 (orphaned, in Failed state)
Desired:  CSV cluster-logging.v6.2.3 (from subscription)
Conflict: Two CSVs with same version, first is orphaned
Result:   OLM refuses to install, ConfigMap not created
```

**Cluster Logging Operator Conflict:**
```
Existing: CSV cluster-logging.v6.2.6 (orphaned, Succeeded but not managed)
Desired:  CSV cluster-logging.v6.2.3 (from subscription)
Conflict: Existing CSV not managed by current subscription
Result:   OLM constraint: "constraints not satisfiable"
```

### How Orphaned CSVs Occur

**Common Scenarios:**

**1. Failed Previous Installation**
```bash
# Sequence of events:
1. InstallPlan created → CSV installed
2. Installation fails (resource conflict, permissions, etc.)
3. Subscription deleted or modified
4. CSV remains in cluster (orphaned)
5. New subscription created
6. OLM sees existing CSV → Conflict!
```

**2. Manual Operator Deletion**
```bash
# Wrong way to uninstall:
oc delete deployment loki-operator  # Only deletes deployment
# CSV still exists → Orphaned
```

**3. ArgoCD Sync Issues**
```bash
# Sequence:
1. ArgoCD deploys subscription
2. InstallPlan not approved (Manual approval)
3. ArgoCD times out, deletes resources
4. CSV partially installed → Orphaned
5. ArgoCD retries → Conflict
```

### Why ConfigMap Was Missing

**Normal Flow:**
```
Subscription created
    ↓
OLM creates InstallPlan
    ↓
InstallPlan approved
    ↓
OLM installs CSV
    ↓
CSV creates:
    - Deployment
    - ConfigMap (loki-operator-manager-config)
    - ServiceAccount
    - RBAC rules
    ↓
Pod starts with ConfigMap mounted
```

**Broken Flow (Our Case):**
```
Subscription exists
    ↓
OLM detects orphaned CSV
    ↓
OLM refuses to create new InstallPlan
    ↓
No CSV installation occurs
    ↓
No ConfigMap created
    ↓
Pod stuck waiting for ConfigMap mount
```

**Why Pod Couldn't Start:**
```yaml
# Pod spec references ConfigMap
spec:
  containers:
  - name: manager
    volumeMounts:
    - name: manager-config
      mountPath: /etc/manager
  volumes:
  - name: manager-config
    configMap:
      name: loki-operator-manager-config  # Missing!
```

Kubernetes keeps pod in `ContainerCreating` until all volume mounts are available.

---

## Incident Timeline

### Initial State (T-0)
```
Time: 2025-11-07 11:04:59 UTC
Status: ArgoCD deploys subscriptions
Issue: Orphaned CSVs already exist in cluster
```

### T+4 hours: Problem Discovered
```
Symptom: Loki operator pod stuck in ContainerCreating
Command: oc get pods -n openshift-operators-redhat
Output: loki-operator-controller-manager-xyz  0/2  ContainerCreating  0  4h
```

### Troubleshooting Phase

**Step 1: Check Pod Events (T+4h 5m)**
```bash
$ oc describe pod loki-operator-controller-manager-xyz -n openshift-operators-redhat
Events:
  Warning  FailedMount  4m (x100 over 4h)  kubelet  
    MountVolume.SetUp failed for volume "manager-config": 
    configmap "loki-operator-manager-config" not found
```
**Discovery**: ConfigMap missing

**Step 2: Check CSV Status (T+4h 10m)**
```bash
$ oc get csv -n openshift-operators-redhat | grep loki
loki-operator.v6.2.3  Loki Operator  6.2.3  loki-operator.v6.2.2  Failed
```
**Discovery**: CSV in Failed state

**Step 3: Check Subscription (T+4h 15m)**
```bash
$ oc get subscription loki-operator -n openshift-operators-redhat -o yaml
status:
  conditions:
  - message: 'constraints not satisfiable: @existing/openshift-operators-redhat//loki-operator.v6.2.3...'
    reason: ConstraintsNotSatisfiable
    status: "True"
    type: ResolutionFailed
```
**Discovery**: OLM constraint conflict due to orphaned CSV

**Step 4: Resolution (T+4h 20m)**
```bash
# Delete orphaned CSV
$ oc delete csv loki-operator.v6.2.3 -n openshift-operators-redhat

# Wait for new InstallPlan
$ oc get installplan -n openshift-operators-redhat
NAME            CSV                   APPROVAL   APPROVED
install-abc123  loki-operator.v6.2.3  Manual     false

# Approve InstallPlan
$ oc patch installplan install-abc123 -n openshift-operators-redhat \
    --type merge --patch '{"spec":{"approved":true}}'

# Verify CSV
$ oc get csv -n openshift-operators-redhat | grep loki
loki-operator.v6.2.3  Loki Operator  6.2.3  loki-operator.v6.2.2  Succeeded

# Verify ConfigMap created
$ oc get configmap loki-operator-manager-config -n openshift-operators-redhat
NAME                           DATA   AGE
loki-operator-manager-config   1      91s

# Verify pod running
$ oc get pods -n openshift-operators-redhat | grep loki
loki-operator-controller-manager-8675699dc-8zrcf  2/2  Running  0  111s
```

### T+4h 30m: Repeat for Cluster Logging
Same process for cluster-logging operator with version conflict (v6.2.6 vs v6.2.3)

### T+4h 45m: Resolution Complete
```
✅ loki-operator: Healthy & Synced
✅ cluster-logging: Healthy & Synced
✅ ArgoCD applications: All green
```

---

## Detailed Troubleshooting Steps

### Phase 1: Initial Triage

#### Step 1: Identify the Problem

**Check ArgoCD Application Status**
```bash
# List all ArgoCD applications
oc get application -n openshift-gitops

# Check specific application
oc get application cpaas-d1-operator-loki -n openshift-gitops -o yaml

# Look for:
# - status.health.status: Degraded
# - status.sync.status: OutOfSync
# - status.conditions: Error messages
```

**Check Pod Status**
```bash
# List pods in operator namespace
oc get pods -n openshift-operators-redhat

# Look for:
# - Pods stuck in ContainerCreating
# - Pods with CrashLoopBackOff
# - Pods with low Ready count (e.g., 0/2)

# Common namespaces:
# - openshift-operators-redhat (Red Hat operators)
# - openshift-operators (community operators)
# - openshift-logging (logging operators)
```

#### Step 2: Check Pod Events

```bash
# Describe the stuck pod
oc describe pod <pod-name> -n <namespace>

# Focus on Events section at bottom
# Common issues:
# - FailedMount: Missing ConfigMap or Secret
# - ImagePullBackOff: Image not accessible
# - CrashLoopBackOff: Container failing to start
```

**Example Output Analysis:**
```
Events:
  Type     Reason       Age                   From     Message
  ----     ------       ----                  ----     -------
  Warning  FailedMount  5m (x100 over 4h)     kubelet  MountVolume.SetUp failed for volume "manager-config": configmap "loki-operator-manager-config" not found
```

**Interpretation:**
- `FailedMount`: Volume mount issue
- `x100 over 4h`: Been retrying for 4 hours (definitely stuck)
- `configmap "loki-operator-manager-config" not found`: Missing ConfigMap

#### Step 3: Check CSV Status

```bash
# List all CSVs in namespace
oc get csv -n <namespace>

# Check specific CSV
oc get csv <csv-name> -n <namespace> -o yaml

# Look for:
# - phase: Failed, Pending, Installing
# - status.conditions: Error messages
# - status.reason: Why it failed
```

**CSV Phase Meanings:**
| Phase | Meaning | Action |
|-------|---------|--------|
| Succeeded | Healthy | No action needed |
| Installing | In progress | Wait or investigate if stuck |
| Pending | Waiting for resources | Check dependencies |
| Failed | Installation failed | Check status.reason |
| Replacing | Being upgraded | Normal during upgrade |

**Example Failed CSV:**
```yaml
status:
  phase: Failed
  reason: ConstraintsNotSatisfiable
  message: "clusterserviceversion loki-operator.v6.2.3 exists and is not referenced by a subscription"
```

### Phase 2: Diagnose OLM Issues

#### Step 4: Check Subscription Status

```bash
# Get subscription
oc get subscription <subscription-name> -n <namespace> -o yaml

# Key fields to check:
# - spec.startingCSV: Desired version
# - spec.installPlanApproval: Manual or Automatic
# - status.conditions: Error messages
# - status.currentCSV: Currently installed version
# - status.installplan: Reference to InstallPlan
```

**Healthy Subscription Example:**
```yaml
status:
  conditions:
  - type: CatalogSourcesUnhealthy
    status: "False"  # Good! Catalogs are healthy
  currentCSV: loki-operator.v6.2.3
  installedCSV: loki-operator.v6.2.3
  installplan:
    name: install-abc123
```

**Unhealthy Subscription Example:**
```yaml
status:
  conditions:
  - type: ResolutionFailed
    status: "True"  # Bad! Dependency resolution failed
    message: "constraints not satisfiable: ..."
```

**Common Error Messages:**

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `constraints not satisfiable` | Orphaned CSV or version conflict | Delete orphaned CSV |
| `CatalogSourcesUnhealthy: True` | Catalog pod not running | Check catalog source pods |
| `no operators found in channel` | Wrong channel name | Check available channels |
| `InstallPlan not found` | Manual approval needed | Approve InstallPlan |

#### Step 5: Check InstallPlans

```bash
# List InstallPlans
oc get installplan -n <namespace>

# Check specific InstallPlan
oc get installplan <installplan-name> -n <namespace> -o yaml

# Key fields:
# - spec.approved: true/false
# - spec.clusterServiceVersionNames: CSV to install
# - status.phase: Complete, Failed, Installing
# - status.conditions: Error messages
```

**InstallPlan Status:**
```bash
$ oc get installplan -n openshift-operators-redhat
NAME            CSV                   APPROVAL   APPROVED
install-abc123  loki-operator.v6.2.3  Manual     false
```

**Interpretation:**
- `APPROVAL: Manual` → Requires human approval
- `APPROVED: false` → Waiting for approval
- Action: Approve the InstallPlan

#### Step 6: Check for Orphaned CSVs

**What to Look For:**
```bash
# Get all CSVs
oc get csv -n <namespace>

# Check which CSVs are referenced by subscriptions
oc get subscription -n <namespace> -o yaml | grep currentCSV

# Orphaned CSV indicators:
# 1. CSV exists but not in any subscription's currentCSV
# 2. CSV phase is Failed
# 3. Multiple versions of same operator
```

**Example:**
```bash
$ oc get csv -n openshift-logging
NAME                        PHASE       AGE
cluster-logging.v6.2.3      Failed      2d   ← Orphaned!
cluster-logging.v6.2.6      Succeeded   1d   ← Also orphaned!

$ oc get subscription -n openshift-logging -o yaml | grep currentCSV
currentCSV: ""  ← No CSV referenced!
```

**Red Flags:**
- Multiple CSVs for same operator
- CSV with Failed phase
- Subscription with empty `currentCSV`

### Phase 3: Resolution

#### Step 7: Delete Orphaned CSV

**⚠️ CAUTION: This will temporarily disrupt the operator**

```bash
# Identify the orphaned CSV
oc get csv -n <namespace>

# Delete orphaned CSV
oc delete csv <csv-name> -n <namespace>

# Verify deletion
oc get csv -n <namespace>
```

**What Happens Next:**
1. OLM detects subscription without CSV
2. OLM creates new InstallPlan
3. InstallPlan waits for approval (if Manual)

**Wait Time:**
- Usually 5-30 seconds for InstallPlan to appear
- Check with: `oc get installplan -n <namespace>`

#### Step 8: Approve InstallPlan

**For Manual Approval:**
```bash
# Check for pending InstallPlan
oc get installplan -n <namespace>

# Approve the InstallPlan
oc patch installplan <installplan-name> -n <namespace> \
    --type merge \
    --patch '{"spec":{"approved":true}}'

# Verify approval
oc get installplan <installplan-name> -n <namespace>
```

**Monitor Installation:**
```bash
# Watch InstallPlan status
oc get installplan <installplan-name> -n <namespace> -w

# Expected phases:
# - Installing → Complete

# Check CSV creation
oc get csv -n <namespace> -w
# Expected: CSV appears in Installing, then Succeeded
```

#### Step 9: Verify Resolution

**Check CSV Status:**
```bash
oc get csv -n <namespace>
# Expected: phase should be "Succeeded"
```

**Check Required Resources:**
```bash
# ConfigMaps
oc get configmap -n <namespace> | grep <operator-name>

# Deployments
oc get deployment -n <namespace> | grep <operator-name>

# Pods
oc get pods -n <namespace> | grep <operator-name>
# Expected: Running with all containers ready (e.g., 2/2)
```

**Check Subscription Status:**
```bash
oc get subscription <subscription-name> -n <namespace> -o yaml
# Check:
# - status.currentCSV matches spec.startingCSV
# - status.conditions shows no errors
```

#### Step 10: Sync ArgoCD Application

**From CLI:**
```bash
# Sync application
argocd app sync <application-name>

# Check sync status
argocd app get <application-name>

# Or using oc
oc get application <application-name> -n openshift-gitops
```

**From UI:**
1. Navigate to ArgoCD UI
2. Find your application
3. Click "SYNC" button
4. Wait for sync to complete
5. Verify Health: Healthy, Sync: Synced

**Verify Final State:**
```bash
# Check application health
oc get application <application-name> -n openshift-gitops \
    -o jsonpath='{.status.health.status}'
# Expected: Healthy

# Check sync status
oc get application <application-name> -n openshift-gitops \
    -o jsonpath='{.status.sync.status}'
# Expected: Synced
```

---

## Prevention and Best Practices

### 1. Operator Installation Best Practices

**Use Proper Uninstallation Procedure:**
```bash
# Correct way to uninstall operator:

# Step 1: Delete operator-managed resources
oc delete <custom-resources> -n <namespace>

# Step 2: Delete subscription
oc delete subscription <subscription-name> -n <namespace>

# Step 3: Delete CSV (will be auto-deleted usually)
oc delete csv <csv-name> -n <namespace>

# Step 4: Delete operator group (if no other operators)
oc delete operatorgroup <operatorgroup-name> -n <namespace>

# Step 5: Clean up namespace (if dedicated to operator)
oc delete namespace <namespace>
```

**❌ DON'T DO THIS:**
```bash
# This leaves orphaned CSVs!
oc delete deployment <operator-deployment>
oc delete namespace <namespace>  # Without cleaning subscriptions
```

### 2. Managing InstallPlan Approvals

**Choose Appropriate Approval Mode:**

| Environment | Recommendation | Reason |
|-------------|----------------|--------|
| Development | Automatic | Fast iterations, easy testing |
| Staging | Manual | Test before production |
| Production | Manual | Control upgrade timing |

**Automatic Approval:**
```yaml
spec:
  installPlanApproval: Automatic
```
- Pros: Hands-off, automatic upgrades
- Cons: Surprise breaking changes

**Manual Approval:**
```yaml
spec:
  installPlanApproval: Manual
```
- Pros: Control over upgrades, test in lower env first
- Cons: Requires monitoring and manual action

**ArgoCD Integration for Manual Approval:**
```yaml
# Use installplan-approver job in ArgoCD
apiVersion: batch/v1
kind: Job
metadata:
  name: installplan-approver
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/sync-wave: "1"
spec:
  template:
    spec:
      serviceAccountName: installplan-approver
      containers:
      - name: approve
        image: registry.redhat.io/openshift4/ose-cli:latest
        command:
        - /bin/bash
        - -c
        - |
          #!/bin/bash
          # Wait for InstallPlan
          sleep 10
          # Find unapproved InstallPlans
          for plan in $(oc get installplan -n ${NAMESPACE} -o name); do
            approved=$(oc get ${plan} -n ${NAMESPACE} -o jsonpath='{.spec.approved}')
            if [ "${approved}" == "false" ]; then
              echo "Approving ${plan}"
              oc patch ${plan} -n ${NAMESPACE} --type merge -p '{"spec":{"approved":true}}'
            fi
          done
      restartPolicy: Never
```

### 3. Monitoring OLM Health

**Regular Health Checks:**
```bash
#!/bin/bash
# check-olm-health.sh

NAMESPACE=$1

echo "=== Checking OLM Health in ${NAMESPACE} ==="

echo -e "\n1. Subscriptions:"
oc get subscription -n ${NAMESPACE}

echo -e "\n2. CSVs:"
oc get csv -n ${NAMESPACE}

echo -e "\n3. InstallPlans:"
oc get installplan -n ${NAMESPACE}

echo -e "\n4. Failed CSVs:"
oc get csv -n ${NAMESPACE} --field-selector=status.phase==Failed

echo -e "\n5. Subscription Issues:"
oc get subscription -n ${NAMESPACE} -o json | \
  jq '.items[] | select(.status.conditions[]? | select(.type=="ResolutionFailed" and .status=="True")) | .metadata.name'

echo -e "\n6. Pending InstallPlans:"
oc get installplan -n ${NAMESPACE} -o json | \
  jq '.items[] | select(.spec.approved==false) | .metadata.name'
```

**Usage:**
```bash
chmod +x check-olm-health.sh
./check-olm-health.sh openshift-operators-redhat
```

### 4. ArgoCD Configuration Best Practices

**Sync Waves for Proper Ordering:**
```yaml
# 1. Namespace (wave 0)
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"

# 2. OperatorGroup (wave 0)
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"

# 3. Subscription (wave 1)
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"

# 4. InstallPlan Approver Job (wave 1)
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/sync-wave: "1"

# 5. Custom Resources (wave 2)
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"
```

**Health Check Configuration:**
```yaml
# In ArgoCD Application
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  ignoreDifferences:
  - group: operators.coreos.com
    kind: Subscription
    jsonPointers:
    - /status
  # Allow time for operator to become ready
  syncPolicy:
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### 5. Version Pinning Strategy

**Pin Specific Versions in Production:**
```yaml
# Good: Specific version
spec:
  channel: stable-6.2
  startingCSV: loki-operator.v6.2.3
  installPlanApproval: Manual

# Risky: No version pin
spec:
  channel: stable-6.2
  # No startingCSV - gets latest in channel
  installPlanApproval: Automatic  # Auto-upgrades!
```

**Version Upgrade Process:**
1. Test new version in dev/staging
2. Update `startingCSV` in Git
3. Commit and push
4. ArgoCD syncs → Creates InstallPlan
5. Approve InstallPlan (if Manual)
6. Verify upgrade successful
7. Repeat for production

---

## Quick Reference Commands

### Diagnostic Commands

```bash
# Check operator pod status
oc get pods -n <namespace> | grep <operator-name>

# Describe stuck pod
oc describe pod <pod-name> -n <namespace>

# Check CSV status
oc get csv -n <namespace>
oc get csv <csv-name> -n <namespace> -o yaml

# Check subscription status
oc get subscription -n <namespace>
oc get subscription <subscription-name> -n <namespace> -o yaml

# Check InstallPlans
oc get installplan -n <namespace>
oc get installplan <installplan-name> -n <namespace> -o yaml

# Check ArgoCD application status
oc get application -n openshift-gitops
oc get application <app-name> -n openshift-gitops -o yaml

# Check catalog sources
oc get catalogsource -n openshift-marketplace
oc get pods -n openshift-marketplace
```

### Resolution Commands

```bash
# Delete orphaned CSV
oc delete csv <csv-name> -n <namespace>

# Approve InstallPlan
oc patch installplan <installplan-name> -n <namespace> \
    --type merge \
    --patch '{"spec":{"approved":true}}'

# Sync ArgoCD application
argocd app sync <application-name>

# Force refresh ArgoCD application
argocd app get <application-name> --refresh

# Restart operator pod (if needed)
oc delete pod <pod-name> -n <namespace>
```

### Monitoring Commands

```bash
# Watch CSV status
oc get csv -n <namespace> -w

# Watch pod status
oc get pods -n <namespace> -w

# Watch InstallPlan status
oc get installplan -n <namespace> -w

# Check operator logs
oc logs <pod-name> -n <namespace>
oc logs <pod-name> -n <namespace> -c <container-name>

# Check previous logs (if pod crashed)
oc logs <pod-name> -n <namespace> --previous
```

### Investigation Commands

```bash
# Find all CSVs across cluster
oc get csv --all-namespaces

# Find orphaned CSVs (not referenced by subscriptions)
for ns in $(oc get csv --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "=== Namespace: $ns ==="
  oc get csv -n $ns -o json | jq -r '.items[] | .metadata.name'
  oc get subscription -n $ns -o json | jq -r '.items[] | .status.currentCSV // empty'
  echo ""
done

# Check OLM pod logs
oc logs -n openshift-operator-lifecycle-manager deployment/olm-operator

# Check catalog operator logs
oc logs -n openshift-operator-lifecycle-manager deployment/catalog-operator
```

---

## Common Scenarios and Solutions

### Scenario 1: Pod Stuck in ContainerCreating

**Symptoms:**
```bash
$ oc get pods -n openshift-operators-redhat
NAME                                    READY   STATUS              
loki-operator-controller-manager-xyz    0/2     ContainerCreating   
```

**Diagnosis:**
```bash
oc describe pod loki-operator-controller-manager-xyz -n openshift-operators-redhat
# Look for: FailedMount, ImagePullBackOff, etc.
```

**Common Causes:**
1. Missing ConfigMap/Secret → Check CSV status
2. Image pull failure → Check image registry access
3. Resource constraints → Check node resources

**Solution Path:**
- If ConfigMap missing → Check CSV → Delete orphaned CSV → Approve InstallPlan
- If ImagePullBackOff → Check image pull secrets, registry connectivity
- If resource constraints → Scale nodes or adjust resource requests

---

### Scenario 2: CSV in Failed State

**Symptoms:**
```bash
$ oc get csv -n openshift-logging
NAME                        PHASE    
cluster-logging.v6.2.3      Failed   
```

**Diagnosis:**
```bash
oc get csv cluster-logging.v6.2.3 -n openshift-logging -o yaml
# Check: status.reason, status.message
```

**Common Causes:**
1. Constraint conflict (orphaned CSV)
2. Insufficient permissions
3. Missing dependencies
4. Resource conflicts (port, name, etc.)

**Solution:**
```bash
# Delete failed CSV
oc delete csv cluster-logging.v6.2.3 -n openshift-logging

# Check for new InstallPlan
oc get installplan -n openshift-logging

# Approve if needed
oc patch installplan <name> -n openshift-logging \
    --type merge --patch '{"spec":{"approved":true}}'
```

---

### Scenario 3: Subscription ResolutionFailed

**Symptoms:**
```bash
$ oc get subscription loki-operator -n openshift-operators-redhat -o yaml
status:
  conditions:
  - type: ResolutionFailed
    status: "True"
    message: "constraints not satisfiable..."
```

**Diagnosis:**
```bash
# Check for orphaned CSVs
oc get csv -n openshift-operators-redhat

# Check subscription desired vs current
oc get subscription loki-operator -n openshift-operators-redhat \
    -o jsonpath='{.spec.startingCSV}{"\n"}{.status.currentCSV}{"\n"}'
```

**Solution:**
Delete orphaned CSV as described in Scenario 2

---

### Scenario 4: ArgoCD Application Degraded

**Symptoms:**
```
APP HEALTH: Degraded
SYNC STATUS: OutOfSync
```

**Diagnosis:**
```bash
# Check application details
oc get application <app-name> -n openshift-gitops -o yaml

# Look at resources section for degraded resources
oc get application <app-name> -n openshift-gitops \
    -o jsonpath='{.status.resources[?(@.health.status=="Degraded")].name}'
```

**Common Causes:**
1. Underlying operator not healthy → Fix operator first
2. Custom resource creation failed → Check operator logs
3. Sync wave timing issues → Adjust sync waves
4. InstallPlan not approved → Approve or add approver job

**Solution:**
1. Fix underlying operator issues
2. Sync ArgoCD application: `argocd app sync <app-name>`
3. Verify: Check resources in ArgoCD UI

---

### Scenario 5: Multiple Versions of Same Operator

**Symptoms:**
```bash
$ oc get csv -n openshift-logging
NAME                      PHASE
cluster-logging.v6.2.3    Succeeded
cluster-logging.v6.2.6    Succeeded
```

**Problem:**
- Multiple versions running
- Subscription not controlling either
- Possible conflicts

**Diagnosis:**
```bash
# Check which is referenced by subscription
oc get subscription cluster-logging -n openshift-logging \
    -o jsonpath='{.status.currentCSV}'

# If empty or doesn't match, all are orphaned
```

**Solution:**
```bash
# Delete all CSVs
oc delete csv cluster-logging.v6.2.3 cluster-logging.v6.2.6 \
    -n openshift-logging

# Wait for InstallPlan
sleep 10
oc get installplan -n openshift-logging

# Approve InstallPlan
oc patch installplan <name> -n openshift-logging \
    --type merge --patch '{"spec":{"approved":true}}'
```

---

## Troubleshooting Flowchart

```
Start: Operator Issue Detected
    ↓
Check Pod Status
    ├─ Running? → Check application logs
    ├─ CrashLoopBackOff? → Check pod logs
    ├─ ImagePullBackOff? → Check image/registry
    └─ ContainerCreating? → Continue below
          ↓
    Describe Pod
          ↓
    FailedMount (ConfigMap/Secret)?
          ↓ Yes
    Check CSV Status
          ↓
    CSV Failed or Missing?
          ↓ Yes
    Check Subscription Status
          ↓
    ResolutionFailed?
          ↓ Yes
    Check for Orphaned CSVs
          ↓
    Found Orphaned CSV?
          ↓ Yes
    ┌─────────────────────┐
    │ SOLUTION:           │
    │ 1. Delete CSV       │
    │ 2. Approve Plan     │
    │ 3. Verify           │
    │ 4. Sync ArgoCD      │
    └─────────────────────┘
```

---

## Additional Resources

### Official Documentation

- [OpenShift Operator Lifecycle Manager](https://docs.openshift.com/container-platform/latest/operators/understanding/olm/olm-understanding-olm.html)
- [Managing Subscriptions](https://docs.openshift.com/container-platform/latest/operators/admin/olm-adding-operators-to-cluster.html)
- [Loki Operator Documentation](https://docs.openshift.com/container-platform/latest/logging/cluster-logging-loki.html)
- [OpenShift Logging](https://docs.openshift.com/container-platform/latest/logging/cluster-logging.html)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)

### Useful Commands Reference

**OLM Objects Hierarchy:**
```
CatalogSource (catalog of available operators)
    ↓
OperatorGroup (defines operator scope)
    ↓
Subscription (declares desired operator)
    ↓
InstallPlan (execution plan)
    ↓
CSV (operator instance)
    ↓
Deployment (operator pods)
```

**Check All OLM Objects:**
```bash
#!/bin/bash
NAMESPACE=$1

echo "=== CatalogSources ==="
oc get catalogsource -n openshift-marketplace

echo -e "\n=== OperatorGroups ==="
oc get operatorgroup -n $NAMESPACE

echo -e "\n=== Subscriptions ==="
oc get subscription -n $NAMESPACE

echo -e "\n=== InstallPlans ==="
oc get installplan -n $NAMESPACE

echo -e "\n=== CSVs ==="
oc get csv -n $NAMESPACE

echo -e "\n=== Operator Pods ==="
oc get pods -n $NAMESPACE
```

---

## Lessons Learned

### Key Takeaways

1. **OLM Constraint Conflicts are Common**
   - Orphaned CSVs are the #1 cause of operator installation failures
   - Always check for multiple versions of same operator
   - Clean up properly when uninstalling operators

2. **Manual Approval Requires Monitoring**
   - `installPlanApproval: Manual` requires active monitoring
   - Consider ArgoCD installplan-approver jobs for automation
   - Balance control vs automation based on environment

3. **Order Matters for Dependent Operators**
   - Loki Operator must be healthy before Cluster Logging
   - Use ArgoCD sync waves to enforce order
   - CRDs must exist before resources using them

4. **Symptoms Can Be Misleading**
   - Pod stuck in ContainerCreating doesn't mean pod issue
   - ConfigMap missing doesn't mean ConfigMap issue
   - Always trace back to root cause (CSV/OLM)

5. **Prevention is Better Than Cure**
   - Use proper uninstallation procedures
   - Regular health checks catch issues early
   - Version pinning prevents surprise upgrades
   - Document your operator dependencies

---

## Contact and Support

### When to Escalate

Escalate to Red Hat Support if:
- OLM pods in `openshift-operator-lifecycle-manager` namespace failing
- CatalogSource pods not running
- Subscription issues persist after cleaning orphaned CSVs
- Cluster-wide operator issues
- Upgrade path blocked by OLM

### Information to Collect

Before contacting support:
```bash
# Collect must-gather
oc adm must-gather --image=registry.redhat.io/openshift4/ose-must-gather

# Collect OLM-specific info
oc adm inspect namespace/openshift-operator-lifecycle-manager \
    --dest-dir=olm-inspect

# Collect operator namespace info
oc adm inspect namespace/<operator-namespace> \
    --dest-dir=operator-inspect

# Export all relevant objects
oc get csv,subscription,installplan,operatorgroup -n <namespace> -o yaml > operator-objects.yaml
```

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-07 | pandyalr_anz | Initial creation based on loki/logging operator incident |

---

## Appendix: Complete Command Reference

### Health Check Script

```bash
#!/bin/bash
# operator-health-check.sh

set -e

NAMESPACE=${1:-openshift-operators-redhat}
OPERATOR_NAME=${2}

echo "=========================================="
echo "Operator Health Check"
echo "Namespace: $NAMESPACE"
if [ -n "$OPERATOR_NAME" ]; then
  echo "Operator: $OPERATOR_NAME"
fi
echo "=========================================="

echo -e "\n1. SUBSCRIPTIONS"
echo "===================="
if [ -n "$OPERATOR_NAME" ]; then
  oc get subscription $OPERATOR_NAME -n $NAMESPACE 2>/dev/null || echo "Not found"
else
  oc get subscription -n $NAMESPACE
fi

echo -e "\n2. CSVS"
echo "===================="
if [ -n "$OPERATOR_NAME" ]; then
  oc get csv -n $NAMESPACE | grep $OPERATOR_NAME || echo "Not found"
else
  oc get csv -n $NAMESPACE
fi

echo -e "\n3. INSTALLPLANS"
echo "===================="
oc get installplan -n $NAMESPACE

echo -e "\n4. PODS"
echo "===================="
if [ -n "$OPERATOR_NAME" ]; then
  oc get pods -n $NAMESPACE | grep $OPERATOR_NAME || echo "Not found"
else
  oc get pods -n $NAMESPACE
fi

echo -e "\n5. SUBSCRIPTION DETAILS"
echo "===================="
if [ -n "$OPERATOR_NAME" ]; then
  oc get subscription $OPERATOR_NAME -n $NAMESPACE -o yaml 2>/dev/null || echo "Not found"
fi

echo -e "\n6. FAILED CSVS"
echo "===================="
FAILED=$(oc get csv -n $NAMESPACE --field-selector=status.phase==Failed -o name 2>/dev/null)
if [ -n "$FAILED" ]; then
  echo "$FAILED"
else
  echo "None found"
fi

echo -e "\n7. PENDING INSTALLPLANS"
echo "===================="
PENDING=$(oc get installplan -n $NAMESPACE -o json | jq -r '.items[] | select(.spec.approved==false) | .metadata.name' 2>/dev/null)
if [ -n "$PENDING" ]; then
  echo "$PENDING"
else
  echo "None found"
fi

echo -e "\n=========================================="
echo "Health Check Complete"
echo "=========================================="
```

### Cleanup Script

```bash
#!/bin/bash
# operator-cleanup.sh
# USE WITH CAUTION - This will remove the operator

set -e

OPERATOR_NAME=$1
NAMESPACE=$2

if [ -z "$OPERATOR_NAME" ] || [ -z "$NAMESPACE" ]; then
  echo "Usage: $0 <operator-name> <namespace>"
  echo "Example: $0 loki-operator openshift-operators-redhat"
  exit 1
fi

echo "=========================================="
echo "Operator Cleanup Script"
echo "Operator: $OPERATOR_NAME"
echo "Namespace: $NAMESPACE"
echo "=========================================="
echo ""
echo "⚠️  WARNING: This will remove the operator and all its resources!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo -e "\nStep 1: Finding Subscription..."
SUBSCRIPTION=$(oc get subscription -n $NAMESPACE -o name | grep $OPERATOR_NAME)
if [ -n "$SUBSCRIPTION" ]; then
  echo "Found: $SUBSCRIPTION"
  echo "Deleting subscription..."
  oc delete $SUBSCRIPTION -n $NAMESPACE
else
  echo "No subscription found"
fi

echo -e "\nStep 2: Finding CSVs..."
CSVS=$(oc get csv -n $NAMESPACE -o name | grep $OPERATOR_NAME)
if [ -n "$CSVS" ]; then
  echo "Found CSVs:"
  echo "$CSVS"
  echo "Deleting CSVs..."
  echo "$CSVS" | xargs oc delete -n $NAMESPACE
else
  echo "No CSVs found"
fi

echo -e "\nStep 3: Finding InstallPlans..."
INSTALLPLANS=$(oc get installplan -n $NAMESPACE -o json | \
  jq -r ".items[] | select(.spec.clusterServiceVersionNames[] | contains(\"$OPERATOR_NAME\")) | .metadata.name")
if [ -n "$INSTALLPLANS" ]; then
  echo "Found InstallPlans:"
  echo "$INSTALLPLANS"
  echo "Deleting InstallPlans..."
  echo "$INSTALLPLANS" | xargs -I {} oc delete installplan {} -n $NAMESPACE
else
  echo "No InstallPlans found"
fi

echo -e "\n=========================================="
echo "Cleanup Complete"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Reinstall operator via ArgoCD or subscription"
echo "2. Approve InstallPlan if using Manual approval"
echo "3. Verify operator pods are running"
```

---

## Notes

- This runbook is based on a real incident that occurred on 2025-11-07
- The issue affected both loki-operator and cluster-logging operators
- Total time to resolution: ~45 minutes after proper diagnosis
- Root cause: Orphaned CSVs from previous installation attempts
- Key learning: Always check for orphaned CSVs when operators fail to install

---

**END OF RUNBOOK**
