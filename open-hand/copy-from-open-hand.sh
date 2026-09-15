#!/usr/bin/env bash
# Run this on your laptop from codev-prod/open-hand. Copies deploy files
# from the Open-Hand checkout. Zip this folder yourself afterward.
#
#   cd codev-prod/open-hand
#   ./copy-from-open-hand.sh
#   # optional: OPEN_HAND_DIR=/path/to/Open-Hand ./copy-from-open-hand.sh
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${OPEN_HAND_DIR:-}" ]]; then
  SRC="$OPEN_HAND_DIR"
else
  SRC="$(cd "$DEST/../.." && pwd)/Open-Hand"
fi

if [[ ! -f "$SRC/docker-compose.prod.yml" ]]; then
  echo "Open-Hand not found at $SRC (set OPEN_HAND_DIR)" >&2
  exit 1
fi

cp "$SRC/docker-compose.prod.yml" "$DEST/docker-compose.yml"
cp "$SRC/docker-compose.prod.yml" "$DEST/docker-compose.prod.yml"
cp "$SRC/.env.example" "$DEST/.env.example"
mkdir -p "$DEST/workspace"

if [[ ! -f "$DEST/.env" ]]; then
  cp "$SRC/.env.example" "$DEST/.env"
  echo "Created .env from .env.example — fill secrets before or after you zip."
fi

echo "Copied from $SRC into $DEST"
echo "Zip this folder yourself when ready."
