# Dynatrace Deployment Troubleshooting on ROSA with ArgoCD

## Overview
This runbook addresses common issues encountered when deploying Dynatrace on Red Hat OpenShift Service on AWS (ROSA) clusters using ArgoCD, including namespace creation failures, missing secrets, and ActiveGate pod deployment issues.

---

## Problem Statement
When deploying a ROSA cluster with Dynatrace via ArgoCD, the following issues may occur:
1. ArgoCD fails to create the namespace, preventing application sync
2. Application sync fails due to missing `dynatraceproxysecret`
3. `dynakube-activegate-0` pod fails to deploy (responsible for endpoints)
4. DynaKube status shows as `Failed` instead of `Running`

---

## Prerequisites
- Access to the ROSA cluster with appropriate permissions
- `oc` CLI tool installed and configured
- ArgoCD access credentials
- Dynatrace tenant credentials and API tokens

---

## Troubleshooting Steps

### Step 1: Manually Create the Namespace

**Issue**: ArgoCD fails to create the namespace automatically.

**Resolution**:
```bash
# Create the Dynatrace namespace manually
oc create namespace dynatrace

# Verify namespace creation
oc get namespace dynatrace
```

**Expected Output**:
```
NAME        STATUS   AGE
dynatrace   Active   5s
```

---

### Step 2: Sync the ArgoCD Application

After creating the namespace manually, attempt to sync the application.

```bash
# Sync the application via ArgoCD CLI
argocd app sync <application-name>

# Or sync from the ArgoCD UI
# Navigate to Applications → Select your app → Click SYNC
```

---

### Step 3: Resolve Missing `dynatraceproxysecret`

**Issue**: Application fails to sync due to missing `dynatraceproxysecret`.

**Resolution**:
```bash
# Check if the secret exists
oc get secret dynatraceproxysecret -n dynatrace

# If missing, create the secret manually
oc create secret generic dynatraceproxysecret \
  --from-literal=proxy="<PROXY_URL>" \
  --from-literal=username="<PROXY_USERNAME>" \
  --from-literal=password="<PROXY_PASSWORD>" \
  -n dynatrace

# Verify secret creation
oc describe secret dynatraceproxysecret -n dynatrace
```

**Note**: Replace `<PROXY_URL>`, `<PROXY_USERNAME>`, and `<PROXY_PASSWORD>` with your actual proxy credentials.

---

### Step 4: Verify Pod Status

**Issue**: Pods are running but `dynakube-activegate-0` pod is not created.

**Resolution**:
```bash
# Check all pods in the dynatrace namespace
oc get pods -n dynatrace

# Check for any errors or pending pods
oc get pods -n dynatrace --field-selector=status.phase!=Running
```

---

### Step 5: Check DynaKube Status

**Issue**: DynaKube status shows as `Failed`.

**Resolution**:
```bash
# Check DynaKube custom resource status
oc get dynakube -n dynatrace

# Get detailed information about DynaKube
oc describe dynakube -n dynatrace
```

**Initial Output (Failed State)**:
```
NAME       APIURL                                    STATUS   AGE
dynakube   https://your-tenant.live.dynatrace.com   Failed   5m
```

---

### Step 6: Create Missing `dynakube` Secret

**Issue**: DynaKube remains in failed state due to missing authentication secret.

**Resolution**:
```bash
# Create the dynakube secret with API token and PaaS token
oc create secret generic dynakube \
  --from-literal=apiToken="<API_TOKEN>" \
  --from-literal=paasToken="<PAAS_TOKEN>" \
  -n dynatrace

# Verify secret creation
oc get secret dynakube -n dynatrace
```

**Where to find tokens**:
- Log in to your Dynatrace tenant
- Navigate to **Access Tokens** (Settings → Integration → Dynatrace API)
- Create tokens with appropriate permissions:
  - **API Token**: Requires `Read configuration` and `Write configuration` permissions
  - **PaaS Token**: Requires `InstallerDownload` permission

---

### Step 7: Verify Successful Deployment

After creating the required secrets, verify that all components are running correctly.

```bash
# Check DynaKube status (should show Running)
oc get dynakube -n dynatrace

# Verify all pods are running, including activegate
oc get pods -n dynatrace

# Check activegate pod specifically
oc get pod dynakube-activegate-0 -n dynatrace

# Verify logs for any errors
oc logs dynakube-activegate-0 -n dynatrace
```

**Expected Output**:
```
NAME       APIURL                                    STATUS    AGE
dynakube   https://your-tenant.live.dynatrace.com   Running   10m

NAME                                  READY   STATUS    RESTARTS   AGE
dynakube-activegate-0                 1/1     Running   0          5m
dynatrace-operator-xxxx               1/1     Running   0          10m
dynatrace-webhook-xxxx                1/1     Running   0          10m
```


