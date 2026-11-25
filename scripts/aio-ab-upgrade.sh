#!/usr/bin/env bash
# shellcheck disable=SC2016 # Compose expressions like ${AIO_IMAGE} are literals.
set -Eeuo pipefail

# Host-side A/B upgrade for the MetaCubeXD AIO bypass router.
#
# The script is intentionally self-contained: the installer copies it to
# /opt/metacubexd/aio-ab-upgrade.sh and the Pi bundle ships it next to the
# installer. It never builds an image on the Pi.
#
# Flow:
#   1. load the new image into the inactive slot
#   2. precheck it (mihomo -t + a bridge-network control-plane smoke test)
#   3. snapshot .env, compose and the data volume
#   4. recreate the container with the new slot
#   5. run host-side health/TUN/DNS/data-path/provider checks for 90 s
#   6. commit the new slot, or restore the old slot and data on failure
#
# A marker is written before the switch. If the host reboots mid-upgrade, the
# installed metacubexd-upgrade-recover.service runs this script with --recover
# and rolls back to the previous slot.
#
# Usage:
#   sudo /opt/metacubexd/aio-ab-upgrade.sh --archive metacubexd-server-pi.tar.gz
#   sudo /opt/metacubexd/aio-ab-upgrade.sh --image metacubexd-server:pi-test
#   sudo /opt/metacubexd/aio-ab-upgrade.sh --self-test-only
#   sudo /opt/metacubexd/aio-ab-upgrade.sh --recover
#
# The default is to detach via systemd-run, so an SSH disconnect cannot stop
# the upgrade. Use --foreground for an interactive run.

APP_DIR=${APP_DIR:-/opt/metacubexd}
AB_DIR=${AB_DIR:-$APP_DIR/ab}
BACKUP_DIR=${BACKUP_DIR:-$APP_DIR/backups}
CONTAINER_NAME=${CONTAINER_NAME:-metacubexd}
COMPOSE_FILE=$APP_DIR/compose.yaml
MARKER=$AB_DIR/upgrade-in-progress
ACTIVE_SLOT_FILE=$AB_DIR/active-slot
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")

AIO_SLOT_PREFIX=${AIO_SLOT_PREFIX:-}
AIO_IMAGE=${AIO_IMAGE:-}
IMAGE_TAG=${IMAGE_TAG:-}
DATA_VOLUME=${DATA_VOLUME:-}
LAN_IP=${LAN_IP:-}
CONTROL_TOKEN=${CONTROL_TOKEN:-}
CLASH_SECRET=${CLASH_SECRET:-}
CONTROL_PORT=${CONTROL_PORT:-8080}
CLASH_API_PORT=${CLASH_API_PORT:-9090}
MIXED_PORT=${MIXED_PORT:-7890}
TUN_DEVICE=${AB_TUN_DEVICE:-Meta}
ROUTE_TABLE=${AB_ROUTE_TABLE:-2022}
TUN_RULE_INDEX=${AB_TUN_RULE_INDEX:-9000}
AUTO_REDIRECT_RULE_A=${AB_AUTO_REDIRECT_RULE_A:-9001}
AUTO_REDIRECT_RULE_B=${AB_AUTO_REDIRECT_RULE_B:-9002}

AB_TEST_NETNS=${AB_TEST_NETNS:-mcxd-ab-test}
AB_TEST_VETH=${AB_TEST_VETH:-mcxd-ab0}
AB_TEST_HOST_IP=${AB_TEST_HOST_IP:-100.64.0.1}
AB_TEST_CLIENT_IP=${AB_TEST_CLIENT_IP:-100.64.0.2}
AB_TEST_PREFIX=${AB_TEST_PREFIX:-30}

HEALTH_TIMEOUT=${AB_HEALTH_TIMEOUT:-60}
KERNEL_TIMEOUT=${AB_KERNEL_TIMEOUT:-30}
CANDIDATE_TIMEOUT=${AB_CANDIDATE_TIMEOUT:-180}
WARMUP_SECONDS=${AB_WARMUP_SECONDS:-30}
STABILITY_SAMPLES=${AB_STABILITY_SAMPLES:-9}
SAMPLE_INTERVAL=${AB_SAMPLE_INTERVAL:-10}
TOTAL_TIMEOUT=${AB_TOTAL_TIMEOUT:-300}
MIN_PROVIDER_RATIO=${AB_MIN_PROVIDER_RATIO:-80}

ARCHIVE=""
IMAGE_INPUT=""
TARGET_SLOT=""
CHILD_ARGS=()
SELF_TEST_ONLY=0
RECOVER=0
DETACH=1
NO_DETACH=0
NO_DATA_RESTORE=0
IN_ROLLBACK=0
NETNS_READY=0
OLD_RP_FILTER=""
CANDIDATE_NAME=""
CANDIDATE_DATA=""
PRECHECK_DATA=""
HISTORY_DIR=""
LOG_FILE=""
TS=""
PHASE=""
BASELINE_PROVIDER_TOTAL=0
CONTAINER_START_AT=""
CONTAINER_RESTART_COUNT=""
KERNEL_PID=""
SWITCH_START=0
START_TS=""

die() {
  log "ERROR: $*"
  exit 1
}

warn() {
  log "WARN: $*"
}

log() {
  local line
  line="[$(date '+%F %T')] $*"
  printf '%s\n' "$line"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

usage() {
  cat <<'EOF'
Usage: sudo aio-ab-upgrade.sh [options]

Options:
  --archive FILE       docker-save archive of the new image (.tar/.tar.gz)
  --image REF          use an already-loaded image instead of an archive
  --slot a|b           target slot (default: the inactive slot)
  --self-test-only     run the host self-test against the current deployment
  --recover            roll back an interrupted upgrade left by a marker
  --foreground         do not detach via systemd-run
  --no-detach          internal: already running under systemd-run
  --no-data-restore    do not restore the data snapshot during rollback
  -h, --help           show this help

The default is to detach through systemd-run. Monitor it with:
  sudo journalctl -u metacubexd-ab-upgrade -f
  sudo cat /opt/metacubexd/ab/upgrade-in-progress

State:
  /opt/metacubexd/ab/active-slot
  /opt/metacubexd/ab/upgrade-in-progress
  /opt/metacubexd/ab/history/<timestamp>/upgrade.log
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive)
        [[ $# -ge 2 ]] || die "--archive requires a value"
        ARCHIVE=$2
        shift 2
        ;;
      --image)
        [[ $# -ge 2 ]] || die "--image requires a value"
        IMAGE_INPUT=$2
        shift 2
        ;;
      --slot)
        [[ $# -ge 2 ]] || die "--slot requires a value"
        TARGET_SLOT=$2
        shift 2
        ;;
      --self-test-only)
        SELF_TEST_ONLY=1
        DETACH=0
        shift
        ;;
      --recover)
        RECOVER=1
        DETACH=0
        shift
        ;;
      --foreground)
        DETACH=0
        shift
        ;;
      --detach)
        DETACH=1
        shift
        ;;
      --no-detach)
        NO_DETACH=1
        shift
        ;;
      --no-data-restore)
        NO_DATA_RESTORE=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (use --help)"
        ;;
    esac
  done

  if [[ "$SELF_TEST_ONLY" == 0 && "$RECOVER" == 0 ]]; then
    [[ -n "$ARCHIVE" || -n "$IMAGE_INPUT" ]] ||
      die "one of --archive or --image is required"
    [[ -z "$ARCHIVE" || -z "$IMAGE_INPUT" ]] ||
      die "use either --archive or --image, not both"
    if [[ -n "$ARCHIVE" ]]; then
      [[ -f "$ARCHIVE" ]] || die "archive not found: $ARCHIVE"
      ARCHIVE=$(readlink -f "$ARCHIVE")
    fi
    # systemd-run starts the child in /, so rebuild the arguments from the
    # resolved values instead of forwarding a possibly relative archive path.
    CHILD_ARGS=()
    if [[ -n "$ARCHIVE" ]]; then
      CHILD_ARGS+=(--archive "$ARCHIVE")
    else
      CHILD_ARGS+=(--image "$IMAGE_INPUT")
    fi
    [[ -n "$TARGET_SLOT" ]] && CHILD_ARGS+=(--slot "$TARGET_SLOT")
    [[ "$NO_DATA_RESTORE" == 1 ]] && CHILD_ARGS+=(--no-data-restore)
    CHILD_ARGS+=(--no-detach)
  fi
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run this script as root (sudo)"
}

require_commands() {
  local cmd
  for cmd in docker curl jq dig ip iptables ss sysctl timeout tar gzip date; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
  done
  if [[ "$DETACH" == 1 && "$NO_DETACH" == 0 ]]; then
    command -v systemd-run >/dev/null 2>&1 ||
      die "systemd-run is required for detached upgrades; use --foreground"
  fi
}

detach_if_requested() {
  if [[ "$DETACH" != 1 || "$NO_DETACH" == 1 ]]; then
    return 0
  fi
  local unit=metacubexd-ab-upgrade
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  log "detaching upgrade as systemd unit $unit"
  if ! systemd-run \
    --unit="$unit" \
    --collect \
    --property=Type=oneshot \
    --property=TimeoutStartSec=900 \
    --property=StandardOutput=journal \
    --property=StandardError=journal \
    --setenv=APP_DIR="$APP_DIR" \
    --setenv=AB_DIR="$AB_DIR" \
    --setenv=BACKUP_DIR="$BACKUP_DIR" \
    --setenv=CONTAINER_NAME="$CONTAINER_NAME" \
    /bin/bash "$SCRIPT_PATH" "${CHILD_ARGS[@]}" >/dev/null; then
    die "failed to start systemd unit $unit; check journalctl -u $unit"
  fi
  log "upgrade started; monitor with: journalctl -u $unit -f"
  exit 0
}

read_env() {
  local key=$1
  sed -n "s/^${key}=//p" "$APP_DIR/.env" 2>/dev/null | tail -n1
}

set_env() {
  local key=$1
  local value=$2
  local tmp
  [[ -f "$APP_DIR/.env" ]] || die "missing $APP_DIR/.env"
  tmp=$(mktemp "$APP_DIR/.env.XXXXXX")
  awk -v k="$key" -v v="$value" '
    BEGIN { found = 0 }
    $0 ~ "^" k "=" { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$APP_DIR/.env" >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$APP_DIR/.env"
}

slot_image() {
  printf '%s-%s\n' "${AIO_SLOT_PREFIX%-}" "$1"
}

load_env() {
  [[ -f "$APP_DIR/.env" ]] || die "missing $APP_DIR/.env"

  DATA_VOLUME=${DATA_VOLUME:-$(read_env DATA_VOLUME)}
  if [[ -z "$DATA_VOLUME" ]]; then
    if docker volume inspect metacubexd_metacubexd-data >/dev/null 2>&1; then
      DATA_VOLUME=metacubexd_metacubexd-data
    elif docker volume inspect metacubexd-data >/dev/null 2>&1; then
      DATA_VOLUME=metacubexd-data
    else
      DATA_VOLUME=metacubexd-data
    fi
  fi

  LAN_IP=${LAN_IP:-$(read_env LAN_IP)}
  if [[ -z "$LAN_IP" ]]; then
    LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
  fi
  [[ -n "$LAN_IP" ]] || die "could not determine LAN_IP; set it in $APP_DIR/.env"

  IMAGE_TAG=${IMAGE_TAG:-$(read_env IMAGE_TAG)}
  AIO_IMAGE=${AIO_IMAGE:-$(read_env AIO_IMAGE)}
  AIO_SLOT_PREFIX=${AIO_SLOT_PREFIX:-$(read_env AIO_SLOT_PREFIX)}
  AIO_SLOT_PREFIX=${AIO_SLOT_PREFIX:-${IMAGE_TAG:-metacubexd-server:pi}}
  AIO_SLOT_PREFIX=${AIO_SLOT_PREFIX%-}

  CONTROL_TOKEN=${CONTROL_TOKEN:-$(read_env CONTROL_TOKEN)}
  CLASH_SECRET=${CLASH_SECRET:-$(read_env CLASH_SECRET)}

  local volume_path
  volume_path=$(docker volume inspect -f '{{ .Mountpoint }}' "$DATA_VOLUME" 2>/dev/null || true)
  [[ -n "$volume_path" && -d "$volume_path" ]] ||
    die "data volume $DATA_VOLUME is missing"

  COMPOSE_AVAILABLE=0
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_AVAILABLE=1
  fi

  AUTH=()
  if [[ -n "$CONTROL_TOKEN" ]]; then
    AUTH=(-H "Authorization: Bearer $CONTROL_TOKEN")
  fi
  CLASH_AUTH=()
  if [[ -n "$CLASH_SECRET" ]]; then
    CLASH_AUTH=(-H "Authorization: Bearer $CLASH_SECRET")
  fi
}

init_history() {
  TS=$(date +%Y%m%d-%H%M%S)-$$
  HISTORY_DIR=$AB_DIR/history/$TS
  LOG_FILE=$HISTORY_DIR/upgrade.log
  mkdir -p "$AB_DIR" "$BACKUP_DIR" "$HISTORY_DIR"
  chmod 0700 "$AB_DIR" "$HISTORY_DIR"
  log "history: $HISTORY_DIR"
}

migrate_compose() {
  # shellcheck disable=SC2016 # ${AIO_IMAGE} is a literal Compose expression.
  [[ -f "$COMPOSE_FILE" ]] || return 0
  if grep -qF 'image: ${AIO_IMAGE}' "$COMPOSE_FILE"; then
    return 0
  fi
  sed -i '0,/^[[:space:]]*image:[[:space:]].*/s//    image: ${AIO_IMAGE}/' "$COMPOSE_FILE"
  grep -qF 'image: ${AIO_IMAGE}' "$COMPOSE_FILE" ||
    die "could not migrate $COMPOSE_FILE to use AIO_IMAGE"
  log "migrated compose image to \${AIO_IMAGE}"
}

migrate_layout() {
  mkdir -p "$AB_DIR" "$BACKUP_DIR"

  if [[ ! -f "$ACTIVE_SLOT_FILE" ]]; then
    local current current_id
    current=${AIO_IMAGE:-${IMAGE_TAG:-$AIO_SLOT_PREFIX}}
    current_id=$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
    if [[ -n "$current_id" ]]; then
      current=$current_id
    fi
    if ! docker image inspect "$current" >/dev/null 2>&1; then
      current=$(slot_image a)
      docker image inspect "$current" >/dev/null 2>&1 ||
        die "current image is missing; cannot initialize A/B layout"
    fi
    docker tag "$current" "$(slot_image a)"
    printf 'a\n' >"$ACTIVE_SLOT_FILE"
    set_env AIO_SLOT_PREFIX "$AIO_SLOT_PREFIX"
    set_env AIO_IMAGE "$(slot_image a)"
    migrate_compose
    log "initialized A/B layout: active=a image=$current"
  fi

  ACTIVE_SLOT=$(cat "$ACTIVE_SLOT_FILE")
  case "$ACTIVE_SLOT" in
    a | b) ;;
    *) die "invalid active slot: $ACTIVE_SLOT" ;;
  esac

  if ! docker image inspect "$(slot_image "$ACTIVE_SLOT")" >/dev/null 2>&1; then
    local fallback
    fallback=${AIO_IMAGE:-${IMAGE_TAG:-}}
    if [[ -n "$fallback" ]] && docker image inspect "$fallback" >/dev/null 2>&1; then
      docker tag "$fallback" "$(slot_image "$ACTIVE_SLOT")"
    else
      die "active slot image $(slot_image "$ACTIVE_SLOT") is missing"
    fi
  fi

  set_env AIO_SLOT_PREFIX "$AIO_SLOT_PREFIX"
  set_env AIO_IMAGE "$(slot_image "$ACTIVE_SLOT")"
  migrate_compose
}

inactive_slot() {
  if [[ "$ACTIVE_SLOT" == a ]]; then
    printf 'b\n'
  else
    printf 'a\n'
  fi
}

resolve_new_slot() {
  if [[ -n "$TARGET_SLOT" ]]; then
    case "$TARGET_SLOT" in
      a | b) ;;
      *) die "--slot must be a or b" ;;
    esac
    [[ "$TARGET_SLOT" != "$ACTIVE_SLOT" ]] ||
      die "target slot $TARGET_SLOT is already active"
    NEW_SLOT=$TARGET_SLOT
  else
    NEW_SLOT=$(inactive_slot)
  fi
  OLD_IMAGE=$(slot_image "$ACTIVE_SLOT")
  NEW_IMAGE=$(slot_image "$NEW_SLOT")
  OLD_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$OLD_IMAGE")
  log "active slot: $ACTIVE_SLOT ($OLD_IMAGE)"
  log "target slot: $NEW_SLOT ($NEW_IMAGE)"
}

load_new_image() {
  local loaded ref image_id
  if [[ -n "$IMAGE_INPUT" ]]; then
    docker image inspect "$IMAGE_INPUT" >/dev/null 2>&1 ||
      die "image not found: $IMAGE_INPUT"
    loaded=$IMAGE_INPUT
    image_id=$(docker image inspect -f '{{.Id}}' "$loaded")
    log "using loaded image: $loaded ($image_id)"
  else
    [[ -f "$ARCHIVE" ]] || die "archive not found: $ARCHIVE"
    log "loading image archive: $ARCHIVE"
    loaded=$(docker load -i "$ARCHIVE")
    ref=$(printf '%s\n' "$loaded" | sed -n 's/^Loaded image: //p' | tail -n1)
    if [[ -z "$ref" ]]; then
      ref=$(printf '%s\n' "$loaded" | sed -n 's/^Loaded image ID: //p' | tail -n1)
    fi
    [[ -n "$ref" ]] || die "docker load did not report a loaded image"
    image_id=$(docker image inspect -f '{{.Id}}' "$ref")
    log "loaded image: $ref ($image_id)"
  fi

  # A bundle is normally tagged metacubexd-server:pi. Make sure a load that
  # happens to carry the active slot tag cannot destroy the rollback image.
  local active_id
  active_id=$(docker image inspect -f '{{.Id}}' "$(slot_image "$ACTIVE_SLOT")" 2>/dev/null || true)
  if [[ "$active_id" != "$OLD_IMAGE_ID" ]]; then
    docker tag "$OLD_IMAGE_ID" "$(slot_image "$ACTIVE_SLOT")"
    log "restored active slot tag $(slot_image "$ACTIVE_SLOT")"
  fi

  docker tag "$image_id" "$NEW_IMAGE"
  NEW_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$NEW_IMAGE")
  log "staged $NEW_IMAGE ($NEW_IMAGE_ID)"
}

precheck_new_image() {
  log "precheck: mihomo version"
  timeout 60 docker run --rm --entrypoint /usr/local/bin/mihomo "$NEW_IMAGE" -v ||
    die "new image failed to run mihomo -v"

  local volume_path
  volume_path=$(docker volume inspect -f '{{ .Mountpoint }}' "$DATA_VOLUME")
  if [[ -f "$volume_path/active.yaml" ]]; then
    log "precheck: mihomo -t against a data copy"
    PRECHECK_DATA=$(mktemp -d "${TMPDIR:-/tmp}/mcxd-ab-data.XXXXXX")
    cp -a "$volume_path/." "$PRECHECK_DATA/"
    if ! timeout 330 docker run --rm \
      -v "$PRECHECK_DATA:/data" \
      --entrypoint /bin/sh "$NEW_IMAGE" \
      -c '/usr/local/bin/mihomo -t -d /data -f /data/active.yaml'; then
      rm -rf "$PRECHECK_DATA"
      PRECHECK_DATA=""
      die "new image rejected the current active config"
    fi
    rm -rf "$PRECHECK_DATA"
    PRECHECK_DATA=""
  else
    log "precheck: no active.yaml yet; skipping mihomo -t"
  fi

  precheck_candidate_container
}

precheck_candidate_container() {
  local port=18080 attempt candidate_token=ab-candidate-token
  while ss -ltn 2>/dev/null | grep -q ":${port} "; do
    port=$((port + 1))
    [[ "$port" -lt 18100 ]] || die "no free port for the candidate smoke test"
  done

  CANDIDATE_NAME="mcxd-ab-candidate-$$"
  CANDIDATE_DATA=$(mktemp -d "${TMPDIR:-/tmp}/mcxd-ab-candidate.XXXXXX")
  # Seed the candidate with the existing geo assets so mihomo does not spend
  # minutes downloading them on the Pi just for a control-plane smoke test.
  local volume_path
  volume_path=$(docker volume inspect -f '{{ .Mountpoint }}' "$DATA_VOLUME" 2>/dev/null || true)
  if [[ -n "$volume_path" && -d "$volume_path" ]]; then
    local geo
    for geo in geoip.dat geosite.dat country.mmdb geoip.metadb; do
      if [[ -f "$volume_path/$geo" ]]; then
        cp -a "$volume_path/$geo" "$CANDIDATE_DATA/"
      fi
    done
  fi
  docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
  log "precheck: control-plane smoke on 127.0.0.1:$port"
  if ! docker run -d --rm \
    --name "$CANDIDATE_NAME" \
    --network bridge \
    -p "127.0.0.1:${port}:${port}" \
    -v "$CANDIDATE_DATA:/data" \
    -e ROUTER_MODE=0 \
    -e CONTROL_TOKEN="$candidate_token" \
    -e CONTROL_PORT="$port" \
    -e CLASH_API_PORT=19090 \
    -e MIXED_PORT=17890 \
    -e DATA_DIR=/data \
    "$NEW_IMAGE" >/dev/null; then
    die "candidate container failed to start"
  fi

  attempt=0
  while (( attempt < CANDIDATE_TIMEOUT )); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/api/control/health" >/dev/null 2>&1 &&
      curl -fsS --max-time 2 -H "Authorization: Bearer ${candidate_token}" \
        "http://127.0.0.1:${port}/api/control/kernel/status" 2>/dev/null |
      jq -e '.status == "running"' >/dev/null 2>&1; then
      docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
      rm -rf "$CANDIDATE_DATA"
      CANDIDATE_NAME=""
      CANDIDATE_DATA=""
      log "precheck: candidate control plane is healthy"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  docker logs --tail 80 "$CANDIDATE_NAME" 2>&1 || true
  docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
  rm -rf "$CANDIDATE_DATA"
  CANDIDATE_NAME=""
  CANDIDATE_DATA=""
  die "candidate control plane did not become healthy"
}

check_health() {
  curl -fsS --max-time 5 "http://127.0.0.1:${CONTROL_PORT}/api/control/health" 2>/dev/null |
    jq -e '.ok == true' >/dev/null 2>&1
}

check_kernel() {
  curl -fsS --max-time 5 "${AUTH[@]}" \
    "http://127.0.0.1:${CONTROL_PORT}/api/control/kernel/status" 2>/dev/null |
    jq -e '.status == "running"' >/dev/null 2>&1
}

kernel_pid() {
  curl -fsS --max-time 5 "${AUTH[@]}" \
    "http://127.0.0.1:${CONTROL_PORT}/api/control/kernel/status" 2>/dev/null |
    jq -r '.pid // empty' 2>/dev/null
}

container_started_at() {
  docker inspect -f '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null
}

container_restart_count() {
  docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null
}

check_tun() {
  ip link show "$TUN_DEVICE" >/dev/null 2>&1
}

check_rules() {
  ip rule show 2>/dev/null | grep -q "^${TUN_RULE_INDEX}:" &&
    ip rule show 2>/dev/null | grep -q "^${AUTO_REDIRECT_RULE_A}:" &&
    ip rule show 2>/dev/null | grep -q "^${AUTO_REDIRECT_RULE_B}:" &&
    ip route show table "$ROUTE_TABLE" 2>/dev/null | grep -q "dev ${TUN_DEVICE}"
}

check_dns() {
  dig +time=2 +tries=1 @"$LAN_IP" www.google.com A +short 2>/dev/null |
    grep -qE '^198\.18\.'
}

check_proxy() {
  local code
  if ! ss -ltn 2>/dev/null | grep -q ":${MIXED_PORT} "; then
    warn "mixed port ${MIXED_PORT} is not listening; skipping host proxy check"
    return 0
  fi
  code=$(curl -x "http://127.0.0.1:${MIXED_PORT}" -sS -o /dev/null -w '%{http_code}' \
    --max-time 10 https://www.gstatic.com/generate_204 2>/dev/null || true)
  [[ "$code" == "204" ]]
}

provider_lines() {
  curl -fsS --max-time 10 "${CLASH_AUTH[@]}" \
    "http://127.0.0.1:${CLASH_API_PORT}/providers/proxies" 2>/dev/null |
    jq -r '.providers | to_entries[] |
      select(.key | startswith("router_")) |
      "\(.key) \(.value.proxies | length)"' 2>/dev/null
}

provider_total() {
  local lines total=0 name count
  lines=$(provider_lines) || return 1
  while read -r name count; do
    [[ -n "$name" ]] || continue
    total=$((total + count))
  done <<<"$lines"
  printf '%s\n' "$total"
}

check_providers() {
  local lines name count total=0 min
  if ! lines=$(provider_lines); then
    warn "provider API is unavailable"
    return 1
  fi
  if [[ -z "$lines" ]]; then
    warn "no router_ providers found"
    if [[ "$BASELINE_PROVIDER_TOTAL" -gt 0 ]]; then
      warn "baseline had $BASELINE_PROVIDER_TOTAL provider nodes"
      return 1
    fi
    return 0
  fi
  while read -r name count; do
    [[ -n "$name" ]] || continue
    if [[ "$count" -le 0 ]]; then
      warn "provider $name has no nodes"
      return 1
    fi
    total=$((total + count))
  done <<<"$lines"

  if [[ "$BASELINE_PROVIDER_TOTAL" -gt 0 ]]; then
    min=$((BASELINE_PROVIDER_TOTAL * MIN_PROVIDER_RATIO / 100))
    if [[ "$total" -lt "$min" ]]; then
      warn "provider node total $total is below baseline ${BASELINE_PROVIDER_TOTAL} (min $min)"
      return 1
    fi
  fi
  log "providers: $total nodes (baseline ${BASELINE_PROVIDER_TOTAL})"
}

setup_netns() {
  cleanup_netns
  ip netns add "$AB_TEST_NETNS"
  ip link add "$AB_TEST_VETH" type veth peer name "${AB_TEST_VETH}p"
  ip link set "${AB_TEST_VETH}p" netns "$AB_TEST_NETNS"
  ip addr add "${AB_TEST_HOST_IP}/${AB_TEST_PREFIX}" dev "$AB_TEST_VETH"
  ip link set "$AB_TEST_VETH" up
  ip netns exec "$AB_TEST_NETNS" ip link set lo up
  ip netns exec "$AB_TEST_NETNS" ip link set "${AB_TEST_VETH}p" name eth0
  ip netns exec "$AB_TEST_NETNS" ip addr add "${AB_TEST_CLIENT_IP}/${AB_TEST_PREFIX}" dev eth0
  ip netns exec "$AB_TEST_NETNS" ip link set eth0 up
  ip netns exec "$AB_TEST_NETNS" ip route add default via "$AB_TEST_HOST_IP"

  OLD_RP_FILTER=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)
  sysctl -qw net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -qw "net.ipv4.conf.${AB_TEST_VETH}.rp_filter=0" >/dev/null 2>&1 || true
  ip netns exec "$AB_TEST_NETNS" sysctl -qw net.ipv4.conf.eth0.rp_filter=0 >/dev/null 2>&1 || true

  iptables -I FORWARD -i "$AB_TEST_VETH" -o "$TUN_DEVICE" -j ACCEPT
  iptables -I FORWARD -i "$TUN_DEVICE" -o "$AB_TEST_VETH" -j ACCEPT
  NETNS_READY=1
}

cleanup_netns() {
  if [[ "$NETNS_READY" == 1 ]]; then
    iptables -D FORWARD -i "$AB_TEST_VETH" -o "$TUN_DEVICE" -j ACCEPT >/dev/null 2>&1 || true
    iptables -D FORWARD -i "$TUN_DEVICE" -o "$AB_TEST_VETH" -j ACCEPT >/dev/null 2>&1 || true
  fi
  ip netns del "$AB_TEST_NETNS" >/dev/null 2>&1 || true
  ip link del "$AB_TEST_VETH" >/dev/null 2>&1 || true
  if [[ -n "$OLD_RP_FILTER" ]]; then
    sysctl -qw net.ipv4.conf.all.rp_filter="$OLD_RP_FILTER" >/dev/null 2>&1 || true
  fi
  NETNS_READY=0
}

check_netns_client() {
  local fake_ip code
  fake_ip=$(ip netns exec "$AB_TEST_NETNS" \
    dig +time=2 +tries=1 @"$LAN_IP" www.gstatic.com A +short 2>/dev/null |
    grep -E '^198\.18\.' | head -n1)
  if [[ -z "$fake_ip" ]]; then
    warn "netns DNS did not return a fake-ip"
    return 1
  fi
  code=$(ip netns exec "$AB_TEST_NETNS" \
    curl --resolve "www.gstatic.com:443:${fake_ip}" \
    -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    https://www.gstatic.com/generate_204 2>/dev/null || true)
  [[ "$code" == "204" ]]
}

check_logs() {
  local since=$1
  local out
  out=$(docker logs --since "$since" "$CONTAINER_NAME" 2>&1 || true)
  if printf '%s\n' "$out" |
    grep -qE 'panic|fatal|invalid tun stack|config validation failed|ready timeout|not allowed two tun'; then
    printf '%s\n' "$out" | grep -E 'panic|fatal|invalid tun stack|config validation failed|ready timeout|not allowed two tun' | tail -n 20
    return 1
  fi
}

check_container_stable() {
  [[ -n "$CONTAINER_START_AT" && -n "$CONTAINER_RESTART_COUNT" && -n "$KERNEL_PID" ]] || return 1
  [[ "$(container_started_at)" == "$CONTAINER_START_AT" ]] || {
    warn "container restarted during the self-test"
    return 1
  }
  [[ "$(container_restart_count)" == "$CONTAINER_RESTART_COUNT" ]] || {
    warn "container restart count changed during the self-test"
    return 1
  }
  [[ "$(kernel_pid)" == "$KERNEL_PID" ]] || {
    warn "kernel PID changed during the self-test"
    return 1
  }
}

run_checks_once() {
  local failed=0
  check_health || {
    warn "health check failed"
    failed=1
  }
  check_kernel || {
    warn "kernel is not running"
    failed=1
  }
  if [[ "$PHASE" == "new" ]]; then
    check_container_stable || failed=1
  fi
  check_tun || {
    warn "TUN interface $TUN_DEVICE is missing"
    failed=1
  }
  check_rules || {
    warn "ip rule/table ${ROUTE_TABLE} is incomplete"
    failed=1
  }
  check_dns || {
    warn "DNS did not return a fake-ip"
    failed=1
  }
  check_proxy || {
    warn "host proxy check failed"
    failed=1
  }
  check_netns_client || {
    warn "netns client data path failed"
    failed=1
  }
  check_providers || failed=1
  if [[ "$PHASE" == "new" ]] && ! check_logs "$START_TS"; then
    warn "critical log lines found"
    failed=1
  fi
  return "$failed"
}

run_baseline() {
  log "baseline: self-test against the current deployment"
  PHASE=baseline
  BASELINE_PROVIDER_TOTAL=$(provider_total 2>/dev/null || echo 0)
  setup_netns
  if ! run_checks_once; then
    cleanup_netns
    die "baseline self-test failed; refusing to upgrade a broken deployment"
  fi
  cleanup_netns
  log "baseline: OK (providers: $BASELINE_PROVIDER_TOTAL)"
}

wait_health() {
  local timeout=$1
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if check_health; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_kernel() {
  local timeout=$1
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if check_kernel; then
      return 0
    fi
    sleep 2
  done
  return 1
}

start_container() {
  local image=$1
  set_env AIO_IMAGE "$image"
  if [[ "$COMPOSE_AVAILABLE" == 1 && -f "$COMPOSE_FILE" ]]; then
    ( cd "$APP_DIR" && docker compose up -d --force-recreate ) || return 1
  else
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
      --name "$CONTAINER_NAME" \
      --restart unless-stopped \
      --network host \
      --cap-add NET_ADMIN \
      --device /dev/net/tun:/dev/net/tun \
      --log-driver json-file \
      --log-opt max-size=10m \
      --log-opt max-file=3 \
      --env-file "$APP_DIR/.env" \
      -e CONTROL_PORT="$CONTROL_PORT" \
      -e CLASH_API_PORT="$CLASH_API_PORT" \
      -e MIXED_PORT="$MIXED_PORT" \
      -v "${DATA_VOLUME}:/data" \
      "$image" >/dev/null || return 1
  fi
}

snapshot_state() {
  local volume_path
  volume_path=$(docker volume inspect -f '{{ .Mountpoint }}' "$DATA_VOLUME")
  ENV_BACKUP=$HISTORY_DIR/env.backup
  COMPOSE_BACKUP=$HISTORY_DIR/compose.backup
  DATA_SNAPSHOT=$BACKUP_DIR/pre-upgrade-$TS.tar.gz

  cp -a "$APP_DIR/.env" "$ENV_BACKUP"
  chmod 0600 "$ENV_BACKUP"
  if [[ -f "$COMPOSE_FILE" ]]; then
    cp -a "$COMPOSE_FILE" "$COMPOSE_BACKUP"
    chmod 0600 "$COMPOSE_BACKUP"
  fi
  log "snapshot: data volume -> $DATA_SNAPSHOT"
  tar -C "$volume_path" -czf "$DATA_SNAPSHOT" . ||
    die "failed to snapshot the data volume"
  [[ -s "$DATA_SNAPSHOT" ]] || die "data snapshot is empty"
}

write_marker() {
  cat >"$MARKER" <<EOF
TS=$TS
STATE=switching
OLD_SLOT=$ACTIVE_SLOT
NEW_SLOT=$NEW_SLOT
OLD_IMAGE=$OLD_IMAGE
NEW_IMAGE=$NEW_IMAGE
OLD_IMAGE_ID=$OLD_IMAGE_ID
NEW_IMAGE_ID=$NEW_IMAGE_ID
ENV_BACKUP=$ENV_BACKUP
COMPOSE_BACKUP=$COMPOSE_BACKUP
DATA_SNAPSHOT=$DATA_SNAPSHOT
DATA_VOLUME=$DATA_VOLUME
APP_DIR=$APP_DIR
EOF
  chmod 0600 "$MARKER"
  log "marker written: $MARKER"
}

diagnose_failure() {
  local reason=$1
  local file=$HISTORY_DIR/failure.log
  {
    printf 'reason: %s\n' "$reason"
    printf 'time: %s\n' "$(date -Iseconds)"
    printf '\n--- docker ps ---\n'
    docker ps -a || true
    printf '\n--- container logs ---\n'
    docker logs --tail 200 "$CONTAINER_NAME" 2>&1 || true
    printf '\n--- ip rule ---\n'
    ip rule show || true
    printf '\n--- ip route table %s ---\n' "$ROUTE_TABLE"
    ip route show table "$ROUTE_TABLE" || true
    printf '\n--- providers ---\n'
    provider_lines || true
  } >"$file" 2>&1 || true
  log "diagnostics: $file"
}

rollback() {
  local reason=$1
  if [[ "$IN_ROLLBACK" == 1 ]]; then
    return 1
  fi
  IN_ROLLBACK=1
  trap - ERR
  log "ROLLBACK: $reason"
  diagnose_failure "$reason"

  if [[ ! -f "$MARKER" ]]; then
    log "ROLLBACK: no marker found; cannot determine the previous slot"
    return 1
  fi

  # shellcheck source=/dev/null
  source "$MARKER"

  if [[ "${STATE:-}" == committed ]]; then
    log "upgrade was already committed; clearing marker"
    rm -f "$MARKER"
    return 0
  fi

  local volume_path
  volume_path=$(docker volume inspect -f '{{ .Mountpoint }}' "$DATA_VOLUME" 2>/dev/null || true)

  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  if [[ -f "${ENV_BACKUP:-}" ]]; then
    cp -a "$ENV_BACKUP" "$APP_DIR/.env"
    chmod 0600 "$APP_DIR/.env"
  fi
  set_env AIO_IMAGE "$OLD_IMAGE"

  if [[ "$NO_DATA_RESTORE" != 1 && -n "${DATA_SNAPSHOT:-}" && -f "$DATA_SNAPSHOT" && -n "$volume_path" ]]; then
    log "ROLLBACK: restoring data snapshot $DATA_SNAPSHOT"
    find "$volume_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    tar -xzf "$DATA_SNAPSHOT" -C "$volume_path" ||
      log "ROLLBACK: data restore failed; continuing with the current volume"
  fi

  if ! start_container "$OLD_IMAGE"; then
    log "ROLLBACK FAILED: could not start $OLD_IMAGE"
    exit 2
  fi
  if ! wait_health "$HEALTH_TIMEOUT"; then
    log "ROLLBACK FAILED: old container did not become healthy"
    exit 2
  fi
  if ! wait_kernel "$KERNEL_TIMEOUT"; then
    log "ROLLBACK FAILED: old kernel did not become running"
    exit 2
  fi

  PHASE=baseline
  local failed=0
  check_tun || failed=1
  check_rules || failed=1
  check_dns || failed=1
  check_proxy || failed=1
  check_providers || failed=1

  if [[ "$failed" == 0 ]]; then
    printf '%s\n' "$OLD_SLOT" >"$ACTIVE_SLOT_FILE"
    rm -f "$MARKER"
    log "ROLLBACK OK: slot $OLD_SLOT is running"
    exit 1
  fi

  log "ROLLBACK FAILED: old slot $OLD_SLOT is running but its self-test failed; marker kept"
  exit 2
}

recover_interrupted() {
  if [[ ! -f "$MARKER" ]]; then
    log "no interrupted upgrade marker; nothing to recover"
    return 0
  fi
  # shellcheck source=/dev/null
  source "$MARKER"
  if [[ "${STATE:-}" == committed ]]; then
    rm -f "$MARKER"
    log "upgrade already committed; cleared marker"
    return 0
  fi
  log "found interrupted upgrade; rolling back to slot ${OLD_SLOT:-unknown}"
  rollback "boot recovery"
}

switch_and_verify() {
  SWITCH_START=$SECONDS
  START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "switching to $NEW_IMAGE"

  if ! start_container "$NEW_IMAGE"; then
    rollback "failed to start the new slot"
    return 1
  fi
  if ! wait_health "$HEALTH_TIMEOUT"; then
    rollback "new container health timeout"
    return 1
  fi
  if ! wait_kernel "$KERNEL_TIMEOUT"; then
    rollback "new kernel did not become running"
    return 1
  fi

  local warm=0
  CONTAINER_START_AT=$(container_started_at)
  CONTAINER_RESTART_COUNT=$(container_restart_count)
  KERNEL_PID=$(kernel_pid)
  if [[ -z "$KERNEL_PID" ]]; then
    rollback "could not read the new kernel PID"
    return 1
  fi
  while (( warm < WARMUP_SECONDS )); do
    if ! check_health; then
      rollback "new container lost health during warm-up"
      return 1
    fi
    sleep 5
    warm=$((warm + 5))
  done

  setup_netns
  PHASE=new
  local total_failures=0 consecutive=0 i
  for ((i = 1; i <= STABILITY_SAMPLES; i++)); do
    if (( SECONDS - SWITCH_START > TOTAL_TIMEOUT )); then
      cleanup_netns
      rollback "self-test exceeded ${TOTAL_TIMEOUT}s"
      return 1
    fi
    if run_checks_once; then
      log "self-test sample $i/$STABILITY_SAMPLES: ok"
      consecutive=0
    else
      total_failures=$((total_failures + 1))
      consecutive=$((consecutive + 1))
      log "self-test sample $i/$STABILITY_SAMPLES: failed (consecutive $consecutive)"
      if [[ "$consecutive" -ge 3 ]]; then
        cleanup_netns
        rollback "3 consecutive self-test failures"
        return 1
      fi
    fi
    sleep "$SAMPLE_INTERVAL"
  done
  cleanup_netns

  if [[ "$total_failures" -ne 0 ]]; then
    rollback "self-test had ${total_failures} failed sample(s)"
    return 1
  fi

  printf '%s\n' "$NEW_SLOT" >"$ACTIVE_SLOT_FILE"
  sed -i 's/^STATE=.*/STATE=committed/' "$MARKER"
  rm -f "$MARKER"
  log "UPGRADE OK: active slot $NEW_SLOT ($NEW_IMAGE)"
}

ensure_host_helper() {
  local installed=$APP_DIR/aio-ab-upgrade.sh
  if [[ "$SCRIPT_PATH" != "$installed" ]]; then
    install -m 0755 "$SCRIPT_PATH" "$installed" ||
      die "could not install the A/B helper to $installed"
  fi
  if [[ ! -d /run/systemd/system ]]; then
    warn "systemd is not available; boot-time upgrade recovery is disabled"
    return 0
  fi
  if [[ ! -f /etc/systemd/system/metacubexd-upgrade-recover.service ]]; then
    cat >/etc/systemd/system/metacubexd-upgrade-recover.service <<EOF
[Unit]
Description=Roll back an interrupted MetaCubeXD A/B upgrade
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
TimeoutStartSec=900
ExecStart=$installed --recover
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || true
    systemctl enable metacubexd-upgrade-recover.service >/dev/null 2>&1 ||
      warn "could not enable metacubexd-upgrade-recover.service"
    log "installed boot-time upgrade recovery unit"
  fi
}

real_upgrade() {
  if [[ -f "$MARKER" ]]; then
    die "an upgrade marker already exists ($MARKER); run --recover first"
  fi
  ensure_host_helper
  log "MetaCubeXD A/B upgrade starting"
  migrate_layout
  resolve_new_slot
  load_new_image
  precheck_new_image
  run_baseline
  snapshot_state
  write_marker
  switch_and_verify
}

self_test_only() {
  [[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)" == "running" ]] ||
    die "container $CONTAINER_NAME is not running"
  PHASE=baseline
  BASELINE_PROVIDER_TOTAL=$(provider_total 2>/dev/null || echo 0)
  setup_netns
  if run_checks_once; then
    cleanup_netns
    log "SELF-TEST PASS (providers: $BASELINE_PROVIDER_TOTAL)"
    return 0
  fi
  cleanup_netns
  log "SELF-TEST FAIL"
  return 1
}

on_error() {
  local line=$1
  trap - ERR
  log "ERROR: unexpected failure at line $line"
  if [[ -f "$MARKER" && "$IN_ROLLBACK" != 1 ]]; then
    rollback "unexpected error at line $line"
  fi
  exit 1
}

cleanup_on_exit() {
  cleanup_netns
  if [[ -n "$CANDIDATE_NAME" ]]; then
    docker rm -f "$CANDIDATE_NAME" >/dev/null 2>&1 || true
    CANDIDATE_NAME=""
  fi
  if [[ -n "$CANDIDATE_DATA" ]]; then
    rm -rf "$CANDIDATE_DATA"
    CANDIDATE_DATA=""
  fi
  if [[ -n "$PRECHECK_DATA" ]]; then
    rm -rf "$PRECHECK_DATA"
    PRECHECK_DATA=""
  fi
}

main() {
  trap 'cleanup_on_exit' EXIT
  trap 'on_error $LINENO' ERR

  parse_args "$@"
  require_root
  require_commands

  if [[ "$SELF_TEST_ONLY" == 0 && "$RECOVER" == 0 && "$DETACH" == 1 && "$NO_DETACH" == 0 ]]; then
    detach_if_requested
  fi

  load_env
  if [[ "$RECOVER" == 1 ]]; then
    if [[ ! -f "$MARKER" ]]; then
      log "no interrupted upgrade marker; nothing to recover"
      return 0
    fi
    init_history
    recover_interrupted
    return $?
  fi

  init_history

  if [[ "$SELF_TEST_ONLY" == 1 ]]; then
    self_test_only
    return $?
  fi

  real_upgrade
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit $?
fi
