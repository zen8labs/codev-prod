# Open-Hand production bundle

Replace `tuzaku95` with your Docker Hub username (`tuzaku95` is an example). It is the start of each `-t` name.

## 1. Machine that contains the repo (for Zen8labs's team)

You need `Open-Hand/` and sibling `OpenHands-SDK/` (the Dockerfile `COPY OpenHands-SDK`). This folder sits at `…/codev-prod/open-hand`.

```text
parent/
├── Open-Hand/
├── OpenHands-SDK/
└── codev-prod/open-hand/
```

### 1.1 Refresh this bundle from the repo

```bash
cd codev-prod/open-hand
./copy-from-open-hand.sh
# or: OPEN_HAND_DIR=/path/to/Open-Hand ./copy-from-open-hand.sh
```

Fill or keep `.env` (`OPENHANDS_REGISTRY`, `OPENHANDS_IMAGE_TAG`, `SANDBOX_HOST_PORT`, `AGENT_SERVER_IMAGE_*`, `COREVIEW_WEBHOOK_PROCESSING_CALLBACK_URL`). Zip this folder yourself when you are ready to take it to the server (omit `.env` from the zip if you prefer to fill secrets only on the host). Keep `workspace/` in the zip or create it on the server.

### 1.2 Build and push images

From the **parent** of `Open-Hand/` and `OpenHands-SDK/` (not from inside `Open-Hand/`, not from this folder). Docker only copies files from that folder (the build context). The SDK lives next to `Open-Hand/`, so the context cannot be `Open-Hand/` itself.

Log in to Docker Hub first. The `-t` name must match `OPENHANDS_REGISTRY` and `OPENHANDS_IMAGE_TAG` in `.env` (`vtnet-openhands`, `0.1.2`). There is no build script for this image. `--push` uploads it when the build finishes. There is no separate `docker push`.

```text
-f   Dockerfile, relative to the parent folder
-t   Hub name:tag
.    Build context (this parent folder, so COPY can see Open-Hand and OpenHands-SDK)
```

The production host is **linux/amd64**. Set `OPENHANDS_REGISTRY=tuzaku95` and `OPENHANDS_IMAGE_TAG=0.1.2` (or `latest`) in the server `.env` to match the tags you pushed.

Do **not** run this build on the production host. Do **not** push the SDK or agent-server from this repo. If `ghcr.io/oadtq/agent-server` is private, `docker login ghcr.io` on the **server** (the app pulls it through the Docker socket on first review).

#### Linux (amd64)

amd64 is native. Build only that platform so Buildx does not also emulate arm64.

```bash
cd parent
docker login

docker buildx build \
  --platform linux/amd64 \
  -f Open-Hand/containers/app/Dockerfile.local \
  -t tuzaku95/vtnet-openhands:0.1.2 \
  -t tuzaku95/vtnet-openhands:latest \
  --push \
  .
```

#### Apple Silicon

Turn on Docker Desktop → Settings → General → **Use Rosetta for x86/amd64 emulation on Apple Silicon**. Build with the `desktop-linux` builder so the image is still `linux/amd64` for the server. `--builder desktop-linux` exists only in Docker Desktop.

```bash
cd parent
docker login

docker buildx build --builder desktop-linux \
  --platform linux/amd64 \
  -f Open-Hand/containers/app/Dockerfile.local \
  -t tuzaku95/vtnet-openhands:0.1.2 \
  -t tuzaku95/vtnet-openhands:latest \
  --push \
  .
```

If the server is ARM instead, use `--platform linux/arm64` on the same command.

---

## 2. Production machine (no git clone of the app) (for Viettel's team)

Unzip this folder. Docker Engine + Compose. The host needs the Docker socket (sandbox containers). Private Hub repos: `docker login` on this host too.

### 2.1 Configure and start

```bash
mkdir -p workspace
# OPENHANDS_REGISTRY / OPENHANDS_IMAGE_TAG must match what you pushed
nano .env

docker compose -f docker-compose.prod.yml --env-file .env pull
docker compose -f docker-compose.prod.yml --env-file .env up -d
```

Default host port is **3005** (`SANDBOX_HOST_PORT`) so it does not collide with Co-review dashboard `:3000`. Open `http://<host>:3005` → Settings → LLM.

Check:

```bash
curl -s http://127.0.0.1:3005/api/v1/external/health
```

### 2.2 Wire Co-review

On the Co-review host, set `AGENT_EXTERNAL_URL` to this Open-Hand URL (`http://<this-host>:3005`, a public URL, or `http://host.docker.internal:3005` if they share one machine). Enable the external-agent flags Co-review expects. Point `COREVIEW_WEBHOOK_PROCESSING_CALLBACK_URL` in this `.env` at Co-review PR-Agent (`http://<co-review-host>:3001/api/webhooks/processing-callback`, or `http://pr-agent-api:3001/...` only if both stacks share a Compose network).
