#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for bin in curl python3; do
  require_bin "$bin"
done

read_env_value() {
  local key="$1"
  local default_value="${2:-}"

  if [[ ! -f "$ENV_FILE" ]]; then
    printf "%s" "$default_value"
    return
  fi

  local parsed
  parsed="$(
    ENV_FILE_PATH="$ENV_FILE" ENV_KEY="$key" python3 - <<'PY'
import os
import re

path = os.environ.get("ENV_FILE_PATH")
key = os.environ.get("ENV_KEY")
pattern = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$')
ref_pattern = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)')

values = {}
with open(path, "r", encoding="utf-8") as file:
    for line in file:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = pattern.match(line.rstrip("\n"))
        if not match:
            continue
        current_key, current_value = match.groups()
        current_value = current_value.strip()
        if len(current_value) >= 2 and (
            (current_value[0] == '"' and current_value[-1] == '"')
            or (current_value[0] == "'" and current_value[-1] == "'")
        ):
            current_value = current_value[1:-1]
        values[current_key] = current_value

def resolve(name, seen):
    if name in seen:
        return values.get(name, os.environ.get(name, ""))
    seen = seen | {name}
    raw = values.get(name)
    if raw is None:
        return os.environ.get(name, "")
    return ref_pattern.sub(lambda m: resolve(m.group(1) or m.group(2), seen), raw)

print("" if key not in values else resolve(key, set()))
PY
  )"

  if [[ -n "$parsed" ]]; then
    printf "%s" "$parsed"
  else
    printf "%s" "$default_value"
  fi
}

DEVLAKE_GRAFANA_ROOT_URL_FILE="$(read_env_value "DEVLAKE_GRAFANA_ROOT_URL" "")"
DEVLAKE_GRAFANA_ADMIN_USER_FILE="$(read_env_value "DEVLAKE_GRAFANA_ADMIN_USER" "")"
DEVLAKE_GRAFANA_ADMIN_PASSWORD_FILE="$(read_env_value "DEVLAKE_GRAFANA_ADMIN_PASSWORD" "")"

GRAFANA_BASE_URL="${GRAFANA_BASE_URL:-${DEVLAKE_GRAFANA_ROOT_URL:-${DEVLAKE_GRAFANA_ROOT_URL_FILE:-http://localhost:30090/grafana}}}"
GRAFANA_BASE_URL="${GRAFANA_BASE_URL%/}"
GRAFANA_API_URL="${GRAFANA_BASE_URL}/api"
GRAFANA_USER="${GRAFANA_USER:-${DEVLAKE_GRAFANA_ADMIN_USER:-${DEVLAKE_GRAFANA_ADMIN_USER_FILE:-admin}}}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-${DEVLAKE_GRAFANA_ADMIN_PASSWORD:-${DEVLAKE_GRAFANA_ADMIN_PASSWORD_FILE:-admin}}}"
GRAFANA_DOCKER_CONTAINER="${GRAFANA_DOCKER_CONTAINER:-co-review-devlake-grafana}"
REQUEST_TRANSPORT="host"

if [[ -z "$GRAFANA_USER" || -z "$GRAFANA_PASSWORD" ]]; then
  echo "Grafana admin credentials are required (DEVLAKE_GRAFANA_ADMIN_USER / DEVLAKE_GRAFANA_ADMIN_PASSWORD)." >&2
  exit 1
fi

request_host() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url="${GRAFANA_API_URL}${path}"
  local response_file
  local status
  response_file="$(mktemp)"

  if [[ -n "$data" ]]; then
    status="$(curl -sS -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
      -H "Content-Type: application/json" \
      -X "$method" \
      "$url" \
      --data "$data" \
      -o "$response_file" \
      -w "%{http_code}")"
  else
    status="$(curl -sS -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
      -H "Content-Type: application/json" \
      -X "$method" \
      "$url" \
      -o "$response_file" \
      -w "%{http_code}")"
  fi

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    local body
    body="$(cat "$response_file")"
    rm -f "$response_file"
    echo "Grafana API request failed: ${method} ${url} -> HTTP ${status}" >&2
    if [[ -n "$body" ]]; then
      echo "$body" >&2
    fi
    if [[ "$status" -eq 403 ]]; then
      echo "Hint: the configured user '${GRAFANA_USER}' is authenticated but lacks required Grafana permissions." >&2
      echo "Use a Grafana server admin account (for example DEVLAKE_GRAFANA_ADMIN_USER/PASSWORD) and rerun." >&2
    fi
    return 22
  fi

  cat "$response_file"
  rm -f "$response_file"
}

request_docker() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url="http://localhost:3000/api${path}"
  local response_file
  local status
  response_file="$(mktemp)"

  if [[ -n "$data" ]]; then
    status="$(printf "%s" "$data" | docker exec -i "$GRAFANA_DOCKER_CONTAINER" sh -lc \
      "curl -sS -u '${GRAFANA_USER}:${GRAFANA_PASSWORD}' -H 'Content-Type: application/json' -X '$method' '$url' --data-binary @- -o /tmp/coreview-grafana-api-response.json -w '%{http_code}'")"
  else
    status="$(docker exec "$GRAFANA_DOCKER_CONTAINER" sh -lc \
      "curl -sS -u '${GRAFANA_USER}:${GRAFANA_PASSWORD}' -H 'Content-Type: application/json' -X '$method' '$url' -o /tmp/coreview-grafana-api-response.json -w '%{http_code}'")"
  fi

  docker exec "$GRAFANA_DOCKER_CONTAINER" sh -lc "cat /tmp/coreview-grafana-api-response.json" >"$response_file"

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    local body
    body="$(cat "$response_file")"
    rm -f "$response_file"
    echo "Grafana API request failed (docker mode): ${method} ${url} -> HTTP ${status}" >&2
    if [[ -n "$body" ]]; then
      echo "$body" >&2
    fi
    return 22
  fi

  cat "$response_file"
  rm -f "$response_file"
}

request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  if [[ "$REQUEST_TRANSPORT" == "docker" ]]; then
    request_docker "$method" "$path" "$data"
    return
  fi
  request_host "$method" "$path" "$data"
}

echo "Waiting for Grafana API at ${GRAFANA_API_URL}/health ..."
for attempt in $(seq 1 30); do
  if request GET "/health" >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    echo "Grafana API is not ready after 30 attempts." >&2
    exit 1
  fi
  sleep 2
done
echo "Grafana API is ready."

USER_INFO=""
if ! USER_INFO="$(request GET "/user" 2>/tmp/coreview-grafana-user.err)"; then
  USER_ERR_CONTENT="$(cat /tmp/coreview-grafana-user.err)"
  if [[ "$USER_ERR_CONTENT" == *"HTTP 401"* ]]; then
    if command -v docker >/dev/null 2>&1; then
      if docker inspect "$GRAFANA_DOCKER_CONTAINER" >/dev/null 2>&1; then
        REQUEST_TRANSPORT="docker"
        if USER_INFO="$(request GET "/user")"; then
          echo "Grafana proxy rejected Basic auth. Switched to docker mode against container '${GRAFANA_DOCKER_CONTAINER}'." >&2
        else
          echo "$USER_ERR_CONTENT" >&2
          exit 1
        fi
      else
        echo "$USER_ERR_CONTENT" >&2
        echo "Could not find Grafana container '${GRAFANA_DOCKER_CONTAINER}' for docker fallback mode." >&2
        exit 1
      fi
    else
      echo "$USER_ERR_CONTENT" >&2
      exit 1
    fi
  else
    echo "$USER_ERR_CONTENT" >&2
    exit 1
  fi
fi
USER_ADMIN_STATUS="$(
  JSON_INPUT="$USER_INFO" python3 - <<'PY'
import json
import os

data = json.loads(os.environ.get("JSON_INPUT", "{}"))
print("true" if data.get("isGrafanaAdmin") else "false")
PY
)"
if [[ "$USER_ADMIN_STATUS" != "true" ]]; then
  USER_LOGIN="$(
    JSON_INPUT="$USER_INFO" python3 - <<'PY'
import json
import os

data = json.loads(os.environ.get("JSON_INPUT", "{}"))
print(data.get("login", "unknown"))
PY
  )"
  echo "Authenticated as '${USER_LOGIN}', but this user is not a Grafana server admin." >&2
  echo "Please provide credentials for a Grafana admin user and rerun." >&2
  exit 1
fi

FOLDER_TITLE="CoReview Dashboards"
FOLDERS_JSON="$(request GET "/folders?limit=1000")"
FOLDER_UID="$(
  JSON_INPUT="$FOLDERS_JSON" python3 - "$FOLDER_TITLE" <<'PY'
import json
import os
import sys

folders = json.loads(os.environ.get("JSON_INPUT", "[]"))
target = sys.argv[1].strip().lower()
for folder in folders:
    title = str(folder.get("title", "")).strip().lower()
    if title == target:
        print(folder.get("uid", ""))
        break
PY
)"

if [[ -z "$FOLDER_UID" ]]; then
  echo "Creating Grafana folder: ${FOLDER_TITLE}"
  CREATE_FOLDER_PAYLOAD="$(python3 - "$FOLDER_TITLE" <<'PY'
import json
import sys

print(json.dumps({"title": sys.argv[1]}))
PY
)"
  CREATE_FOLDER_RESPONSE="$(request POST "/folders" "$CREATE_FOLDER_PAYLOAD")"
  FOLDER_UID="$(
    JSON_INPUT="$CREATE_FOLDER_RESPONSE" python3 - <<'PY'
import json
import os

print(json.loads(os.environ.get("JSON_INPUT", "{}")).get("uid", ""))
PY
)"
  if [[ -z "$FOLDER_UID" ]]; then
    echo "Failed to create or resolve Grafana folder UID." >&2
    exit 1
  fi
fi

pick_source_dashboard_uid() {
  local provider="$1"
  local search_json="$2"

  JSON_INPUT="$search_json" python3 - "$provider" <<'PY'
import json
import os
import sys

provider = sys.argv[1]
rows = json.loads(os.environ.get("JSON_INPUT", "[]"))

provider_markers = {
    "github": ["github"],
    "gitlab": ["gitlab"],
    "bitbucket": ["bitbucket"],
    "azure_devops": ["azure devops", "azuredevops", "azure_devops", "azure"],
}

def score(row):
    title = str(row.get("title", "")).lower()
    uri = str(row.get("uri", "")).lower()
    text = f"{title} {uri}"
    markers = provider_markers[provider]
    if not any(marker in text for marker in markers):
        return -1
    tags = [str(tag).lower() for tag in (row.get("tags") or [])]
    points = 0
    if "coreview" not in text and "demo" not in text:
        points += 4
    if "data source dashboard" in tags:
        points += 4
    if "stable data sources" in tags:
        points += 2
    if "default" in text or "builtin" in text or "built-in" in text:
        points += 2
    # Prefer exact provider dashboard titles (GitHub/GitLab/Azure DevOps)
    provider_titles = {
        "github": "github",
        "gitlab": "gitlab",
        "bitbucket": "bitbucket",
        "azure_devops": "azure devops",
    }
    if title == provider_titles.get(provider, ""):
        points += 5
    return points

candidates = []
for row in rows:
    uid = row.get("uid")
    if not uid:
        continue
    points = score(row)
    if points >= 0:
        candidates.append((points, uid))

candidates.sort(key=lambda item: item[0], reverse=True)
if candidates:
    print(candidates[0][1])
PY
}

duplicate_dashboard() {
  local provider="$1"
  local source_uid="$2"
  local target_title="$3"
  local target_uid="$4"

  local dashboard_json
  dashboard_json="$(request GET "/dashboards/uid/${source_uid}")"

  local payload
  payload="$(
    JSON_INPUT="$dashboard_json" python3 - "$target_title" "$target_uid" "$provider" "$FOLDER_UID" <<'PY'
import json
import os
import sys

data = json.loads(os.environ.get("JSON_INPUT", "{}"))
target_title = sys.argv[1]
target_uid = sys.argv[2]
provider = sys.argv[3]
folder_uid = sys.argv[4]

dashboard = data.get("dashboard") or {}
dashboard["id"] = None
dashboard["uid"] = target_uid
dashboard["title"] = target_title
dashboard["version"] = 0

tags = list(dashboard.get("tags") or [])
for tag in ["coreview", "devlake", provider]:
    if tag not in tags:
        tags.append(tag)
dashboard["tags"] = tags

payload = {
    "dashboard": dashboard,
    "folderUid": folder_uid,
    "overwrite": True,
    "message": "CoReview bootstrap: duplicate built-in DevLake dashboard for embedding",
}
print(json.dumps(payload))
PY
  )"

  request POST "/dashboards/db" "$payload"
}

SEARCH_JSON="$(request GET "/search?type=dash-db&limit=500")"

provider_label() {
  case "$1" in
    github) echo "GitHub" ;;
    gitlab) echo "GitLab" ;;
    bitbucket) echo "Bitbucket" ;;
    azure_devops) echo "Azure DevOps" ;;
    *) echo "$1" ;;
  esac
}

target_uid_for_provider() {
  case "$1" in
    github) echo "coreview-github" ;;
    gitlab) echo "coreview-gitlab" ;;
    bitbucket) echo "coreview-bitbucket" ;;
    azure_devops) echo "coreview-azuredevops" ;;
    *) echo "" ;;
  esac
}

SOURCE_UID_GITHUB="$(pick_source_dashboard_uid "github" "$SEARCH_JSON")"
SOURCE_UID_GITLAB="$(pick_source_dashboard_uid "gitlab" "$SEARCH_JSON")"
SOURCE_UID_BITBUCKET="$(pick_source_dashboard_uid "bitbucket" "$SEARCH_JSON")"
SOURCE_UID_AZURE_DEVOPS="$(pick_source_dashboard_uid "azure_devops" "$SEARCH_JSON")"

if [[ -z "$SOURCE_UID_GITHUB" || -z "$SOURCE_UID_GITLAB" || -z "$SOURCE_UID_BITBUCKET" || -z "$SOURCE_UID_AZURE_DEVOPS" ]]; then
  echo "Could not resolve all built-in DevLake dashboards (github/gitlab/bitbucket/azure_devops)." >&2
  echo "Check Grafana dashboards list manually in /grafana and rerun." >&2
  exit 1
fi

echo "Duplicating dashboards into folder '${FOLDER_TITLE}' ..."
TARGET_UID_GITHUB="$(target_uid_for_provider "github")"
TARGET_UID_GITLAB="$(target_uid_for_provider "gitlab")"
TARGET_UID_BITBUCKET="$(target_uid_for_provider "bitbucket")"
TARGET_UID_AZURE_DEVOPS="$(target_uid_for_provider "azure_devops")"

for provider in github gitlab bitbucket azure_devops; do
  title="CoReview DevLake $(provider_label "$provider")"

  case "$provider" in
    github)
      target_uid="$TARGET_UID_GITHUB"
      source_uid="$SOURCE_UID_GITHUB"
      ;;
    gitlab)
      target_uid="$TARGET_UID_GITLAB"
      source_uid="$SOURCE_UID_GITLAB"
      ;;
    bitbucket)
      target_uid="$TARGET_UID_BITBUCKET"
      source_uid="$SOURCE_UID_BITBUCKET"
      ;;
    azure_devops)
      target_uid="$TARGET_UID_AZURE_DEVOPS"
      source_uid="$SOURCE_UID_AZURE_DEVOPS"
      ;;
  esac

  response="$(duplicate_dashboard "$provider" "$source_uid" "$title" "$target_uid")"
  saved_uid="$(
    JSON_INPUT="$response" python3 - <<'PY'
import json
import os

print(json.loads(os.environ.get("JSON_INPUT", "{}")).get("uid", ""))
PY
  )"
  if [[ -z "$saved_uid" ]]; then
    echo "Failed to duplicate dashboard for ${provider}." >&2
    exit 1
  fi

  case "$provider" in
    github) TARGET_UID_GITHUB="$saved_uid" ;;
    gitlab) TARGET_UID_GITLAB="$saved_uid" ;;
    bitbucket) TARGET_UID_BITBUCKET="$saved_uid" ;;
    azure_devops) TARGET_UID_AZURE_DEVOPS="$saved_uid" ;;
  esac

  echo "  - ${provider}: source=${source_uid} target=${saved_uid}"
done

echo ""
echo "Copy these values into your .env file:"
echo "NEXT_PUBLIC_DEVLAKE_GRAFANA_BASE_URL=${GRAFANA_BASE_URL}"
echo "NEXT_PUBLIC_DEVLAKE_GRAFANA_DASHBOARD_UID_MAP=github:${TARGET_UID_GITHUB},gitlab:${TARGET_UID_GITLAB},bitbucket:${TARGET_UID_BITBUCKET},azure_devops:${TARGET_UID_AZURE_DEVOPS}"
echo ""
echo "Optional direct links:"
echo "GitHub:      ${GRAFANA_BASE_URL}/d/${TARGET_UID_GITHUB}?orgId=1&kiosk&theme=light"
echo "GitLab:      ${GRAFANA_BASE_URL}/d/${TARGET_UID_GITLAB}?orgId=1&kiosk&theme=light"
echo "Bitbucket:   ${GRAFANA_BASE_URL}/d/${TARGET_UID_BITBUCKET}?orgId=1&kiosk&theme=light"
echo "AzureDevOps: ${GRAFANA_BASE_URL}/d/${TARGET_UID_AZURE_DEVOPS}?orgId=1&kiosk&theme=light"
