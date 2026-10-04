# Enterprise Banking Storage Architecture: Dell PowerMax CSI vs. NetApp Trident CSI

A comprehensive platform engineering runbook and senior interview cheat sheet covering Kubernetes Container Storage Interface (CSI), Dell PowerMax (Tier-0 Block/SAN), NetApp Trident (Unified NAS/SAN), wire-level attach flows, Linux kernel multipathing, and enterprise production failure recovery.

---

## ⚡ The 30-Second Elevator Pitch

> *"Enterprise banking storage divides workloads strictly by latency, I/O profile, and access semantics. For **Tier-0 mission-critical transactional engines** (Core Banking ledgers, Oracle RAC, high-throughput PostgreSQL), we deploy **Dell PowerMax CSI with Fibre Channel/iSCSI**, orchestrating LUN masking via UniSphere REST APIs into Storage Groups and utilizing Linux host-side DM-multipath (`multipathd`) for active/active multi-bus resilience. For **Tier-1/2 application state and shared multi-tenant filesystems**, we deploy **NetApp Trident CSI**, dynamically provisioning **`ontap-nas` (NFS v4.1)** for scalable `ReadWriteMany` (RWX) workloads with automated junction path management and export policies, alongside **`ontap-san` (iSCSI)** for low-overhead block storage with instant zero-copy FlexClone branching."*

---

## 🏛️ 1. Architecture Overview: Dell PowerMax vs. NetApp Trident

```
                                  ┌────────────────────────────────────────┐
                                  │      OpenShift 4 Control Plane         │
                                  │   kube-controller-manager (A/D)        │
                                  └──────────────────┬─────────────────────┘
                                                     │ Watches PVC / PV
                                                     ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                       CSI Architecture Topology                                          │
│                                                                                                          │
│   ┌────────────────────────────────────────────────────────┐  ┌───────────────────────────────────────┐  │
│   │               CSI Controller (Deployment)              │  │        CSI Node (DaemonSet)           │  │
│   │ • csi-provisioner (gRPC CreateVolume)                  │  │ • Runs on every Worker Node           │  │
│   │ • csi-attacher    (gRPC ControllerPublishVolume)       │  │ • csi-node-driver-registrar (Kubelet) │  │
│   │ • csi-resizer     (gRPC ControllerExpandVolume)        │  │ • NodeStageVolume (LUN scan/format)   │  │
│   │ • csi-snapshotter (gRPC CreateSnapshot)                │  │ • NodePublishVolume (Bind mount)      │  │
│   └───────────┬────────────────────────────────┬───────────┘  └───────────────────▲───────────────────┘  │
└───────────────┼────────────────────────────────┼──────────────────────────────────┼──────────────────────┘
                │ REST API                       │ REST API                         │ SCSI / NFS / iSCSI
                ▼                                ▼                                  │ Data Plane
┌──────────────────────────────┐ ┌──────────────────────────────┐                   │
│   Dell UniSphere REST API    │ │   NetApp ONTAP REST / ZAPI   │                   │
│ • Storage Group (SG)         │ │ • Storage Virtual Machine(SVM│                   │
│ • Port Group (PG)            │ │ • Aggregate / FlexVol        │                   │
│ • Initiator Group (IG)       │ │ • Export Policies            │                   │
│ • Masking View (MV)          │ │ • Junction Paths             │                   │
└───────────────┬──────────────┘ └──────────────┬───────────────┘                   │
                │                               │                                   │
                ▼                               ▼                                   │
┌──────────────────────────────┐ ┌──────────────────────────────┐                   │
│     Dell PowerMax SAN        │ │     NetApp ONTAP FAS/AFF     │                   │
│  (Tier-0 Mission Critical)   │ │   (Unified NAS / SAN Tier)   │                   │
│    FC / iSCSI NVMe-oF        │ │    NFS v3/v4.1 / iSCSI       │───────────────────┘
└──────────────────────────────┘ └──────────────────────────────┘
```

---

## 📊 2. Architectural Comparison Matrix

| Architectural Feature | **Dell PowerMax CSI / CSM** | **NetApp Trident CSI** |
| :--- | :--- | :--- |
| **Primary Tier** | **Tier 0 Ultra-Low Latency / High IOPS** | **Tier 1 & Tier 2 Unified Hybrid** |
| **Target Banking Workloads** | Core Banking DBs (Oracle, PostgreSQL, Kafka) | Web microservices, shared caches, logging, analytics |
| **Primary Access Modes** | `ReadWriteOnce` (RWO), `ReadWriteOncePod` | **`ReadWriteMany` (RWX)**, `ReadWriteOnce` (RWO) |
| **Transport Protocols** | **Fibre Channel (FC)**, iSCSI, NVMe/TCP | **NFS v3/v4.1** (`ontap-nas`), **iSCSI** (`ontap-san`) |
| **Array API Interface** | UniSphere REST API (HTTPS port 8443) | ONTAP REST API / ZAPI (HTTPS port 443) |
| **Array Logic Entity** | **Masking View (MV)** = SG + PG + IG | **SVM (Storage Virtual Machine)** + FlexVol / Qtree |
| **Host-Side Kernel Layer** | `dm-multipath` (`multipathd`), `mpath*` devices | Kernel NFS client (`mount.nfs`), `iscsiadm` |
| **Zero-Copy Cloning** | PowerMax SnapVX (Target LUN copy) | NetApp FlexClone (Instant pointer copy, 0 initial space) |
| **Failover Mechanism** | Hardware Fabric Multipathing (ALUA / Active-Active)| LIF (Logical Interface) failover / multipathing |


---

## 🧠 3. Foundational Mental Models & Real-World Case Study

### A. The 1-to-1 Firehose vs. The 1-to-Many Collaboration Desk

```
┌──────────────────────────────────────────────┐  ┌──────────────────────────────────────────────┐
│            DELL POWERMAX (RWO)               │  │           NETAPP TRIDENT (RWX)               │
├──────────────────────────────────────────────┤  ├──────────────────────────────────────────────┤
│ • Role: The Ultra-Fast Firehose              │  │ • Role: The Smart Collaboration Desk         │
│ • Focus: Raw IOPS & Sub-Millisecond Speed    │  │ • Focus: Multi-Pod & Multi-App Coordination  │
│ • Relation: 1-to-1 (Dedicated Disk to Node)  │  │ • Relation: 1-to-Many (Shared Filesystem)    │
│ • Champion Workload: Kafka, Oracle, Postgres │  │ • Champion Workload: Shared Docs, CMS, Batch │
└──────────────────────────────────────────────┘  └──────────────────────────────────────────────┘
```

* **One-to-One Model (`ReadWriteOnce` / `ReadWriteOncePod`):**
  $$\textbf{1 PVC} \longleftrightarrow \textbf{1 PV} \longleftrightarrow \textbf{1 Single Worker Node}$$
  Like a dedicated physical external drive or USB stick cabled directly to ONE server. Multiple pods across different nodes *cannot* attach simultaneously.
* **One-to-Many Model (`ReadWriteMany`):**
  $$\textbf{1 PVC} \longleftrightarrow \textbf{1 PV} \longleftrightarrow \textbf{MANY Worker Nodes Simultaneously}$$
  Like a high-performance network drive / Google Drive. Pods across Node 1, Node 2, and Node 5 mount the shared NFS junction path simultaneously.

---

### B. End-to-End Master Architecture: From Pod to Physical SSD Chips

```
                            OpenShift Worker Node
  ┌────────────────────────────────────────────────────────────────────────┐
  │  [ Database Application Pod ]                                          │
  │        │ (writes to /var/lib/data)                                     │
  │        ▼                                                               │
  │  /dev/mapper/mpatha (Single virtual device managed by multipathd)     │
  │        │                                                               │
  │        ├──────────────────────────────┬─────────────────────────────┐  │
  │        ▼                              ▼                             │  │
  │   [ HBA Port 1 ]                [ HBA Port 2 ]                      │  │
  │   (WWN: 10:00:00:fa:01)         (WWN: 20:00:00:fa:02)               │  │
  │   └───┬──────────────────────────────┴───────────────────────────┐  │  │
  └───────┼──────────────────────────────────────────────────────────┼──┼──┘
          │                                                          │  │
          │ ─── Path 1 (Cable 1) ───┐      ┌─── Path 3 (Cable 3) ─── │ ─┘
          │ ─── Path 2 (Cable 2) ─┐ │      │ ┌─ Path 4 (Cable 4) ─── ┘
          ▼                       ▼ ▼      ▼ ▼
  ┌───────────────┐              ┌────────────────┐
  │ SAN Switch A  │              │  SAN Switch B  │   (Redundant SAN Fabrics)
  └───────┬───────┘              └────────┬───────┘
          │ (Cable 1 & 2)                 │ (Cable 3 & 4)
          ▼                               ▼
════════════════════════════════════════════════════════════════════════════════
                       DELL POWERMAX STORAGE ARRAY
════════════════════════════════════════════════════════════════════════════════

  1. THE 4 DOORS (Port Group):
  ┌──────────────────────────────┐    ┌──────────────────────────────┐
  │  DIRECTOR CARD 1 (Brain 1)   │    │  DIRECTOR CARD 2 (Brain 2)   │
  │                              │    │                              │
  │  [ Port 1 ]    [ Port 2 ]    │    │  [ Port 3 ]    [ Port 4 ]    │
  └──────▲─────────────▲─────────┘    └──────▲─────────────▲─────────┘
         │ (Door 1)    │ (Door 2)            │ (Door 3)    │ (Door 4)
         └─────────────┴──────────┬──────────┴─────────────┘
                                  │
                                  ▼
  2. THE PERMISSION SLIP:
  ┌──────────────────────────────────────────────────────────────────┐
  │                       THE MASKING VIEW                           │
  │   Connects Worker Node WWNs (Initiators) ──► Ports 1, 2, 3, 4    │
  │   and unlocks permission to the Storage Group                    │
  └───────────────────────────────┬──────────────────────────────────┘
                                  │
                                  ▼
  3. THE VIRTUAL DISK (LUN / TDEV):
  ┌──────────────────────────────────────────────────────────────────┐
  │ Chunk 1  │  Chunk 2  │  Chunk 3  │  Chunk 4  │  Chunk 5  │  ...  │
  └────┬───────────┬───────────┬───────────┬───────────┬───────────┬─┘
       │           │           │           │           │           │ (Striping / RAID)
       ▼           ▼           ▼           ▼           ▼           ▼
  4. THE PHYSICAL SSD POOL:
    [SSD 1]     [SSD 2]     [SSD 3]     [SSD 4]     [SSD 5]     [SSD 6] ...
  (500 GB)    (500 GB)    (500 GB)    (500 GB)    (500 GB)    (500 GB)
```

---

### C. Enterprise Production Case Study: Kafka Event Mesh on Dell PowerMax

* **Workload:** 6-Broker Kafka Event Mesh streaming mission-critical transactions.
* **Storage Allocation:** 6 $\times$ 10 TB `ReadWriteOnce` PVCs (60 TB active) provisioned via `volumeClaimTemplates` under a 100 TB `ResourceQuota` (40 TB safety headroom).
* **Node Topology (The 7-Node Mandate):** 
  * Why 7 nodes for 6 brokers? **Pod Anti-Affinity + N+1 Failover.**
  * `podAntiAffinity` enforces `topologyKey: "kubernetes.io/hostname"`, guaranteeing no two Kafka brokers ever land on the same physical host.
  * Node 7 sits as a clean standby host. If any worker node suffers hardware failure, OpenShift reschedules the impacted broker onto Node 7, and PowerMax CSI remaps the Masking View.
* **Decoding Production `multipath -ll` & Hex Device IDs:**
  ```text
  mpathah (360000970000420000189533030354543) dm-0 EMC,SYMMETRIX
  size=10T features='1 queue_if_no_path' hwhandler='0' wp=rw
  `-+- policy='round-robin 0' prio=1 status=active
    |- 0:0:0:1 sda 8:0  active ready running
    |- 1:0:0:1 sdc 8:32 active ready running
    |- 0:0:1:1 sdb 8:16 active ready running
    `- 1:0:1:1 sdd 8:48 active ready running
  ```
  * `EMC,SYMMETRIX`: Kernel identification for Dell PowerMax.
  * `0189533030`: Array Serial Number.
  * `35 45 43`: ASCII hex encoding for **`5 E C`** $\rightarrow$ PowerMax Device ID **`005EC`**!
  * `policy='round-robin 0'`: Traffic balanced across all 4 Fibre Channel paths.

---

## ⚙️ 4. Wire-Level Provisioning & Mount Mechanics


### Flow A: Dell PowerMax Fibre Channel (Block / RWO)

```
[ Developer ] ──> PVC Created (StorageClass: powermax-fc)
                        │
                        ▼
[ CSI-Provisioner ] ──> gRPC CreateVolume() ──> [ UniSphere REST API ]
                                                       │
                                                       ├── Allocates TDEV (Thin Device / LUN)
                                                       └── Adds TDEV to target Storage Group (SG)
                                                       │
[ Kube-Scheduler ]  ──> Places Pod on 'worker-node-01'
                        │
                        ▼
[ CSI-Attacher ]    ──> gRPC ControllerPublishVolume() ──> [ UniSphere REST API ]
                                                       │
                                                       └── Adds Worker WWNs (IG) + Ports (PG) 
                                                           to Masking View (MV)
                                                       │
[ CSI-Node (DaemonSet) ] ── (Runs on worker-node-01)
         │
         ├── 1. SAN Bus Rescan:
         │      Issues: echo 1 > /sys/class/fc_host/host*/issue_lip
         │      Detects: New SCSI target LUNs (e.g. /dev/sdb, /dev/sdc, /dev/sdd)
         │
         ├── 2. Multipath Aggregation:
         │      multipathd identifies identical SCSI WWID
         │      Creates unified device: /dev/mapper/mpatha (or /dev/dm-2)
         │
         ├── 3. NodeStageVolume:
         │      Formats /dev/mapper/mpatha with XFS/ext4
         │      Mounts to global directory:
         │      /var/lib/kubelet/plugins/kubernetes.io/csi/csi-powermax.../globalmount
         │
         └── 4. NodePublishVolume:
                Executes OS bind-mount into target container namespace:
                /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pvc-uid>/mount
```

### Flow B: NetApp Trident NFS (`ontap-nas` / RWX)

```
[ Developer ] ──> PVC Created (StorageClass: trident-nfs-rwx)
                        │
                        ▼
[ Trident Controller ] ──> Reads TridentBackendConfig (TBC)
                                │
                                ▼
                       Calls ONTAP REST API
                                │
                                ├── Provisions FlexVol inside SVM (e.g., /vol/trident_pvc_123)
                                ├── Mounts volume to Junction Path: /trident_pvc_123
                                └── Updates ONTAP Export Policy: Adds Worker Node Subnet CIDR
                                │
[ Pod Scheduled on Worker-01 & Worker-02 simultaneously ]
                        │
                        ▼
[ CSI-Node on each Worker ] ──> gRPC NodePublishVolume()
                                │
                                └── Executes Linux Kernel NFS Mount:
                                    mount -t nfs -o vers=4.1,proto=tcp,timeo=600 \
                                      10.100.20.50:/trident_pvc_123 \
                                      /var/lib/kubelet/pods/<pod-uid>/volumes/.../mount
```

---

## 🛠️ 4. Host-Level Configuration & Diagnostics Runbook

### A. Dell PowerMax Host Multipathing (`multipathd`)

Worker nodes connecting to Dell PowerMax over Fibre Channel must have redundant Host Bus Adapters (HBAs) and properly configured path checkers:

```ini
# /etc/multipath.conf (Red Hat Enterprise Linux / RHCOS MachineConfig)
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
}

devices {
    device {
        vendor "EMC"
        product "SYMMETRIX"
        path_grouping_policy "multibus"
        path_checker "tur"              # Test Unit Ready (checks active array port)
        features "1 queue_if_no_path"   # Prevents immediate I/O errors during brief failovers
        hardware_handler "0"
        prio "const"
        rr_weight "uniform"
        rr_min_io 1000
        failback "immediate"
    }
}
```

#### Diagnostic Commands for Platform Engineers:
```bash
# 1. View all active multipath devices and path health
multipath -ll

# Expected Output:
# mpatha (360000970000197900123533030313233) dm-2 EMC,SYMMETRIX
# size=500G features='1 queue_if_no_path' hwhandler='0' wp=rw
# `-+- selector='round-robin 0' [prio=1][status=active]
#   |- 1:0:0:1 sdb 8:16 active ready running
#   |- 1:0:1:1 sdc 8:32 active ready running
#   |- 2:0:0:1 sdd 8:48 active ready running
#   `- 2:0:1:1 sde 8:64 active ready running

# 2. Force manual SCSI bus scan on worker node without reboot
rescan-scsi-bus.sh -a -r

# 3. Check Fibre Channel HBA link states and WWNs
cat /sys/class/fc_host/host*/port_name
cat /sys/class/fc_host/host*/port_state
```

---

### B. NetApp Trident Backend & StorageClass YAML

#### 1. Trident Backend Configuration (`TridentBackendConfig`):
```yaml
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: ontap-nas-backend
  namespace: trident
spec:
  version: 1
  storageDriverName: ontap-nas
  managementLIF: 10.100.20.10
  dataLIF: 10.100.20.50
  svm: svm_enterprise_core
  autoExportPolicy: true
  autoExportCIDRs:
    - "10.128.0.0/14"        # Worker Node Subnet CIDR
  credentials:
    name: ontap-credentials
  storagePrefix: bb_prod_    # Prefix for identifying volumes on array
```

#### 2. StorageClass Manifest for RWX Workloads:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: trident-nfs-rwx
provisioner: csi.trident.netapp.io
parameters:
  backendType: ontap-nas
  media: ssd
  provisioningType: thin
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - proto=tcp
  - hard
  - timeo=600
  - retrans=2
```

---

## 🚨 5. Enterprise War Stories & Production Failure Modes

### 💥 War Story 1: The Ungraceful Node Reboot & `Multi-Attach Error`
* **Symptoms:** A worker node suffers a kernel panic or sudden power loss. The scheduler evicts StatefulSet pods to another healthy worker. The pods remain indefinitely in `ContainerCreating`.
* **Kubelet Event:**
  ```text
  Warning  FailedAttachVolume  Multi-Attach error for volume "pvc-78a9..." 
  Volume is already exclusively attached to one node and can't be attached to another
  ```
* **Root Cause:**
  1. The crashed node never executed `NodeUnstageVolume` or `NodeUnpublishVolume`.
  2. The Kubernetes `kube-controller-manager` retains an active `VolumeAttachment` CRD locking the volume to the dead node.
  3. Dell PowerMax Masking View still maintains the dead worker’s Initiator Group (IG) mapping.
* **Resolution Runbook:**
  ```bash
  # Step 1: Check existing VolumeAttachment CRDs
  oc get volumeattachment | grep <pvc-id>

  # Step 2: Confirm dead node status (must be NotReady or cordoned)
  oc get node <dead-node>

  # Step 3: If node is physically dead and SAN fenced, force delete the stuck pod:
  oc delete pod <pod-name> -n <namespace> --force --grace-period=0

  # Step 4: If VolumeAttachment remains orphaned, delete it to allow csi-attacher to rebind:
  oc delete volumeattachment <volume-attachment-name>
  ```

---

### 💥 War Story 2: Multipath Path Flap Causing Uninterruptible Sleep (`D` State)
* **Symptoms:** Application pods hang. Any `ls` or write to the PVC mount freezes. Running `ps aux` shows worker node processes stuck in `D` state (kernel un-interruptible sleep waiting for disk I/O).
* **Root Cause:**
  1. Fibre Channel switch port suffered CRC frame drops, causing path flapping.
  2. The multipath configuration had `features "1 queue_if_no_path"`. When all paths failed temporarily, `multipathd` queued all kernel I/O indefinitely instead of failing fast or recovering.
  3. Kubelet health probes failed because I/O was blocked, causing node NotReady.
* **Resolution Runbook:**
  ```bash
  # Step 1: Inspect multipath daemon logs on the affected worker
  journalctl -u multipathd -n 100 --no-pager

  # Step 2: Check whether paths are faulty or degraded
  multipath -ll | grep -E "failed|faulty"

  # Step 3: Reconfigure no_path_retry to prevent indefinite hangs:
  # In /etc/multipath.conf: no_path_retry 12 (retry for 60 seconds, then error out)
  multipathd reconfigure
  ```

---

### 💥 War Story 3: Stale NFS File Handles on Trident RWX During Pod Eviction
* **Symptoms:** Pod rescheduling triggers `mount.nfs: Stale file handle` or `device or resource busy` during volume teardown.
* **Root Cause:**
  A process inside the dying container held open an unlinked file descriptor, or the ONTAP SVM unexported/remounted the junction path before the Linux kernel client completed dirty page flushes.
* **Resolution Runbook:**
  ```bash
  # Step 1: Identify lingering processes holding the mount point on the worker
  fuser -vm /var/lib/kubelet/pods/<pod-uid>/volumes/.../mount

  # Step 2: Kill lingering stuck processes gracefully or with SIGKILL:
  fuser -km /var/lib/kubelet/pods/<pod-uid>/volumes/.../mount

  # Step 3: Force unmount if kernel mount table is wedged:
  umount -l /var/lib/kubelet/pods/<pod-uid>/volumes/.../mount
  ```

---

## 🎯 6. Senior Platform Engineer Interview Q&A

### Q1: What is the architectural role split between CSI Controller and CSI Node DaemonSet?
> **Answer:** 
> * The **CSI Controller** runs centrally as a Deployment (with leader election). It contains sidecars (`csi-provisioner`, `csi-attacher`, `csi-resizer`, `csi-snapshotter`) that watch Kubernetes API objects (PVCs, PVs, VolumeAttachments) and call the external storage array control plane (UniSphere REST API or ONTAP REST API) to allocate LUNs/volumes and bind masking views.
> * The **CSI Node** runs on *every worker node* as a DaemonSet. It performs host-local kernel operations: triggering SCSI bus rescans, assembling device mapper multipath targets (`/dev/dm-X`), creating filesystems (`mkfs.xfs`), and issuing mount/bind-mount syscalls into pod container namespaces.

### Q2: How does Dell PowerMax handle volume mapping to specific Kubernetes worker nodes?
> **Answer:** 
> PowerMax uses **Masking Views (MV)** composed of three entities:
> 1. **Storage Group (SG):** Contains the Thin Devices (TDEVs/LUNs) provisioned for the cluster.
> 2. **Port Group (PG):** Front-end Fibre Channel FA/SE director ports zoned to the SAN switches.
> 3. **Initiator Group (IG):** The World Wide Names (WWNs) or IQNs of the specific worker node HBAs.
> When the `csi-attacher` executes `ControllerPublishVolume`, it directs UniSphere to add the worker node's Initiator Group to the Masking View, granting that specific host physical access to the target LUN across the SAN fabric.

### Q3: Why is DM-Multipath mandatory for PowerMax Block storage on OpenShift, and how does `path_checker` work?
> **Answer:** 
> Enterprise storage arrays connect via multiple SAN fabrics and redundant HBA paths (typically 4 paths per LUN). Without multipathing, the Linux kernel presents each physical path as an independent disk (`sdb`, `sdc`, `sdd`, `sde`), risking immediate filesystem corruption if mounted directly. 
> `multipathd` groups these paths under a single virtual device (`/dev/mapper/mpathX`). The `path_checker "tur"` (Test Unit Ready) continuously sends low-overhead SCSI interrogation commands to each path. If a director port fails, `multipathd` reroutes I/O to alternate paths in under a second with zero application I/O interruption.

### Q4: How does NetApp Trident provide `ReadWriteMany` (RWX) volumes without risking file corruption across different worker nodes?
> **Answer:** 
> NetApp Trident achieves RWX by leveraging its **`ontap-nas`** driver over **NFS (Network File System v3 / v4.1)**. Because NFS operates at the **file layer** rather than the block layer, the ONTAP storage array acts as the centralized file server managing distributed locking, file handles, and directory structures. Multiple worker nodes mount the exact same NFS export junction path simultaneously, and ONTAP coordinates file locks (via NLM in v3 or stateful lease delegations in v4.1).

### Q5: How does CSI Volume Expansion work under the hood, and why is `allowVolumeExpansion: true` required on the StorageClass?
> **Answer:** 
> Expansion is a two-phase process:
> 1. **Control Plane / Array Expansion (`ControllerExpandVolume`):** The `csi-resizer` sidecar detects an increased PVC spec, calls UniSphere or ONTAP to extend the underlying TDEV or FlexVol, and updates the PV object size.
> 2. **Host Node / Filesystem Expansion (`NodeExpandVolume`):** When the pod is running, the `csi-node` on the host resizes the block device (`rescan` on SCSI device and `multipathd resize map mpathX`), then executes online filesystem expansion (`xfs_growfs` for XFS or `resize2fs` for ext4) to expose the new sectors to the running container without downtime.
