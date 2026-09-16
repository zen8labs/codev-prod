# Production deploy (pull and run)

Need Docker on the server. If images are private: `docker login`. Fill `.env` in each folder (`COREVIEW_REGISTRY` / `OPENHANDS_REGISTRY` must match the published images). Details: [co-review/README.md](co-review/README.md), [open-hand/README.md](open-hand/README.md).

---

## 1. Co-review

```bash
cd co-review
nano .env   # COREVIEW_REGISTRY, COREVIEW_IMAGE_TAG, SSO, DB, encryption, NEXT_PUBLIC_BASE_PATH=/co-review (healthcheck)

docker compose -f docker-compose.prod.yml --env-file .env pull
./scripts/stack-up.sh --skip-devlake
```

Open `{host}:3000/co-review/` (or `{host}:3000/` if the image was not built with `/co-review`). Set `CO_REVIEW_DASHBOARD_PORT` if 3000 is taken. Register SSO `redirect_uri` as `{origin}/co-review/auth/sso/callback`.

---

## 2. DevLake + Grafana

Same folder as Co-review. Do **not** run `stack-up.sh` again. Enable the DevLake profile, then wire Analytics once:

```bash
cd co-review
docker compose -f docker-compose.prod.yml --env-file .env --profile devlake up -d
./scripts/devlake-setup-grafana-dashboards.sh
```

In `.env` set (browser URL, not `localhost` on a remote host):

- `DEVLAKE_GRAFANA_EMBED_BASE_URL`
- `DEVLAKE_GRAFANA_EMBED_DASHBOARD_UID_MAP` (e.g. `github:coreview-github,gitlab:coreview-gitlab,bitbucket:coreview-bitbucket`)

```bash
docker compose -f docker-compose.prod.yml --env-file .env up -d dashboard
```

Config UI: port `DEVLAKE_UI_HOST_PORT` (default 30090). Skip this section if you do not need Analytics.

To start Co-review **and** DevLake in one go, use `./scripts/stack-up.sh` (no `--skip-devlake`) in §1 and only run the Grafana script + dashboard recreate here.

---

## 3. Open-Hand

```bash
cd open-hand
mkdir -p workspace
nano .env   # OPENHANDS_REGISTRY, OPENHANDS_IMAGE_TAG, SANDBOX_HOST_PORT=3005, COREVIEW_WEBHOOK_PROCESSING_CALLBACK_URL

docker compose -f docker-compose.prod.yml --env-file .env pull
docker compose -f docker-compose.prod.yml --env-file .env up -d
curl -s http://127.0.0.1:3005/api/v1/external/health
```

Open `{host}:3005` → Settings → LLM. If GHCR agent-server is private: `docker login ghcr.io`.

In Co-review `.env`: `AGENT_EXTERNAL_URL=http://<open-hand-host>:3005` and the `*_EXTERNAL=true` flags you need, then recreate Co-review API/dashboard if those vars changed. In Open-Hand `.env`: `COREVIEW_WEBHOOK_PROCESSING_CALLBACK_URL` → Co-review `http://<co-review-host>:3001/api/webhooks/processing-callback`.
