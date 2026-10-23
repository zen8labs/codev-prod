#!/usr/bin/env bash
# cloned from codev-notes, use once. REMOVE THIS AFTER USING IT IN DEV SERVER

set -euo pipefail

# Must match the project name when you run `docker compose` from dashboard/
# (default: directory name "dashboard"). Override if you set COMPOSE_PROJECT_NAME in .env.
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-dashboard}"
SOURCE_COMPOSE_PROJECT_NAME="${SOURCE_COMPOSE_PROJECT_NAME:-co-review}"

COMPOSE_VOLUME_KEYS=(
  postgres_data
  wal_archive
  devlake_mysql_data
  devlake_grafana_data
  devlake_log
  rustfs_data
)

clone_compose_volume() {
  local key="$1"
  local src="${SOURCE_COMPOSE_PROJECT_NAME}_${key}"
  local dst="${COMPOSE_PROJECT_NAME}_${key}"

  if ! docker volume inspect "$src" >/dev/null 2>&1; then
    echo "SKIP: source volume ${src} does not exist"
    return 0
  fi

  if docker volume inspect "$dst" >/dev/null 2>&1; then
    echo "Removing existing ${dst} ..."
    docker volume rm "$dst"
  fi

  docker volume create "$dst" \
    --label "com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --label "com.docker.compose.volume=${key}"

  docker run --rm \
    -v "${src}:/from:ro" \
    -v "${dst}:/to" \
    alpine sh -c 'cd /from && cp -a . /to'

  echo "OK: ${src} -> ${dst}"
}

for key in "${COMPOSE_VOLUME_KEYS[@]}"; do
  clone_compose_volume "$key"
done

echo "Done."
