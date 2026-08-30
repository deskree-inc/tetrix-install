# Tetrix Enterprise installers

Public installers for **Tetrix Enterprise**: Docker Compose (this repository)
and Helm via a published OCI chart. You do **not** need access to any other
Deskree GitHub repository.

Latest published release: **0.8.56**
([GitHub Release](https://github.com/deskree-inc/tetrix-install/releases/tag/v0.8.56)).
This tree's `VERSION` is **0.8.65** (Cloud guest: drop compose init:true so
exec /bin/vault is PID 1; keep /bin/sh + vault-server.sh). First-party `sha-` pins stay at chart 0.8.56. The Helm
OCI chart remains **0.8.54** (latest published chart). A public `v0.8.65`
Release is required before ops can finalize that lock.

Cloud first-provision (`release_catalog`) may only approve a version that exists
as a **published GitHub Release in this repository**. Helm chart tags this repo
has not released (for example helm `v0.8.54`) are not catalog rows. Approval
lives in **Deskree Ops**: auto-approve (`/api/cron/approve-public-install`) or
Support › Releases › Approve. This public repo has no ingest/finalize secrets
and does not call helm `OPS_RELEASE_FINALIZE_TOKEN`. Cutting a new public tag
+ Release is what makes a new lock eligible.

---

## Before you start

| Need | Notes |
|------|-------|
| A Deskree **license token** | Required to pull images from `registry.deskree.com`. Ask your Deskree representative. |
| `OPENAI_API_KEY` | Used for embeddings / semantic search. Compose prompts for it; Helm can set it later in the SPA. |
| Network to `ops.deskree.com` | License verify keys and the short-lived registry credential are minted here. |

Images tagged `deskree/*` pull through **`registry.deskree.com`**, Deskree's
pull-through proxy. The credential is minted from your `LICENSE_TOKEN` and is
valid for **at most an hour**. Third-party images (PostgreSQL/pgvector, Neo4j,
Meilisearch, MinIO, Vault) keep their own public origins.

To evaluate **without** a license token, pull first-party images from Docker Hub
instead (see each path below).

---

## Kubernetes — Helm (production)

The chart is an **OCI artifact**. Install it with Helm — do not clone a chart
source tree.

Requires Helm 3.8+, Kubernetes 1.23+, a StorageClass, a public DNS record, and
TLS (cert-manager ClusterIssuer **or** a pre-created TLS secret).

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

Do **not** pass `--wait` or `--atomic` on a default install. Post-install hooks
(schema, Keycloak, Vault) run after the main workloads; `--wait` blocks on
collectors becoming Ready before those hooks finish. Watch Jobs with
`kubectl -n tetrix get jobs`.

A starter values file is in [`helm/values-example.yaml`](helm/values-example.yaml).
A commented customer-safe skeleton is [`helm/values-reference.yaml`](helm/values-reference.yaml).
The curated parameter catalog (every typical key, Table 1.8-G secret keys, unlicensed
path, external DBs, opt-in collectors) is **[`HELM.md`](HELM.md)**.
You can also `helm show values oci://registry-1.docker.io/deskree/tetrixaidb-chart --version 0.8.54`
for the machine-readable full catalog.

**Without a license token** (Docker Hub / air-gapped / your own mirror).
First-party `deskree/*` images on Docker Hub are **private** — create a pull
secret first or pods stay in `ImagePullBackOff`:

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

Passwords auto-generate on first install and are reused on upgrade. Pin any
secret explicitly with `--set secrets.<name>=…` if you need to.

---

## Docker Compose — evaluation and single-host

Requires Docker + Compose v2.24+, `openssl`, `curl`, and `python3`.

### 1 — Get these files

**Production (recommended):** download the checksummed release asset from this
repository. SHA-256 is also in the [v0.8.56 release notes](https://github.com/deskree-inc/tetrix-install/releases/tag/v0.8.56)
(`bundle_sha256` in `public-release.json`):

```bash
curl -fsSL https://raw.githubusercontent.com/deskree-inc/tetrix-install/main/scripts/download.sh \
  | bash -s -- --version 0.8.56 --sha256 b9243c5edebbef49705d12e0264cbf26444b23c7ac8bd102a6cb9ac5faecb0c4 ~/tetrix-docker
cd ~/tetrix-docker
```

`download.sh` refuses to run unless it gets **both** `--version` and `--sha256`,
and it verifies the checksum before extracting anything.

Already cloned this repo? `cd` into it — the repository root **is** the compose
bundle.

<details>
<summary><strong>Development only:</strong> track the default branch</summary>

`--dev-main` copies this repository's `main` branch. It is **unversioned** — no
release, no checksum — so use it only while developing *on* this bundle, never
for a deployment you have to support:

```bash
curl -fsSL https://raw.githubusercontent.com/deskree-inc/tetrix-install/main/scripts/download.sh \
  | bash -s -- --dev-main ~/tetrix-docker
```

`--dev-main` cannot be combined with `--version` / `--sha256`.

</details>

### 2 — Run setup

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

Put your Deskree license token in `.env` as `LICENSE_TOKEN=…` **before** setup
(or the `deskree/*` image pulls will fail). The script will:

- Create `.env` from `.env.example` if missing
- **Prompt only for `OPENAI_API_KEY`** (or `export OPENAI_API_KEY=sk-...` first)
- Auto-generate unset passwords / Keycloak secrets into `.env`
- Generate TLS certs and Traefik routes
- Add `tetrix.local` to `/etc/hosts` (sudo prompt)
- Fetch Deskree license verify keys
- Mint the `registry.deskree.com` credential and run `docker compose up -d`

Wait 3–6 minutes, then open **https://tetrix.local/**

| What | URL |
|------|-----|
| Web UI | https://tetrix.local/ |
| Sign-in (Keycloak) | https://tetrix.local/auth |
| Collectors API | https://tetrix.local/api/v1 |
| MCP | https://tetrix.local/mcp |
| Daemon (CLI/SDK) | tcp://localhost:7779 |

**SPA login:** `KEYCLOAK_OWNER_EMAIL` / `KEYCLOAK_OWNER_PASSWORD` in `.env`
**Daemon SDK:** `AIDB_USERNAME` / `AIDB_PASSWORD` in `.env`

Accept the self-signed certificate in your browser on first visit.

**Bootstrap only (no start):** `./scripts/setup.sh --no-start`

Frontend + collectors images are multi-arch. Compose defaults
`FRONTEND_PLATFORM` / `COLLECTORS_PLATFORM` to `linux/arm64` (Apple Silicon).
On Intel hosts, set both to `linux/amd64` in `.env`.

**Pulling from Docker Hub instead** — set `TETRIX_IMAGE_ORIGIN=` and
`TETRIX_BROKER_ENABLED=false` in `.env`, then use your own `docker login` if
needed.

---

## Day-to-day (Compose)

```bash
docker compose logs -f keycloak daemon remote frontend collectors-api
docker compose down                  # stop (keeps data)
docker compose down -v               # stop + wipe data
```

Registry credentials expire within the hour. Before a later `docker compose pull`:

```bash
./scripts/registry-login.sh
```

On a long-lived host, install a 30-minute refresh:

```bash
./scripts/install-credential-timer.sh
```

Full reset:

```bash
docker compose down -v
rm -rf runtime/* certs/*
./scripts/setup.sh
```

---

## Upgrades (Compose)

**In-app (Owner):** Settings → System → Platform, after enabling the opt-in
`updater` compose profile:

```bash
docker compose --profile updater up -d updater
```

**Manual:** download the next `deploy-docker-<version>.tgz` from this repo's
[Releases](https://github.com/deskree-inc/tetrix-install/releases), then:

```bash
cd ~/tetrix-docker
cp .env .env.backup
tar -xzf deploy-docker-<version>.tgz --strip-components=1
./scripts/setup.sh --no-start
./scripts/registry-login.sh
docker compose pull
docker compose up -d --remove-orphans
```

`setup.sh` never rotates existing secrets and never overwrites a non-empty pin.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `pull access denied` / `unauthorized` for `deskree/*` | Credential expired (≤ 1 h). `./scripts/registry-login.sh`, then retry. Install `./scripts/install-credential-timer.sh` on long-lived hosts. |
| No licence, or air-gapped host | Set `TETRIX_IMAGE_ORIGIN=` and `TETRIX_BROKER_ENABLED=false` in `.env` |
| Blank UI / crypto errors | Re-run `./scripts/setup.sh` (fixes `/etc/hosts` + certs) |
| `password authentication failed` | `docker compose down -v` then `./scripts/setup.sh` |
| Keycloak not ready | `docker compose logs keycloak keycloak-provision` |
| Collectors worker / Vault | `docker compose logs vault-init vault-unseal collectors-worker` |
| License paste fails with `unknown_kid` | Re-run `./scripts/setup.sh`, recreate `licensing`, then re-paste |
| Setup fails fetching ops keys | Need network to `ops.deskree.com` |
| Intel / amd64 host | Set `FRONTEND_PLATFORM=linux/amd64` and `COLLECTORS_PLATFORM=linux/amd64` |
| `unknown flag: --quiet` / `docker compose` not a command | Install Compose v2 (`docker-compose-v2` on Ubuntu). `setup.sh` installs the plugin when `apt-get` is present. Do not pass `--quiet` to `docker compose pull`. |

Paste a real Deskree-issued license token in the SPA after sign-in (or set
`LICENSE_TOKEN` in `.env` and recreate `licensing`).
