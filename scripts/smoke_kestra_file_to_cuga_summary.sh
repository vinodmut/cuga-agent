#!/usr/bin/env bash
# Smoke test for a file-driven automation:
#   new transcript file -> Kestra scheduled file poller -> CUGA summary endpoint
#   -> summary markdown file in an outbox directory
#
# Requirements:
#   - curl
#   - python3
#   - Docker if using --start-kestra
#   - a CUGA instance exposing POST /events/meeting-summary
#
# Example:
#   dotenv -e .env -- ./scripts/smoke_kestra_file_to_cuga_summary.sh --start-kestra --no-cleanup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KESTRA_PORT="${KESTRA_PORT:-8081}"
KESTRA_URL="${KESTRA_URL:-http://127.0.0.1:$KESTRA_PORT}"
KESTRA_TENANT="${KESTRA_TENANT:-main}"
KESTRA_CONTAINER_NAME="${KESTRA_CONTAINER_NAME:-cuga-kestra-file-summary-smoke}"
KESTRA_IMAGE="${KESTRA_IMAGE:-kestra/kestra:latest}"
KESTRA_SERVER_COMMAND="${KESTRA_SERVER_COMMAND:-standalone}"
KESTRA_JAVA_TOOL_OPTIONS="${KESTRA_JAVA_TOOL_OPTIONS:-}"
KESTRA_BASIC_AUTH_USERNAME="${KESTRA_BASIC_AUTH_USERNAME:-admin@kestra.local}"
KESTRA_BASIC_AUTH_PASSWORD="${KESTRA_BASIC_AUTH_PASSWORD:-DevSmoke1234!}"
CUGA_EVENTS_TOKEN="${CUGA_EVENTS_TOKEN:-dev-smoke-token}"
if [[ -z "${CUGA_MEETING_SUMMARY_URL:-}" ]]; then
  if [[ -n "${CUGA_EVENTS_URL:-}" ]]; then
    CUGA_MEETING_SUMMARY_URL="${CUGA_EVENTS_URL%/events}/events/meeting-summary"
  else
    CUGA_MEETING_SUMMARY_URL="http://host.docker.internal:7860/events/meeting-summary"
  fi
fi
FLOW_FILE="${FLOW_FILE:-$REPO_ROOT/deployment/kestra/cuga_file_summary_smoke.yaml}"
FLOW_ID="${FLOW_ID:-cuga_file_summary_smoke}"
NAMESPACE="${NAMESPACE:-cuga.smoke}"
SMOKE_ROOT="${SMOKE_ROOT:-/private/tmp/cuga-kestra-file-summary-smoke}"
CONTAINER_ROOT="${CONTAINER_ROOT:-/data/cuga-file-summary-smoke}"
HOST_INBOX="$SMOKE_ROOT/inbox"
HOST_OUTBOX="$SMOKE_ROOT/outbox"
HOST_PROCESSED="$SMOKE_ROOT/processed"
CONTAINER_INBOX="$CONTAINER_ROOT/inbox"
CONTAINER_OUTBOX="$CONTAINER_ROOT/outbox"
CONTAINER_PROCESSED="$CONTAINER_ROOT/processed"
START_KESTRA=0
CLEANUP_KESTRA=0
KEEP_KESTRA=0
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"

usage() {
  cat <<EOF
Usage: $0 [--start-kestra] [--no-cleanup] [--kestra-url URL] [--cuga-summary-url URL] [--token TOKEN]

Runs a real Kestra scheduled file-poller smoke test:
  transcript file -> CUGA meeting summary -> summary file.

Options:
  --start-kestra       Start a local Kestra Docker container for this smoke test.
  --no-cleanup         Keep the Kestra container running when --start-kestra is used.
  --kestra-url URL     Kestra base URL. Default: $KESTRA_URL
  --tenant NAME        Kestra tenant for newer multi-tenant APIs. Default: $KESTRA_TENANT
  --cuga-summary-url URL
                       CUGA /events/meeting-summary URL as Kestra can reach it.
                       Default: $CUGA_MEETING_SUMMARY_URL
  --token TOKEN        Bearer token sent to CUGA. Default: value of CUGA_EVENTS_TOKEN or dev-smoke-token.
  --smoke-root DIR     Host directory mounted into Kestra. Default: $SMOKE_ROOT
  --kestra-port PORT   Host port used when --start-kestra starts Docker. Default: $KESTRA_PORT
  -h, --help           Show this help.

Environment variables:
  KESTRA_URL, KESTRA_TENANT, KESTRA_IMAGE, KESTRA_CONTAINER_NAME
  KESTRA_BASIC_AUTH_USERNAME, KESTRA_BASIC_AUTH_PASSWORD, KESTRA_PORT
  KESTRA_SERVER_COMMAND
  KESTRA_JAVA_TOOL_OPTIONS
  CUGA_MEETING_SUMMARY_URL, CUGA_EVENTS_URL, CUGA_EVENTS_TOKEN
  FLOW_FILE, SMOKE_ROOT, CONTAINER_ROOT, TIMEOUT_SECONDS

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
    --cuga-summary-url)
      shift
      CUGA_MEETING_SUMMARY_URL="${1:?--cuga-summary-url requires a URL}"
      shift
      ;;
    --token)
      shift
      CUGA_EVENTS_TOKEN="${1:?--token requires a value}"
      shift
      ;;
    --smoke-root)
      shift
      SMOKE_ROOT="${1:?--smoke-root requires a directory}"
      HOST_INBOX="$SMOKE_ROOT/inbox"
      HOST_OUTBOX="$SMOKE_ROOT/outbox"
      HOST_PROCESSED="$SMOKE_ROOT/processed"
      shift
      ;;
    --kestra-port)
      shift
      KESTRA_PORT="${1:?--kestra-port requires a port}"
      KESTRA_URL="http://127.0.0.1:$KESTRA_PORT"
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

mkdir -p "$HOST_INBOX" "$HOST_OUTBOX" "$HOST_PROCESSED"
find "$HOST_INBOX" "$HOST_OUTBOX" "$HOST_PROCESSED" -mindepth 1 -maxdepth 1 -type f -delete

wait_for_kestra() {
  local deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
  echo "==> Waiting for Kestra at $KESTRA_URL"
  while (( $(date +%s) < deadline )); do
    local api_status
    api_status="$(curl -sS "${curl_auth_args[@]}" --connect-timeout 2 --max-time 5 \
      -o /dev/null -w '%{http_code}' "$KESTRA_URL/api/v1/$KESTRA_TENANT/flows" 2>/dev/null || true)"
    if [[ "$api_status" =~ ^(200|404|405)$ ]]; then
      echo "==> Kestra API is reachable"
      return 0
    fi
    curl -fsS --connect-timeout 2 --max-time 5 "$KESTRA_URL/ui/" >/dev/null 2>&1 || true
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
    docker_run_args=(
      --name "$KESTRA_CONTAINER_NAME" \
      -p "$KESTRA_PORT:8080" \
      --add-host=host.docker.internal:host-gateway \
      -v "$SMOKE_ROOT:$CONTAINER_ROOT" \
      -e KESTRA_CONFIGURATION="kestra:
  repository:
    type: h2
  queue:
    type: h2
  storage:
    type: local
    local:
      base-path: /app/storage
  plugins:
    configurations:
      - type: io.kestra.plugin.fs.local
        values:
          allowed-paths:
            - $CONTAINER_ROOT
  tutorialFlows:
    enabled: false
  server:
    basic-auth:
      username: $KESTRA_BASIC_AUTH_USERNAME
      password: $KESTRA_BASIC_AUTH_PASSWORD
plugins:
  configurations:
    - type: io.kestra.plugin.fs.local
      values:
        allowed-paths:
          - $CONTAINER_ROOT"
    )
    if [[ -n "$KESTRA_JAVA_TOOL_OPTIONS" ]]; then
      docker_run_args=(-e JAVA_TOOL_OPTIONS="$KESTRA_JAVA_TOOL_OPTIONS" "${docker_run_args[@]}")
    fi
    docker run -d "${docker_run_args[@]}" "$KESTRA_IMAGE" server "$KESTRA_SERVER_COMMAND" >/dev/null
  fi
fi

wait_for_kestra

tmp_dir="$(mktemp -d /tmp/cuga-kestra-file-summary.XXXXXX)"
cleanup_tmp() {
  rm -rf "$tmp_dir"
}
trap 'cleanup; cleanup_tmp' EXIT

deploy_body="$tmp_dir/flow.yaml"
python3 - "$FLOW_FILE" "$deploy_body" "$CUGA_MEETING_SUMMARY_URL" "$CUGA_EVENTS_TOKEN" "$CONTAINER_INBOX" "$CONTAINER_OUTBOX" "$CONTAINER_PROCESSED" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
summary_url = sys.argv[3]
token = sys.argv[4]
inbox = sys.argv[5]
outbox = sys.argv[6]
processed = sys.argv[7]

text = source.read_text()
text = text.replace("__CUGA_MEETING_SUMMARY_URL__", summary_url)
text = text.replace("__CUGA_EVENTS_TOKEN__", token)
text = text.replace("__TRANSCRIPT_INBOX_DIR__", inbox)
text = text.replace("__SUMMARY_OUTPUT_DIR__", outbox)
text = text.replace("__PROCESSED_TRANSCRIPT_DIR__", processed)
target.write_text(text)
PY

curl_json() {
  local method="$1"
  local url="$2"
  local out="$3"
  shift 3
  curl -sS "${curl_auth_args[@]}" --connect-timeout 5 --max-time 30 -X "$method" "$url" -o "$out" -w '%{http_code}' "$@"
}

deploy_flow() {
  local body="$1"
  local out="$tmp_dir/deploy.json"
  local status

  echo "==> Deploying flow $NAMESPACE/$FLOW_ID"

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

  echo "error: failed to deploy Kestra flow. Last response:" >&2
  cat "$out" >&2
  echo >&2
  return 1
}

deploy_flow "$deploy_body"

sample_id="$(date +%s)"
transcript_file="$HOST_INBOX/product-launch-sync-$sample_id.txt"
summary_file="$HOST_OUTBOX/product-launch-sync-$sample_id.summary.md"

cat > "$transcript_file" <<'EOF'
Meeting: Product launch sync
Date: 2026-06-05
Attendees: Alex, Priya, Morgan
Agenda: Launch readiness, documentation, customer communications

Alex confirmed the release candidate is stable and the support runbook is almost complete.
Priya noted that customer-facing documentation needs one more API authentication example.
Morgan reported that the pilot customer list is ready for review.
Decision: keep the launch date on June 12 if documentation is finished by Monday.
Action: Priya will publish the final documentation update by Monday 10 AM.
Action: Morgan will send the pilot customer communication draft to Alex today.
Follow-up: Alex will schedule a launch readiness checkpoint for Tuesday.
EOF

echo "==> Wrote transcript: $transcript_file"
echo "==> Waiting for summary: $summary_file"

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while (( $(date +%s) < deadline )); do
  if [[ -s "$summary_file" ]]; then
    if grep -q "Meeting Summary" "$summary_file"; then
      echo "==> Smoke passed: Kestra wrote CUGA summary to $summary_file"
      echo "==> Summary preview:"
      sed -n '1,80p' "$summary_file"
      exit 0
    fi
    echo "error: summary file exists but does not look like a CUGA meeting summary: $summary_file" >&2
    sed -n '1,120p' "$summary_file" >&2
    exit 1
  fi
  sleep 3
done

echo "error: summary file was not written within ${TIMEOUT_SECONDS}s" >&2
echo "Transcript: $transcript_file" >&2
echo "Expected summary: $summary_file" >&2
exit 1
