# Running kubectl from GitHub Actions via OIDC

Goal: let GitHub Actions run `kubectl` against the `mochi` k3s cluster without
storing a long-lived kubeconfig/service-account token as a repo secret. Instead,
each workflow run mints a short-lived GitHub OIDC token that the k3s API server
verifies directly.

```
GitHub Actions ──OIDC token (aud=https://mochi.shyim.de)──▶ kube-apiserver
                                                              │ verifies signature
                                                              │ via GitHub JWKS
                                                              ▼
                                              user = github:repo:shyim/mochi:ref:refs/heads/main
                                                              │
                                                              ▼
                                              ClusterRoleBinding → cluster-admin
```

## Pieces

| Piece | Where | Managed by |
| --- | --- | --- |
| API server trusts GitHub OIDC | `docs/k3s-oidc-auth.yaml` on the node | **manual (host)** |
| RBAC for the GitHub identity | `infrastructure/github-oidc/rbac.yaml` | Flux |
| Workflow that auths + runs kubectl | `.github/workflows/deploy.yaml` | git |

The API-server trust is the one part Flux cannot manage: it is a kube-apiserver
flag, configured on the k3s node itself.

## Prerequisites

- The k3s API server (`:6443`) is reachable from GitHub-hosted runners. We chose
  the **public API** option, so `https://mochi.shyim.de:6443` must resolve and be
  open to GitHub's runner egress ranges (or all of the internet). The API server
  TLS cert must include that hostname as a SAN — add it on the node with the k3s
  flag `--tls-san=mochi.shyim.de` if it is not already present.
- Kubernetes >= 1.30 on the node (structured authentication is beta / default
  on). Check with `k3s --version`.

## 1. Configure the k3s API server (manual, on the node)

Copy the auth config onto the control-plane node:

```bash
sudo mkdir -p /var/lib/rancher/k3s/server/oidc
sudo cp docs/k3s-oidc-auth.yaml \
  /var/lib/rancher/k3s/server/oidc/github-auth.yaml
```

Add the flag to `/etc/rancher/k3s/config.yaml` (create the file if missing):

```yaml
# /etc/rancher/k3s/config.yaml
kube-apiserver-arg:
  - "authentication-config=/var/lib/rancher/k3s/server/oidc/github-auth.yaml"
tls-san:
  - "mochi.shyim.de"
```

Restart k3s **once** to register the flag (this is the only restart ever needed
— subsequent edits to the auth file are hot-reloaded, see
"Granting another repository" below):

```bash
sudo systemctl restart k3s
```

Watch the API server come back healthy. A malformed auth config will keep the
API server from starting, so keep a second SSH session / console open:

```bash
sudo journalctl -u k3s -f
```

> Note: editing `authentication-config` does **not** disable the normal
> client-certificate kubeconfig that k3s writes to
> `/etc/rancher/k3s/k3s.yaml`. Your existing admin access keeps working, so this
> is safe to roll back by removing the flag and restarting.

## 2. RBAC (managed by Flux)

`infrastructure/github-oidc/rbac.yaml` binds the GitHub identity to a role. It is
wired into `clusters/mochi/sync.yaml` as the `github-oidc` Kustomization and
reconciles automatically after merge:

```bash
flux reconcile kustomization github-oidc --with-source
```

The mapped username is `github:` + the token's `sub` claim. For a push to `main`
in this repo the `sub` is:

```
repo:shyim/mochi:ref:refs/heads/main
```

so the username is `github:repo:shyim/mochi:ref:refs/heads/main`, which we bind
to `cluster-admin`. To grant another branch or a GitHub Environment, add another
`ClusterRoleBinding` (or a namespaced `RoleBinding` for least privilege) with the
matching subject, e.g.:

- branch `staging`: `github:repo:shyim/mochi:ref:refs/heads/staging`
- environment `production`: `github:repo:shyim/mochi:environment:production`

### Granting another repository (no downtime)

Two things are required to let a different repo authenticate. **Neither needs a
k3s restart** — the API server hot-reloads `--authentication-config` on file
change (structured auth, k8s >= 1.30), and RBAC is plain GitOps.

1. Add it to the `claimValidationRules` allowlist in `docs/k3s-oidc-auth.yaml`,
   then on the node run `sudo ./docs/reload-oidc-auth.sh`. The script validates
   the file, swaps it atomically, and confirms the API server reloaded it via the
   `apiserver_authentication_config_controller_automatic_reload_last_timestamp_seconds`
   metric. No restart, no outage. (If the new file is invalid the API server
   simply keeps the previous good config — the script's pre-check catches typos
   so the change doesn't silently fail to apply.)
2. Add a least-privilege `Role`/`RoleBinding` (or `ClusterRoleBinding`) for its
   identity in `infrastructure/github-oidc/rbac.yaml`. Flux applies it on merge —
   no node access, no restart.

The allowlist is kept explicit (one entry per repo) on purpose: a token from any
repo not on the list is rejected at authentication, before RBAC. The trade-off
is that step 1 needs node access; step 2 is pure GitOps.

`FriendsOfShopware/shopmon` (main branch) is wired up this way: it gets a
namespaced `Role` in `shopmon-staging` that allows only `get/list/watch/patch`
on deployments (plus read on replicasets/pods) — exactly what
`kubectl rollout restart deployment/api` and `rollout status` need, and nothing
more. Its identity is:

```
github:repo:FriendsOfShopware/shopmon:ref:refs/heads/main
```

## 3. The workflow

`.github/workflows/deploy.yaml` shows the full flow. The essentials:

- `permissions: id-token: write` — required to mint the OIDC token.
- The token is requested for `audience=https://mochi.shyim.de`, matching the
  `audiences` list in the auth config.
- `kubectl config set-credentials ... --token=$TOKEN` points kubectl at the
  cluster using that bearer token.

## Verifying

In a workflow run, `kubectl auth whoami` should report the
`github:repo:shyim/mochi:ref:refs/heads/main` username. Locally you can sanity
check RBAC with impersonation (using your admin kubeconfig):

```bash
kubectl auth can-i '*' '*' \
  --as 'github:repo:shyim/mochi:ref:refs/heads/main'   # -> yes
```

## Security notes

- Scope is per-branch: only runs on `main` get admin. PRs from forks cannot mint
  a token for this audience with a `main` `sub`, so they cannot authenticate as
  the admin identity.
- `claimValidationRules` pins `repository: shyim/mochi`, so a token from any
  other repo is rejected even before RBAC.
- Prefer binding to a least-privilege `ClusterRole`/`Role` instead of
  `cluster-admin` once you know exactly which resources CI needs to touch.
- Rotation is automatic: GitHub OIDC tokens are short-lived (minutes) and signed
  by GitHub's rotating JWKS, which the API server fetches from the issuer's
  discovery endpoint. No secrets to rotate.
```
