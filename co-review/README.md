# Co-review production bundle

Replace `tuzaku95` with your own Docker Hub username (`tuzaku95` is my username). On Linux that value is `REGISTRY`. On Apple Silicon it is the start of each `-t` name.

## 1. Machine that contains the repo (for Zen8labs's team)

You need a clone of `co-review` (this `codev-prod/co-review` folder sits next to it: `…/codev-prod/co-review` and `…/co-review`).

### 1.1 Refresh this bundle from the repo (in `codev-prod/co-review`)

```bash
cd codev-prod/co-review
./copy-from-co-review.sh
```

Commit the changes and push to the repo.

### 1.2 Build and push images (in `co-review`)

From the **co-review repo root** (not this folder). Log in to Docker Hub first. `REGISTRY` must match `COREVIEW_REGISTRY` in `.env`.

The production host is **linux/amd64**. Publish that architecture. Set `COREVIEW_IMAGE_TAG=0.1.2` on the server (the value in `.env.example`).

`NEXT_PUBLIC_BASE_PATH` is a **dashboard build-arg** (Next.js `basePath`). It does not apply to PR-Agent or backup. Omit it only if the UI should live at `/`.

Do **not** run these builds on the production host. After backup is on Hub, start it with `--profile backup` (see below).

#### Linux (amd64)

Use `scripts/docker-buildx-co-review.sh`. On this machine amd64 is native. Set `PLATFORMS=linux/amd64` so the script does not also build arm64 under QEMU.

The script uploads to Docker Hub (`--push` is inside it). PR-Agent is tagged `:0.1.2` and `:latest`. Dashboard and backup take a single tag, so set `DASHBOARD_IMAGE` and `BACKUP_IMAGE` to `:0.1.2`.

```bash
cd co-review
docker login
./scripts/docker-buildx-co-review.sh setup

REGISTRY=tuzaku95 \
COREVIEW_IMAGE_TAG=0.1.2 \
NEXT_PUBLIC_BASE_PATH=/co-review \
PLATFORMS=linux/amd64 \
DASHBOARD_IMAGE=tuzaku95/vtnet-coreview-dashboard:0.1.2 \
BACKUP_IMAGE=tuzaku95/vtnet-coreview-backup:0.1.2 \
  ./scripts/docker-buildx-co-review.sh push
```

After a UI change, run the same variables with `dashboard` instead of `push`. After a backup change, use `backup` instead of `push`.

#### Apple Silicon

Turn on Docker Desktop → Settings → General → **Use Rosetta for x86/amd64 emulation on Apple Silicon**. Build with the `desktop-linux` builder. Do **not** run `./scripts/docker-buildx-co-review.sh push` on this Mac. That script emulates amd64 with QEMU, and the dashboard `bun run build` hangs or aborts (`SIGABRT`).

`--builder desktop-linux` exists only in Docker Desktop. `--push` uploads each image when the build finishes. There is no separate `docker push`.

```bash
cd co-review
docker login

# PR-Agent (API, GitHub, GitLab, Bitbucket, Azure DevOps — one image)
docker buildx build --builder desktop-linux --platform linux/amd64 --push \
  --target pr_agent_runtime \
  -f pr-agent/docker/Dockerfile \
  -t tuzaku95/vtnet-coreview-pr-agent:0.1.2 \
  -t tuzaku95/vtnet-coreview-pr-agent:latest \
  pr-agent

# Dashboard
docker buildx build --builder desktop-linux --platform linux/amd64 --push \
  -f dashboard/Dockerfile \
  --build-arg NEXT_PUBLIC_BASE_PATH=/co-review \
  -t tuzaku95/vtnet-coreview-dashboard:0.1.2 \
  -t tuzaku95/vtnet-coreview-dashboard:latest \
  dashboard

# Backup
docker buildx build --builder desktop-linux --platform linux/amd64 --push \
  -f backup/Dockerfile \
  -t tuzaku95/vtnet-coreview-backup:0.1.2 \
  -t tuzaku95/vtnet-coreview-backup:latest \
  backup
```

After a UI change, rerun only the Dashboard command. After a backup change, rerun only the Backup command.

If the server is ARM instead, use `--platform linux/arm64` on these three commands.

---

## 2. Production machine (no git clone of the app) (for Viettel's team)

### 2.1 Configure `.env`

```bash
cp -n .env.example .env
nano .env
```

(`cp -n` does not overwrite an existing `.env`.)

| Key | Example |
| --- | --- |
| `COREVIEW_REGISTRY` | `tuzaku95` (Docker Hub user; must match the pulled images) |
| `COREVIEW_IMAGE_TAG` | `latest` or `0.1.2` |
| `CO_REVIEW_DASHBOARD_PORT` | `3000` |
| `DASHBOARD_PUBLIC_BASE_URL` | `https://netmind.viettel.vn` (origin only, no `/co-review`) |
| `NEXT_PUBLIC_BASE_PATH` | `/co-review` (must match the baked dashboard image; needed for healthcheck) |
| `SSO_BASE_URL` | `https://netmind.viettel.vn/sso-wrapper` |
| `SSO_CLIENT_ID` | `litellm-test` |
| `SSO_SESSION_SECRET` | output of `openssl rand -base64 48` |
| `DASHBOARD_BOOTSTRAP_ADMIN_EMAILS` | `alice@company.com,bob@company.com` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `postgres` / a strong password / `pr_agent` |
| `DATABASE_URL` | `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}` |
| `GIT_PROVIDER_CREDENTIALS_ENCRYPTION_KEY` | output of `openssl rand -base64 32` |
| `ENCRYPTION_SECRET` | DevLake encrypt-at-rest secret (`openssl rand -base64 2000 \| tr -dc 'A-Z' \| fold -w 128 \| head -n 1`) |
| `DEVLAKE_MYSQL_ROOT_PASSWORD` | a strong password (required if you start DevLake) |
| `AGENT_EXTERNAL_URL` | `http://host.docker.internal:3005` (required if any `*_EXTERNAL=true`) |

### 2.2 Pull images

Private Hub repos need `docker login` on this host. `--profile backup` is required so the backup image is included. PR-Agent, dashboard, and backup all use `COREVIEW_IMAGE_TAG`.

```bash
docker login
docker compose -f docker-compose.prod.yml --env-file .env --profile backup pull
```

### 2.3 Start containers

```bash
./scripts/stack-up.sh
# without DevLake: ./scripts/stack-up.sh --skip-devlake
```

### 2.4 Grafana

Once, after DevLake is healthy. Skip if you do not use Analytics.

```bash
./scripts/devlake-setup-grafana-dashboards.sh
```

Paste the two printed lines into `.env` as `DEVLAKE_GRAFANA_EMBED_BASE_URL` (the URL the browser uses, not `localhost`) and `DEVLAKE_GRAFANA_EMBED_DASHBOARD_UID_MAP`, then recreate the dashboard:

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d dashboard
```

### 2.5 Backup

Starts the backup container and Minio. Postgres must already be up from §2.3.

```bash
docker compose -f docker-compose.prod.yml --env-file .env --profile backup up -d
```
