#!/usr/bin/env bash
# Smoke test for the event automation boundary:
#   Kestra flow -> HTTP POST -> CUGA /events
#
# Requirements:
#   - curl
#   - python3
#   - a CUGA instance exposing POST /events
#   - a Kestra instance, or Docker if using --start-kestra
#
# Example:
#   CUGA_EVENTS_TOKEN=dev-smoke-token \
#   CUGA_EVENTS_URL=http://host.docker.internal:7860/events \
#   ./scripts/smoke_kestra_to_cuga.sh --start-kestra
#
# Success means the Kestra execution reaches SUCCESS after its HTTP Request task
# receives a 2xx response from CUGA.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KESTRA_URL="${KESTRA_URL:-http://127.0.0.1:8080}"
KESTRA_TENANT="${KESTRA_TENANT:-main}"
KESTRA_CONTAINER_NAME="${KESTRA_CONTAINER_NAME:-cuga-kestra-smoke}"
KESTRA_IMAGE="${KESTRA_IMAGE:-kestra/kestra:latest}"
KESTRA_BASIC_AUTH_USERNAME="${KESTRA_BASIC_AUTH_USERNAME:-admin@kestra.local}"
KESTRA_BASIC_AUTH_PASSWORD="${KESTRA_BASIC_AUTH_PASSWORD:-DevSmoke1234!}"
CUGA_EVENTS_URL="${CUGA_EVENTS_URL:-http://host.docker.internal:7860/events}"
CUGA_EVENTS_TOKEN="${CUGA_EVENTS_TOKEN:-dev-smoke-token}"
FLOW_FILE="${FLOW_FILE:-$REPO_ROOT/deployment/kestra/cuga_event_smoke.yaml}"
FLOW_ID="${FLOW_ID:-cuga_event_smoke}"
NAMESPACE="${NAMESPACE:-cuga.smoke}"
START_KESTRA=0
CLEANUP_KESTRA=0
KEEP_KESTRA=0
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"

usage() {
  cat <<EOF
Usage: $0 [--start-kestra] [--no-cleanup] [--kestra-url URL] [--cuga-events-url URL] [--token TOKEN]

Runs a real Kestra flow that POSTs a normalized event to CUGA.

Options:
  --start-kestra       Start a local Kestra Docker container for this smoke test.
  --no-cleanup         Keep the Kestra container running when --start-kestra is used.
  --kestra-url URL     Kestra base URL. Default: $KESTRA_URL
  --tenant NAME        Kestra tenant for newer multi-tenant APIs. Default: $KESTRA_TENANT
  --cuga-events-url URL
                       CUGA /events URL as Kestra can reach it.
                       Default: $CUGA_EVENTS_URL
  --token TOKEN        Bearer token sent to CUGA. Default: value of CUGA_EVENTS_TOKEN or dev-smoke-token.
  --kestra-user USER   Kestra Basic Auth username. Default: $KESTRA_BASIC_AUTH_USERNAME
  --kestra-password PASSWORD
                       Kestra Basic Auth password. Default: value of KESTRA_BASIC_AUTH_PASSWORD.
  -h, --help           Show this help.

Environment variables:
  KESTRA_URL, KESTRA_TENANT, KESTRA_IMAGE, KESTRA_CONTAINER_NAME
  KESTRA_BASIC_AUTH_USERNAME, KESTRA_BASIC_AUTH_PASSWORD
  CUGA_EVENTS_URL, CUGA_EVENTS_TOKEN, FLOW_FILE, TIMEOUT_SECONDS

EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-kestra)
      START_KESTRA=1
      shift
      ;;
    --no-cleanup)
      KEEP_KESTRA=1
      shift
      ;;
    --kestra-url)
      shift
      KESTRA_URL="${1:?--kestra-url requires a URL}"
      shift
      ;;
    --tenant)
      shift
      KESTRA_TENANT="${1:?--tenant requires a name}"
      shift
      ;;
    --cuga-events-url)
      shift
      CUGA_EVENTS_URL="${1:?--cuga-events-url requires a URL}"
      shift
      ;;
    --token)
      shift
      CUGA_EVENTS_TOKEN="${1:?--token requires a value}"
      shift
      ;;
    --kestra-user)
      shift
      KESTRA_BASIC_AUTH_USERNAME="${1:?--kestra-user requires a value}"
      shift
      ;;
    --kestra-password)
      shift
      KESTRA_BASIC_AUTH_PASSWORD="${1:?--kestra-password requires a value}"
      shift
      ;;
    -h | --help)
      usage 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

require_cmd curl
require_cmd python3

curl_auth_args=()
if [[ -n "$KESTRA_BASIC_AUTH_USERNAME" || -n "$KESTRA_BASIC_AUTH_PASSWORD" ]]; then
  curl_auth_args=(-u "$KESTRA_BASIC_AUTH_USERNAME:$KESTRA_BASIC_AUTH_PASSWORD")
fi

if [[ ! -f "$FLOW_FILE" ]]; then
  echo "error: flow file not found: $FLOW_FILE" >&2
  exit 1
fi

cleanup() {
  if [[ "$START_KESTRA" -eq 1 && "$CLEANUP_KESTRA" -eq 1 ]]; then
    docker stop "$KESTRA_CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_kestra() {
  local deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
  echo "==> Waiting for Kestra at $KESTRA_URL"
  while (( $(date +%s) < deadline )); do
    if curl -fsS "${curl_auth_args[@]}" --connect-timeout 2 --max-time 5 "$KESTRA_URL/api/v1/health" >/dev/null 2>&1; then
      echo "==> Kestra is reachable"
      return 0
    fi
    if curl -fsS --connect-timeout 2 --max-time 5 "$KESTRA_URL/ui/" >/dev/null 2>&1; then
      echo "==> Kestra UI is reachable"
      return 0
    fi
    sleep 2
  done
  echo "error: Kestra did not become reachable within ${TIMEOUT_SECONDS}s" >&2
  return 1
}

if [[ "$START_KESTRA" -eq 1 ]]; then
  require_cmd docker
  if [[ "$KEEP_KESTRA" -eq 0 ]]; then
    CLEANUP_KESTRA=1
  fi
  if docker ps --format '{{.Names}}' | grep -qx "$KESTRA_CONTAINER_NAME"; then
    echo "==> Reusing running Kestra container: $KESTRA_CONTAINER_NAME"
    CLEANUP_KESTRA=0
  else
    docker rm -f "$KESTRA_CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "==> Starting Kestra container: $KESTRA_IMAGE"
    docker run -d \
      --name "$KESTRA_CONTAINER_NAME" \
      -p 8080:8080 \
      --add-host=host.docker.internal:host-gateway \
      -e KESTRA_CONFIGURATION="kestra:
  server:
    basic-auth:
      username: $KESTRA_BASIC_AUTH_USERNAME
      password: $KESTRA_BASIC_AUTH_PASSWORD" \
      "$KESTRA_IMAGE" server local >/dev/null
  fi
fi

wait_for_kestra

tmp_dir="$(mktemp -d /tmp/cuga-kestra-smoke.XXXXXX)"
cleanup_tmp() {
  rm -rf "$tmp_dir"
}
trap 'cleanup; cleanup_tmp' EXIT

deploy_body="$tmp_dir/flow.yaml"
cp "$FLOW_FILE" "$deploy_body"

curl_json() {
  local method="$1"
  local url="$2"
  local out="$3"
  shift 3
  curl -sS "${curl_auth_args[@]}" -X "$method" "$url" -o "$out" -w '%{http_code}' "$@"
}

deploy_flow() {
  local body="$1"
  local out="$tmp_dir/deploy.json"
  local status

  echo "==> Deploying flow $NAMESPACE/$FLOW_ID"

  local endpoints=(
    "$KESTRA_URL/api/v1/$KESTRA_TENANT/flows/$NAMESPACE/$FLOW_ID"
    "$KESTRA_URL/api/v1/flows/$NAMESPACE/$FLOW_ID"
  )

  for endpoint in "${endpoints[@]}"; do
    status="$(curl_json PUT "$endpoint" "$out" \
      -H 'Content-Type: application/x-yaml' \
      --data-binary "@$body")"
    if [[ "$status" =~ ^2 ]]; then
      echo "==> Flow deployed with PUT $endpoint"
      return 0
    fi
  done

  local collection_endpoints=(
    "$KESTRA_URL/api/v1/$KESTRA_TENANT/flows"
    "$KESTRA_URL/api/v1/flows"
  )

  for endpoint in "${collection_endpoints[@]}"; do
    status="$(curl_json POST "$endpoint" "$out" \
      -H 'Content-Type: application/x-yaml' \
      --data-binary "@$body")"
    if [[ "$status" =~ ^2 ]]; then
      echo "==> Flow deployed with POST $endpoint"
      return 0
    fi
  done

  echo "error: failed to deploy Kestra flow. Last response:" >&2
  cat "$out" >&2
  echo >&2
  return 1
}

upsert_secret() {
  local key="$1"
  local value="$2"
  local out="$tmp_dir/secret-${key}.json"
  local status
  local endpoints=(
    "$KESTRA_URL/api/v1/$KESTRA_TENANT/namespaces/$NAMESPACE/secrets/$key"
    "$KESTRA_URL/api/v1/namespaces/$NAMESPACE/secrets/$key"
  )

  for endpoint in "${endpoints[@]}"; do
    status="$(curl_json PUT "$endpoint" "$out" \
      -H 'Content-Type: text/plain' \
      --data-binary "$value")"
    if [[ "$status" =~ ^2 ]]; then
      return 0
    fi
  done

  # Some Kestra deployments disable namespace secrets. The flow body is patched
  # below as a fallback, so this is informative rather than fatal.
  return 1
}

patch_flow_without_secrets() {
  python3 - "$deploy_body" "$CUGA_EVENTS_URL" "$CUGA_EVENTS_TOKEN" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
url = sys.argv[2]
token = sys.argv[3]
text = path.read_text()
text = text.replace("{{ secret('CUGA_EVENTS_URL') }}", url)
text = text.replace("Bearer {{ secret('CUGA_EVENTS_TOKEN') }}", f"Bearer {token}")
path.write_text(text)
PY
}

echo "==> Configuring CUGA target for Kestra"
if upsert_secret CUGA_EVENTS_URL "$CUGA_EVENTS_URL" && upsert_secret CUGA_EVENTS_TOKEN "$CUGA_EVENTS_TOKEN"; then
  echo "==> Kestra namespace secrets configured"
else
  echo "==> Namespace secrets unavailable; patching smoke flow with direct CUGA URL/token"
  patch_flow_without_secrets
fi

deploy_flow "$deploy_body"

execute_flow() {
  local out="$tmp_dir/execute.json"
  local status
  local endpoints=(
    "$KESTRA_URL/api/v1/$KESTRA_TENANT/executions/$NAMESPACE/$FLOW_ID"
    "$KESTRA_URL/api/v1/executions/$NAMESPACE/$FLOW_ID"
  )

  echo "==> Executing flow $NAMESPACE/$FLOW_ID" >&2
  for endpoint in "${endpoints[@]}"; do
    status="$(curl_json POST "$endpoint" "$out")"
    if [[ "$status" =~ ^2 ]]; then
      python3 - "$out" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get("id", ""))
PY
      return 0
    fi
  done

  echo "error: failed to execute Kestra flow. Last response:" >&2
  cat "$out" >&2
  echo >&2
  return 1
}

execution_id="$(execute_flow)"
if [[ -z "$execution_id" ]]; then
  echo "error: Kestra execution response did not include an id" >&2
  exit 1
fi
echo "==> Execution id: $execution_id"

get_execution() {
  local execution_id="$1"
  local out="$2"
  local status
  local endpoints=(
    "$KESTRA_URL/api/v1/$KESTRA_TENANT/executions/$execution_id"
    "$KESTRA_URL/api/v1/executions/$execution_id"
  )

  for endpoint in "${endpoints[@]}"; do
    status="$(curl_json GET "$endpoint" "$out")"
    if [[ "$status" =~ ^2 ]]; then
      return 0
    fi
  done
  return 1
}

state_from_execution() {
  python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    data = json.load(f)
state = data.get("state") or {}
print(state.get("current") or state.get("name") or "")
PY
}

terminal_states=' SUCCESS WARNING FAILED KILLED CANCELLED ERROR '
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
execution_json="$tmp_dir/execution.json"

echo "==> Waiting for execution to finish"
while (( $(date +%s) < deadline )); do
  get_execution "$execution_id" "$execution_json" || true
  state="$(state_from_execution "$execution_json" 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    echo "==> Kestra state: $state"
  fi
  if [[ "$terminal_states" == *" $state "* ]]; then
    if [[ "$state" == "SUCCESS" || "$state" == "WARNING" ]]; then
      echo "==> Smoke passed: Kestra POSTed to CUGA and execution finished with $state"
      echo "==> CUGA target: $CUGA_EVENTS_URL"
      exit 0
    fi
    echo "error: Kestra execution ended with $state" >&2
    echo "Execution payload:" >&2
    cat "$execution_json" >&2
    echo >&2
    exit 1
  fi
  sleep 3
done

echo "error: execution did not finish within ${TIMEOUT_SECONDS}s: $execution_id" >&2
exit 1
