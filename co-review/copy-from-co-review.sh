#!/usr/bin/env bash
# Run this on your laptop (next to a co-review checkout). Copies deploy files
# into this folder. Zip the folder yourself afterward.
#
#   cd codev-prod/co-review
#   ./copy-from-co-review.sh
#   # optional: CO_REVIEW_DIR=/path/to/co-review ./copy-from-co-review.sh
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${CO_REVIEW_DIR:-}" ]]; then
  SRC="$CO_REVIEW_DIR"
else
  SRC="$(cd "$DEST/../.." && pwd)/co-review"
fi

if [[ ! -f "$SRC/docker-compose.prod.yml" ]]; then
  echo "co-review not found at $SRC (set CO_REVIEW_DIR)" >&2
  exit 1
fi

mkdir -p "$DEST/scripts"

cp "$SRC/docker-compose.prod.yml" "$DEST/docker-compose.yml"
cp "$SRC/docker-compose.prod.yml" "$DEST/docker-compose.prod.yml"
cp "$SRC/.env.example" "$DEST/.env.example"
cp "$SRC/scripts/stack-up.sh" "$DEST/scripts/stack-up.sh"
cp "$SRC/scripts/validate_env.py" "$DEST/scripts/validate_env.py"
cp "$SRC/scripts/devlake-setup-grafana-dashboards.sh" "$DEST/scripts/devlake-setup-grafana-dashboards.sh"
chmod +x "$DEST/scripts/"*.sh "$DEST/scripts/validate_env.py"

if [[ ! -f "$DEST/.env" ]]; then
  cp "$SRC/.env.example" "$DEST/.env"
  echo "Created .env from .env.example — fill secrets before or after you zip."
fi

echo "Copied from $SRC into $DEST"
echo "Zip this folder yourself when ready."
