# Open-Hand production bundle

On your laptop, with `Open-Hand/` next to `codev-prod/` (same parent as `co-review/`):

```bash
./copy-from-open-hand.sh
```

Then zip this folder and copy it to the server.

## On the server

```bash
mkdir -p workspace
# Edit OPENHANDS_REGISTRY, OPENHANDS_IMAGE_TAG, SANDBOX_HOST_PORT,
# AGENT_SERVER_IMAGE_*, COREVIEW_WEBHOOK_PROCESSING_CALLBACK_URL, etc.
nano .env

docker compose --env-file .env pull
docker compose --env-file .env up -d
```

Check: `curl -s http://127.0.0.1:3005/api/v1/external/health`

`docker-compose.yml` here is a copy of `docker-compose.prod.yml` from Open-Hand.
Point Co-review `AGENT_EXTERNAL_URL` at this host (port `SANDBOX_HOST_PORT`, default 3005).
