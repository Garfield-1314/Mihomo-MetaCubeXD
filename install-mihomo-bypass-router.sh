#!/usr/bin/env bash
set -Eeuo pipefail

# Install the MetaCubeXD all-in-one server on Debian/Ubuntu, including WSL test mode.
# Import the Clash/Mihomo subscription later from the dashboard.
# Run: sudo bash install-mihomo-bypass-router.sh

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

. /etc/os-release
if [[ " ${ID:-} ${ID_LIKE:-} " != *debian* && " ${ID:-} ${ID_LIKE:-} " != *ubuntu* ]] || ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer requires a Debian/Ubuntu-family system with apt." >&2
  exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64|x86_64|amd64) ;;
  *) echo "Unsupported architecture: $ARCH (expected 64-bit ARM or x86_64 Ubuntu)." >&2; exit 1 ;;
esac

IS_WSL=false
if grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null; then
  IS_WSL=true
fi

apt-get update
PACKAGES=(ca-certificates curl openssl)
if [[ "$IS_WSL" == true ]]; then
  # WSL test mode uses docker run, so it does not need the Compose plugin.
  if ! command -v docker >/dev/null 2>&1; then PACKAGES+=(docker.io); fi
else
  PACKAGES+=(docker.io docker-compose-v2)
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

if ! docker info >/dev/null 2>&1; then
  if [[ -d /run/systemd/system ]]; then
    systemctl enable --now docker
  else
    service docker start || true
  fi
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is unavailable. In WSL, enable Docker Desktop integration or systemd." >&2
  exit 1
fi

if [[ "$IS_WSL" != true ]]; then
  if [[ ! -c /dev/net/tun ]]; then
    modprobe tun || true
  fi
  if [[ ! -c /dev/net/tun ]]; then
    echo "Missing /dev/net/tun. Check that the Linux TUN module is available." >&2
    exit 1
  fi
fi

# Stop the earlier standalone Mihomo service, if this script is being used to migrate.
if systemctl list-unit-files mihomo.service --no-legend 2>/dev/null | grep -q '^mihomo.service'; then
  systemctl disable --now mihomo.service || true
fi

APP_DIR=/opt/metacubexd
install -d -m 0750 "$APP_DIR"
if [[ -f "$APP_DIR/.env" ]]; then
  cp -a "$APP_DIR/.env" "$APP_DIR/.env.bak.$(date +%Y%m%d-%H%M%S)"
fi

CONTROL_TOKEN=$(openssl rand -hex 32)
CLASH_SECRET=$(openssl rand -hex 32)
cat > "$APP_DIR/.env" <<EOF
CONTROL_TOKEN=$CONTROL_TOKEN
CLASH_SECRET=$CLASH_SECRET
TZ=Asia/Shanghai
EOF
chmod 0600 "$APP_DIR/.env"

if [[ "$IS_WSL" == true ]]; then
  # WSL mode is for UI/subscription testing only. It deliberately does not
  # attach TUN or alter host routing.
  cat > "$APP_DIR/compose.yaml" <<'EOF'
services:
  metacubexd:
    image: ghcr.io/metacubex/metacubexd-server:latest
    container_name: metacubexd
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "9090:9090"
      - "7890:7890"
    environment:
      CONTROL_TOKEN: ${CONTROL_TOKEN}
      CLASH_SECRET: ${CLASH_SECRET}
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
    image: ghcr.io/metacubex/metacubexd-server:latest
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

cd "$APP_DIR"
if [[ "$IS_WSL" == true ]]; then
  docker pull ghcr.io/metacubex/metacubexd-server:latest
  docker volume create metacubexd-data >/dev/null
  docker rm -f metacubexd >/dev/null 2>&1 || true
  docker run -d --name metacubexd --restart unless-stopped \
    -p 8080:8080 -p 9090:9090 -p 7890:7890 \
    --env-file "$APP_DIR/.env" \
    -e CONTROL_PORT=8080 -e CLASH_API_PORT=9090 -e MIXED_PORT=7890 \
    -v metacubexd-data:/data \
    ghcr.io/metacubex/metacubexd-server:latest >/dev/null
else
  docker compose pull
  docker compose up -d
fi

echo
echo "MetaCubeXD all-in-one has been installed."
if [[ "$IS_WSL" == true ]]; then
  echo "WSL test mode: open the dashboard at http://localhost:8080"
  echo "TUN and host routing are disabled in WSL test mode."
else
  echo "Open the dashboard: http://192.168.5.100:8080"
fi
echo "In the UI, import your subscription URL as a Remote Profile."
if [[ "$IS_WSL" == true ]]; then
  echo "The Clash API endpoint is http://localhost:9090"
else
  echo "The Clash API endpoint is http://192.168.5.100:9090"
fi
echo "Clash API secret: $CLASH_SECRET"
echo
if [[ "$IS_WSL" != true ]]; then
  echo "For bypass-router TUN mode, add a Merge Profile in the UI and activate it with:"
cat <<'YAML'
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
  route-exclude-address:
    - 192.168.5.0/24
  dns-hijack:
    - any:53
    - tcp://any:53
YAML
  echo "Set one test client's gateway and DNS to 192.168.5.100."
else
  echo "WSL test mode does not enable TUN; use this run only to test UI and subscription import."
fi
if [[ "$IS_WSL" == true ]]; then
  echo "Container logs: docker logs -f metacubexd"
else
  echo "Container logs: cd $APP_DIR && docker compose logs -f"
fi
