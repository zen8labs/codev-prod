# Co-review production bundle

Why this folder exists (no app source on the server, prod Compose vs local): `co-review/docs/PRODUCTION_DEPLOYMENT.md` in the git repo.

This README is the **operator runbook**: commands on a machine that has the repo, then commands on a machine that does not.

The Compose file in this folder is `docker-compose.prod.yml` from the repo. `stack-up.sh` uses it when `docker-compose.yml` is not present.

Should replace `REGISTRY=tuzaku95` with your own Docker Hub username (`tuzaku95` is my username).

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

`NEXT_PUBLIC_BASE_PATH` is a **dashboard build-arg** (Next.js `basePath`). It is ignored by `setup`, PR-Agent, and backup. Omit it only if the UI should live at `/`. For `/co-review`, set it on every command that builds the dashboard (`push` and `dashboard`).

```bash
cd co-review
docker login
./scripts/docker-buildx-co-review.sh setup
REGISTRY=tuzaku95 NEXT_PUBLIC_BASE_PATH=/co-review ./scripts/docker-buildx-co-review.sh push
```

That script tags PR-Agent as `:latest` by default. Set `COREVIEW_IMAGE_TAG=latest` in `.env`, or retag to `0.1.2` after push.

**Apple Silicon:** multi-arch `linux/amd64` emulates via QEMU. Dashboard `bun run build` often hangs or SIGABRTs. For an ARM server:

```bash
REGISTRY=tuzaku95 PLATFORMS=linux/arm64 NEXT_PUBLIC_BASE_PATH=/co-review ./scripts/docker-buildx-co-review.sh push
```

Dashboard only (after a UI change):

```bash
REGISTRY=tuzaku95 PLATFORMS=linux/arm64 NEXT_PUBLIC_BASE_PATH=/co-review ./scripts/docker-buildx-co-review.sh dashboard
```

Backup only (no base path):

```bash
REGISTRY=tuzaku95 PLATFORMS=linux/arm64 ./scripts/docker-buildx-co-review.sh backup
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
docker compose -f docker-compose.prod.yml --env-file .env up -d --force-recreate --no-deps dashboard
```

If host port 3000 is taken, set `CO_REVIEW_DASHBOARD_PORT` in `.env`. Compose health for the dashboard is `GET /api/health` (not `/health`, which SSO redirects).

### 2.2 Login and `/co-review` base path

The `/co-review` prefix is **baked into the dashboard image** at build time (§1.2). You can open `http://localhost:3000/co-review/en-US` even if `.env` has no `NEXT_PUBLIC_BASE_PATH` — Next.js `basePath` does not change when the container starts.

Still set `NEXT_PUBLIC_BASE_PATH=/co-review` in `.env` so it **matches the image**. Compose and `stack-up.sh` use that value for the health probe (`/co-review/api/health`). If it is empty, the site can work while the dashboard container looks **unhealthy**.

| Place               | What to set                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| Image build         | `NEXT_PUBLIC_BASE_PATH=/co-review` on `push` / `dashboard` (see §1.2)                              |
| `.env` (same value) | `NEXT_PUBLIC_BASE_PATH=/co-review` — healthcheck / SSO helpers; does **not** move the app          |
| `.env`              | `DASHBOARD_PUBLIC_BASE_URL=https://your.public.host` — **origin only**, no `/co-review`            |
| SSO IdP             | `redirect_uri` = `{origin}/co-review/auth/sso/callback`                                            |
| Browser             | Open `{origin}/co-review/`                                                                         |
| nginx               | `location /co-review/` must `proxy_pass` to the dashboard **keeping** `/co-review` on the upstream |

If you built the image **without** the build-arg, the app lives at `/`. Setting `/co-review` only in `.env` does not move it.

A public IdP such as `https://netmind.viettel.vn/sso-wrapper` is reachable from the dashboard container with `SSO_BASE_URL` alone. A host-only IdP at `localhost` is rewritten to `host.docker.internal` inside the container (Compose `extra_hosts`).

### 2.3 Grafana embed (once, after DevLake is healthy)

`stack-up.sh` only **starts** DevLake and Grafana. It does not create the charts Co-review shows on **Analytics**.

This script talks to Grafana’s API and:

1. Waits until Grafana is up.
2. Makes a folder **CoReview Dashboards**.
3. Copies the built-in GitHub / GitLab / Bitbucket / Azure DevOps dashboards into that folder with **fixed IDs** (`coreview-github`, and so on).
4. Prints Grafana URL + dashboard UID lines for `.env`.

Co-review embeds Grafana by those IDs. Run this **once** per new Grafana (or after Grafana data is wiped). Skip it if you do not use Analytics.

```bash
./scripts/devlake-setup-grafana-dashboards.sh
```

The script prints two `NEXT_PUBLIC_DEVLAKE_GRAFANA_*` lines. On production, paste the **same values** into these `.env` keys (runtime; no image rebuild):

| Script prints                                                                   | Put in `.env`                                                                                                                                                         |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NEXT_PUBLIC_DEVLAKE_GRAFANA_BASE_URL=…`                                        | `DEVLAKE_GRAFANA_EMBED_BASE_URL` — URL the **browser** uses to load Grafana (not `localhost` on a remote server). Example: `https://your.public.host/devlake/grafana` |
| `NEXT_PUBLIC_DEVLAKE_GRAFANA_DASHBOARD_UID_MAP=github:coreview-github,gitlab:…` | `DEVLAKE_GRAFANA_EMBED_DASHBOARD_UID_MAP` — same `github:…,gitlab:…,bitbucket:…,azure_devops:…` string                                                                |

`NEXT_PUBLIC_DEVLAKE_GRAFANA_BASE_URL` and `NEXT_PUBLIC_DEVLAKE_GRAFANA_DASHBOARD_UID_MAP` still work as a fallback (local/dev). Prefer the `DEVLAKE_GRAFANA_EMBED_*` pair in production.

Then recreate the dashboard so it reads `.env`:

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d dashboard
```

### 2.4 Backup (optional)

Requires Hub image `${COREVIEW_REGISTRY}/vtnet-coreview-backup:${COREVIEW_IMAGE_TAG}` (from `docker-buildx-co-review.sh backup` or `push`). Minio is in the same profile.

```bash
docker compose -f docker-compose.prod.yml --env-file .env --profile backup --profile devlake up -d
```
