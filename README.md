# mochi

Kubernetes manifests for the multi-node k3s `mochi` cluster (control-plane node
`mochi` on Hetzner plus compute-only agents on other providers, joined over an
encrypted flannel WireGuard mesh).

See [`docs/gitops.md`](docs/gitops.md) for the Flux bootstrap flow and the
Fleet/"flate" evaluation, and [`docs/nodes.md`](docs/nodes.md) for the node
label scheme (role, shared/dedicated CPU class, provider) and how workloads
select nodes.

