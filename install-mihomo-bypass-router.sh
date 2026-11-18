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
DATA_VOLUME=${DATA_VOLUME:-}
NET_IFACE=${NET_IFACE:-}
NET_GATEWAY=${NET_GATEWAY:-}
NET_DNS=${NET_DNS:-}
TZ=${TZ:-}
NODE_VERSION=${NODE_VERSION:-22}
GO_VERSION=${GO_VERSION:-1.26}

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
  --disable-wifi        Disable Wi-Fi persistently when --set-ip is used
  --reboot              Reboot after writing the static-IP config
  --help                Show this help

Environment:
  APP_DIR, IMAGE_TAG, MIHOMO_TAG, TARGET_PLATFORM, LAN_IP, LAN_CIDR,
  DATA_VOLUME, NET_IFACE, NET_GATEWAY, NET_DNS, TZ, NODE_VERSION, GO_VERSION
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

if [[ "$SET_IP" == 1 && "$IS_WSL" == true ]]; then
  die "--set-ip is not supported in WSL test mode"
fi

apt-get update
PACKAGES=(ca-certificates curl openssl git iproute2 gzip)
if [[ "$DISABLE_WIFI" == 1 ]]; then
  PACKAGES+=(rfkill)
fi
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
DATA_VOLUME=$DATA_VOLUME
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
      TZ: ${TZ}
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
  RUN_ARGS=(--name metacubexd --restart unless-stopped)
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

if [[ "$SET_IP" == 1 ]]; then
  echo
  echo "Static IP ${LAN_IP} is written but not active yet."
  echo "Reboot to apply it: sudo reboot"
  if [[ "$REBOOT_AFTER" == 1 ]]; then
    echo "Rebooting now..."
    reboot
  fi
fi
