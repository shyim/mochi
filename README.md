# mochi

Kubernetes manifests for the multi-node k3s `mochi` cluster (control-plane node
`mochi` on Hetzner plus compute-only agents on other providers, joined over an
encrypted flannel WireGuard mesh).

See [`docs/gitops.md`](docs/gitops.md) for the Flux bootstrap flow and the
Fleet/"flate" evaluation, and [`docs/multi-node.md`](docs/multi-node.md) for the
node topology, provisioning runbook, and scheduling pins.

