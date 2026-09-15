# Co-review production bundle

Why this folder exists (no app source on the server, prod Compose vs local): `co-review/docs/PRODUCTION_DEPLOYMENT.md` in the git repo.

This README is the **operator runbook**: commands on a machine that has the repo, then commands on a machine that does not.

The Compose file in this folder is `docker-compose.prod.yml` from the repo. `stack-up.sh` uses it when `docker-compose.yml` is not present.

---

## 1. Machine that contains the repo

You need a clone of `co-review` (this `codev-prod/co-review` folder sits next to it: `…/codev-prod/co-review` and `…/co-review`).

### 1.1 Refresh this bundle from the repo

```bash
cd codev-prod/co-review
./copy-from-co-review.sh
# or: CO_REVIEW_DIR=/path/to/co-review ./copy-from-co-review.sh
```

Fill or keep `.env` (`COREVIEW_REGISTRY`, `COREVIEW_IMAGE_TAG`, SSO, DB, encryption, and `AGENT_EXTERNAL_URL` if any `*_EXTERNAL=true`). Zip this folder yourself when you are ready to take it to the server (omit `.env` from the zip if you prefer to fill secrets only on the host).

### 1.2 Build and push images

From the **co-review repo root** (not this folder). Log in to Docker Hub first. `REGISTRY` must match `COREVIEW_REGISTRY` in `.env`.

```bash
cd co-review
docker login
./scripts/docker-buildx-co-review.sh setup
REGISTRY=your-dockerhub-user ./scripts/docker-buildx-co-review.sh push
```

That script tags PR-Agent as `:latest` by default. Set `COREVIEW_IMAGE_TAG=latest` in `.env`, or retag to `0.1.2` after push.

**Apple Silicon:** multi-arch `linux/amd64` emulates via QEMU. Dashboard `bun run build` often hangs or SIGABRTs. For an ARM server:

```bash
REGISTRY=your-dockerhub-user PLATFORMS=linux/arm64 ./scripts/docker-buildx-co-review.sh push
```

Dashboard only (after a UI change):

```bash
REGISTRY=your-dockerhub-user PLATFORMS=linux/arm64 ./scripts/docker-buildx-co-review.sh dashboard

REGISTRY=tuzaku95 PLATFORMS=linux/arm64 NEXT_PUBLIC_BASE_PATH=/co-review ./scripts/docker-buildx-co-review.sh dashboard
```

Backup only:

```bash
REGISTRY=your-dockerhub-user PLATFORMS=linux/arm64 ./scripts/docker-buildx-co-review.sh backup
```

If the UI is served under a path (for example `/co-review`), bake it at **build** time:

```bash
REGISTRY=your-dockerhub-user NEXT_PUBLIC_BASE_PATH=/co-review ./scripts/docker-buildx-co-review.sh dashboard
```

Do **not** run `docker-buildx-co-review.sh` on the production host. After backup is on Hub, start it with `--profile backup` (see below).

Azure DevOps webhook image is not tagged by the script; either omit that profile or retag from the API image.

---

## 2. Production machine (no git clone of the app)

Unzip this folder. Docker Engine + Compose. Private Hub repos: `docker login` on this host too.

### 2.1 Configure and start

```bash
# COREVIEW_REGISTRY / COREVIEW_IMAGE_TAG must match what you pushed
nano .env

docker compose -f docker-compose.prod.yml --env-file .env pull
./scripts/stack-up.sh
# skip DevLake:  ./scripts/stack-up.sh --skip-devlake

# dashboard only
# docker compose -f docker-compose.prod.yml --env-file .env up -d --force-recreate --no-deps dashboard
```

If host port 3000 is taken, set `CO_REVIEW_DASHBOARD_PORT` in `.env`. Compose health for the dashboard is `GET /api/health` (not `/health`, which SSO redirects).

### 2.4 Login and `/co-review` base path

`NEXT_PUBLIC_BASE_PATH` is **not** enough in `.env` alone. Next.js `basePath` is fixed when the **dashboard image is built**. Runtime env must match that bake, and SSO/nginx must use the same path.

| Place | What to set |
| --- | --- |
| Image build | `NEXT_PUBLIC_BASE_PATH=/co-review` on `docker-buildx-co-review.sh dashboard` (see §1.2) |
| `.env` (same value) | `NEXT_PUBLIC_BASE_PATH=/co-review` |
| `.env` | `DASHBOARD_PUBLIC_BASE_URL=https://your.public.host` — **origin only**, no `/co-review` |
| SSO IdP | `redirect_uri` = `{DASHBOARD_PUBLIC_BASE_URL}/co-review/auth/sso/callback` |
| Browser | Open `{origin}/co-review/` (not `{origin}/` if basePath is set) |
| nginx | `location /co-review/` must `proxy_pass` to the dashboard **keeping** `/co-review` on the upstream (Next serves that prefix) |

If you built the image **without** the build-arg, the app lives at `/`. Putting `/co-review` only in `.env` makes SSO `redirect_uri` include `/co-review` while Next still serves `/auth/sso/callback` — login breaks. Rebuild the dashboard with the build-arg, or clear `NEXT_PUBLIC_BASE_PATH` and use the site root.

Local sim without nginx: `http://localhost:${CO_REVIEW_DASHBOARD_PORT}/co-review/en-US/login` after a baked image.

Register SSO `redirect_uri` as `{DASHBOARD_PUBLIC_BASE_URL}{NEXT_PUBLIC_BASE_PATH}/auth/sso/callback`.

A public IdP such as `https://netmind.viettel.vn/sso-wrapper` is reachable from the dashboard container with `SSO_BASE_URL` alone. A host-only IdP at `localhost` is rewritten to `host.docker.internal` inside the container (Compose `extra_hosts`).

### 2.2 Grafana embed (once, after DevLake is healthy)

```bash
./scripts/devlake-setup-grafana-dashboards.sh
```

Paste the printed Grafana UID lines into `.env`, then:

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d dashboard
```

### 2.3 Backup (optional)

Requires Hub image `${COREVIEW_REGISTRY}/vtnet-coreview-backup:${COREVIEW_IMAGE_TAG}` (from `docker-buildx-co-review.sh backup` or `push`). Minio is in the same profile.

```bash
docker compose -f docker-compose.prod.yml --env-file .env --profile backup --profile devlake up -d
```
