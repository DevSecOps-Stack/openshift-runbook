# Runbook: Cloudability Agent Fails with Invalid Region and Proxy Misconfiguration

## Overview

This runbook explains the troubleshooting process and resolution for the Cloudability metrics collection agent issue caused by setting an incorrect `CLOUDABILITY_UPLOAD_REGION` value that results in connectivity failure due to an unconfigured proxy for a regional endpoint.

## Problem Description

The Cloudability agent fails to start with connectivity issues, logging errors similar to the following:

```
time="YYYY-MM-DDTHH:MM:SSZ" level=error msg="GetURL Retry 0: Failed to acquire s3 url, Status: X-Amzn-Requestid: "
time="YYYY-MM-DDTHH:MM:SSZ" level=warning msg="WARNING: failed to retrieve S3 URL in connectivity test, agent will fail to upload metrics to Cloudability with error: Unable to retrieve upload URI: Post \"https://metrics-collector-au1.cloudability.com/metricsample\": read tcp xxx.xxx.xxx.xxx:xxxxx->xxx.xxx.xxx.xxx:xx: read: connection reset by peer"
time="YYYY-MM-DDTHH:MM:SSZ" level=info msg="Cloudability Metrics Agent successfully started."
```

### Root Cause

1. The environment variable `CLOUDABILITY_UPLOAD_REGION=ap-southeast-2` was set, causing the agent to use the unsupported custom endpoint `https://metrics-collector-au1.cloudability.com`.

2. A proxy (`https://vse.swg.np.au2.aws.anz.com:80`) was **not configured/whitelisted** for `https://metrics-collector-au1.cloudability.com`, resulting in connectivity failure.

3. When the `CLOUDABILITY_UPLOAD_REGION` environment variable was **removed**, the agent defaulted to `us-west-2`, using the global endpoint `https://metrics-collector.cloudability.com`, which worked properly because the proxy had already been configured for the global endpoint.

---

## Resolution

### Summary of Fixes
- Removed the `CLOUDABILITY_UPLOAD_REGION=ap-southeast-2` environment variable.
- The agent now defaults to the global endpoint (`https://metrics-collector.cloudability.com`) for uploading metrics.
- No need to configure additional proxies as the global endpoint was already working.

---

## Step-by-Step Resolution

### Step 1: Verify Logs
1. Check the Cloudability agent logs to confirm the endpoint being used:
   ```bash
   kubectl logs deployment/cloudability-metrics-agent --tail 20
   ```
2. Look for an error containing the unsupported endpoint:
   ```
   Post "https://metrics-collector-au1.cloudability.com/metricsample": read tcp xxx.xxx.xxx.xxx:xxxxx->xxx.xxx.xxx.xxx:xx: read: connection reset by peer
   ```

---

### Step 2: Identify and Remove Incorrect Region Configuration
1. Verify the current environment variables for the Cloudability agent:
   ```bash
   kubectl exec deployment/cloudability-metrics-agent -- env | grep CLOUDABILITY_UPLOAD_REGION
   ```
   Example output:
   ```
   CLOUDABILITY_UPLOAD_REGION=ap-southeast-2
   ```

2. Remove the `CLOUDABILITY_UPLOAD_REGION` environment variable to allow the agent to default to the `us-west-2` region:
   ```bash
   kubectl set env deployment/cloudability-metrics-agent CLOUDABILITY_UPLOAD_REGION-
   ```

3. Confirm the environment variable has been removed:
   ```bash
   kubectl exec deployment/cloudability-metrics-agent -- env | grep CLOUDABILITY_UPLOAD_REGION
   ```

---

### Step 3: Verify the Agent Behavior
1. Restart the Cloudability agent pod (optional, for immediate changes):
   ```bash
   kubectl rollout restart deployment/cloudability-metrics-agent
   ```

2. Monitor the agent logs again:
   ```bash
   kubectl logs -f deployment/cloudability-metrics-agent --tail 20
   ```
3. The logs should indicate that the agent is now defaulting to `us-west-2` and using the correct endpoint:
   ```
   Region ap-southeast-2 is not supported. Defaulting to us-west-2 region.
   GetURL Retry 0: Successfully acquired s3 URL.
   Cloudability Metrics Agent successfully started.
   ```

---

### Optional Step: Support for ap-southeast-2
If the `ap-southeast-2` region must be used (e.g., for data compliance or latency reasons), ensure the following:
1. Work with your IT/network team to whitelist the custom endpoint:
   - **Region Endpoint:** `https://metrics-collector-au1.cloudability.com`
2. Configure the proxy to allow traffic through:
   - Example Proxy: `https://vse.swg.np.au2.aws.anz.com:80`

Once the region and proxy are configured correctly, reapply the region as follows:
1. Set the region in the deployment:
   ```bash
   kubectl set env deployment/cloudability-metrics-agent CLOUDABILITY_UPLOAD_REGION=ap-southeast-2
   ```

2. Verify connectivity and logs:
   ```bash
   kubectl logs -f deployment/cloudability-metrics-agent --tail 20
   ```

---
