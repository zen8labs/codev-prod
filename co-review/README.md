# Co-review production bundle

On your laptop, with `co-review/` next to this folder:

```bash
./copy-from-co-review.sh
```

Then zip this folder and copy it to the server.

## On the server

```bash
# Edit secrets, COREVIEW_REGISTRY, COREVIEW_IMAGE_TAG, SSO, DB, etc.
nano .env

docker compose --env-file .env pull
./scripts/stack-up.sh
# skip DevLake:  ./scripts/stack-up.sh --skip-devlake
```

After DevLake is healthy, once:

```bash
./scripts/devlake-setup-grafana-dashboards.sh
```

Paste the printed Grafana UID lines into `.env`, then:

```bash
docker compose --env-file .env up -d dashboard
```

`docker-compose.yml` here is a copy of `docker-compose.prod.yml` from the repo.
