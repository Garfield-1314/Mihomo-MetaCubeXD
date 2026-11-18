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
APP_DIR=${APP_DIR:-/opt/metacubexd}
IMAGE_TAG=${IMAGE_TAG:-metacubexd-server:local}
MIHOMO_TAG=${MIHOMO_TAG:-v1.19.27}
TARGET_PLATFORM=${TARGET_PLATFORM:-}
LAN_IP=${LAN_IP:-}
LAN_CIDR=${LAN_CIDR:-}
TZ=${TZ:-}
NODE_VERSION=${NODE_VERSION:-22}
GO_VERSION=${GO_VERSION:-1.26}

BUILD_LOCAL=1
NO_BUILD=0
NO_CACHE=0
TAG_SET=0
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
  --help                Show this help

Environment:
  APP_DIR, IMAGE_TAG, MIHOMO_TAG, TARGET_PLATFORM, LAN_IP, LAN_CIDR, TZ,
  NODE_VERSION, GO_VERSION
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (use --help)"
      ;;
  esac
done

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

apt-get update
PACKAGES=(ca-certificates curl openssl git iproute2 gzip)
if ! command -v docker >/dev/null 2>&1; then
  PACKAGES+=(docker.io)
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

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

  count=$(printf '%s' "$candidates" | grep -c . || true)
  if [[ "$count" -gt 1 ]]; then
    warn "multiple LAN candidates found; using ${iface} ${LAN_CIDR}. Rerun with --lan-ip/--lan-cidr to override."
  fi
  return 0
}

if [[ "$IS_WSL" == true ]]; then
  LAN_IP=localhost
  LAN_CIDR=""
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
      TZ: ${TZ}
    volumes:
      - metacubexd-data:/data

volumes:
  metacubexd-data:
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
      TZ: ${TZ}
    volumes:
      - metacubexd-data:/data

volumes:
  metacubexd-data:
EOF
fi
chmod 0640 "$APP_DIR/compose.yaml"

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
  docker volume create metacubexd-data >/dev/null
  RUN_ARGS=(--name metacubexd --restart unless-stopped)
  if [[ "$IS_WSL" == true ]]; then
    RUN_ARGS+=(-p 8080:8080 -p 9090:9090 -p 7890:7890)
  else
    RUN_ARGS+=(--network host --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun)
  fi
  docker run -d "${RUN_ARGS[@]}" \
    --env-file "$APP_DIR/.env" \
    -e CONTROL_PORT=8080 -e CLASH_API_PORT=9090 -e MIXED_PORT=7890 \
    -v metacubexd-data:/data \
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
  die "the container did not become healthy"
fi

# ---------------------------------------------------------------------------
# Dashboard merge-profile template
# ---------------------------------------------------------------------------

if [[ "$IS_WSL" == true ]]; then
  cat > "$APP_DIR/merge-profile.yaml" <<'EOF'
# Paste this into Dashboard -> Profiles -> New Merge Profile, then activate it.
# WSL test mode does not enable TUN.
allow-lan: false

external-controller-cors:
  allow-private-network: true
  allow-origins:
    - 'http://localhost:8080'
    - 'http://127.0.0.1:8080'
EOF
else
  cat > "$APP_DIR/merge-profile.yaml" <<EOF
# Paste this into Dashboard -> Profiles -> New Merge Profile, then activate it.
allow-lan: false

# The dashboard and the Clash API use different ports, so the browser treats
# them as different origins. Without this the UI may report
# "Unable to connect to backend".
external-controller-cors:
  allow-private-network: true
  allow-origins:
    - 'http://${LAN_IP}:8080'
    - 'http://localhost:8080'
    - 'http://127.0.0.1:8080'

# If LAN clients use this host as DNS and lookups fail, add a top-level block:
# dns:
#   listen: 0.0.0.0:53

tun:
  enable: true
  stack: mips
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
  route-exclude-address:
    - ${LAN_CIDR}
    - 127.0.0.0/8
    - 169.254.0.0/16
    - 10.0.0.0/8
    - 172.16.0.0/12
  dns-hijack:
    - any:53
    - tcp://any:53
EOF
fi
chmod 0640 "$APP_DIR/merge-profile.yaml"

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
echo "Merge profile template: $APP_DIR/merge-profile.yaml"
echo
if [[ "$IS_WSL" != true ]]; then
  echo "Bypass-router steps:"
  echo "  1. Import your subscription as a Remote Profile."
  echo "  2. Create a Merge Profile from $APP_DIR/merge-profile.yaml and activate it."
  echo "  3. Set the test client's gateway and DNS to ${LAN_IP}."
  echo "  4. Confirm IPv4 forwarding: sysctl net.ipv4.ip_forward"
  echo "  5. If DNS fails, test: dig @${LAN_IP} example.com"
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
