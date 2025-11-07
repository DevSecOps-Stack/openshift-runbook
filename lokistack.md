# OpenShift Operator Installation Troubleshooting Runbook

## Document Information
- **Date**: 2025-11-07
- **Incident**: Loki & Cluster Logging Operator Stuck in ContainerCreating
- **Author**: Rakesh Pandyala
- **Environment**: OpenShift with ArgoCD GitOps

---

## Table of Contents
1. [Problem Summary](#problem-summary)
2. [Understanding the Components](#understanding-the-components)
3. [Loki & Logging Architecture](#loki--logging-architecture)
4. [Root Cause Explained](#root-cause-explained)
5. [Complete Fix Procedure](#complete-fix-procedure)
6. [Prevention](#prevention)
7. [Quick Reference](#quick-reference)

---

## Problem Summary

### What Happened
- **Loki Operator** pod stuck in `ContainerCreating` for 4+ hours
- **Cluster Logging** operator failed with `ResolutionFailed` 
- **ArgoCD** applications showing `Degraded` and `OutOfSync`

### Root Cause
Orphaned CSVs (ClusterServiceVersions) causing OLM (Operator Lifecycle Manager) constraint conflicts.

### Impact
- No log collection/storage infrastructure
- Unable to create LokiStack instances
- Logging pipeline completely down

---

## Understanding the Components

### OLM Workflow: How Operators Get Installed

```
1. CatalogSource (redhat-operators)
   └─ Contains: List of available operators and versions
   
2. Subscription (loki-operator)
   └─ Declares: "I want loki-operator v6.2.3"
   
3. OLM (Controller)
   └─ Creates: InstallPlan (execution blueprint)
   
4. InstallPlan (install-abc123)
   └─ Contains: Steps to install CSV
   └─ Status: Waiting for approval (if Manual)
   
5. CSV (loki-operator.v6.2.3)
   └─ Creates: Deployment, ConfigMaps, RBAC, CRDs
   
6. Deployment
   └─ Creates: Operator Pod (loki-operator-controller-manager-xxx)
```

### Key Components Explained

**CSV (ClusterServiceVersion)**
- YAML manifest describing operator installation
- Contains: version, dependencies, permissions, deployment specs
- Naming: `<operator-name>.v<version>` (e.g., `loki-operator.v6.2.3`)
- States: `Pending` → `Installing` → `Succeeded` | `Failed`

**Subscription**
- Links operator to catalog source
- Specifies: desired version, update channel, approval mode
- Think of it as: "Standing order to keep this operator installed"

**InstallPlan**
- OLM's execution plan to install/upgrade operator
- Approval modes:
  - `Automatic`: OLM installs immediately
  - `Manual`: Requires human approval (production best practice)

**CRD (CustomResourceDefinition)**
- Extends Kubernetes API with new resource types
- Example: `LokiStack` CRD allows creating LokiStack resources
- Operators provide CRDs; other operators/apps consume them

### OLM Constraint Rules

OLM enforces these rules to prevent conflicts:
1. **One CSV per operator**: Only one version can be active
2. **Subscription ownership**: CSV must be managed by a subscription
3. **Version conflicts**: Can't have v6.2.3 and v6.2.6 simultaneously
4. **Dependency resolution**: All dependencies must be satisfiable

**When a rule breaks → "constraints not satisfiable" error**

---

## Loki & Logging Architecture

### Why These Two Operators Are Connected

```
OpenShift Logging Stack:

┌─────────────────────────────────────────────────────┐
│                  OpenShift Console                   │
│              (Log Viewing UI Plugin)                 │
└─────────────────────────────────────────────────────┘
                         ↑
                         │ (queries)
┌─────────────────────────────────────────────────────┐
│              LokiStack (Log Storage)                 │
│    - Query Frontend  - Ingester  - Compactor        │
│    Managed by: Loki Operator                         │
└─────────────────────────────────────────────────────┘
                         ↑
                         │ (ships logs)
┌─────────────────────────────────────────────────────┐
│         Vector/Fluentd (Log Collectors)              │
│         DaemonSet on every node                      │
│    Managed by: Cluster Logging Operator              │
└─────────────────────────────────────────────────────┘
                         ↑
                         │ (reads logs)
┌─────────────────────────────────────────────────────┐
│          Container Logs (Applications)               │
└─────────────────────────────────────────────────────┘
```

### Installation Dependency

**CRITICAL ORDER:**

```
Step 1: Install Loki Operator
  ├─ Namespace: openshift-operators-redhat
  ├─ Provides: LokiStack CRD
  └─ Pod: loki-operator-controller-manager-xxxxxxx

Step 2: Install Cluster Logging Operator  
  ├─ Namespace: openshift-logging
  ├─ Requires: LokiStack CRD (from Loki Operator)
  ├─ Provides: ClusterLogForwarder CRD
  └─ Pod: cluster-logging-operator-xxxxxxx

Step 3: Create LokiStack Instance
  ├─ Custom Resource using LokiStack CRD
  ├─ Managed by: Loki Operator
  └─ Creates: Actual log storage backend pods

Step 4: Create ClusterLogForwarder
  ├─ Custom Resource using ClusterLogForwarder CRD
  ├─ Managed by: Cluster Logging Operator
  └─ Creates: Vector/Fluentd DaemonSet
```

**Why order matters:**
- Cluster Logging Operator needs `LokiStack` CRD to validate resources
- Without Loki Operator, CRD doesn't exist → Installation fails
- Without LokiStack instance, logs have nowhere to go

### Components Details

**Loki Operator**
- **Purpose**: Manages Loki (log storage) lifecycle
- **Namespace**: `openshift-operators-redhat` (cluster-scoped)
- **Pod Name Pattern**: `loki-operator-controller-manager-<hash>`
- **CSV Pattern**: `loki-operator.v6.x.x`
- **Key ConfigMap**: `loki-operator-manager-config` (CRITICAL - if missing, pod won't start)
- **Provides CRDs**: `LokiStack`, `LokiStackRule`, `AlertingRule`, `RecordingRule`

**Cluster Logging Operator**
- **Purpose**: Manages log collection and forwarding
- **Namespace**: `openshift-logging` (namespace-scoped)
- **Pod Name Pattern**: `cluster-logging-operator-<hash>`
- **CSV Pattern**: `cluster-logging.v6.x.x`
- **Provides CRDs**: `ClusterLogForwarder`, `ClusterLogging`, `LogFileMetricExporter`
- **Depends On**: Loki Operator's LokiStack CRD

---

## Root Cause Explained

### What is an "Orphaned CSV"?

An orphaned CSV is a ClusterServiceVersion that:
1. Exists in the cluster
2. Is NOT managed by any active Subscription
3. Prevents new installations due to OLM constraints

### How It Happened (Our Case)

**Loki Operator Scenario:**
```
Timeline:
1. Previous installation attempt creates CSV: loki-operator.v6.2.3
2. Installation fails (resource conflict, timeout, etc.)
3. CSV status: Failed
4. Subscription gets deleted/recreated (by ArgoCD or admin)
5. New Subscription tries to install loki-operator.v6.2.3
6. OLM sees existing CSV with same name
7. OLM Error: "constraints not satisfiable - CSV already exists"
8. Result: No InstallPlan created → No ConfigMap → Pod stuck
```

**Cluster Logging Scenario:**
```
Timeline:
1. CSV cluster-logging.v6.2.6 exists (Succeeded state)
2. Subscription wants cluster-logging.v6.2.3 (older version)
3. OLM sees version mismatch
4. OLM Error: "CSV v6.2.6 exists and not referenced by subscription"
5. Result: Subscription can't install v6.2.3
```

### Why ConfigMap Was Missing

**Normal Installation Flow:**
```
Subscription created
    ↓
OLM creates InstallPlan
    ↓
InstallPlan approved (Manual or Auto)
    ↓
OLM installs CSV
    ↓
CSV creates resources:
    ├─ Deployment: loki-operator-controller-manager
    ├─ ConfigMap: loki-operator-manager-config ← CRITICAL
    ├─ ServiceAccount: loki-operator-controller-manager
    └─ RBAC: ClusterRole, ClusterRoleBinding
    ↓
Deployment creates Pod
    ↓
Pod mounts ConfigMap
    ↓
Pod starts successfully
```

**Broken Flow (Our Case):**
```
Subscription exists
    ↓
OLM detects orphaned CSV
    ↓
OLM refuses to proceed
    ↓
No InstallPlan created
    ↓
CSV not installed
    ↓
ConfigMap NOT created ← PROBLEM
    ↓
Pod spec references missing ConfigMap
    ↓
Kubernetes keeps retrying mount
    ↓
Pod stuck: ContainerCreating (4+ hours)
```

**Pod Volume Mount:**
```yaml
# Pod specification:
volumes:
  - name: manager-config
    configMap:
      name: loki-operator-manager-config  # Missing!
      
volumeMounts:
  - name: manager-config
    mountPath: /etc/manager
    readOnly: true
```

Kubernetes rule: Pod can't start until ALL volume mounts are available.

---

## Complete Fix Procedure

### Phase 1: Loki Operator Fix

#### Step 1: Verify the Problem

```bash
# Check pod status - should show ContainerCreating
oc get pods -n openshift-operators-redhat | grep loki-operator

# Expected output:
# loki-operator-controller-manager-8675699dc-8zrcf  0/2  ContainerCreating  0  4h
```

#### Step 2: Check Pod Events

```bash
# Get detailed pod information
oc describe pod loki-operator-controller-manager-8675699dc-8zrcf -n openshift-operators-redhat

# Look for in Events section:
# Warning  FailedMount  MountVolume.SetUp failed for volume "manager-config": 
#          configmap "loki-operator-manager-config" not found
```

#### Step 3: Verify ConfigMap is Missing

```bash
# Try to find the ConfigMap
oc get configmap loki-operator-manager-config -n openshift-operators-redhat

# Expected output:
# Error from server (NotFound): configmaps "loki-operator-manager-config" not found
```

#### Step 4: Check CSV Status

```bash
# List CSVs in the namespace
oc get csv -n openshift-operators-redhat | grep loki

# Problem output:
# loki-operator.v6.2.3  Loki Operator  6.2.3  loki-operator.v6.2.2  Failed
```

#### Step 5: Check Subscription for Constraint Errors

```bash
# Get subscription details
oc get subscription loki-operator -n openshift-operators-redhat -o yaml

# Look for in status.conditions:
# - type: ResolutionFailed
#   status: "True"
#   message: "constraints not satisfiable: @existing/openshift-operators-redhat//loki-operator.v6.2.3..."
```

#### Step 6: Delete Orphaned CSV

```bash
# Delete the failed CSV
oc delete csv loki-operator.v6.2.3 -n openshift-operators-redhat

# Expected output:
# clusterserviceversion.operators.coreos.com "loki-operator.v6.2.3" deleted
```

#### Step 7: Wait for New InstallPlan

```bash
# OLM needs a few seconds to create new InstallPlan
sleep 10

# Check for new InstallPlan
oc get installplan -n openshift-operators-redhat

# Expected output:
# NAME            CSV                   APPROVAL   APPROVED
# install-c96kc   loki-operator.v6.2.3  Manual     false
```

#### Step 8: Approve InstallPlan

```bash
# Approve the InstallPlan (use actual name from previous step)
oc patch installplan install-c96kc -n openshift-operators-redhat \
    --type merge \
    --patch '{"spec":{"approved":true}}'

# Expected output:
# installplan.operators.coreos.com/install-c96kc patched
```

#### Step 9: Monitor Installation

```bash
# Watch InstallPlan status (should change to Complete)
oc get installplan install-c96kc -n openshift-operators-redhat -o jsonpath='{.status.phase}' && echo

# Expected output:
# Complete

# Check CSV is now being installed
oc get csv -n openshift-operators-redhat | grep loki

# Expected progression:
# loki-operator.v6.2.3  Loki Operator  6.2.3  loki-operator.v6.2.2  Installing
# ... wait 30-60 seconds ...
# loki-operator.v6.2.3  Loki Operator  6.2.3  loki-operator.v6.2.2  Succeeded
```

#### Step 10: Verify ConfigMap Created

```bash
# Check ConfigMap now exists
oc get configmap loki-operator-manager-config -n openshift-operators-redhat

# Expected output:
# NAME                           DATA   AGE
# loki-operator-manager-config   1      91s
```

#### Step 11: Verify Pod Started

```bash
# Check pod status - should now be Running
oc get pods -n openshift-operators-redhat | grep loki-operator

# Expected output:
# loki-operator-controller-manager-8675699dc-8zrcf  2/2  Running  0  111s
```

#### Step 12: Sync ArgoCD Application

```bash
# From ArgoCD UI: Navigate to cpaas-d1-operator-loki → Click SYNC

# Or from CLI:
argocd app sync cpaas-d1-operator-loki

# Verify health
oc get application cpaas-d1-operator-loki -n openshift-gitops \
    -o jsonpath='{.status.health.status}' && echo

# Expected output:
# Healthy
```

---

### Phase 2: Cluster Logging Operator Fix

#### Step 1: Check Application Status

```bash
# Check ArgoCD application for cluster-logging
oc get application cpaas-d1-cluster-logging -n openshift-gitops

# Expected problem output:
# NAME                        SYNC STATUS   HEALTH STATUS
# cpaas-d1-cluster-logging    OutOfSync     Degraded
```

#### Step 2: Check CSV Status

```bash
# List CSVs in openshift-logging namespace
oc get csv -n openshift-logging | grep cluster-logging

# Problem output (version mismatch):
# cluster-logging.v6.2.6  Red Hat OpenShift Logging  6.2.6  cluster-logging.v6.2.3  Succeeded
```

#### Step 3: Check Subscription Desired Version

```bash
# Check what version subscription wants
oc get subscription cluster-logging -n openshift-logging -o yaml | grep startingCSV

# Output:
# startingCSV: cluster-logging.v6.2.3

# ISSUE: Subscription wants v6.2.3 but v6.2.6 exists (orphaned)
```

#### Step 4: Verify Constraint Error

```bash
# Check subscription conditions
oc get subscription cluster-logging -n openshift-logging -o yaml | grep -A 10 "conditions:"

# Look for:
# - type: ResolutionFailed
#   status: "True"
#   message: "constraints not satisfiable: ...cluster-logging.v6.2.6 exists and is not referenced..."
```

#### Step 5: Delete Orphaned CSV

```bash
# Delete the orphaned v6.2.6 CSV
oc delete csv cluster-logging.v6.2.6 -n openshift-logging

# Expected output:
# clusterserviceversion.operators.coreos.com "cluster-logging.v6.2.6" deleted
```

#### Step 6: Wait and Check for InstallPlan

```bash
# Wait for OLM to create new InstallPlan
sleep 10

# Check for InstallPlan
oc get installplan -n openshift-logging

# Expected output:
# NAME            CSV                      APPROVAL   APPROVED
# install-tll8l   cluster-logging.v6.2.3   Manual     false
```

#### Step 7: Approve InstallPlan

```bash
# Approve the InstallPlan
oc patch installplan install-tll8l -n openshift-logging \
    --type merge \
    --patch '{"spec":{"approved":true}}'

# Expected output:
# installplan.operators.coreos.com/install-tll8l patched
```

#### Step 8: Verify Installation

```bash
# Check InstallPlan status
oc get installplan install-tll8l -n openshift-logging -o jsonpath='{.status.phase}' && echo

# Expected output:
# Complete

# Check CSV is Succeeded
oc get csv -n openshift-logging | grep cluster-logging

# Expected output:
# cluster-logging.v6.2.3  Red Hat OpenShift Logging  6.2.3  cluster-logging.v6.2.2  Succeeded
```

#### Step 9: Verify Operator Pod

```bash
# Check cluster-logging operator pod
oc get pods -n openshift-logging | grep cluster-logging-operator

# Expected output:
# cluster-logging-operator-f8c889b78-rl88n  1/1  Running  0  69s
```

#### Step 10: Sync ArgoCD Application

```bash
# Sync from UI: Navigate to cpaas-d1-cluster-logging → Click SYNC

# Or from CLI:
argocd app sync cpaas-d1-cluster-logging

# Wait for sync to complete (may take 1-2 minutes)
# ArgoCD will run installplan-approver job automatically
```

#### Step 11: Verify Final Status

```bash
# Check application health
oc get application cpaas-d1-cluster-logging -n openshift-gitops \
    -o jsonpath='{.status.health.status}' && echo

# Expected output:
# Healthy

# Check sync status
oc get application cpaas-d1-cluster-logging -n openshift-gitops \
    -o jsonpath='{.status.sync.status}' && echo

# Expected output:
# Synced
```

#### Step 12: Verify LokiStack Created

```bash
# Check if LokiStack resource was created
oc get lokistack -n openshift-logging

# Expected output:
# NAME              AGE
# cluster-logging   2m
```

---

## Prevention

### 1. Proper Operator Uninstallation

**✅ CORRECT WAY:**
```bash
# Step 1: Delete custom resources created by operator
oc delete lokistack --all -n openshift-logging
oc delete clusterlogforwarder --all -n openshift-logging

# Step 2: Delete subscription
oc delete subscription cluster-logging -n openshift-logging

# Step 3: Delete CSV (usually auto-deleted, but verify)
oc get csv -n openshift-logging | grep cluster-logging
oc delete csv cluster-logging.v6.2.3 -n openshift-logging

# Step 4: Verify cleanup
oc get csv -n openshift-logging  # Should not show cluster-logging
```

**❌ WRONG WAY (Creates Orphaned CSVs):**
```bash
# This leaves orphaned CSVs!
oc delete deployment cluster-logging-operator -n openshift-logging
oc delete namespace openshift-logging  # Without deleting subscription first
```

### 2. Monitor InstallPlans

**For Manual Approval Mode:**
```bash
# Create a monitoring script: check-installplans.sh
#!/bin/bash
NAMESPACES="openshift-operators-redhat openshift-logging"

for ns in $NAMESPACES; do
  echo "=== Checking $ns ==="
  oc get installplan -n $ns -o json | \
    jq -r '.items[] | select(.spec.approved==false) | 
    "PENDING: \(.metadata.name) for \(.spec.clusterServiceVersionNames[])"'
done

# Run periodically:
watch -n 60 ./check-installplans.sh
```

### 3. Health Check Script

```bash
# Save as: operator-health.sh
#!/bin/bash
OPERATOR=$1
NAMESPACE=$2

echo "Checking $OPERATOR in $NAMESPACE..."

# Check CSV
CSV=$(oc get csv -n $NAMESPACE -o json | \
  jq -r ".items[] | select(.metadata.name | contains(\"$OPERATOR\")) | .metadata.name")
CSV_PHASE=$(oc get csv $CSV -n $NAMESPACE -o jsonpath='{.status.phase}')
echo "CSV: $CSV - Phase: $CSV_PHASE"

# Check Subscription
SUB=$(oc get subscription -n $NAMESPACE -o json | \
  jq -r ".items[] | select(.metadata.name == \"$OPERATOR\") | .metadata.name")
SUB_STATUS=$(oc get subscription $SUB -n $NAMESPACE -o json | \
  jq -r '.status.conditions[] | select(.type=="ResolutionFailed") | .status')
echo "Subscription: $SUB - ResolutionFailed: $SUB_STATUS"

# Check Pod
POD=$(oc get pods -n $NAMESPACE | grep $OPERATOR | awk '{print $1}')
POD_STATUS=$(oc get pod $POD -n $NAMESPACE -o jsonpath='{.status.phase}')
echo "Pod: $POD - Status: $POD_STATUS"

# Usage:
# ./operator-health.sh loki-operator openshift-operators-redhat
# ./operator-health.sh cluster-logging openshift-logging
```

---

## Quick Reference

### Key Namespaces
```bash
openshift-operators-redhat    # Loki Operator lives here
openshift-logging             # Cluster Logging Operator lives here
openshift-marketplace         # Catalog sources (redhat-operators)
openshift-gitops              # ArgoCD applications
```

### Key Pod Patterns
```bash
# Loki Operator
loki-operator-controller-manager-<hash>
# Location: openshift-operators-redhat
# Containers: 2/2 (kube-rbac-proxy, manager)

# Cluster Logging Operator  
cluster-logging-operator-<hash>
# Location: openshift-logging
# Containers: 1/1
```

### Key ConfigMaps
```bash
# If these are missing, pods won't start:
loki-operator-manager-config              # openshift-operators-redhat
cluster-logging-operator-<version>        # openshift-logging (version-specific)
```

### CSV Naming Patterns
```bash
loki-operator.v6.2.3              # Loki Operator
cluster-logging.v6.2.3            # Cluster Logging Operator
```

### Common Commands Cheat Sheet

```bash
# Quick diagnosis
oc get csv -n <namespace>
oc get subscription -n <namespace>
oc get installplan -n <namespace>
oc get pods -n <namespace>

# Fix orphaned CSV
oc delete csv <csv-name> -n <namespace>
sleep 10
oc get installplan -n <namespace>
oc patch installplan <plan-name> -n <namespace> --type merge --patch '{"spec":{"approved":true}}'

# Verify fix
oc get csv -n <namespace>  # Should show Succeeded
oc get pods -n <namespace> # Should show Running

# ArgoCD sync
argocd app sync <app-name>
oc get application <app-name> -n openshift-gitops
```

### Troubleshooting Decision Tree

```
Pod stuck in ContainerCreating?
  ├─ YES → Check pod events: oc describe pod <pod-name>
  │        └─ FailedMount (ConfigMap missing)?
  │            ├─ YES → Check CSV status
  │            │        └─ CSV Failed or missing?
  │            │            ├─ YES → Check Subscription
  │            │            │        └─ ResolutionFailed?
  │            │            │            └─ YES → Delete orphaned CSV
  │            │            └─ NO → Check OLM pods health
  │            └─ NO → Different issue (image, resources, etc.)
  └─ NO → Check for different symptoms
```

### Error Message Lookup

| Error Message | Location | Cause | Fix |
|---------------|----------|-------|-----|
| `FailedMount: configmap "loki-operator-manager-config" not found` | Pod events | CSV not installed | Delete orphaned CSV |
| `constraints not satisfiable` | Subscription status | Orphaned CSV exists | Delete orphaned CSV |
| `ResolutionFailed: True` | Subscription conditions | OLM can't resolve | Check for orphaned CSVs |
| `clusterserviceversion XXX exists and is not referenced` | Subscription message | Version conflict | Delete conflicting CSV |

---

## Summary

### What We Fixed
1. ✅ Loki Operator: Deleted orphaned CSV v6.2.3 (Failed state)
2. ✅ Cluster Logging: Deleted orphaned CSV v6.2.6 (version mismatch)
3. ✅ Both operators: Approved InstallPlans
4. ✅ ArgoCD applications: Synced and healthy

### Key Lessons
- **Orphaned CSVs** are the #1 cause of operator installation failures
- **ConfigMaps created by CSV** - if CSV doesn't install, ConfigMaps don't exist
- **Pod waits forever** for missing volume mounts
- **Always delete CSV first**, then let OLM create new InstallPlan
- **Manual approval** requires monitoring and action

### Time to Resolution
- Diagnosis: 5-10 minutes
- Fix per operator: 2-3 minutes
- Total: ~15 minutes once root cause identified

---

**END OF RUNBOOK**
