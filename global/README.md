# Cluster ingress: Envoy Gateway + Gateway API

This cluster (single-node k3s `mochi`, dual-stack IPv4 + IPv6) serves all HTTP(S)
traffic through **Envoy Gateway** using the **Gateway API**. Traefik (k3s's
bundled ingress) has been removed.

## Components

| Thing | Where | Notes |
|---|---|---|
| Envoy Gateway | helm release `eg`, ns `envoy-gateway-system` | chart `gateway-helm-v1.8.0` |
| Gateway API CRDs | installed by the Envoy Gateway chart | v1.5.1, experimental channel |
| cert-manager | helm release `cert-manager`, ns `cert-manager` | chart `v1.20.0`, Gateway API enabled |
| Datadog Operator | helm release `datadog-operator`, ns `datadog-operator` | manages `DatadogAgent` CRs |
| GatewayClass `eg` + EnvoyProxy `dual-stack` | `gateway-class.yaml` | dual-stack listener config |
| Shared Gateway `eg` | `gateway.yaml`, ns `default` | wildcard listeners |
| ClusterIssuer `letsencrypt-prod` | `cert-issuer.yaml` | HTTP-01 via gatewayHTTPRoute |
| ClusterIssuer `letsencrypt-dns` | `cert-issuer-dns.yaml` | DNS-01 (Cloudflare) for wildcards |
| Wildcard certs `*.fos.gg`, `*.staging.fos.gg` | `wildcard-certificates.yaml`, ns `default` | shared by all apps |

## Files in this folder

- `gateway-class.yaml` — GatewayClass `eg` + the `dual-stack` EnvoyProxy config
- `gateway.yaml` — the shared `eg` Gateway with wildcard listeners
- `cert-issuer.yaml` — `letsencrypt-prod` ClusterIssuer (HTTP-01, gatewayHTTPRoute)
- `cert-issuer-dns.yaml` — `letsencrypt-dns` ClusterIssuer (DNS-01, Cloudflare)
- `wildcard-certificates.yaml` — `*.fos.gg` + `*.staging.fos.gg` certs (in `default`)
- `cert-manager-values.yaml` — helm values that enable Gateway API support
- `mochi-certificate.yaml` — standalone cert for `mochi.shyim.de`
- `../infrastructure/datadog-config/datadogagent.yaml` — DatadogAgent custom
  resource for logs/OTLP/cluster checks

Per-app routing (HTTPRoute + redirect) lives in each app's own folder
(`../shopmon-staging`, `../sitespeed`).

## Adding a new app (no Gateway edit needed)

Because the Gateway uses wildcard listeners, a new app under `*.fos.gg` or
`*.staging.fos.gg` only needs an HTTPRoute in its own namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: myapp, namespace: myapp }
spec:
  parentRefs:
    - name: eg
      namespace: default
      sectionName: fos-gg-https        # or staging-fos-gg-https
  hostnames: ["myapp.fos.gg"]
  rules:
    - backendRefs: [{ name: myapp-svc, port: 80 }]
```

Listener sectionNames: `fos-gg-https` / `fos-gg-http` (for `*.fos.gg`),
`staging-fos-gg-https` / `staging-fos-gg-http` (for `*.staging.fos.gg`).
No new cert, no ReferenceGrant, no `gateway.yaml` change. A brand-new apex
domain (not under fos.gg) still needs its own listener + cert.

## Host-level changes (NOT in any manifest)

These were made on the k3s server in `/etc/rancher/k3s/config.yaml` and require
a k3s restart / node reboot. They cannot be expressed as Kubernetes objects:

```yaml
# /etc/rancher/k3s/config.yaml
tls-san:
  - "mochi.shyim.de"
node-ip: "162.55.47.201,2a01:4f8:c17:e302::1"
cluster-cidr: "10.42.0.0/16,fd42::/48"
service-cidr: "10.43.0.0/16,fd43::/112"
disable:
  - traefik                 # removed k3s's bundled Traefik ingress
disable-network-policy: true # disabled kube-router (see IPv6 note below)
```

## Bootstrap order (clean cluster)

```bash
# 1. Envoy Gateway (installs Gateway API CRDs)
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.0 \
  -n envoy-gateway-system --create-namespace

# 2. cert-manager with Gateway API support
helm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager --version v1.20.0 \
  -n cert-manager --create-namespace -f global/cert-manager-values.yaml

# 3. Cluster-level gateway objects
kubectl apply -f global/gateway-class.yaml
kubectl apply -f global/cert-issuer.yaml

# 3a. DNS-01 issuer for wildcards (needs the Cloudflare token first)
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token='<scoped token: Zone>DNS>Edit on fos.gg>'
kubectl apply -f global/cert-issuer-dns.yaml
kubectl apply -f global/wildcard-certificates.yaml   # wait until Ready

kubectl apply -f global/gateway.yaml
kubectl apply -f global/mochi-certificate.yaml

# 4. Per-app routing
kubectl apply -f shopmon-staging/
kubectl apply -f sitespeed/
```

## Gotchas we hit (so future-you doesn't re-debug them)

### IPv6 was broken — two independent causes
1. **Envoy bound IPv4-only.** Envoy Gateway defaults to `ipFamily: IPv4`, so
   Envoy listened only on `0.0.0.0`. v6 clients got "connection refused" even
   though the LB Service had a v6 address. Fixed by `spec.ipFamily: DualStack`
   on the EnvoyProxy (`gateway-class.yaml`).
2. **kube-router rejected v6.** k3s's built-in NetworkPolicy controller installs
   a v6 default-REJECT (`KUBE-POD-FW`) without the matching allow rules, blocking
   all IPv6 to pods — despite there being zero NetworkPolicies. Fixed by
   `disable-network-policy: true` + reboot (a plain restart leaves stale
   ip6tables chains behind).

### cert-manager HTTP-01 via Gateway
- The issuer solver uses `gatewayHTTPRoute` (not `ingress`) pointing at the `eg`
  Gateway's `http` listener.
- Do **not** put the `cert-manager.io/cluster-issuer` annotation on the `eg`
  Gateway. The gateway-shim then injects the Gateway as an extra parentRef,
  colliding with the issuer's own parentRef and producing an invalid HTTPRoute
  ("sectionName or port must be unique"). Apps use standalone `Certificate`
  resources instead.

### Single-node ServiceLB
- Only ONE Gateway, because each Gateway gets its own LoadBalancer Service and
  k3s ServiceLB binds hostPort 80/443 per Service — two Gateways collide and one
  stays Pending. Add hosts as extra listeners on the shared `eg` Gateway.
