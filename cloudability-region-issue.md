# Cloudability Agent: TLS Handshake Failure Troubleshooting and Fix

## Overview
This runbook describes the troubleshooting and resolution process for TLS handshake failures faced by the Cloudability metrics collection agent when the `CLOUDABILITY_UPLOAD_REGION` environment variable is set to `ap-southeast-4`.

## Problem Description
The Cloudability agent fails to start and sends the following errors in the logs:
```
time="YYYY-MM-DDTHH:MM:SSZ" level=error msg="GetURL Retry 0: Failed to acquire s3 url, Status: X-Amzn-Requestid: "
time="YYYY-MM-DDTHH:MM:SSZ" level=warning msg="WARNING: failed to retrieve S3 URL in connectivity test, agent will fail to upload metrics to Cloudability with error: Unable to retrieve upload URI: Post 'https://metrics-collector-au.cloudability.com/metricsample': read tcp xxx.xxx.xxx.xxx:xxxxx->xxx.xxx.xxx.xxx:xx: read: connection reset by peer"
time="YYYY-MM-DDTHH:MM:SSZ" level=info msg="Cloudability Metrics Agent successfully started."
```

The cause of the issue is the combination of:
1. **TLS Handshake Failure:** Zscaler Proxy is conducting SSL/TLS inspection, and the SSL certificate presented by Zscaler is not trusted due to the missing Zscaler Root CA certificate in the system certificate store.
2. **Regional Endpoint Issue:** By setting `CLOUDABILITY_UPLOAD_REGION=ap-southeast-4`, the agent uses the endpoint `https://metrics-collector-au.cloudability.com`, which faces connectivity issues because Zscaler intercepts the TLS handshake.

---

## Root Cause Analysis
1. **Proxy Configuration:**
   - Observed that both `https://metrics-collector.cloudability.com` and `https://metrics-collector-au.cloudability.com` endpoints returned:
     ```
     HTTP/1.1 200 Connection Established
     ```
     This confirms the Zscaler proxy successfully establishes a tunnel.

2. **TLS Handshake Failure:**
   - The proxy replaces the SSL certificate with its own Zscaler-signed certificate.
   - The absence of the Zscaler Root CA certificate on the system causes the TLS handshake to fail with:
     ```
     TLS connect error: error:00000000:lib(0)::reason(0)
     Recv failure: Connection reset by peer
     ```

3. **Mismatch in Working Configuration:**
   - The working cluster didn't set the `CLOUDABILITY_UPLOAD_REGION` variable and automatically defaulted to `us-west-2` (`https://metrics-collector.cloudability.com`).
   - The failing cluster explicitly declared `CLOUDABILITY_UPLOAD_REGION=ap-southeast-4`, causing it to use the endpoint `https://metrics-collector-au.cloudability.com`, where the issue is manifested.

---

## Resolution

### 1. Quick Fix: Remove `CLOUDABILITY_UPLOAD_REGION`
To resolve the issue quickly, remove the `CLOUDABILITY_UPLOAD_REGION` environment variable. The agent defaults back to the `us-west-2` region and the global endpoint (`https://metrics-collector.cloudability.com`), which avoids the problem.

#### Steps:
1. Update the Cloudability agent deployment:
   ```bash
   kubectl set env deployment/cloudability-metrics-agent CLOUDABILITY_UPLOAD_REGION-
   ```

2. Verify the logs:
   ```bash
   kubectl logs -f deployment/cloudability-metrics-agent --tail=20
   ```

You should see:
```
Region ap-southeast-4 is not supported. Defaulting to us-west-2 region.
GetURL Retry 0: Successfully acquired s3 url.
Cloudability Metrics Agent successfully started.
```

---

### 2. Long-Term Solution: Address Zscaler Certificate Issue
To prevent similar issues in the future, ensure the Zscaler Root CA certificate is trusted:

1. **Obtain the Zscaler Root CA Certificate:**
   Request the Zscaler Root CA certificate from your IT/Security team or export it from a trusted system.

2. **Install the Zscaler Certificate on Alpine Linux:**
   Copy the certificate file (e.g., `ZscalerRootCA.crt`) to the system's certificate directory:
   ```bash
   cp ZscalerRootCA.crt /usr/local/share/ca-certificates/
   update-ca-certificates
   ```

3. **Test the Connectivity:**
   Validate connectivity to both endpoints:
   ```bash
   curl -I -x http://<proxy> https://metrics-collector.cloudability.com
   curl -I -x http://<proxy> https://metrics-collector-au.cloudability.com
   ```

---

## Summary
The `CLOUDABILITY_UPLOAD_REGION` value caused the agent to switch to a different endpoint (`ap-southeast-4`) subject to TLS issues with Zscaler. Removing the region variable restored functionality via the default `us-west-2` (global) endpoint.

**Next Actions:**
- Optionally, address the Zscaler certificate issue for long-term reliability.
- Notify your team about the region handling behavior of the Cloudability metrics agent.
