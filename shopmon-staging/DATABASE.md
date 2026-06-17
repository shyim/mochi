# shopmon-staging database — ops notes

The Postgres database is a CloudNativePG `Cluster` (`db.yaml`) with continuous
WAL archiving + nightly base backups to Backblaze B2 via the Barman Cloud
Plugin, giving point-in-time recovery (PITR).

Everything except the two things below is described by the manifests
(`db.yaml`, `secret.yaml`, `../global/cloudnative-pg-values.yaml`). This file
only records the non-obvious operational knowledge.

## One-time install: the Barman Cloud Plugin

The CNPG operator (Helm) does **not** include the backup plugin. It must be
installed separately, into the operator namespace, and requires cert-manager
(already present on this cluster):

```sh
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.12.0/manifest.yaml
```

> Do **not** set a memory *limit* on `spec.instanceSidecarConfiguration` in the
> `ObjectStore` — `barman-cloud-backup` buffers/compresses during base backups
> and a tight limit gets the sidecar OOMKilled (exit 137), which surfaces as an
> `EOF` gRPC error and a `failed` Backup even though data reached B2. A request
> without a limit is fine.

## Backblaze B2 caveats

- **Lifecycle rules vs. retention.** Do not add a B2 lifecycle rule that
  deletes/hides objects inside the 30-day window. It would remove WAL/base
  files out from under Barman and break the recovery chain. Let the
  `ObjectStore` `retentionPolicy: "30d"` own deletion (or use a lifecycle rule
  strictly longer than 30 days).
- **Small-object load.** WAL archiving generates many small PUT/DELETE ops. If
  archiving falls behind, raise `spec.configuration.wal.maxParallel` in the
  `ObjectStore`.

## Point-in-time recovery

PITR bootstraps a **new** Cluster from the object store — never restore in
place. Recover into `db-restore`, verify, then repoint the app. The recovery
reuses the existing `db-backup` ObjectStore; `serverName` is the original
cluster name (`db`).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: db-restore
  namespace: shopmon-staging
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.4
  storage:
    size: 10Gi
  walStorage:
    size: 2Gi
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: db-backup
  bootstrap:
    recovery:
      source: db-origin
      recoveryTarget:
        targetTime: "2026-05-31 02:00:00+00"   # <- omit to recover to latest WAL
  externalClusters:
    - name: db-origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: db-backup
          serverName: db
```

## Trigger a manual backup (verify)

```sh
kubectl -n shopmon-staging create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  generateName: db-manual-
  namespace: shopmon-staging
spec:
  cluster:
    name: db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

kubectl -n shopmon-staging get backups   # should reach PHASE: completed
```
