# GitOps with Flux

This repository is prepared for Flux on the single-node k3s `mochi` cluster.

## Bootstrap

Install the Flux CLI, make sure `kubectl` points at `mochi`, then bootstrap the
repo:

```bash
flux bootstrap github \
  --owner=shyim \
  --repository=mochi \
  --branch=main \
  --path=clusters/mochi
```

Flux creates the `flux-system` namespace and a `GitRepository` named
`flux-system`. The current bootstrap starts with Datadog plus Envoy Gateway and
creates ordered Flux `Kustomization` objects:

1. `datadog-controller` installs the Datadog Operator Helm chart in the
   `datadog-operator` namespace.
2. `datadog-config` applies `DatadogAgent/default/datadog` from
   `infrastructure/datadog-config`.
3. `envoy-controller` adopts/manages the existing Envoy Gateway Helm release
   `eg` in `envoy-gateway-system`.
4. `cnpg-controller` adopts/manages the existing CloudNativePG Helm release
   `cnpg` in `cnpg-system`.
5. `cert-manager-controller` adopts/manages the existing cert-manager Helm
   release `cert-manager` in `cert-manager`.
6. `barman-controller` installs/manages the CNPG Barman Cloud plugin Helm
   release `plugin-barman-cloud` in `cnpg-system`.
7. `external-secrets-controller` adopts/upgrades the External Secrets Operator
   Helm release `external-secrets` in `external-secrets`.
8. `global-config` applies cluster-wide Gateway API and cert-manager resources
   from `global/`.
9. `app-sitespeed` applies the Sitespeed API app from `sitespeed/`.
10. `app-swdemo` applies the Shopware demo app from `swdemo/`.
11. `app-shopmon-staging` applies the Shopmon staging app, Redis, CNPG database
    custom resources, backups, secrets, and routes from `shopmon-staging/`.

All current cluster controllers, global config, and apps are now reconciled by
Flux from `clusters/mochi/sync.yaml`.

The ordering matters: it prevents Flux from applying resources such as
`HTTPRoute`, `Certificate`, `ExternalSecret`, `DatadogAgent`, and CNPG
`Cluster` before their CRDs exist.

## Pre-existing secrets

These secrets are intentionally not committed and must exist before the related
controllers/apps become healthy:

- `cert-manager/cloudflare-api-token` for wildcard DNS-01 certificates.
- `default/datadog-secret` with the Datadog API key expected by
  `datadogagent.yaml`.
- `shopmon-staging/op-token`, `sitespeed/op-token`, and `swdemo/op-token` for
  the 1Password SDK SecretStores.

## Local validation

```bash
kustomize build clusters/mochi
kustomize build infrastructure/datadog-controller
kustomize build infrastructure/datadog-config
kustomize build infrastructure/envoy-controller
kustomize build infrastructure/cnpg-controller
kustomize build infrastructure/cert-manager-controller
kustomize build infrastructure/barman-controller
kustomize build infrastructure/external-secrets-controller
kustomize build global
kustomize build sitespeed
kustomize build swdemo
kustomize build shopmon-staging
```

For Flux-aware offline validation, use
[`flate`](https://github.com/home-operations/flate). It renders and tests Flux
`Kustomization`, `HelmRelease`, `OCIRepository`, and `HelmRepository` resources
without a live cluster:

```bash
brew install --cask home-operations/tap/flate

flate test all --path clusters/mochi
flate build all --path clusters/mochi -o yaml >/tmp/mochi-rendered.yaml
flate get images --path clusters/mochi -o name
```

The GitHub workflow in `.github/workflows/flate.yaml` runs the same offline
reconcile on pushes and pull requests, plus a rendered PR diff.

After bootstrap:

```bash
flux get all
flux reconcile source git flux-system
flux reconcile kustomization datadog-controller --with-source
flux reconcile kustomization datadog-config --with-source
flux reconcile kustomization envoy-controller --with-source
flux reconcile kustomization cnpg-controller --with-source
flux reconcile kustomization cert-manager-controller --with-source
flux reconcile kustomization barman-controller --with-source
flux reconcile kustomization external-secrets-controller --with-source
flux reconcile kustomization global-config --with-source
flux reconcile kustomization app-sitespeed --with-source
flux reconcile kustomization app-swdemo --with-source
flux reconcile kustomization app-shopmon-staging --with-source
```

## flate evaluation

`flate` does make sense for this repo. It is not a deployment controller; it is
an offline Flux renderer/tester. That complements Flux well because this repo
now has a real Flux graph with ordered `Kustomization` and `HelmRelease`
resources.

Validated locally with flate:

- `flate test all --path clusters/mochi` found 17 Flux resources and all passed.
- `flate build all --path clusters/mochi` rendered the full graph offline.
- `flate get images --path clusters/mochi -o name` listed the rendered workload
  images, including Envoy Gateway, cert-manager, CloudNativePG, External
  Secrets, Datadog Operator, Shopmon, Sitespeed, and swdemo.

Keep using plain `kustomize build` as a quick syntax/structure check, but use
`flate` in CI because it catches Flux-specific issues such as broken
`sourceRef`, `dependsOn`, Helm chart rendering, and OCI/Helm source resolution.

