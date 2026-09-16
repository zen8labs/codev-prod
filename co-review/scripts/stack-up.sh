#!/usr/bin/env bash
# Orchestrate Co-review startup: validate env, Compose (dependency order),
# wait for API migrations, then health-check each service.
# Open-Hand is a separate stack (codev-prod/open-hand); do not start it here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
LOG_FILE="${STACK_INIT_LOG:-$ROOT_DIR/logs/stack-init.log}"
if [[ -z "${COMPOSE_FILE:-}" ]]; then
  if [[ -f "$ROOT_DIR/docker-compose.yml" ]]; then
    COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
  else
    COMPOSE_FILE="$ROOT_DIR/docker-compose.prod.yml"
  fi
fi

WITH_DEVLAKE=1
VALIDATE_ONLY=0
HEALTH_ONLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  (default)   Validate .env, start Compose, wait for health, log results
  --validate-only
  --health-only
  --skip-devlake
  --env-file PATH          Default: co-review/.env
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) VALIDATE_ONLY=1 ;;
    --health-only) HEALTH_ONLY=1 ;;
    --skip-devlake) WITH_DEVLAKE=0 ;;
    --with-devlake) WITH_DEVLAKE=1 ;;
    --env-file)
      ENV_FILE="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
  printf '%s\n' "$line" | tee -a "$LOG_FILE"
}

step_ok() { log "OK    $*"; }
step_fail() { log "FAIL  $*"; }
step_skip() { log "SKIP  $*"; }

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

read_env() {
  local key="$1"
  local default_value="${2:-}"
  local parsed=""
  if [[ -f "$ENV_FILE" ]]; then
    parsed="$(
      ENV_FILE_PATH="$ENV_FILE" ENV_KEY="$key" python3 - <<'PY'
import os, re
path = os.environ["ENV_FILE_PATH"]
key = os.environ["ENV_KEY"]
pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$")
ref = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
values = {}
with open(path, encoding="utf-8") as fh:
    for line in fh:
        m = pattern.match(line)
        if not m:
            continue
        raw = m.group(2).strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
            raw = raw[1:-1]
        values[m.group(1)] = raw
for _ in range(8):
    changed = False
    for k, v in list(values.items()):
        nv = ref.sub(lambda m: values.get(m.group(1) or m.group(2), ""), v)
        if nv != v:
            values[k] = nv
            changed = True
    if not changed:
        break
print(values.get(key, ""), end="")
PY
    )"
  fi
  if [[ -n "$parsed" ]]; then
    printf '%s' "$parsed"
  else
    printf '%s' "$default_value"
  fi
}

service_running() {
  local id
  id="$(compose ps --status running -q "$1" 2>/dev/null || true)"
  [[ -n "$id" ]]
}

exec_http() {
  local service="$1"
  local url="$2"
  compose exec -T "$service" sh -c "curl -fsS '$url' >/dev/null || wget -q -O /dev/null '$url'"
}

check_one() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    step_ok "health $name"
    return 0
  fi
  step_fail "health $name"
  return 1
}

run_health() {
  local failed=0
  local base_path pg_user
  base_path="$(read_env NEXT_PUBLIC_BASE_PATH "")"
  pg_user="$(read_env POSTGRES_USER postgres)"

  log "--- health checks ---"

  check_one "postgres (pg_isready)" \
    compose exec -T postgres pg_isready -U "$pg_user" || failed=1

  check_one "pr-agent-api /health" \
    exec_http pr-agent-api "http://127.0.0.1:3001/health" || failed=1

  check_one "pr-agent-api /ready (migrations finished)" \
    exec_http pr-agent-api "http://127.0.0.1:3001/ready" || failed=1

  if service_running pr-agent-github; then
    check_one "pr-agent-github /health" \
      exec_http pr-agent-github "http://127.0.0.1:3000/health" || failed=1
  else
    step_skip "health pr-agent-github (not running)"
  fi

  if service_running pr-agent-gitlab; then
    check_one "pr-agent-gitlab /health" \
      exec_http pr-agent-gitlab "http://127.0.0.1:3000/health" || failed=1
  else
    step_skip "health pr-agent-gitlab (not running)"
  fi

  check_one "dashboard /health" \
    exec_http dashboard "http://127.0.0.1:3000${base_path}/health" || failed=1

  if [[ "$WITH_DEVLAKE" -eq 1 ]]; then
    check_one "devlake /health" \
      exec_http devlake "http://127.0.0.1:8080/health" || failed=1
    check_one "devlake-grafana /api/health" \
      exec_http devlake-grafana "http://127.0.0.1:3000/api/health" || failed=1
    check_one "devlake-config-ui /health/" \
      exec_http devlake-config-ui "http://127.0.0.1:4000/health/" || failed=1
  else
    step_skip "health DevLake/Grafana (profile not requested)"
  fi

  return "$failed"
}

run_validate() {
  log "--- step 1: validate configuration ---"
  local extra=()
  [[ "$WITH_DEVLAKE" -eq 1 ]] && extra+=(--with-devlake)
  if python3 "$ROOT_DIR/scripts/validate_env.py" --env-file "$ENV_FILE" "${extra[@]+"${extra[@]}"}"; then
    step_ok "step 1 configuration"
    return 0
  fi
  step_fail "step 1 configuration"
  return 1
}

require_bin docker
require_bin python3
require_bin curl

log "init log: $LOG_FILE"
log "env file: $ENV_FILE"

if [[ "$HEALTH_ONLY" -eq 1 ]]; then
  run_health
  exit $?
fi

if ! run_validate; then
  exit 1
fi

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
  exit 0
fi

log "--- step 2: Docker Compose (dependency order) ---"
profiles=()
[[ "$WITH_DEVLAKE" -eq 1 ]] && profiles+=(--profile devlake)
if compose "${profiles[@]+"${profiles[@]}"}" up -d --wait; then
  step_ok "step 2 compose up"
else
  step_fail "step 2 compose up"
  exit 1
fi

log "--- step 3: wait for PR-Agent API migrations (/ready) ---"
if exec_http pr-agent-api "http://127.0.0.1:3001/ready"; then
  step_ok "step 3 API ready (schema at head)"
else
  step_fail "step 3 API /ready"
  exit 1
fi

log "--- step 4: health summary ---"
if run_health; then
  step_ok "all requested health checks passed"
  log "done"
  exit 0
fi
step_fail "one or more health checks failed (see lines above)"
exit 1
