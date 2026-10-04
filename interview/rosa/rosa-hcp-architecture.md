# ROSA Hosted Control Planes (HCP) Architecture & Networking Deep-Dive

A platform engineer's architectural guide to Red Hat OpenShift on AWS (ROSA) with Hosted Control Planes (HCP), HyperShift mechanics, AWS PrivateLink plumbing, and the Konnectivity tunnel.

---

## ⚡ The 30-Second Elevator Pitch

> *"Classic ROSA deploys dedicated control plane EC2 instances (3 master nodes + 2 infrastructure nodes) directly inside the customer's AWS account, costing thousands of dollars in baseline compute and requiring 45+ minutes to provision. **ROSA with Hosted Control Planes (HCP)** utilizes **HyperShift and KubeVirt** to package the entire control plane (`etcd`, `kube-apiserver`, `oauth`, controllers) into lightweight, isolated **Kubernetes pods hosted inside Red Hat-managed AWS infrastructure**. The customer account only pays for actual worker nodes running in their private VPC. Communication between customer workers and the hosted API server travels over an encrypted, private **AWS PrivateLink** connection running the **Konnectivity reverse proxy tunnel**, achieving sub-15-minute cluster spin-up, zero master node EC2 cost, and independent control plane scaling."*

---

## 🏛️ 1. Architecture: Classic ROSA vs. ROSA HCP

```
========================================================================================
CLASSIC ROSA (Standalone Control Plane)
All VMs reside in Customer AWS Account. Customer pays EC2 bills for Masters & Infra VMs.
========================================================================================

  CUSTOMER AWS ACCOUNT & PRIVATE VPC
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │  CONTROL PLANE (Customer Pays EC2 Cost):                                         │
 │  [ Master 1 (EC2) ]    [ Master 2 (EC2) ]    [ Master 3 (EC2) ]                  │
 │  [ Infra 1 (EC2)  ]    [ Infra 2 (EC2)  ]                                        │
 │                                                                                  │
 │  DATA PLANE (Customer Pays EC2 Cost):                                            │
 │  [ Worker 1 (EC2) ]    [ Worker 2 (EC2) ]    [ Worker 3 (EC2) ] ...              │
 └──────────────────────────────────────────────────────────────────────────────────┘

========================================================================================
ROSA WITH HOSTED CONTROL PLANES (HCP)
Control plane runs as PODS inside Red Hat AWS VPC. Customer pays ONLY for Worker Nodes.
========================================================================================

  RED HAT-MANAGED AWS ACCOUNT (Service Provider VPC)
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │  HYPERSHIFT HOSTING CLUSTER                                                      │
 │  Namespace: 'clusters-<cluster-name>'                                            │
 │                                                                                  │
 │  [ etcd Pod 1 ]      [ etcd Pod 2 ]      [ etcd Pod 3 ]                          │
 │  [ kube-apiserver Pod ] [ kube-controller-manager Pod ] [ openshift-oauth Pod ]  │
 │                                                                                  │
 │  ┌─────────────────────────────────────────────────────────┐                     │
 │  │              KONNECTIVITY SERVER POD                    │                     │
 │  └────────────────────────────▲────────────────────────────┘                     │
 └───────────────────────────────┼──────────────────────────────────────────────────┘
                                 │
                                 │ AWS PrivateLink (Secure, High-Throughput VPC Endpoint)
                                 │ (No Public Internet Exposure!)
                                 │
  CUSTOMER AWS ACCOUNT (Your Private VPC)
 ┌───────────────────────────────┼──────────────────────────────────────────────────┐
 │  YOUR PRIVATE WORKER SUBNETS  │                                                  │
 │                               ▼                                                  │
 │  ┌─────────────────────────────────────────────────────────┐                     │
 │  │      KONNECTIVITY AGENT (Runs on every Worker Node)     │                     │
 │  └────────────────────────────▲────────────────────────────┘                     │
 │                               │                                                  │
 │  [ Worker Node 1 ]     [ Worker Node 2 ]     [ Worker Node 3 ] ...               │
 │  (Runs Kubelet, Application Pods, Kafka, Microservices)                          │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📊 2. Architectural Comparison Matrix

| Architectural Dimension | **Classic ROSA (Standalone)** | **ROSA with Hosted Control Planes (HCP)** |
| :--- | :--- | :--- |
| **Control Plane Topology** | 3 Master EC2 VMs + 2 Infra EC2 VMs in Customer VPC | Containerized Pods running in Red Hat-managed AWS Account |
| **Customer EC2 Bill** | **High:** Customer pays for 5 dedicated m5.xlarge+ VMs 24/7 | **Zero:** Customer pays $0 for master and infra nodes |
| **Cluster Provisioning Time**| **40 to 50 Minutes** (Waiting for EC2 boots, EBS mounts) | **10 to 15 Minutes** (Starting lightweight container pods) |
| **Underlying Engine** | Traditional OpenShift Installer (`openshift-install`) | **HyperShift** (KubeVirt containerized virtual control planes) |
| **Network Plumbing** | Local VPC networking between Masters and Workers | **AWS PrivateLink + Konnectivity Reverse Proxy Tunnel** |
| **Control Plane Scaling** | Static (Fixed 3 master VMs; resizing requires VM replacement) | **Dynamic:** Apiserver and etcd pods scale dynamically |
| **Upgrades & Maintenance** | Master nodes upgraded in-place (1 VM at a time; slow) | Zero customer impact; Red Hat rolls out pod updates in minutes |
| **Blast Radius Isolation** | 1 Cluster per 5 control plane VMs | Multi-tenant control plane isolation via Kubernetes namespaces |

---

## 🔌 3. The Wire-Level Network Plumbing: The Konnectivity Tunnel

In Classic OpenShift, worker nodes talk to master nodes over direct local private IP routing in the same VPC.

**In ROSA HCP, the master nodes and worker nodes live in TWO COMPLETELY DIFFERENT AWS ACCOUNTS.**
* How does `kubelet` on your worker node talk to `kube-apiserver` in Red Hat's VPC without exposing the cluster to the public internet?
* And how does `kube-apiserver` initiate connections down to pods (e.g. `oc logs`, `oc exec`, `oc port-forward`)?

This is solved by **AWS PrivateLink + The Konnectivity Tunnel**:

### The Step-by-Step Flow:
1. **The PrivateLink Handshake:**
   * Red Hat deploys an **AWS VPC Endpoint Service (NLB)** in front of the Hosted Control Plane.
   * In the customer's private VPC, AWS provisions an **Interface VPC Endpoint (PrivateLink)**.
   * All network packets travel across the private AWS backbone with **zero traversal of the public internet**.
2. **The Konnectivity Agent:**
   * On every customer worker node, a system pod called **`konnectivity-agent`** launches.
   * It establishes an **outbound, persistent gRPC TCP tunnel** through AWS PrivateLink to the **`konnectivity-server`** running in Red Hat's VPC.
3. **Handling `oc exec` and `oc logs` (The Reverse Proxy Magic):**
   * When an engineer runs `oc exec -it <pod> -- bash`:
   * The request hits `kube-apiserver` in Red Hat's VPC.
   * `kube-apiserver` cannot directly initiate a connection into your private customer VPC (blocked by firewalls).
   * Instead, it pushes the request **down the pre-established Konnectivity reverse tunnel**!
   * The `konnectivity-agent` on the worker receives the stream and proxies it to the local container runtime (`CRI-O`).

---

## 🎯 4. Senior Platform Engineer Interview Q&A

### Q1: What is the core business and architectural motivation for migrating from Classic ROSA to ROSA HCP?
> **Answer:** 
> The primary motivations are **cost efficiency**, **provisioning velocity**, and **operational simplicity**. In Classic ROSA, customers must pay AWS EC2 and EBS costs for 3 master nodes and 2 infrastructure nodes 24/7 per cluster, costing thousands of dollars per month before running a single workload. ROSA HCP eliminates customer compute costs for control planes entirely by packaging masters into container pods hosted in Red Hat's AWS account. Furthermore, provisioning time drops from 45 minutes to under 15 minutes, and control plane upgrades no longer cause node reboot churn in the customer account.

### Q2: How do worker nodes in the customer VPC securely communicate with the control plane in Red Hat's account without public internet access?
> **Answer:** 
> Communication is plumbed through **AWS PrivateLink** running the **Konnectivity reverse tunnel**. Red Hat exposes the hosted control plane via an AWS VPC Endpoint Service, and an Interface VPC Endpoint is provisioned in the customer's private subnets. The `konnectivity-agent` running on worker nodes establishes a secure outbound gRPC connection to the `konnectivity-server` in the hosted plane. For control-plane-to-node streams (`oc logs`, `oc exec`), the apiserver tunnels data back through this existing outbound connection, eliminating the need for ingress internet gateways or public IP addresses.

### Q3: What technology underpins ROSA Hosted Control Planes under the hood?
> **Answer:** 
> ROSA HCP is powered by **HyperShift**, an open-source project that decouples the OpenShift control plane from the data plane. HyperShift allows OpenShift control plane components (`kube-apiserver`, `etcd`, `kube-controller-manager`) to run as standard container workloads inside a management Kubernetes cluster, managed via declarative Custom Resources (`HostedCluster` and `NodePool`).
