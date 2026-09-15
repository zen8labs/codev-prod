# Open-Hand production bundle

Why this folder exists (no app source on the server, prod Compose vs local): `Open-Hand/PRODUCTION_DEPLOYMENT.md` in the git repo.

This README is the **operator runbook**: commands on a machine that has the repo, then commands on a machine that does not.

The Compose file in this folder is `docker-compose.prod.yml` from Open-Hand. You build and push **one** app image. The SDK is copied into that image at build time; **agent-server** is pulled from GHCR at runtime (not pushed from this repo).

Replace `REGISTRY=tuzaku95` with your Docker Hub username (`tuzaku95` is an example).

---

## 1. Machine that contains the repo

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

From the **parent** of `Open-Hand/` and `OpenHands-SDK/` (not from inside `Open-Hand/`, not from this folder). Log in to Docker Hub first. The `-t` registry/name must match `OPENHANDS_REGISTRY` / image name in `.env` (`vtnet-openhands`).

```bash
# Go to the folder that contains BOTH Open-Hand/ and OpenHands-SDK/.
# Docker only COPYs files from this folder (the "build context"). The SDK
# lives next to Open-Hand, so the context cannot be Open-Hand/ itself.
cd parent

# Log in to Docker Hub so --push can upload vtnet-openhands.
docker login

# One-time (or reuse) a buildx builder that can produce linux/amd64 + linux/arm64.
docker buildx create --name openhands-multiarch --driver docker-container --use 2>/dev/null || docker buildx use openhands-multiarch

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -f Open-Hand/containers/app/Dockerfile.local \
  -t tuzaku95/vtnet-openhands:0.1.2 \
  -t tuzaku95/vtnet-openhands:latest \
  --push \
  .
# --platform  CPU types in the image (the server must match one of them)
# -f          Dockerfile, relative to the parent folder you are in now
# -t          Hub name:tag (must match OPENHANDS_REGISTRY / OPENHANDS_IMAGE_TAG)
# --push      Upload to Hub
# .           Build context = this parent folder (so COPY can see Open-Hand AND OpenHands-SDK)
```

**Apple Silicon:** multi-arch `linux/amd64` emulates via QEMU and may be slow or fail. For an ARM server:

```bash
# Same as above, but only ARM (faster on Apple Silicon when the server is ARM).
# Still run from the parent directory. Context `.` is required for the same reason.
docker buildx build \
  --platform linux/arm64 \
  -f Open-Hand/containers/app/Dockerfile.local \
  -t tuzaku95/vtnet-openhands:0.1.2 \
  -t tuzaku95/vtnet-openhands:latest \
  --push \
  .
```

Set `OPENHANDS_REGISTRY=tuzaku95` and `OPENHANDS_IMAGE_TAG=0.1.2` (or `latest`) in the server `.env` to match the tags you pushed.

Do **not** run this build on the production host. Do **not** push the SDK or agent-server from this repo. If `ghcr.io/oadtq/agent-server` is private, `docker login ghcr.io` on the **server** (the app pulls it through the Docker socket on first review).

---

## 2. Production machine (no git clone of the app)

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
