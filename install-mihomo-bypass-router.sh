#!/usr/bin/env bash
set -Eeuo pipefail

# Install the MetaCubeXD all-in-one server on Debian/Ubuntu.
#
# By default the image is built from the local sources in this repository:
#   - mihomo/       the Go kernel source (pinned submodule)
#   - metacubexd/   the dashboard/server monorepo
# It does not pull the GHCR all-in-one image unless --image is used.
#
# Run from the repository root:
#   sudo bash install-mihomo-bypass-router.sh
#
# WSL test mode is detected automatically. It publishes ports 8080/9090/7890
# but deliberately does not attach TUN or change host routing.

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
APP_DIR=${APP_DIR:-/opt/metacubexd}
IMAGE_TAG=${IMAGE_TAG:-metacubexd-server:local}
MIHOMO_TAG=${MIHOMO_TAG:-v1.19.27}
TARGET_PLATFORM=${TARGET_PLATFORM:-}
LAN_IP=${LAN_IP:-}
LAN_CIDR=${LAN_CIDR:-}
LAN_IFACE=${LAN_IFACE:-}
DATA_VOLUME=${DATA_VOLUME:-}
NET_IFACE=${NET_IFACE:-}
NET_GATEWAY=${NET_GATEWAY:-}
NET_DNS=${NET_DNS:-}
TZ=${TZ:-}
NODE_VERSION=${NODE_VERSION:-22}
GO_VERSION=${GO_VERSION:-1.26}
# Router mode turns the AIO image into a self-managed bypass router: one
# managed base profile, one mihomo proxy-provider per imported subscription,
# TUN + DNS + forwarding configured automatically. WSL is test-only.
TUN_STACK=${TUN_STACK:-gvisor}
ROUTER_MODE=${ROUTER_MODE:-1}
# Point the host's own resolver at mihomo once the container is healthy. This
# keeps host tools (ping/curl/apt) from using the polluted main-router DNS.
if [[ -n "${HOST_DNS:-}" ]]; then
  HOST_DNS_SET=1
else
  HOST_DNS=1
  HOST_DNS_SET=0
fi
CLEANUP=${CLEANUP:-1}
HOST_DNS_OK=1

BUILD_LOCAL=1
NO_BUILD=0
NO_CACHE=0
TAG_SET=0
SET_IP=0
DISABLE_WIFI=0
REBOOT_AFTER=0
PREVIOUS_IMAGE=""
IMAGE_REF=""
ARCHIVE_FILE=""

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

usage() {
  cat <<EOF
Usage: sudo bash $0 [options]

By default this builds the all-in-one image from the local
metacubexd/ and mihomo/ sources, then starts it.

Options:
  --image REF           Use an existing image instead of building locally
                        (for example ghcr.io/metacubex/metacubexd-server:latest)
  --tag TAG             Local image tag (default: $IMAGE_TAG)
  --archive FILE        Load a docker-save archive (.tar/.tar.gz) and use it
  --mihomo-tag TAG      mihomo version to build (default: $MIHOMO_TAG)
  --platform PLATFORM   Build for a platform, e.g. linux/amd64 or linux/arm64
  --node-version VER    Node base image version (default: $NODE_VERSION)
  --go-version VER      Go base image version (default: $GO_VERSION)
  --no-build            Require an existing image; do not build
  --rebuild             Rebuild without Docker layer cache
  --lan-ip IP           Override the LAN IP used in URLs and CORS
  --lan-cidr CIDR       Override the LAN CIDR excluded from TUN
  --set-ip              Write a persistent static-IP config (applies on reboot)
  --interface IFACE     Interface for --set-ip (default: auto-detect)
  --gateway IP          Gateway for --set-ip (default: current default route)
  --dns IP              DNS server for --set-ip (default: gateway)
  --host-dns            Point the host resolver at mihomo (default in router mode)
  --no-host-dns         Leave the host resolver untouched
  --no-cleanup          Keep the image archive and installer after a successful install
  --disable-wifi        Disable Wi-Fi persistently when --set-ip is used
  --reboot              Reboot after writing the static-IP config
  --help                Show this help

Environment:
  APP_DIR, IMAGE_TAG, MIHOMO_TAG, TARGET_PLATFORM, LAN_IP, LAN_CIDR, LAN_IFACE,
  DATA_VOLUME, NET_IFACE, NET_GATEWAY, NET_DNS, TZ, NODE_VERSION, GO_VERSION,
  ROUTER_MODE, TUN_STACK, HOST_DNS, CLEANUP
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      [[ $# -ge 2 ]] || die "--image requires a value"
      IMAGE_REF=$2
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      IMAGE_TAG=$2
      TAG_SET=1
      shift 2
      ;;
    --archive)
      [[ $# -ge 2 ]] || die "--archive requires a value"
      ARCHIVE_FILE=$2
      shift 2
      ;;
    --mihomo-tag)
      [[ $# -ge 2 ]] || die "--mihomo-tag requires a value"
      MIHOMO_TAG=$2
      shift 2
      ;;
    --platform)
      [[ $# -ge 2 ]] || die "--platform requires a value"
      TARGET_PLATFORM=$2
      shift 2
      ;;
    --node-version)
      [[ $# -ge 2 ]] || die "--node-version requires a value"
      NODE_VERSION=$2
      shift 2
      ;;
    --go-version)
      [[ $# -ge 2 ]] || die "--go-version requires a value"
      GO_VERSION=$2
      shift 2
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --rebuild)
      NO_CACHE=1
      shift
      ;;
    --lan-ip)
      [[ $# -ge 2 ]] || die "--lan-ip requires a value"
      LAN_IP=$2
      shift 2
      ;;
    --lan-cidr)
      [[ $# -ge 2 ]] || die "--lan-cidr requires a value"
      LAN_CIDR=$2
      shift 2
      ;;
    --set-ip)
      SET_IP=1
      shift
      ;;
    --interface)
      [[ $# -ge 2 ]] || die "--interface requires a value"
      NET_IFACE=$2
      shift 2
      ;;
    --gateway)
      [[ $# -ge 2 ]] || die "--gateway requires a value"
      NET_GATEWAY=$2
      shift 2
      ;;
    --dns)
      [[ $# -ge 2 ]] || die "--dns requires a value"
      NET_DNS=$2
      shift 2
      ;;
    --host-dns)
      HOST_DNS=1
      HOST_DNS_SET=1
      shift
      ;;
    --no-host-dns)
      HOST_DNS=0
      HOST_DNS_SET=1
      shift
      ;;
    --no-cleanup)
      CLEANUP=0
      shift
      ;;
    --disable-wifi)
      DISABLE_WIFI=1
      shift
      ;;
    --reboot)
      REBOOT_AFTER=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (use --help)"
      ;;
  esac
done

case "$HOST_DNS" in
  0|1) ;;
  *) HOST_DNS=1 ;;
esac
case "$CLEANUP" in
  0|1) ;;
  *) CLEANUP=1 ;;
esac

# Resolve the archive path before the script changes directory to APP_DIR.
if [[ -n "$ARCHIVE_FILE" && -f "$ARCHIVE_FILE" ]]; then
  ARCHIVE_FILE=$(cd "$(dirname "$ARCHIVE_FILE")" && pwd)/$(basename "$ARCHIVE_FILE")
fi

if [[ ${EUID} -ne 0 ]]; then
  die "run as root: sudo bash $0"
fi

if [[ -n "$IMAGE_REF" && -n "$ARCHIVE_FILE" ]]; then
  die "use either --image or --archive, not both"
fi

if [[ -n "$IMAGE_REF" ]]; then
  BUILD_LOCAL=0
  IMAGE_TAG=$IMAGE_REF
fi

if [[ -n "$ARCHIVE_FILE" ]]; then
  BUILD_LOCAL=0
fi

# shellcheck source=/dev/null
. /etc/os-release
if [[ " ${ID:-} ${ID_LIKE:-} " != *debian* && " ${ID:-} ${ID_LIKE:-} " != *ubuntu* ]] ||
  ! command -v apt-get >/dev/null 2>&1; then
  die "this installer requires a Debian/Ubuntu-family system with apt"
fi

case "$(uname -m)" in
  aarch64|arm64|x86_64|amd64) ;;
  *) die "unsupported architecture: $(uname -m) (expected 64-bit ARM or x86_64)" ;;
esac

IS_WSL=false
if grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null; then
  IS_WSL=true
fi

if [[ "$IS_WSL" == true ]]; then
  HOST_DNS=0
  CLEANUP=0
fi

if [[ "$SET_IP" == 1 && "$IS_WSL" == true ]]; then
  die "--set-ip is not supported in WSL test mode"
fi

# Upgrades normally already have every runtime dependency. Only touch apt when
# something is actually missing: some Pi images point at an unreleased Ubuntu
# suite, and a failing apt-get update must not block an otherwise valid upgrade.
need_packages=0
for cmd in curl openssl git ip iptables gzip; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd"
    need_packages=1
  fi
done
if [[ "$DISABLE_WIFI" == 1 ]] && ! command -v rfkill >/dev/null 2>&1; then
  echo "Missing command: rfkill"
  need_packages=1
fi
if [[ ! -f /etc/ssl/certs/ca-certificates.crt ]]; then
  echo "Missing CA certificate bundle"
  need_packages=1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Missing command: docker"
  need_packages=1
fi

if [[ "$need_packages" == 1 ]]; then
  apt-get update
  PACKAGES=(ca-certificates curl openssl git iproute2 iptables gzip)
  if [[ "$DISABLE_WIFI" == 1 ]]; then
    PACKAGES+=(rfkill)
  fi
  if ! command -v docker >/dev/null 2>&1; then
    PACKAGES+=(docker.io)
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
else
  echo "System packages already present; skipping apt-get."
fi

# Compose v2 is preferred when available, but some Raspberry Pi OS images do
# not ship docker-compose-v2. The start section falls back to docker run.
if [[ "$IS_WSL" != true ]] && ! docker compose version >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2 || true
fi

if ! docker info >/dev/null 2>&1; then
  if [[ -d /run/systemd/system ]]; then
    systemctl enable --now docker
  else
    service docker start || true
  fi
fi
if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is unavailable. In WSL, enable Docker Desktop integration or systemd."
fi

if ! docker compose version >/dev/null 2>&1; then
  warn "Docker Compose v2 is not available; falling back to docker run."
fi

# Preserve the existing data volume across upgrades. Older Compose installs
# used the implicit project prefix (metacubexd_metacubexd-data); fresh installs
# use the explicit metacubexd-data name.
if [[ -z "$DATA_VOLUME" && -f "$APP_DIR/.env" ]]; then
  DATA_VOLUME=$(sed -n 's/^DATA_VOLUME=//p' "$APP_DIR/.env" | tail -n1)
fi
if [[ -z "$DATA_VOLUME" ]]; then
  if docker volume inspect metacubexd_metacubexd-data >/dev/null 2>&1; then
    DATA_VOLUME=metacubexd_metacubexd-data
  elif docker volume inspect metacubexd-data >/dev/null 2>&1; then
    DATA_VOLUME=metacubexd-data
  else
    DATA_VOLUME=metacubexd-data
  fi
fi
echo "Data volume: $DATA_VOLUME"

# Keep the currently deployed image available for rollback. This is especially
# important for archive upgrades: the new archive is loaded under the same tag.
if [[ -n "$ARCHIVE_FILE" || "$BUILD_LOCAL" == 1 ]] &&
  docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  PREVIOUS_IMAGE="${IMAGE_TAG}.previous"
  docker tag "$IMAGE_TAG" "$PREVIOUS_IMAGE"
  echo "Previous image saved as: $PREVIOUS_IMAGE"
fi

if [[ "$IS_WSL" != true ]]; then
  if [[ ! -c /dev/net/tun ]]; then
    command -v modprobe >/dev/null 2>&1 && modprobe tun || true
  fi
  if [[ ! -c /dev/net/tun ]]; then
    die "missing /dev/net/tun. Check that the Linux TUN module is available."
  fi
fi

# Stop an earlier standalone Mihomo service when migrating.
if command -v systemctl >/dev/null 2>&1 &&
  systemctl list-unit-files mihomo.service --no-legend 2>/dev/null | grep -q '^mihomo.service'; then
  systemctl disable --now mihomo.service || true
fi

# ---------------------------------------------------------------------------
# Optional image archive (pre-built on WSL/PC for Raspberry Pi)
# ---------------------------------------------------------------------------

if [[ -n "$ARCHIVE_FILE" ]]; then
  [[ -f "$ARCHIVE_FILE" ]] || die "archive not found: $ARCHIVE_FILE"

  echo "Loading image archive: $ARCHIVE_FILE"
  if [[ "$ARCHIVE_FILE" == *.gz || "$ARCHIVE_FILE" == *.tgz ]]; then
    LOAD_OUTPUT=$(gunzip -c "$ARCHIVE_FILE" | docker load 2>&1)
  else
    LOAD_OUTPUT=$(docker load -i "$ARCHIVE_FILE" 2>&1)
  fi
  printf '%s\n' "$LOAD_OUTPUT"

  LOADED_REF=$(printf '%s\n' "$LOAD_OUTPUT" | sed -n 's/^Loaded image: //p' | tail -n1)
  LOADED_ID=$(printf '%s\n' "$LOAD_OUTPUT" | sed -n 's/^Loaded image ID: //p' | tail -n1)
  if [[ -z "$LOADED_REF" && -n "$LOADED_ID" ]]; then
    LOADED_REF=$LOADED_ID
  fi
  [[ -n "$LOADED_REF" ]] ||
    die "could not determine the image tag in $ARCHIVE_FILE; pass --tag"

  if [[ "$LOADED_REF" == sha256:* ]]; then
    [[ "$TAG_SET" == 1 ]] ||
      die "the archive has no image tag; pass --tag metacubexd-server:pi"
    docker tag "$LOADED_REF" "$IMAGE_TAG"
  elif [[ "$TAG_SET" == 1 ]]; then
    docker tag "$LOADED_REF" "$IMAGE_TAG"
  else
    IMAGE_TAG=$LOADED_REF
  fi
  echo "Using image: $IMAGE_TAG"
fi

# ---------------------------------------------------------------------------
# LAN address and forwarding
# ---------------------------------------------------------------------------

is_private_ipv4() {
  case "$1" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

cidr_for_ip() {
  ip -4 -o addr show scope global 2>/dev/null |
    awk -v ip="$1" '$4 ~ "^" ip "/" { print $4; exit }'
}

ip_for_cidr() {
  ip -4 -o addr show scope global 2>/dev/null |
    awk -v cidr="$1" '$4 == cidr { split($4, a, "/"); print a[1]; exit }'
}

iface_for_ip() {
  ip -4 -o addr show scope global 2>/dev/null |
    awk -v ip="$1" '$4 ~ "^" ip "/" { print $2; exit }'
}

detect_lan_pair() {
  local def_if candidates="" best score iface cidr count

  def_if=$(ip -4 route show default 2>/dev/null | awk '{ print $5; exit }')

  while read -r iface cidr; do
    case "$iface" in
      lo|docker*|br-*|veth*|virbr*|tun*|tap*) continue ;;
    esac
    [[ -n "$cidr" ]] || continue
    case "${cidr%/*}" in
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
        # Prefer wired LAN interfaces (Raspberry Pi: eth0/end0) over Wi-Fi,
        # and give the default-route interface a small boost for single-NIC
        # setups. Multi-interface users can always override with --lan-ip.
        score=10
        case "$iface" in
          eth*|end*|en*) score=100 ;;
          wlan*|wlp*|wl*) score=50 ;;
        esac
        if [[ -n "$def_if" && "$iface" == "$def_if" ]]; then
          score=$((score + 20))
        fi
        candidates+="${score} ${iface} ${cidr}"$'\n'
        ;;
    esac
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{ print $2, $4 }')

  [[ -n "$candidates" ]] || return 1

  best=$(printf '%s' "$candidates" | sort -k1,1nr | head -n1)
  read -r score iface cidr <<<"$best"
  LAN_IP=${cidr%/*}
  LAN_CIDR=$cidr
  LAN_IFACE=$iface

  count=$(printf '%s' "$candidates" | grep -c . || true)
  if [[ "$count" -gt 1 ]]; then
    warn "multiple LAN candidates found; using ${iface} ${LAN_CIDR}. Rerun with --lan-ip/--lan-cidr to override."
  fi
  return 0
}

if [[ "$IS_WSL" == true ]]; then
  LAN_IP=localhost
  LAN_CIDR=""
  ROUTER_MODE=0
else
  if [[ -z "$LAN_IP" && -z "$LAN_CIDR" ]]; then
    detect_lan_pair || true
  elif [[ -n "$LAN_IP" && -z "$LAN_CIDR" ]]; then
    LAN_CIDR=$(cidr_for_ip "$LAN_IP")
  elif [[ -z "$LAN_IP" && -n "$LAN_CIDR" ]]; then
    LAN_IP=$(ip_for_cidr "$LAN_CIDR")
  fi

  [[ -n "$LAN_IP" ]] ||
    die "could not detect the LAN IP; pass --lan-ip and --lan-cidr"
  [[ -n "$LAN_CIDR" ]] ||
    die "could not detect the LAN CIDR; pass --lan-cidr (for example 192.168.5.0/24)"

  if ! is_private_ipv4 "$LAN_IP"; then
    warn "LAN_IP=$LAN_IP is not a private IPv4 address; check --lan-ip"
  fi

  echo "LAN: ${LAN_IP} (${LAN_CIDR})"

  if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" != "1" ]]; then
    echo "Enabling IPv4 forwarding for bypass-router mode..."
    install -d -m 0755 /etc/sysctl.d
    cat > /etc/sysctl.d/99-metacubexd-router.conf <<'EOF'
# Required by the MetaCubeXD bypass-router deployment.
net.ipv4.ip_forward=1
EOF
    if ! sysctl --system >/dev/null 2>&1; then
      sysctl -w net.ipv4.ip_forward=1 >/dev/null
    fi
  fi

  LAN_IFACE=${LAN_IFACE:-${NET_IFACE:-$(iface_for_ip "$LAN_IP")}}
  LAN_IFACE=${LAN_IFACE:-$(ip -4 route show default 2>/dev/null | awk '{ print $5; exit }')}
  if [[ -z "$LAN_IFACE" ]]; then
    warn "could not determine the LAN interface; host DNS management will be skipped"
  fi
  if [[ -z "$NET_GATEWAY" ]]; then
    NET_GATEWAY=$(ip -4 route show default 2>/dev/null | awk '{ print $3; exit }')
  fi
fi

DEFAULT_BACKEND_URL="http://${LAN_IP}:9090"

# ---------------------------------------------------------------------------
# Persistent application directory and secrets
# ---------------------------------------------------------------------------

install -d -m 0750 "$APP_DIR"
if [[ -f "$APP_DIR/.env" ]]; then
  cp -a "$APP_DIR/.env" "$APP_DIR/.env.bak.$(date +%Y%m%d-%H%M%S)"
fi

read_env_value() {
  local key=$1
  [[ -f "$APP_DIR/.env" ]] || return 0
  sed -n "s/^${key}=//p" "$APP_DIR/.env" | tail -n1
}

if [[ "$HOST_DNS_SET" == 0 ]]; then
  HOST_DNS=$(read_env_value HOST_DNS)
  HOST_DNS=${HOST_DNS:-1}
fi
if [[ "$IS_WSL" == true ]]; then
  HOST_DNS=0
fi
case "$HOST_DNS" in
  0|1) ;;
  *) HOST_DNS=1 ;;
esac

CONTROL_TOKEN=${CONTROL_TOKEN:-$(read_env_value CONTROL_TOKEN)}
CLASH_SECRET=${CLASH_SECRET:-$(read_env_value CLASH_SECRET)}
TZ=${TZ:-$(read_env_value TZ)}
TZ=${TZ:-Asia/Shanghai}
CONTROL_TOKEN=${CONTROL_TOKEN:-$(openssl rand -hex 32)}
CLASH_SECRET=${CLASH_SECRET:-$(openssl rand -hex 32)}

cat > "$APP_DIR/.env" <<EOF
CONTROL_TOKEN=$CONTROL_TOKEN
CLASH_SECRET=$CLASH_SECRET
DEFAULT_BACKEND_URL=$DEFAULT_BACKEND_URL
IMAGE_TAG=$IMAGE_TAG
LAN_IP=$LAN_IP
LAN_CIDR=$LAN_CIDR
LAN_IFACE=$LAN_IFACE
DATA_VOLUME=$DATA_VOLUME
ROUTER_MODE=$ROUTER_MODE
TUN_STACK=$TUN_STACK
HOST_DNS=$HOST_DNS
TZ=$TZ
EOF
chmod 0600 "$APP_DIR/.env"

# ---------------------------------------------------------------------------
# Build or select the image
# ---------------------------------------------------------------------------

if [[ "$BUILD_LOCAL" == 1 ]]; then
  if [[ "$NO_BUILD" == 1 ]]; then
    # Image-only deployment (for example, cross-built on WSL and loaded on a
    # Raspberry Pi). No local source tree is required in this mode.
    docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 ||
      die "image $IMAGE_TAG does not exist; remove --no-build or build it first"
  else
    [[ -f "$REPO_DIR/scripts/build-local-image.sh" ]] ||
      die "missing $REPO_DIR/scripts/build-local-image.sh"
    [[ -f "$REPO_DIR/mihomo/go.mod" ]] ||
      die "missing $REPO_DIR/mihomo/go.mod"
    grep -q '^module github.com/metacubex/mihomo$' "$REPO_DIR/mihomo/go.mod" ||
      die "./mihomo is not the Go kernel source. Run: git -C mihomo checkout $MIHOMO_TAG"

    if command -v git >/dev/null 2>&1 &&
      { [[ -d "$REPO_DIR/mihomo/.git" ]] || [[ -f "$REPO_DIR/mihomo/.git" ]]; }; then
      CURRENT_TAG=$(git -C "$REPO_DIR/mihomo" describe --tags --exact-match 2>/dev/null ||
        git -C "$REPO_DIR/mihomo" describe --tags --always 2>/dev/null || true)
      if [[ -n "$CURRENT_TAG" ]]; then
        if [[ "$CURRENT_TAG" != "$MIHOMO_TAG" ]]; then
          warn "mihomo checkout is $CURRENT_TAG (requested $MIHOMO_TAG); building the current checkout"
          MIHOMO_TAG=$CURRENT_TAG
        fi
      fi
      if [[ -n "$(git -C "$REPO_DIR/mihomo" status --porcelain 2>/dev/null)" ]]; then
        warn "mihomo worktree is dirty; the build will use the current files"
      fi
    fi

    BUILD_ARGS=(--tag "$IMAGE_TAG" --mihomo-tag "$MIHOMO_TAG"
      --node-version "$NODE_VERSION" --go-version "$GO_VERSION")
    [[ -n "$TARGET_PLATFORM" ]] && BUILD_ARGS+=(--platform "$TARGET_PLATFORM")
    [[ "$NO_CACHE" == 1 ]] && BUILD_ARGS+=(--no-cache)
    bash "$REPO_DIR/scripts/build-local-image.sh" "${BUILD_ARGS[@]}"
  fi
else
  if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Pulling $IMAGE_TAG..."
    docker pull "$IMAGE_TAG"
  fi
fi

# ---------------------------------------------------------------------------
# Compose file
# ---------------------------------------------------------------------------

if [[ "$IS_WSL" == true ]]; then
  cat > "$APP_DIR/compose.yaml" <<'EOF'
services:
  metacubexd:
    image: ${IMAGE_TAG}
    container_name: metacubexd
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "9090:9090"
      - "7890:7890"
    environment:
      CONTROL_TOKEN: ${CONTROL_TOKEN}
      CLASH_SECRET: ${CLASH_SECRET}
      DEFAULT_BACKEND_URL: ${DEFAULT_BACKEND_URL}
      CONTROL_PORT: "8080"
      CLASH_API_PORT: "9090"
      MIXED_PORT: "7890"
      ROUTER_MODE: ${ROUTER_MODE}
      LAN_IP: ${LAN_IP}
      LAN_CIDR: ${LAN_CIDR}
      TUN_STACK: ${TUN_STACK}
      TZ: ${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - metacubexd-data:/data

volumes:
  metacubexd-data:
    name: ${DATA_VOLUME}
EOF
else
  cat > "$APP_DIR/compose.yaml" <<'EOF'
services:
  metacubexd:
    image: ${IMAGE_TAG}
    container_name: metacubexd
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      CONTROL_TOKEN: ${CONTROL_TOKEN}
      CLASH_SECRET: ${CLASH_SECRET}
      DEFAULT_BACKEND_URL: ${DEFAULT_BACKEND_URL}
      CONTROL_PORT: "8080"
      CLASH_API_PORT: "9090"
      MIXED_PORT: "7890"
      ROUTER_MODE: ${ROUTER_MODE}
      LAN_IP: ${LAN_IP}
      LAN_CIDR: ${LAN_CIDR}
      TUN_STACK: ${TUN_STACK}
      TZ: ${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - metacubexd-data:/data

volumes:
  metacubexd-data:
    name: ${DATA_VOLUME}
EOF
fi
chmod 0640 "$APP_DIR/compose.yaml"

# ---------------------------------------------------------------------------
# Optional persistent static IP (applied on next boot, not immediately)
# ---------------------------------------------------------------------------

if [[ "$SET_IP" == 1 ]]; then
  [[ -n "$LAN_IP" && -n "$LAN_CIDR" ]] ||
    die "--set-ip requires --lan-ip and --lan-cidr"
fi

ipv4_to_int() {
  local ip=$1 a b c d
  IFS=. read -r a b c d <<<"$ip"
  [[ "$a" =~ ^[0-9]{1,3}$ && "$b" =~ ^[0-9]{1,3}$ &&
     "$c" =~ ^[0-9]{1,3}$ && "$d" =~ ^[0-9]{1,3}$ ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

find_iface_for_network() {
  local target=$1 mask=$2 iface cidr ip chosen=""
  while read -r iface cidr; do
    [[ -n "$iface" && "$cidr" == */* ]] || continue
    ip=${cidr%/*}
    if (( ( $(ipv4_to_int "$ip") & mask) == target )); then
      case "$iface" in
        eth*|end*|en*) echo "$iface"; return 0 ;;
      esac
      [[ -z "$chosen" ]] && chosen=$iface
    fi
  done < <(ip -4 -o addr show scope global | awk '{ print $2, $4 }')
  [[ -n "$chosen" ]] && echo "$chosen"
}

install_rfkill_wifi_unit() {
  local rfkill_bin
  rfkill_bin=$(command -v rfkill 2>/dev/null || true)
  [[ -n "$rfkill_bin" ]] || return 0
  cat > /etc/systemd/system/metacubexd-rfkill-wifi.service <<EOF
[Unit]
Description=Block Wi-Fi for the MetaCubeXD wired deployment
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${rfkill_bin} block wifi

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable metacubexd-rfkill-wifi.service
}

configure_static_ip() {
  local prefix mask ip_int network broadcast iface current_ip manager
  local stamp backup conn

  [[ "$LAN_CIDR" == */* ]] || die "--lan-cidr must be CIDR, e.g. 192.168.5.0/24"
  prefix=${LAN_CIDR#*/}
  if ! [[ "$prefix" =~ ^[0-9]+$ ]] ||
    (( prefix < 8 || prefix > 30 )); then
    die "unsupported prefix in --lan-cidr: $LAN_CIDR"
  fi

  ip_int=$(ipv4_to_int "$LAN_IP") ||
    die "invalid --lan-ip: $LAN_IP"
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  network=$(( ip_int & mask ))
  broadcast=$(( network | (~mask & 0xFFFFFFFF) ))
  (( ip_int != network && ip_int != broadcast )) ||
    die "$LAN_IP is the network or broadcast address of $LAN_CIDR"

  if [[ -z "$NET_GATEWAY" ]]; then
    NET_GATEWAY=$(ip -4 route show default | awk '{ print $3; exit }')
  fi
  [[ -n "$NET_GATEWAY" ]] || die "could not determine gateway; pass --gateway"
  local gw_int
  gw_int=$(ipv4_to_int "$NET_GATEWAY") || die "invalid gateway: $NET_GATEWAY"
  (( (gw_int & mask) == network )) ||
    die "gateway $NET_GATEWAY is not inside $LAN_CIDR"
  NET_DNS=${NET_DNS:-$NET_GATEWAY}
  ipv4_to_int "$NET_DNS" >/dev/null || die "invalid DNS server: $NET_DNS"

  if [[ -n "$NET_IFACE" ]]; then
    iface=$NET_IFACE
  else
    iface=$(find_iface_for_network "$network" "$mask")
    if [[ -z "$iface" ]]; then
      iface=$(ip -4 route show default | awk '{ print $5; exit }')
    fi
  fi
  [[ -n "$iface" ]] || die "could not determine interface; pass --interface"

  current_ip=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
    awk '{ print $4; exit }')
  if [[ "${current_ip%/*}" != "$LAN_IP" ]] &&
    ping -c 1 -W 1 "$LAN_IP" >/dev/null 2>&1; then
    die "$LAN_IP is already in use; choose another address"
  fi
  ping -c 1 -W 1 "$NET_GATEWAY" >/dev/null 2>&1 ||
    die "gateway $NET_GATEWAY is not reachable from the current network"

  echo "Writing static IP for $iface: $LAN_IP/$prefix via $NET_GATEWAY (DNS $NET_DNS)"
  stamp=$(date +%Y%m%d-%H%M%S)

  if command -v netplan >/dev/null 2>&1 &&
    compgen -G "/etc/netplan/*.yaml" >/dev/null &&
    systemctl is-active --quiet systemd-networkd; then
    manager="netplan"
    backup="/etc/netplan.bak.$stamp"
    cp -a /etc/netplan "$backup"
    cat > /etc/netplan/99-metacubexd.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      optional: true
      dhcp4: false
      dhcp6: false
      addresses:
        - ${LAN_IP}/${prefix}
      routes:
        - to: default
          via: ${NET_GATEWAY}
      nameservers:
        addresses:
          - ${NET_DNS}
EOF
    chmod 600 /etc/netplan/99-metacubexd.yaml
    if [[ "$DISABLE_WIFI" == 1 ]]; then
      # Netplan rejects a wifis stanza without access-points. Block the radio
      # instead; the existing Wi-Fi profile may remain, but it cannot associate.
      install_rfkill_wifi_unit
    fi
    if ! netplan generate; then
      echo "netplan generate failed; restoring previous network config" >&2
      rm -rf /etc/netplan
      mv "$backup" /etc/netplan
      netplan generate || true
      die "netplan configuration was not applied"
    fi
    if [[ -d /etc/cloud ]]; then
      mkdir -p /etc/cloud/cloud.cfg.d
      cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
    fi
    systemctl enable systemd-networkd
  elif command -v nmcli >/dev/null 2>&1 &&
    systemctl is-active --quiet NetworkManager; then
    manager="nm"
    backup="/etc/NetworkManager/system-connections.bak.$stamp"
    if [[ -d /etc/NetworkManager/system-connections ]]; then
      cp -a /etc/NetworkManager/system-connections "$backup"
    fi
    conn=$(nmcli -t -f NAME,DEVICE connection show --active |
      awk -F: -v d="$iface" '$2 == d { print $1; exit }')
    if [[ -z "$conn" ]]; then
      conn=$(nmcli -t -f NAME,DEVICE connection show |
        awk -F: -v d="$iface" '$2 == d { print $1; exit }')
    fi
    [[ -n "$conn" ]] || die "no NetworkManager connection found for $iface"
    nmcli connection modify "$conn" \
      ipv4.method manual \
      ipv4.addresses "${LAN_IP}/${prefix}" \
      ipv4.gateway "$NET_GATEWAY" \
      ipv4.dns "$NET_DNS"
    if [[ "$DISABLE_WIFI" == 1 ]]; then
      install_rfkill_wifi_unit
    fi
  elif command -v dhcpcd >/dev/null 2>&1 &&
    systemctl is-active --quiet dhcpcd; then
    manager="dhcpcd"
    backup="/etc/dhcpcd.conf.bak.$stamp"
    cp -a /etc/dhcpcd.conf "$backup"
    sed -i '/^# MetaCubeXD managed begin$/,/^# MetaCubeXD managed end$/d' /etc/dhcpcd.conf
    cat >> /etc/dhcpcd.conf <<EOF

# MetaCubeXD managed begin
interface ${iface}
static ip_address=${LAN_IP}/${prefix}
static routers=${NET_GATEWAY}
static domain_name_servers=${NET_DNS}
EOF
    if [[ "$DISABLE_WIFI" == 1 ]]; then
      cat >> /etc/dhcpcd.conf <<'EOF'
denyinterfaces wlan0
EOF
      systemctl disable --now wpa_supplicant 2>/dev/null || true
      install_rfkill_wifi_unit
    fi
    cat >> /etc/dhcpcd.conf <<'EOF'
# MetaCubeXD managed end
EOF
  else
    die "no supported network manager found (netplan/NetworkManager/dhcpcd)"
  fi

  echo "Static IP configuration written via $manager."
  echo "Current IP is unchanged; reboot is required to apply ${LAN_IP}/${prefix}."
  if [[ -n "${backup:-}" ]]; then
    echo "Previous configuration backup: $backup"
  fi
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

cd "$APP_DIR"
COMPOSE_MODE=0
docker rm -f metacubexd >/dev/null 2>&1 || true

if docker compose version >/dev/null 2>&1; then
  COMPOSE_MODE=1
  if ! docker compose up -d --force-recreate; then
    docker compose logs --tail=100 || true
    die "docker compose failed to start the container"
  fi
else
  # Fallback for systems without the Compose v2 plugin (some Raspberry Pi OS
  # images). The runtime flags mirror compose.yaml.
  docker volume create "$DATA_VOLUME" >/dev/null
  RUN_ARGS=(
    --name metacubexd
    --restart unless-stopped
    --log-driver json-file
    --log-opt max-size=10m
    --log-opt max-file=3
  )
  if [[ "$IS_WSL" == true ]]; then
    RUN_ARGS+=(-p 8080:8080 -p 9090:9090 -p 7890:7890)
  else
    RUN_ARGS+=(--network host --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun)
  fi
  docker run -d "${RUN_ARGS[@]}" \
    --env-file "$APP_DIR/.env" \
    -e CONTROL_PORT=8080 -e CLASH_API_PORT=9090 -e MIXED_PORT=7890 \
    -v "${DATA_VOLUME}:/data" \
    "$IMAGE_TAG" >/dev/null
fi

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

HEALTHY=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:8080/api/control/health" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$HEALTHY" != 1 ]]; then
  echo "Health check failed: http://127.0.0.1:8080/api/control/health" >&2
  if [[ "$COMPOSE_MODE" == 1 ]]; then
    docker compose logs --tail=100 || true
  else
    docker logs --tail=100 metacubexd || true
  fi
  if [[ -n "$PREVIOUS_IMAGE" ]]; then
    echo "Rollback image is available: $PREVIOUS_IMAGE" >&2
    echo "  docker rm -f metacubexd" >&2
    echo "  docker tag $PREVIOUS_IMAGE $IMAGE_TAG" >&2
    echo "  cd $APP_DIR && docker compose up -d --force-recreate" >&2
  fi
  die "the container did not become healthy"
fi

if [[ "$SET_IP" == 1 ]]; then
  configure_static_ip
fi

# ---------------------------------------------------------------------------
# Long-running router support (forwarding, health checks, backups)
# ---------------------------------------------------------------------------

install_router_units() {
  local iface
  iface=${LAN_IFACE:-${NET_IFACE:-$(ip -4 route show default 2>/dev/null | awk '{ print $5; exit }')}}
  if [[ -z "$iface" ]]; then
    warn "could not determine the LAN interface; skipping forwarding service"
    if [[ "$HOST_DNS" == 1 ]]; then
      HOST_DNS_OK=0
    fi
    return 0
  fi

  install -d -m 0755 /usr/local/sbin
  cat > /etc/default/metacubexd-router <<EOF
# Managed by the MetaCubeXD installer.
ROUTER_IFACE=$iface
LAN_IFACE=$iface
LAN_IP=$LAN_IP
NET_GATEWAY=$NET_GATEWAY
APP_DIR=$APP_DIR
EOF
  chmod 0644 /etc/default/metacubexd-router

  cat > /usr/local/sbin/metacubexd-forward.sh <<'EOF'
#!/bin/sh
set -eu
. /etc/default/metacubexd-router
IFACE=${ROUTER_IFACE:-}
if [ -z "$IFACE" ] || ! ip link show "$IFACE" >/dev/null 2>&1; then
  IFACE=$(ip -4 route show default | awk '{ print $5; exit }')
fi
[ -n "$IFACE" ] || exit 0

add_rule() {
  iptables -C FORWARD "$@" 2>/dev/null || iptables -I FORWARD 1 "$@"
}
add_rule -i "$IFACE" -o Meta -j ACCEPT
add_rule -i Meta -o "$IFACE" -j ACCEPT
EOF
  chmod 0755 /usr/local/sbin/metacubexd-forward.sh

  cat > /etc/systemd/system/metacubexd-forward.service <<'EOF'
[Unit]
Description=Allow MetaCubeXD TUN forwarding
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/metacubexd-forward.sh
EOF

  cat > /etc/systemd/system/metacubexd-forward.timer <<'EOF'
[Unit]
Description=Re-assert MetaCubeXD TUN forwarding rules

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > /usr/local/sbin/metacubexd-health.sh <<'EOF'
#!/bin/sh
set -u
. /etc/default/metacubexd-router
APP_DIR=${APP_DIR:-/opt/metacubexd}
BASE=http://127.0.0.1:8080/api/control
STATE=/run/metacubexd-health
mkdir -p "$STATE"

TOKEN=$(sed -n 's/^CONTROL_TOKEN=//p' "$APP_DIR/.env" 2>/dev/null | tail -n1)
AUTH=""
[ -n "$TOKEN" ] && AUTH="Authorization: Bearer $TOKEN"

restart_container() {
  now=$(date +%s)
  last=$(cat "$STATE/last-restart" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt 1800 ]; then
    logger -t metacubexd-health "restart suppressed (cooldown): $1"
    return 0
  fi
  echo "$now" > "$STATE/last-restart"
  logger -t metacubexd-health "restarting container: $1"
  docker restart metacubexd >/dev/null 2>&1 || true
  rm -f "$STATE/health-fail" "$STATE/kernel-fail"
}

if curl -fsS --max-time 5 "$BASE/health" >/dev/null 2>&1; then
  rm -f "$STATE/health-fail"
else
  n=$(cat "$STATE/health-fail" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$STATE/health-fail"
  logger -t metacubexd-health "control server health failed ($n/3)"
  [ "$n" -ge 3 ] && restart_container "control server unhealthy"
fi

if [ -n "$TOKEN" ]; then
  status=$(curl -fsS --max-time 5 -H "$AUTH" "$BASE/kernel/status" 2>/dev/null |
    sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
  if [ "$status" = "errored" ]; then
    n=$(cat "$STATE/kernel-fail" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$STATE/kernel-fail"
    logger -t metacubexd-health "kernel errored ($n/3)"
    [ "$n" -ge 3 ] && restart_container "kernel errored"
  else
    rm -f "$STATE/kernel-fail"
  fi
fi

use=$(df -P / 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')
if [ -n "$use" ] && [ "$use" -ge 90 ]; then
  logger -t metacubexd-health "root filesystem is ${use}% full"
fi
EOF
  chmod 0755 /usr/local/sbin/metacubexd-health.sh

  cat > /etc/systemd/system/metacubexd-health.service <<'EOF'
[Unit]
Description=MetaCubeXD health and recovery check
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/metacubexd-health.sh
EOF

  cat > /etc/systemd/system/metacubexd-health.timer <<'EOF'
[Unit]
Description=Run MetaCubeXD health checks every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > /usr/local/sbin/metacubexd-backup.sh <<'EOF'
#!/bin/sh
set -eu
. /etc/default/metacubexd-router
APP_DIR=${APP_DIR:-/opt/metacubexd}
BACKUP_DIR=$APP_DIR/backups
DATA_VOLUME=$(sed -n 's/^DATA_VOLUME=//p' "$APP_DIR/.env" 2>/dev/null | tail -n1)
[ -n "$DATA_VOLUME" ] || DATA_VOLUME=metacubexd_metacubexd-data
VOLUME_PATH=$(docker volume inspect --format '{{ .Mountpoint }}' "$DATA_VOLUME" 2>/dev/null || true)
[ -n "$VOLUME_PATH" ] || exit 0

mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
stamp=$(date +%Y%m%d)
tar -czf "$BACKUP_DIR/metacubexd-$stamp.tar.gz" \
  -C "$APP_DIR" .env \
  -C "$VOLUME_PATH" .
find "$BACKUP_DIR" -name 'metacubexd-*.tar.gz' -mtime +7 -delete
EOF
  chmod 0700 /usr/local/sbin/metacubexd-backup.sh

  cat > /etc/systemd/system/metacubexd-backup.service <<'EOF'
[Unit]
Description=Back up MetaCubeXD configuration and data
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/sbin/metacubexd-backup.sh
EOF

  cat > /etc/systemd/system/metacubexd-backup.timer <<'EOF'
[Unit]
Description=Daily MetaCubeXD backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  if [[ "$HOST_DNS" == 1 && "$ROUTER_MODE" == 1 ]]; then
    cat > /usr/local/sbin/metacubexd-host-dns.sh <<'EOF'
#!/bin/sh
set -u
. /etc/default/metacubexd-router
IFACE=${LAN_IFACE:-${ROUTER_IFACE:-}}
LAN_IP=${LAN_IP:-}
GATEWAY=${NET_GATEWAY:-}
[ -n "$IFACE" ] || exit 0
[ -n "$LAN_IP" ] || exit 0
command -v resolvectl >/dev/null 2>&1 || exit 0
systemctl is-active --quiet systemd-resolved || exit 0

healthy=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 1 http://127.0.0.1:8080/api/control/health >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [ "$healthy" = 1 ]; then
  target=$LAN_IP
elif [ -n "$GATEWAY" ]; then
  target=$GATEWAY
else
  exit 0
fi

current=$(resolvectl dns "$IFACE" 2>/dev/null | awk '{print $NF}' | tail -n1)
if [ "$current" != "$target" ]; then
  resolvectl dns "$IFACE" "$target" >/dev/null 2>&1 || true
  resolvectl domain "$IFACE" '~.' >/dev/null 2>&1 || true
  resolvectl flush-caches >/dev/null 2>&1 || true
  logger -t metacubexd-host-dns "host DNS -> $target via $IFACE"
fi
EOF
    chmod 0755 /usr/local/sbin/metacubexd-host-dns.sh

    cat > /etc/systemd/system/metacubexd-host-dns.service <<'EOF'
[Unit]
Description=Point host DNS at the MetaCubeXD mihomo resolver
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/metacubexd-host-dns.sh
EOF

    cat > /etc/systemd/system/metacubexd-host-dns.timer <<'EOF'
[Unit]
Description=Re-assert host DNS for MetaCubeXD

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  else
    systemctl disable --now metacubexd-host-dns.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/metacubexd-host-dns.service \
      /etc/systemd/system/metacubexd-host-dns.timer \
      /usr/local/sbin/metacubexd-host-dns.sh
  fi

  systemctl daemon-reload
  systemctl enable --now metacubexd-forward.timer || warn "could not enable forwarding timer"
  systemctl enable --now metacubexd-health.timer || warn "could not enable health timer"
  systemctl enable --now metacubexd-backup.timer || warn "could not enable backup timer"

  if [[ "$HOST_DNS" == 1 && "$ROUTER_MODE" == 1 ]]; then
    systemctl enable --now metacubexd-host-dns.timer || warn "could not enable host DNS timer"
    systemctl start metacubexd-host-dns.service || warn "could not start host DNS service"
    if command -v resolvectl >/dev/null 2>&1; then
      if resolvectl query www.google.com 2>/dev/null | grep -q '198\.18\.'; then
        echo "Host DNS: mihomo (verified)"
      else
        warn "host DNS did not return a fake-ip; keeping the installer package for troubleshooting"
        HOST_DNS_OK=0
      fi
    else
      warn "resolvectl not found; host DNS management is unavailable"
      HOST_DNS_OK=0
    fi
  fi

  echo "Router support: forwarding, health checks, daily backups, host DNS"
}

if [[ "$IS_WSL" != true ]]; then
  install_router_units
fi

# ---------------------------------------------------------------------------
# Installer package cleanup
#
# Bundle mode keeps the archive, checksum and installer next to each other.
# After a successful install (health + host DNS verified), remove the bundle
# directory and the outer archive. The cleanup runs from a detached process so
# it never deletes the installer while bash is still reading it. The source
# checkout is protected by the bundle marker and .git checks below.
# ---------------------------------------------------------------------------

schedule_cleanup() {
  local script_dir bundle_dir="" parent="" outer_tgz="" outer_sha="" archive=""
  local -a targets=()
  local cleanup_cmd t

  script_dir=$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd) || return 0

  if [[ -f "$script_dir/SHA256SUMS" &&
    -f "$script_dir/README-pi.md" &&
    -f "$script_dir/metacubexd-server-pi.tar.gz" ]] &&
    [[ "$(basename "$script_dir")" == metacubexd-pi-* ]] &&
    [[ ! -d "$script_dir/.git" ]] &&
    [[ "$script_dir" != "$HOME" && "$script_dir" != "/" && "$script_dir" != "/opt" ]]; then
    bundle_dir=$script_dir
    parent=$(dirname "$bundle_dir")
    outer_tgz="$parent/$(basename "$bundle_dir").tar.gz"
    # Legacy release asset: remove it when upgrading from an older bundle.
    outer_sha="${outer_tgz}.sha256"
  fi

  if [[ -n "$bundle_dir" ]]; then
    targets+=("$bundle_dir")
    [[ -f "$outer_tgz" ]] && targets+=("$outer_tgz")
    [[ -f "$outer_sha" ]] && targets+=("$outer_sha")
  elif [[ -n "$ARCHIVE_FILE" && -f "$ARCHIVE_FILE" ]]; then
    targets+=("$ARCHIVE_FILE")
  fi

  [[ ${#targets[@]} -gt 0 ]] || return 0

  cleanup_cmd="sleep 5; rm -rf --"
  for t in "${targets[@]}"; do
    cleanup_cmd+=" $(printf '%q' "$t")"
  done
  if [[ -n "$parent" && "$parent" != "$HOME" && "$parent" != "/" ]]; then
    cleanup_cmd+="; rmdir --ignore-fail-on-non-empty -- $(printf '%q' "$parent") 2>/dev/null || true"
  fi

  echo "Cleanup scheduled:"
  for t in "${targets[@]}"; do
    echo "  $t"
  done

  if command -v systemd-run >/dev/null 2>&1 &&
    systemd-run --quiet --collect --on-active=5s \
      --unit="metacubexd-cleanup-$$" /bin/sh -c "$cleanup_cmd"; then
    :
  else
    nohup /bin/sh -c "$cleanup_cmd" >/dev/null 2>&1 &
  fi
}

# ---------------------------------------------------------------------------
# WSL-only CORS helper. Real router deployments get CORS, TUN and DNS from the
# agent-managed AIO Router base; there is no merge profile to create.
# ---------------------------------------------------------------------------

if [[ "$IS_WSL" == true ]]; then
  cat > "$APP_DIR/merge-profile.yaml" <<'EOF'
# Optional for WSL test mode only (no router-mode base there).
# Paste into Dashboard -> Profiles -> New Merge Profile, then activate it.
allow-lan: false

external-controller-cors:
  allow-private-network: true
  allow-origins:
    - 'http://localhost:8080'
    - 'http://127.0.0.1:8080'
EOF
  chmod 0640 "$APP_DIR/merge-profile.yaml"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

echo
echo "MetaCubeXD all-in-one has been installed."
if [[ "$IS_WSL" == true ]]; then
  echo "WSL test mode: open the dashboard at http://localhost:8080"
  echo "TUN and host routing are disabled in WSL test mode."
  echo "The Clash API endpoint is http://localhost:9090"
else
  echo "Open the dashboard: http://${LAN_IP}:8080"
  echo "The Clash API endpoint is http://${LAN_IP}:9090"
fi
echo "Clash API secret: $CLASH_SECRET"
echo
if [[ "$IS_WSL" != true ]]; then
  echo "Bypass-router setup:"
  echo "  1. Open http://${LAN_IP}:8080"
  echo "  2. Paste ONE subscription URL and import it."
  echo "  3. Everything else is automatic: AIO Router, TUN, DNS, rules, groups,"
  echo "     provider refresh and forwarding."
  echo "  4. Set clients' gateway and DNS to ${LAN_IP} (or push both from the"
  echo "     main router's DHCP server)."
  echo
  echo "Additional subscriptions: use the same import box. They become extra"
  echo "provider sources; no merge profile or YAML edit is required."
  echo
  echo "The dashboard has no login. Restrict 8080/9090/7890 to your LAN; do not"
  echo "expose them to the internet. Use a firewall and an authenticated reverse"
  echo "proxy for remote access."
else
  echo "Use the Merge Profile template for the CORS settings needed by the UI."
  echo "WSL test mode does not enable TUN; use it only for UI/subscription tests."
fi
echo
if [[ "$COMPOSE_MODE" == 1 ]]; then
  echo "Container logs: cd $APP_DIR && docker compose logs -f"
else
  echo "Container logs: docker logs -f metacubexd"
fi

if [[ "$CLEANUP" == 1 && "$IS_WSL" != true ]]; then
  if [[ "$HOST_DNS_OK" != 1 ]]; then
    warn "cleanup skipped because host DNS verification failed; remove the bundle manually after fixing it"
  elif [[ "$REBOOT_AFTER" == 1 ]]; then
    warn "cleanup skipped because --reboot was requested; remove the bundle manually after the reboot"
  else
    schedule_cleanup
  fi
fi

if [[ "$SET_IP" == 1 ]]; then
  echo
  echo "Static IP ${LAN_IP} is written but not active yet."
  echo "Reboot to apply it: sudo reboot"
  if [[ "$REBOOT_AFTER" == 1 ]]; then
    echo "Rebooting now..."
    reboot
  fi
fi
