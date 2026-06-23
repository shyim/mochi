# Node labels

The `mochi` cluster spans multiple providers, and the nodes are deliberately
*not* interchangeable: they differ in storage locality, role, and — the subject
of this doc — **CPU class** (shared vs dedicated vCPU). Workloads select nodes
by label so manifests stay provider- and hostname-agnostic: replacing `dango`
with another box only means re-applying labels, never editing YAML.

## Label scheme

| Label | Values | Meaning |
|-------|--------|---------|
| `topology.fos.gg/role` | `storage`, `compute` | `storage` = holds node-local `local-path` PVCs (pinned Postgres) and the Envoy ingress. `compute` = stateless workloads only. |
| `node.fos.gg/cpu` | `shared`, `dedicated` | CPU class of the underlying VM (see below). |
| `node-provider` | `hetzner`, `<provider>` | Informational: which infrastructure provider hosts the node. |

These are orthogonal. A node can be `role=storage` *and* `cpu=shared` at the
same time.

## Shared vs dedicated CPU — what it means and why we label it

Cloud VMs come in two CPU tiers, and the difference is invisible until a
latency-sensitive workload runs on the wrong one:

- **`shared`** (a.k.a. burstable / standard): the physical cores are
  oversubscribed — shared with *other tenants* on the same host. CPU time is
  not guaranteed; a noisy neighbour can steal cycles at any moment. Cheap (often
  free, e.g. Oracle Ampere free tier; Hetzner CX/CAX; AWS t-class). Fine for
  bursty, latency-tolerant, or idle-most-of-the-time workloads.

- **`dedicated`**: the vCPUs are physically reserved for this VM — no
  oversubscription, no noisy neighbours. Consistent, predictable CPU. More
  expensive (Hetzner CCX line; "dedicated vCPU" tiers elsewhere). Required when
  a workload *measures time* or needs steady throughput.

### Why this label exists: PageSpeed / Lighthouse

The headless-Chrome PageSpeed/Lighthouse runs (spawned by `sitespeed-api`)
compute performance scores by **timing** how long the main thread is busy. On a
`shared` node, a noisy neighbour steals CPU mid-audit and the scores get *worse
and noisier* — you end up measuring host contention, not the site under test.
Such runs must land on a `dedicated` node to produce trustworthy, comparable
numbers.

Conversely, stateless web workloads (swdemo, the sitespeed-api control plane,
Redis) tolerate `shared` CPU fine and belong on the cheaper nodes.

## Applying the labels

Run from a kubeconfig with cluster-admin (labels live on the node objects, not
in Git — they describe the host, which is provisioned out-of-band):

```bash
# storage node (Hetzner control-plane): holds Postgres + ingress
kubectl label node mochi \
  topology.fos.gg/role=storage \
  node-provider=hetzner \
  node.fos.gg/cpu=<shared|dedicated> --overwrite

# compute agent
kubectl label node dango \
  topology.fos.gg/role=compute \
  node-provider=<provider> \
  node.fos.gg/cpu=<shared|dedicated> --overwrite

# add taiyaki / further nodes the same way
```

Set `node.fos.gg/cpu` from the VM's instance type, not a guess: check the
provider's product page or `lscpu` / steal-time under load if unsure. When in
doubt, label it `shared` — over-claiming `dedicated` is the dangerous direction
(a latency-sensitive pod would land on a contended host).

## Inspecting

```bash
# see the CPU class of every node at a glance
kubectl get nodes -L node.fos.gg/cpu -L topology.fos.gg/role -L node-provider

# list only dedicated-CPU nodes
kubectl get nodes -l node.fos.gg/cpu=dedicated
```

## Targeting labels from workloads

Pin a CPU-sensitive workload to a dedicated node with a `nodeSelector` (and,
for hard guarantees, pair it with `Guaranteed` QoS — integer CPU
`requests == limits` — so the kubelet does not throttle it):

```yaml
spec:
  template:        # or the controller's pod template
    spec:
      nodeSelector:
        node.fos.gg/cpu: dedicated
```

For the PageSpeed runner specifically, the pod spec is generated at runtime by
`sitespeed-api`, so the selector is supplied through that app's
`K8S_NODE_SELECTOR` env var (comma-separated `key=value` pairs) rather than a
static manifest. It is set to `node.fos.gg/cpu=dedicated` in
`sitespeed/deployment.yaml` so every analysis pod lands on a dedicated-vCPU
node.

## Current assignments

| Node | Provider | `role` | `cpu` | Notes |
|------|----------|--------|-------|-------|
| `mochi` | hetzner | `storage` | _set me_ | control-plane, pinned Postgres + Envoy ingress |
| `dango` | _set me_ | `compute` | _set me_ | stateless workloads |
| `taiyaki` | _set me_ | `compute` | _set me_ | planned; intended dedicated-CPU PageSpeed node |

Keep this table updated when nodes are added or re-tiered.
