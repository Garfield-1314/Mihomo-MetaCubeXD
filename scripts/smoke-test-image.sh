#!/usr/bin/env bash
set -Eeuo pipefail

# Start the all-in-one image and verify the UI, control API and kernel.
#
#   bash scripts/smoke-test-image.sh metacubexd-server:local
#   bash scripts/smoke-test-image.sh --platform linux/arm64 metacubexd-server:pi
#
# Override SMOKE_HTTP_PORT / SMOKE_API_PORT if the defaults are busy.

IMAGE=""
PLATFORM=""

usage() {
  cat <<EOF
Usage: bash scripts/smoke-test-image.sh [--platform PLATFORM] IMAGE

Options:
  --platform PLATFORM   Run the container with a specific platform
  -h, --help            Show this help

Environment:
  SMOKE_HTTP_PORT   Host port for the dashboard/control API (default: 18080)
  SMOKE_API_PORT    Host port for the Clash API (default: 19090)
  SMOKE_NAME        Container name (default: mcxd-smoke-<pid>)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { echo "error: --platform requires a value" >&2; exit 1; }
      PLATFORM=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      exit 1
      ;;
    *)
      [[ -z "$IMAGE" ]] || { echo "error: only one image may be specified" >&2; exit 1; }
      IMAGE=$1
      shift
      ;;
  esac
done

[[ -n "$IMAGE" ]] || { usage >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 ||
  { echo "error: image not found: $IMAGE" >&2; exit 1; }

NAME=${SMOKE_NAME:-mcxd-smoke-$$}
HTTP_PORT=${SMOKE_HTTP_PORT:-18080}
API_PORT=${SMOKE_API_PORT:-19090}
TOKEN=${SMOKE_TOKEN:-smoke-token}
SECRET=${SMOKE_SECRET:-smoke-secret}
BASE_URL="http://127.0.0.1:${HTTP_PORT}"
API_URL="http://127.0.0.1:${API_PORT}"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

fail() {
  echo "smoke test: FAILED: $*" >&2
  docker logs --tail=120 "$NAME" >&2 || true
  exit 1
}

run_args=(--name "$NAME" -d)
[[ -n "$PLATFORM" ]] && run_args+=(--platform "$PLATFORM")
run_args+=(
  -p "${HTTP_PORT}:8080"
  -p "${API_PORT}:9090"
  -e "CONTROL_TOKEN=${TOKEN}"
  -e "CLASH_SECRET=${SECRET}"
  -e "DEFAULT_BACKEND_URL=http://127.0.0.1:9090"
  -e CONTROL_PORT=8080
  -e CLASH_API_PORT=9090
  -e MIXED_PORT=7890
  -e TZ=Asia/Shanghai
  "$IMAGE"
)

docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "smoke test: checking bundled kernel..."
version_args=(--rm)
[[ -n "$PLATFORM" ]] && version_args+=(--platform "$PLATFORM")
docker run "${version_args[@]}" --entrypoint /usr/local/bin/mihomo "$IMAGE" -v ||
  fail "mihomo -v failed"

echo "smoke test: starting $IMAGE..."
docker run "${run_args[@]}" >/dev/null || fail "container did not start"

healthy=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "${BASE_URL}/api/control/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
[[ "$healthy" == 1 ]] || fail "control API health check timed out"

curl -fsS --max-time 5 "${BASE_URL}/" >/dev/null ||
  fail "dashboard returned an error"

config_js=$(curl -fsS --max-time 5 "${BASE_URL}/config.js" || true)
printf '%s' "$config_js" | grep -q "\"controlToken\":\"${TOKEN}\"" ||
  fail "config.js did not inject CONTROL_TOKEN"
printf '%s' "$config_js" | grep -q "\"defaultBackendSecret\":\"${SECRET}\"" ||
  fail "config.js did not inject CLASH_SECRET"
printf '%s' "$config_js" | grep -q '"defaultBackendURL":"http://127.0.0.1:9090"' ||
  fail "config.js did not inject DEFAULT_BACKEND_URL"

kernel_status=""
for _ in $(seq 1 60); do
  kernel_status=$(curl -fsS --max-time 2 \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE_URL}/api/control/kernel/status" 2>/dev/null || true)
  [[ "$kernel_status" == *'"status":"running"'* ]] && break
  sleep 2
done
[[ "$kernel_status" == *'"status":"running"'* ]] ||
  fail "kernel did not reach running state"

clash_version=$(curl -fsS --max-time 5 \
  -H "Authorization: Bearer ${SECRET}" \
  "${API_URL}/version" 2>/dev/null || true)
[[ "$clash_version" == *'"version"'* ]] ||
  fail "Clash API did not return a version"

echo "smoke test: OK"
echo "  kernel: ${kernel_status}"
echo "  clash:  ${clash_version}"
