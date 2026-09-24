# Co-review production bundle

Should replace `REGISTRY=tuzaku95` with your own Docker Hub username (`tuzaku95` is my username).

## 1. Machine that contains the repo (for Zen8labs's team)

You need a clone of `co-review` (this `codev-prod/co-review` folder sits next to it: `…/codev-prod/co-review` and `…/co-review`).

### 1.1 Build and push images

From the **co-review repo root** (not this folder). Log in to Docker Hub first. `REGISTRY` must match `COREVIEW_REGISTRY` in `.env`.

The production host is **linux/amd64**. These commands publish that architecture and both tags Compose pulls: `:0.1.2` (`COREVIEW_IMAGE_TAG` in `.env.example`) and `:latest`.

On Apple Silicon, turn on Docker Desktop → Settings → General → **Use Rosetta for x86/amd64 emulation on Apple Silicon**. Then build with the `desktop-linux` builder. Do **not** run `./scripts/docker-buildx-co-review.sh push` on this Mac. That script emulates amd64 with QEMU, and the dashboard `bun run build` hangs or aborts (`SIGABRT`).

`NEXT_PUBLIC_BASE_PATH` is a **dashboard build-arg** (Next.js `basePath`). It does not apply to PR-Agent or backup. Omit it only if the UI should live at `/`.

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

If the server is ARM instead, use `--platform linux/arm64` on the same three commands.

Do **not** run these builds on the production host. After backup is on Hub, start it with `--profile backup` (see below).

---

## 2. Production machine (no git clone of the app) (for Viettel's team)

Unzip this folder. Docker Engine + Compose. Private Hub repos: `docker login` on this host too.

### 2.1 Refresh this bundle from the repo

```bash
cd codev-prod/co-review
./copy-from-co-review.sh
```

Fill or keep `.env` (`COREVIEW_REGISTRY`, `COREVIEW_IMAGE_TAG`, SSO, DB, encryption, and `AGENT_EXTERNAL_URL` if any `*_EXTERNAL=true`). Zip this folder yourself when you are ready to take it to the server (omit `.env` from the zip if you prefer to fill secrets only on the host).

### 2.2 Configure and start

Create `.env` **once**, then fill the keys below:

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

```bash
docker compose -f docker-compose.prod.yml --env-file .env pull
./scripts/stack-up.sh
# skip DevLake:  ./scripts/stack-up.sh --skip-devlake

# dashboard only (after changing dashboard env)
docker compose -f docker-compose.prod.yml --env-file .env up -d --force-recreate --no-deps dashboard
```

If host port 3000 is taken, set `CO_REVIEW_DASHBOARD_PORT` in `.env`. Compose health for the dashboard is `GET /api/health` (not `/health`, which SSO redirects).

### 2.3 Login and `/co-review` base path

The `/co-review` prefix is **baked into the dashboard image** at build time (§1.1). You can open `http://localhost:3000/co-review/en-US` even if `.env` has no `NEXT_PUBLIC_BASE_PATH` — Next.js `basePath` does not change when the container starts.

Still set `NEXT_PUBLIC_BASE_PATH=/co-review` in `.env` so it **matches the image**. Compose and `stack-up.sh` use that value for the health probe (`/co-review/api/health`). If it is empty, the site can work while the dashboard container looks **unhealthy**.

| Place               | What to set                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| Image build         | `NEXT_PUBLIC_BASE_PATH=/co-review` on the Dashboard command (see §1.1)                             |
| `.env` (same value) | `NEXT_PUBLIC_BASE_PATH=/co-review` — healthcheck / SSO helpers; does **not** move the app          |
| `.env`              | `DASHBOARD_PUBLIC_BASE_URL=https://your.public.host` — **origin only**, no `/co-review`            |
| SSO IdP             | `redirect_uri` = `{origin}/co-review/auth/sso/callback`                                            |
| Browser             | Open `{origin}/co-review/`                                                                         |
| nginx               | `location /co-review/` must `proxy_pass` to the dashboard **keeping** `/co-review` on the upstream |

If you built the image **without** the build-arg, the app lives at `/`. Setting `/co-review` only in `.env` does not move it.

A public IdP such as `https://netmind.viettel.vn/sso-wrapper` is reachable from the dashboard container with `SSO_BASE_URL` alone. A host-only IdP at `localhost` is rewritten to `host.docker.internal` inside the container (Compose `extra_hosts`).

### 2.4 Grafana embed (once, after DevLake is healthy)

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

### 2.5 Backup (optional)

Requires Hub image `${COREVIEW_REGISTRY}/vtnet-coreview-backup:${COREVIEW_IMAGE_TAG}` (from the Backup command in §1.1).

`--profile backup` starts **backup** and **Minio**. That is enough if Co-review Postgres is already up.

Add `--profile devlake` only if you also want DevLake’s MySQL dumped. The backup job connects to `devlake-mysql`. If you already ran `stack-up.sh` with DevLake, MySQL is running and you can omit `--profile devlake`. If you used `--skip-devlake`, skip it here too (Postgres still backs up; the MySQL dump will fail if that host is missing).

```bash
docker compose -f docker-compose.prod.yml --env-file .env --profile backup up -d

# also dump DevLake MySQL (starts lake/grafana/mysql if they are not running):
# docker compose -f docker-compose.prod.yml --env-file .env --profile backup --profile devlake up -d
```
