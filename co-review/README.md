# Co-review production bundle

Why this folder exists (no app source on the server, prod Compose vs local): `co-review/docs/PRODUCTION_DEPLOYMENT.md` in the git repo.

This README is the **operator runbook**: commands on a machine that has the repo, then commands on a machine that does not.

`docker-compose.yml` here is a copy of `docker-compose.prod.yml` from the repo.

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
```

If the UI is served under a path (for example `/co-review`), bake it at **build** time:

```bash
REGISTRY=your-dockerhub-user NEXT_PUBLIC_BASE_PATH=/co-review ./scripts/docker-buildx-co-review.sh dashboard
```

Do **not** run `docker-buildx-co-review.sh` on the production host. Skip `--profile backup` until a backup image is published.

Azure DevOps webhook image is not tagged by the script; either omit that profile or retag from the API image.

---

## 2. Production machine (no git clone of the app)

Unzip this folder. Docker Engine + Compose. Private Hub repos: `docker login` on this host too.

### 2.1 Configure and start

```bash
# COREVIEW_REGISTRY / COREVIEW_IMAGE_TAG must match what you pushed
nano .env

docker compose --env-file .env pull
./scripts/stack-up.sh
# skip DevLake:  ./scripts/stack-up.sh --skip-devlake
```

If host port 3000 is taken, set `CO_REVIEW_DASHBOARD_PORT` in `.env`. Compose health for the dashboard is `GET /api/health` (not `/health`, which SSO redirects).

Register SSO `redirect_uri` as `{DASHBOARD_PUBLIC_BASE_URL}{NEXT_PUBLIC_BASE_PATH}/auth/sso/callback`.

### 2.2 Grafana embed (once, after DevLake is healthy)

```bash
./scripts/devlake-setup-grafana-dashboards.sh
```

Paste the printed Grafana UID lines into `.env`, then:

```bash
docker compose --env-file .env up -d dashboard
```
