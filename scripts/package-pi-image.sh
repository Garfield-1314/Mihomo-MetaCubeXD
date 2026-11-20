#!/usr/bin/env bash
set -Eeuo pipefail

# Build an arm64 image for Raspberry Pi and package it with the installer.
#
# Typical use on an x86 WSL/PC:
#   bash scripts/package-pi-image.sh
#
# Typical use on an arm64 build host:
#   bash scripts/package-pi-image.sh --no-binfmt
#
# Re-package an existing arm64 image without rebuilding:
#   bash scripts/package-pi-image.sh --skip-build

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

IMAGE_TAG=${IMAGE_TAG:-metacubexd-server:pi}
OUTPUT_DIR=${OUTPUT_DIR:-"$REPO_DIR/dist"}
MIHOMO_TAG=${MIHOMO_TAG:-}
NODE_VERSION=${NODE_VERSION:-22}
GO_VERSION=${GO_VERSION:-1.26}
BASE_REGISTRY=${BASE_REGISTRY:-docker.io}
GOPROXY=${GOPROXY:-https://proxy.golang.org,direct}
NPM_REGISTRY=${NPM_REGISTRY:-https://registry.npmjs.org/}
BINFMT_IMAGE=${BINFMT_IMAGE:-tonistiigi/binfmt:latest}
BUNDLE_NAME=${BUNDLE_NAME:-}
NO_CACHE=0
SKIP_BUILD=0
INSTALL_BINFMT=1
MAKE_TAR=1

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

usage() {
  cat <<EOF
Usage: bash scripts/package-pi-image.sh [options]

Builds a linux/arm64 image from the local sources and creates a Raspberry Pi
bundle containing the image, the installer, README-pi.md and SHA256SUMS.

Options:
  --tag TAG             Image tag (default: $IMAGE_TAG)
  --output DIR          Output directory (default: $OUTPUT_DIR)
  --name NAME           Bundle directory name
  --mihomo-tag TAG      mihomo version to build
  --node-version VER    Node base image version (default: $NODE_VERSION)
  --go-version VER      Go base image version (default: $GO_VERSION)
  --no-cache            Rebuild all layers
  --skip-build          Package an existing arm64 image instead of building
  --no-binfmt           Do not install arm64 binfmt on an x86 build host
  --no-tar              Only create the bundle directory, not the outer tar.gz
  -h, --help            Show this help

Environment:
  BASE_REGISTRY   Docker Hub mirror for base images (default: $BASE_REGISTRY)
  GOPROXY         Go module proxy (default: $GOPROXY)
  NPM_REGISTRY    npm registry (default: $NPM_REGISTRY)
  BINFMT_IMAGE    binfmt image (default: $BINFMT_IMAGE)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      IMAGE_TAG=$2
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      OUTPUT_DIR=$2
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      BUNDLE_NAME=$2
      shift 2
      ;;
    --mihomo-tag)
      [[ $# -ge 2 ]] || die "--mihomo-tag requires a value"
      MIHOMO_TAG=$2
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
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --no-binfmt)
      INSTALL_BINFMT=0
      shift
      ;;
    --no-tar)
      MAKE_TAR=0
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

command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

if [[ -z "$MIHOMO_TAG" ]]; then
  if command -v git >/dev/null 2>&1; then
    MIHOMO_TAG=$(git -C "$REPO_DIR/mihomo" describe --tags --exact-match 2>/dev/null ||
      git -C "$REPO_DIR/mihomo" describe --tags --always 2>/dev/null || true)
  fi
  MIHOMO_TAG=${MIHOMO_TAG:-v1.19.27}
fi

METACUBEXD_VERSION=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' \
  "$REPO_DIR/metacubexd/package.json" | head -n1)
METACUBEXD_VERSION=${METACUBEXD_VERSION:-dev}

if [[ -z "$BUNDLE_NAME" ]]; then
  BUNDLE_NAME="metacubexd-pi-${METACUBEXD_VERSION}-${MIHOMO_TAG}"
fi

BUNDLE_DIR="$OUTPUT_DIR/$BUNDLE_NAME"
IMAGE_FILE="$BUNDLE_DIR/metacubexd-server-pi.tar.gz"

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64|amd64) HOST_ARCH=amd64 ;;
  aarch64|arm64) HOST_ARCH=arm64 ;;
  *) die "unsupported build host architecture: $HOST_ARCH" ;;
esac

if [[ "$SKIP_BUILD" == 0 ]]; then
  if [[ "$HOST_ARCH" == "amd64" && "$INSTALL_BINFMT" == 1 ]]; then
    echo "Installing arm64 binfmt for cross-building..."
    docker run --privileged --rm "$BINFMT_IMAGE" --install arm64 ||
      warn "could not install arm64 binfmt; the build may fail with 'exec format error'"
  fi

  BUILD_ARGS=(--tag "$IMAGE_TAG" --mihomo-tag "$MIHOMO_TAG"
    --node-version "$NODE_VERSION" --go-version "$GO_VERSION")
  # Native arm64 builders (including the Pi itself) do not need buildx.
  if [[ "$HOST_ARCH" != "arm64" ]]; then
    BUILD_ARGS+=(--platform linux/arm64)
  fi
  [[ "$NO_CACHE" == 1 ]] && BUILD_ARGS+=(--no-cache)
  bash "$REPO_DIR/scripts/build-local-image.sh" "${BUILD_ARGS[@]}"
else
  docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 ||
    die "image $IMAGE_TAG does not exist; remove --skip-build or build it first"
fi

IMAGE_ARCH=$(docker image inspect "$IMAGE_TAG" --format '{{.Architecture}}' 2>/dev/null || true)
[[ "$IMAGE_ARCH" == "arm64" ]] ||
  die "image $IMAGE_TAG is ${IMAGE_ARCH:-unknown}, expected arm64"

install -d -m 0755 "$BUNDLE_DIR"

echo "Saving image to $IMAGE_FILE..."
docker save "$IMAGE_TAG" | gzip >"$IMAGE_FILE"

cp "$REPO_DIR/install-mihomo-bypass-router.sh" "$BUNDLE_DIR/"
chmod 0755 "$BUNDLE_DIR/install-mihomo-bypass-router.sh"

cat >"$BUNDLE_DIR/README-pi.md" <<EOF
# MetaCubeXD Raspberry Pi bundle

- MetaCubeXD: ${METACUBEXD_VERSION}
- mihomo: ${MIHOMO_TAG}
- Image: \`${IMAGE_TAG}\` (linux/arm64)
- Installer: \`install-mihomo-bypass-router.sh\`

## Requirements

- 64-bit Raspberry Pi OS (\`uname -m\` must be \`aarch64\`)
- Docker installed on the Pi. The installer can install it automatically.
- At least 1 GB free disk for the loaded image, plus profile/geo data.

## Verify

\`\`\`bash
sha256sum -c SHA256SUMS
\`\`\`

## Install

Replace the example LAN values with your own. The installer loads the archive
and does not need the source tree on the Pi.

\`\`\`bash
sudo bash install-mihomo-bypass-router.sh \\
  --archive metacubexd-server-pi.tar.gz \\
  --tag ${IMAGE_TAG} \\
  --lan-ip 192.168.5.100 \\
  --lan-cidr 192.168.5.0/24
\`\`\`

Then open \`http://<LAN_IP>:8080\`, import ONE subscription URL, and wait for
the managed AIO Router profile to activate.

## Notes

- Do not use this image on a 32-bit (\`armv7l\`) system.
- WSL test mode is not used here; this bundle is for the Pi.
- The installer enables IPv4 forwarding and checks \`/dev/net/tun\`.
- The installer installs \`metacubexd-host-dns.timer\`, which points the Pi's
  own resolver at \`<LAN_IP>:53\` once mihomo is healthy. Add \`--no-host-dns\`
  to keep the host resolver untouched.
- When run from this bundle after a successful install, the installer removes
  the image archive, the outer bundle and itself. Add \`--no-cleanup\` to keep
  them for debugging.
- Keep 8080/9090/7890 on the trusted LAN; the dashboard has no login.
EOF
chmod 0644 "$BUNDLE_DIR/README-pi.md"

(
  cd "$BUNDLE_DIR"
  sha256sum install-mihomo-bypass-router.sh metacubexd-server-pi.tar.gz README-pi.md >SHA256SUMS
  sha256sum -c SHA256SUMS
)
chmod 0644 "$BUNDLE_DIR/SHA256SUMS"

if [[ "$MAKE_TAR" == 1 ]]; then
  echo "Creating $OUTPUT_DIR/$BUNDLE_NAME.tar.gz..."
  tar -C "$OUTPUT_DIR" -czf "$OUTPUT_DIR/$BUNDLE_NAME.tar.gz" "$BUNDLE_NAME"
  (
    cd "$OUTPUT_DIR"
    sha256sum "$BUNDLE_NAME.tar.gz" >"$BUNDLE_NAME.tar.gz.sha256"
  )
fi

echo
echo "Bundle: $BUNDLE_DIR"
if [[ "$MAKE_TAR" == 1 ]]; then
  echo "Archive: $OUTPUT_DIR/$BUNDLE_NAME.tar.gz"
fi
echo
echo "Copy the bundle (or the outer archive) to the Raspberry Pi, then run:"
echo "  sudo bash install-mihomo-bypass-router.sh \\"
echo "    --archive metacubexd-server-pi.tar.gz --tag $IMAGE_TAG \\"
echo "    --lan-ip <LAN_IP> --lan-cidr <LAN_CIDR>"
