# Tetrix Enterprise — Helm chart (customer reference)

The chart is an **OCI artifact**. You do **not** clone a chart source tree
(`templates/`, full `values.yaml`). Install with Helm 3.8+:

```bash
helm upgrade --install tetrix \
  oci://registry-1.docker.io/deskree/tetrixaidb-chart \
  --version 0.8.54 \
  --namespace tetrix --create-namespace \
  --timeout 25m --wait=false \
  --set ingress.host=tetrix.yourcompany.com \
  --set ingress.tls.certManager.clusterIssuer=letsencrypt-prod \
  --set-file secrets.licenseToken=./license.jwt
```

The machine-readable full catalog (every key the chart accepts) is:

```bash
helm show values oci://registry-1.docker.io/deskree/tetrixaidb-chart --version 0.8.54
```

This page is the curated customer catalog: every parameter you typically set,
defaults, secret keys, the unlicensed path, external databases, and opt-in
collectors. A starter file is [`helm/values-example.yaml`](helm/values-example.yaml);
a commented skeleton of the same customer-safe keys is
[`helm/values-reference.yaml`](helm/values-reference.yaml).

---

## Before you install

| Need | Notes |
|------|-------|
| Kubernetes 1.23+, Helm 3.8+ | Working `kubectl` context. |
| StorageClass | Default class, or set `global.storageClass`. |
| Public DNS | `ingress.host` must resolve at the ingress **and from inside the cluster**. Pods fetch OIDC discovery at the public issuer URL. Use split-horizon DNS if internal lookups would miss Traefik. |
| TLS | cert-manager ClusterIssuer **or** `ingress.tls.existingSecret`. The certificate must chain to a CA the pods trust. A private CA the images do not trust is rejected. |
| License token | Required on the default path. The pre-install hook mints a short-lived `registry.deskree.com` pull credential from it. |

HTTPS is required in production — the web application uses browser APIs that
only work in a secure context.

**Do not pass `--wait` or `--atomic`** on a default install. Schema, Keycloak,
and Vault hooks run after the main workloads; Helm `--wait` blocks on
collectors becoming Ready before those hooks finish. Use
`--timeout 25m --wait=false` and watch Jobs with `kubectl -n tetrix get jobs`.

### Evaluating without DNS or a certificate

Laptop / minikube only:

```yaml
ingress:
  host: localhost
  publicPort: "18080"
  tls:
    enabled: false
daemon:
  oidcLoopbackProxy:
    enabled: true
```

Then `kubectl -n tetrix port-forward --address 127.0.0.1 svc/tetrix-traefik 18080:80`
and open `http://localhost:18080/`. Production still needs a real hostname and a
trusted certificate.

### Without a license token (Docker Hub / air-gapped / your mirror)

Both settings move together. First-party `deskree/*` images on Docker Hub are
**private** — create a pull secret first or pods stay in `ImagePullBackOff`.

```bash
helm upgrade --install tetrix \
  oci://registry-1.docker.io/deskree/tetrixaidb-chart --version 0.8.54 \
  --namespace tetrix --create-namespace \
  --timeout 25m --wait=false \
  --set ingress.host=tetrix.yourcompany.com \
  --set ingress.tls.certManager.clusterIssuer=letsencrypt-prod \
  --set global.imageOrigin="" \
  --set adminApi.updater.registryBroker.enabled=false \
  --set 'global.imagePullSecrets[0].name=your-dockerhub-secret'
```

### Using your own databases

Disable each bundled backend and point at `external*` (see the parameter table).
Collectors are **on** by default and need their own control-plane database
(control plane ≠ AIDB). Either `--set collectors.enabled=false` or supply
`--set secrets.collectorsControlPlaneDsn='postgresql+asyncpg://…'` and create a
dedicated `control_plane` database.

### Using a pre-created Kubernetes secret

`--set secrets.existingSecret=my-tetrix-secret` disables chart password
auto-generation. The secret must contain every key the enabled components need
(Table 1.8-G below).

---

## Parameter catalog

Set with `--set key=value` or `-f myvalues.yaml`. Rows marked **Required** have
no usable default for a new install of that component.

### Global settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `global.imageOrigin` | `registry.deskree.com/` | Where Tetrix's own images are pulled from. Empty string = Docker Hub (see unlicensed path). Third-party images keep their own origins. |
| `global.imageRegistry` | *(empty)* | Prefix applied to every image, including third-party — for an air-gapped mirror (`registry.internal/`). |
| `global.imagePullSecrets` | `[]` | Pull secrets on every pod. Required for private `deskree/*` Docker Hub pulls or a private mirror. |
| `global.imageTag` | *(empty)* | Default tag for any component whose own tag is unset. |
| `global.storageClass` | *(empty)* | Default StorageClass for every PVC. Empty = cluster default. |

### Ingress and TLS

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ingress.enabled` | `true` | Expose Tetrix through the bundled edge proxy. |
| `ingress.host` | `tetrix.example.com` | **Required.** Public hostname. Must resolve from inside the cluster. |
| `ingress.publicPort` | *(empty)* | Optional non-standard port (e.g. `18080` for `kubectl port-forward`). |
| `ingress.tls.enabled` | `true` | Terminate TLS at the edge. Set `false` only for localhost evaluation. |
| `ingress.tls.certManager.clusterIssuer` | *(empty)* | Existing cert-manager ClusterIssuer. Set this *or* `existingSecret`. |
| `ingress.tls.existingSecret` | *(empty)* | Kubernetes TLS secret you created yourself. |
| `daemon.oidcLoopbackProxy.enabled` | `false` | When `ingress.publicPort` is set, proxy loopback:`publicPort` → Traefik so the core service can fetch OIDC discovery. Local / minikube only. |
| `traefik.enabled` | `true` | Bundle Traefik. Set `false` to reuse an existing instance named `traefik`. |
| `traefik.deployment.replicas` | `2` | Edge-proxy replicas. |
| `gateway.enabled` | `true` | Authenticate every request at the edge. |
| `gateway.replicas` | `2` | Edge-authentication replicas. |
| `gateway.cacheTTL` | `30s` | How long a successful auth check is cached. |
| `networkPolicy.enabled` | `true` | Restricts which components may talk to which others. |

### Sign-in (identity provider)

Tetrix bundles Keycloak at `/auth` (no separate DNS record). Logto is present
only for existing installations that have not moved; it is **not recommended
for new installs**.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `keycloak.enabled` | `true` | Deploy and provision the bundled sign-in service. |
| `keycloak.realm` | `tetrix` | Internal realm name. |
| `keycloak.owner.enabled` | `true` | Create the first administrator (Owner). |
| `keycloak.owner.autoProvision` | `true` | Generate Owner email/password when unset. |
| `secrets.keycloakOwnerEmail` | *(auto)* | Override. Defaults to `owner@<ingress.host>`. |
| `secrets.keycloakOwnerPassword` | *(auto)* | Override. Only takes effect on first creation. |
| `secrets.keycloakDbPassword` | *(auto)* | Sign-in service database password. |
| `secrets.keycloakAdminPassword` | *(auto)* | Bootstrap admin for Keycloak's own console. |

### Storage backends

| Parameter | Default | Description |
|-----------|---------|-------------|
| `postgres.enabled` | `true` | Bundle PostgreSQL + pgvector. |
| `postgres.persistence.size` | `20Gi` | Volume size. |
| `neo4j.enabled` | `true` | Bundle Neo4j. |
| `neo4j.persistence.size` | `20Gi` | Volume size. |
| `meilisearch.enabled` | `true` | Bundle Meilisearch. |
| `meilisearch.persistence.size` | `10Gi` | Volume size. |
| `minio.enabled` | `true` | Bundle MinIO. |
| `minio.persistence.size` | `50Gi` | Volume size. |
| `externalPostgres.host` / `.port` / `.database` / `.user` / `.sslMode` | — | Used only when `postgres.enabled=false`. |
| `externalNeo4j.uri` / `.username` / `.database` | — | Used only when `neo4j.enabled=false`. |
| `externalMeilisearch.host` / `.indexName` | — | Used only when `meilisearch.enabled=false`. |
| `externalMinio.endpoint` / `.useSSL` / `.bucket` | — | Used only when `minio.enabled=false`. |

### Embedding provider

| Parameter | Default | Description |
|-----------|---------|-------------|
| `embedding.provider` | `openai` | `openai`, `ollama`, or `none` (needs `embedding.byov: true`). |
| `embedding.model` | `text-embedding-3-large` | Model name. |
| `embedding.dimensions` | `1024` | Vector size. |
| `secrets.openaiApiKey` | *(empty)* | Required for OpenAI. Can also be set later in Settings → System → Embedding. |

### Licensing and registry access

| Parameter | Default | Description |
|-----------|---------|-------------|
| `secrets.licenseToken` | *(empty)* | **Required** on a default install. Also mints the image-pull credential. |
| `adminApi.updater.registryBroker.enabled` | `true` | Refresh the pull credential from the license. Turn off together with `global.imageOrigin=""`. |
| `licensing.totalSeats` | `10` | Seat count (reflects your license). |
| `licensing.inviteEmail` | `true` | Send invitation email from the app. |

### Administration and self-service upgrades

| Parameter | Default | Description |
|-----------|---------|-------------|
| `adminApi.enabled` | `true` | Administration and licensing services. |
| `adminApi.replicas` | `2` | Replicas. |
| `adminApi.licensing.replicas` | `1` | Licensing service replicas. |
| `adminApi.updater.enabled` | `true` | In-app upgrade. For current releases prefer the Helm CLI — in-app upgrade uses `--atomic --wait` and can hang on post-upgrade hooks. |
| `adminApi.updater.cooldownSeconds` | `900` | Minimum time between accepted upgrade requests. |

### Data collectors (on by default)

Default-on workloads: api, mcp, dispatcher, worker, session-consumer, migrate.
Set `collectors.enabled=false` for a lean daemon-only install.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `collectors.enabled` | `true` | Deploy the data-collection subsystem. |
| `collectors.api.replicas` / `.mcp.replicas` / `.worker.replicas` | `2` | Replica counts. |
| `collectors.healthcheck.enabled` | `false` | Opt-in credential health check. |
| `collectors.hitl.enabled` | `false` | Opt-in HITL answer write-back. |
| `collectors.identityConsumer.enabled` | `false` | Opt-in identity projector. |
| `collectors.webhooks.enabled` | `false` | Opt-in source webhook registration. |
| `collectors.relay.enabled` | `false` | Opt-in dedicated outbox relay (dispatcher already relays each tick). |
| `explore.provider` / `.model` / `.rateLimitPerHour` | `anthropic` / `claude-haiku-4-5-20251001` / `60` | Explore agent. Stays disabled until `secrets.exploreLlmApiKey` is set. |
| `secrets.exploreLlmApiKey` | *(empty)* | Optional. Empty disables the agent. |
| `secrets.collectorsControlPlaneDbPassword` | *(auto)* | Control-plane DB password on bundled Postgres. |
| `secrets.collectorsControlPlaneDsn` | *(empty)* | Full DSN for an external control-plane database. Required when `postgres.enabled=false` and collectors stay on. |
| `secrets.collectorsVaultToken` | *(empty)* | Required only with an external vault. |

### Credential vault, frontend, audit, scheduling

| Parameter | Default | Description |
|-----------|---------|-------------|
| `vault.enabled` | `true` | Bundled HashiCorp Vault, initialized automatically. |
| `collectors.vault.addr` | *(empty)* | Point collectors at a vault you already operate. |
| `frontend.enabled` | `true` | Web application. |
| `frontend.replicas` | `2` | Replicas. |
| `auditLogs.enabled` | `true` | Administrative audit log. |
| `auditLogs.retentionDays` | `365` | Retention before automatic deletion. |
| `podDisruptionBudget.enabled` | `false` | Keep a minimum number of replicas during maintenance. |
| `serviceAccount.create` | `true` | Let the chart create service accounts. |
| `nodeSelector` / `tolerations` / `affinity` | `{}` / `[]` / `{}` | Standard scheduling constraints. |

### Table 1.8-G — Secret keys (`secrets.existingSecret`)

If you supply your own secret, it must contain the keys below for every
component you have enabled.

| Group | Keys |
|-------|------|
| Always required | `TETRIX_PASSWORD`, `AIDB_PASSWORD`, `OPENAI_API_KEY` |
| Bundled databases (if enabled) | `POSTGRES_PASSWORD`, `NEO4J_PASSWORD`, `MEILI_MASTER_KEY`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` |
| Sign-in (default on) | `KEYCLOAK_DB_PASSWORD`, `KEYCLOAK_ADMIN_PASSWORD` |
| Administration (default on) | `ADMIN_API_IAM_PASSWORD`, `LICENSING_IAM_PASSWORD` (each may equal `TETRIX_PASSWORD`) |
| Data collectors (default on) | `CONTROL_PLANE_DSN` or `CONTROL_PLANE_DB_PASSWORD`, plus `COLLECTORS_VAULT_TOKEN` if using an external vault |
| Licensing (default on) | `LICENSE_TOKEN`, `LICENSE_PUBLIC_KEYS` — token required on a default (broker) install; public keys are optional offline verify material (JSON object of kid → SPKI-PEM). When omitted, licensing fetches keys from `ops.deskree.com`. |

---

## After install

| What | URL |
|------|-----|
| Web application | `https://<host>/` |
| Sign-in | `https://<host>/auth` |
| Collectors API | `https://<host>/api/v1` |
| MCP (Streamable HTTP) | `https://<host>/mcp` |
| MCP (Cursor-style SSE) | `https://<host>/mcp/v2/sse` |
| MCP (org-scoped) | `https://<host>/mcp?org=<uuid>` (OAuth audience stays `/mcp` without the query) |

Owner credentials:

```bash
kubectl get secret -n tetrix tetrix-tetrixaidb-keycloak-owner \
  -o jsonpath='{.data.KEYCLOAK_OWNER_EMAIL}' | base64 -d; echo
kubectl get secret -n tetrix tetrix-tetrixaidb-keycloak-owner \
  -o jsonpath='{.data.KEYCLOAK_OWNER_PASSWORD}' | base64 -d; echo
```

Health: `kubectl -n tetrix get pods -l app.kubernetes.io/instance=tetrix` is
authoritative. `helm test tetrix -n tetrix` is blocked by the bundled
NetworkPolicy on current charts (the test pod cannot reach daemon `:9090
/healthz`). No current chart version fixed that — do not treat a passing
`helm test` as a version gate.

### Upgrade / uninstall

```bash
helm upgrade tetrix oci://registry-1.docker.io/deskree/tetrixaidb-chart \
  --version <NEW_VERSION> \
  --namespace tetrix --reuse-values \
  --timeout 25m --wait=false

helm uninstall tetrix -n tetrix
# PVCs are kept on purpose. Delete them only if you intend to wipe data:
# kubectl -n tetrix delete pvc -l app.kubernetes.io/instance=tetrix
```
