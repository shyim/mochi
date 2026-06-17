#!/usr/bin/env bash
# Install/update the GitHub OIDC AuthenticationConfiguration on the k3s node
# WITHOUT restarting k3s. kube-apiserver hot-reloads --authentication-config on
# file change (structured auth, k8s >= 1.30), so adding a repo to the allowlist
# in docs/k3s-oidc-auth.yaml is a zero-downtime operation.
#
# Usage (run on the control-plane node, from a checkout of this repo):
#   sudo ./docs/reload-oidc-auth.sh
#
# It validates the YAML, swaps the file atomically, and watches the apiserver
# reload metric to confirm the new config was picked up.
set -euo pipefail

SRC="$(dirname "$0")/k3s-oidc-auth.yaml"
DEST="/var/lib/rancher/k3s/server/oidc/github-auth.yaml"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

# Basic YAML sanity check before swapping (an invalid file is ignored by the
# apiserver, which keeps the OLD config — so a typo silently fails to apply
# rather than breaking auth; catch it here instead).
if command -v yq >/dev/null 2>&1; then
  yq eval '.kind == "AuthenticationConfiguration"' "$SRC" | grep -qx true \
    || { echo "validation failed: $SRC is not an AuthenticationConfiguration" >&2; exit 1; }
fi

install -D -m 600 "$SRC" "$DEST"
echo "installed $DEST"

# kube-apiserver reloads within a few seconds. Confirm via the reload metric.
echo "waiting for kube-apiserver to hot-reload the auth config..."
for _ in $(seq 1 15); do
  ts=$(kubectl get --raw /metrics 2>/dev/null \
    | grep apiserver_authentication_config_controller_automatic_reload_last_timestamp_seconds \
    | grep 'status="success"' | awk '{print $2}' || true)
  if [[ -n "${ts:-}" ]]; then
    echo "reload succeeded (last success timestamp: $ts)"
    exit 0
  fi
  sleep 2
done
echo "could not confirm reload via metrics; check 'journalctl -u k3s' and the" >&2
echo "apiserver_authentication_config_controller_* metrics manually." >&2
exit 1
