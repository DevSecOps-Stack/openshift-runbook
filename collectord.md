# Collectord — Instances, Mounts, Paths

One Helm chart → N DaemonSets. Each instance ships a different set of namespaces
to a different HEC endpoint.

---

## Flow

```
   pods (testns-1, testns-2)
        │  stdout / stderr
        ▼
   CRI-O writes on the node
   /var/log/pods/<ns>_<pod>_<uid>/<container>/0.log
        │
        │  hostPath mount
        ▼
   collectord DaemonSet pods  (one per instance, per node)
        │  reads /rootfs/var/log/pods/...
        │  matches annotations → picks index
        ▼
   HEC endpoint (per instance)
        ▼
   Splunk index
```

---

## The mount

```
   HOST                            INSIDE COLLECTOR CONTAINER
   ────                            ──────────────────────────

   /var/log/          ────────►    /rootfs/var/log/
     └── pods/                       └── pods/
          ├── testns-1_web-0_<uid>/       ├── testns-1_web-0_<uid>/
          ├── testns-1_api-0_<uid>/       ├── testns-1_api-0_<uid>/
          ├── testns-2_web-0_<uid>/       ├── testns-2_web-0_<uid>/
          └── testns-2_db-0_<uid>/        └── testns-2_db-0_<uid>/
```

```yaml
volumes:
  - name: logs
    hostPath:
      path: /var/log                 # HOST
containers:
  - name: collectorforopenshift
    volumeMounts:
      - name: logs
        mountPath: /rootfs/var/log/  # IN CONTAINER
        readOnly: true
```

**Why `/rootfs`:** the container already has its own `/var/log`. Mounting the
host there would shadow it. With the prefix, every host path is simply
`/rootfs` + the real path.

---

## Full path, both sides

Pod `web-0`, namespace `testns-1`, container `nginx`:

```
HOST       /var/log/pods/testns-1_web-0_3f8a1c2e-9d41/nginx/0.log
CONTAINER  /rootfs/var/log/pods/testns-1_web-0_3f8a1c2e-9d41/nginx/0.log
           └──┬───┘
         mount prefix
```

Directory name = `<namespace>_<pod>_<uid>`

**The namespace is in the path** — that is how routing works before a single
line is read.

---

## Agent config points at the *mounted* path

```ini
[input.files]
crioPath          = /rootfs/var/log/pods/     # CRI-O — OpenShift 4
path              = /rootfs/var/lib/docker/containers/
type              = openshift_logs
pollingInterval   = 250ms      # read open files
walkingInterval   = 5s         # rescan for NEW pod dirs
joinPartialEvents = true       # reassemble P-flagged split lines
thruputPerSecond  = {{ $instance.config.containerthruputpersecond }}
```

Point `crioPath` at `/var/log/pods/` instead and the agent starts cleanly and
ships nothing.

---

## Chart → instances

```yaml
- chart: my-collectord
  targetRevision: 1.0.2
  appVersion: 4.5.4
  namespace: collectorforopenshift
  plugin: true                      # AVP resolves secrets at render time
  values:

    common:                         # shared by every instance
      license: <license>
      splunktoken: <splunk-token>
      clustername: test-cluster-01
      collectorAvpPath: kv/data/prod/test-cluster-01/collectord
      image: registry.internal/collectord/collectorforopenshift
      tag: 5.23.430

    instances:

      # ── default: everything not claimed by another instance ──
      - name: collectorforopenshift
        config:
          splunkhecurl: http://hec-shared.internal:8088/services/collector/event/1.0
          auditindex: k8s_audit_log
          clusterthruputpersecond: 1024Kb
          containerthruputpersecond: 512Kb
          thread: 4
          daemonresources:                 # the DaemonSet (node logs)
            limits:   { cpu: 1000m, memory: 512Mi }
            requests: { cpu: 400m,  memory: 256Mi }
          deployresources:                 # the Deployment (cluster events/objects)
            limits:   { cpu: 200m, memory: 300Mi }
            requests: { cpu: 100m, memory: 200Mi }

      # ── dedicated pipeline for one app ──
      - name: testapp-auth
        config:
          splunkhecurl: http://hec-testapp.internal:10557/contentListener
          annotationsSubdomain: testappsplunk          # ← the routing key
          statePath: /var/lib/collectorforopenshift-testapp/data/
          clusterthruputpersecond: 1024Kb
          containerthruputpersecond: 512Kb
          nodeSelector:
            node-role.kubernetes.io/workload: ""
          resources:
            limits:   { cpu: 2,    memory: 1Gi }
            requests: { cpu: 512m, memory: 512Mi }
```

Result:

```
$ oc get ds -n collectorforopenshift
NAME                              DESIRED  READY
collectorforopenshift-ds          120      120     # default, all nodes
testapp-auth-collector-ds          18       18     # nodeSelector-scoped
```

---

## How a namespace picks its instance — `annotationsSubdomain`

Each instance watches its **own annotation prefix**. That is the binding.

```yaml
# default instance → no subdomain
kind: Namespace
metadata:
  name: testns-1
  annotations:
    collectord.io/index: "testns1_prod"

# dedicated instance → subdomain prefix
kind: Namespace
metadata:
  name: testns-2
  annotations:
    testappsplunk.collectord.io/index: "testapp_prod"
```

- `collectorforopenshift` instance reads `collectord.io/*` → picks up `testns-1`
- `testapp-auth` instance reads `testappsplunk.collectord.io/*` → picks up `testns-2`

Both DaemonSets tail the **same files** on the node. The subdomain decides which
one actually forwards them. Onboarding = one annotation on the namespace. No
platform PR, no restart.

---

## `statePath` — must be unique per instance

```
default    /var/lib/collectorforopenshift/data/
testapp    /var/lib/collectorforopenshift-testapp/data/
```

hostPath dir holding the position/checkpoint file (inode + byte offset per file).
Two instances sharing one `statePath` overwrite each other's offsets → gaps and
duplicate floods. **Separate path per instance, always.**

---

## Two workloads per instance

| | Runs as | Collects |
|---|---|---|
| `daemonresources` | **DaemonSet**, every matching node | Container logs from `/rootfs/var/log/pods` |
| `deployresources` | **Deployment**, 1 replica | Cluster-level: API audit events, object state |

Which is why there are two resource blocks in the values file.

---

## Throughput

```
clusterthruputpersecond:   1024Kb   # ceiling for the whole instance
containerthruputpersecond:  512Kb   # ceiling per container
```

Per-instance ceilings are the noisy-neighbour control: one loud namespace on a
dedicated pipeline cannot delay the shared pipeline's logs.

---

## Secrets

`plugin: true` + `collectorAvpPath` → Argo CD Vault Plugin resolves `<license>`
and `<splunk-token>` at sync time. Git holds the Vault path, never the value.

---

## Verify

```bash
# host side vs container side of the mount
oc get ds <ds> -n collectorforopenshift \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{" host="}{.hostPath.path}{"\n"}{end}'
oc get ds <ds> -n collectorforopenshift \
  -o jsonpath='{range .spec.template.spec.containers[*].volumeMounts[*]}{.name}{" mount="}{.mountPath}{"\n"}{end}'

# what the agent actually sees
oc exec -n collectorforopenshift <pod> -- ls /rootfs/var/log/pods/ | head
oc debug node/<node> -- chroot /host ls /var/log/pods/ | head

# routing in effect
oc get ns testns-2 -o jsonpath='{.metadata.annotations}{"\n"}'
```

Empty inside the pod but populated on the host → mount wrong, or SCC blocked it.

---

## Failure modes

| Symptom | Cause |
|---|---|
| Agent up, zero events | `crioPath` points at host path, not `/rootfs/...` |
| Gaps / duplicate floods | two instances sharing one `statePath` |
| Some nodes have no logs | missing toleration, or `nodeSelector` too narrow |
| `permission denied` at start | SCC denies hostPath / SELinux label |
| Logs to the wrong index | wrong `annotationsSubdomain` prefix on the namespace |
| Node DiskPressure | HEC down, disk buffer growing |
| Duplicate events | retry — delivery is **at-least-once** |

---

## Interview one-liners

- **Namespace is in the log path** (`<ns>_<pod>_<uid>`) — routing works before
  reading a line.
- **`/rootfs` prefix** exists so the host tree doesn't shadow the container's own
  `/var/log`.
- **Instances = isolation**: own HEC, own index RBAC, own throughput ceiling, own
  blast radius.
- **`annotationsSubdomain` is the binding** between a namespace and an instance —
  self-service onboarding by annotation.
- **`statePath` must be unique per instance** or offsets collide.
- hostPath means the agent reads *every* tenant's logs on that node — platform
  owns it, tenants can't deploy their own.
