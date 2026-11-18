#!/usr/bin/env bash
set -Eeuo pipefail

# Build the MetaCubeXD all-in-one image entirely from the local source tree.
#
#   bash scripts/build-local-image.sh
#   bash scripts/build-local-image.sh --tag metacubexd-server:test --no-cache
#   bash scripts/build-local-image.sh --platform linux/arm64
#
# The image includes:
#   - mihomo compiled from ./mihomo (Go source)
#   - the dashboard UI built from ./metacubexd/packages/ui
#   - the Nitro control server built from ./metacubexd/apps/server

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

IMAGE_TAG=${IMAGE_TAG:-metacubexd-server:local}
MIHOMO_TAG=${MIHOMO_TAG:-}
TARGET_PLATFORM=${TARGET_PLATFORM:-}
NODE_VERSION=${NODE_VERSION:-22}
GO_VERSION=${GO_VERSION:-1.26}
BASE_REGISTRY=${BASE_REGISTRY:-docker.io}
GOPROXY=${GOPROXY:-https://proxy.golang.org,direct}
NPM_REGISTRY=${NPM_REGISTRY:-https://registry.npmjs.org/}
NUXT_FONTS_DISABLE_REMOTE=${NUXT_FONTS_DISABLE_REMOTE:-true}
BUILDX_CACHE_FROM=${BUILDX_CACHE_FROM:-}
BUILDX_CACHE_TO=${BUILDX_CACHE_TO:-}
NO_CACHE=0
SAVE_FILE=""

usage() {
  cat <<EOF
Usage: bash scripts/build-local-image.sh [options]

Options:
  --tag TAG             Image tag (default: $IMAGE_TAG)
  --mihomo-tag TAG      Version string compiled into mihomo
                        (default: current git tag of ./mihomo)
  --platform PLATFORM   Build for a platform, e.g. linux/amd64 or linux/arm64
                        (requires docker buildx)
  --node-version VER    Node base image version (default: $NODE_VERSION)
  --go-version VER      Go base image version (default: $GO_VERSION)
  --no-cache            Rebuild all layers
  --save FILE           Save the built image to FILE (.tar or .tar.gz)
  -h, --help            Show this help

Environment:
  BASE_REGISTRY   Docker Hub mirror for base images (default: $BASE_REGISTRY)
  GOPROXY         Go module proxy (default: $GOPROXY)
  NPM_REGISTRY    npm registry (default: $NPM_REGISTRY)
  NUXT_FONTS_DISABLE_REMOTE
                  Skip remote Google Fonts metadata (default: $NUXT_FONTS_DISABLE_REMOTE)
  BUILDX_CACHE_FROM / BUILDX_CACHE_TO
                  BuildKit cache exporters, e.g. type=gha,scope=ci
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      IMAGE_TAG=$2
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
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    --save)
      [[ $# -ge 2 ]] || die "--save requires a value"
      SAVE_FILE=$2
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

command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

[[ -f "$REPO_DIR/metacubexd/pnpm-lock.yaml" ]] ||
  die "missing $REPO_DIR/metacubexd/pnpm-lock.yaml"
[[ -f "$REPO_DIR/mihomo/go.mod" ]] ||
  die "missing $REPO_DIR/mihomo/go.mod"
grep -q '^module github.com/metacubex/mihomo$' "$REPO_DIR/mihomo/go.mod" ||
  die "./mihomo is not the Go kernel source; run: git -C mihomo checkout v1.19.27"
[[ -f "$REPO_DIR/docker/Dockerfile.local" ]] ||
  die "missing $REPO_DIR/docker/Dockerfile.local"

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

case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH=amd64 ;;
  aarch64|arm64) HOST_ARCH=arm64 ;;
  *) die "unsupported host architecture: $(uname -m)" ;;
esac

export DOCKER_BUILDKIT=1

if [[ -n "$TARGET_PLATFORM" || -n "$BUILDX_CACHE_FROM" || -n "$BUILDX_CACHE_TO" ]]; then
  docker buildx version >/dev/null 2>&1 ||
    die "docker buildx is required for --platform or BuildKit cache options"
  BUILD_CMD=(docker buildx build --load)
  if [[ -n "$TARGET_PLATFORM" ]]; then
    DOCKER_ARCH=${TARGET_PLATFORM##*/}
    BUILD_CMD+=(--platform "$TARGET_PLATFORM")
  else
    DOCKER_ARCH=$HOST_ARCH
  fi
else
  DOCKER_ARCH=$HOST_ARCH
  BUILD_CMD=(docker build)
fi

BUILD_ARGS=(
  --build-arg "TARGETARCH=$DOCKER_ARCH"
  --build-arg "MIHOMO_VERSION=$MIHOMO_TAG"
  --build-arg "NODE_VERSION=$NODE_VERSION"
  --build-arg "GO_VERSION=$GO_VERSION"
  --build-arg "BASE_REGISTRY=$BASE_REGISTRY"
  --build-arg "GOPROXY=$GOPROXY"
  --build-arg "NPM_REGISTRY=$NPM_REGISTRY"
  --build-arg "NUXT_FONTS_DISABLE_REMOTE=$NUXT_FONTS_DISABLE_REMOTE"
  --build-arg "METACUBEXD_VERSION=$METACUBEXD_VERSION"
)
if [[ "$NO_CACHE" == 1 ]]; then
  BUILD_ARGS+=(--no-cache)
fi
if [[ -n "$BUILDX_CACHE_FROM" ]]; then
  BUILD_ARGS+=(--cache-from "$BUILDX_CACHE_FROM")
fi
if [[ -n "$BUILDX_CACHE_TO" ]]; then
  BUILD_ARGS+=(--cache-to "$BUILDX_CACHE_TO")
fi

echo "Building $IMAGE_TAG"
echo "  mihomo:      $MIHOMO_TAG ($DOCKER_ARCH)"
echo "  metacubexd:  $METACUBEXD_VERSION"
echo "  base:        $BASE_REGISTRY"
echo "  repo:        $REPO_DIR"

"${BUILD_CMD[@]}" "${BUILD_ARGS[@]}" \
  -f "$REPO_DIR/docker/Dockerfile.local" \
  -t "$IMAGE_TAG" \
  "$REPO_DIR"

if [[ -z "$TARGET_PLATFORM" || "$DOCKER_ARCH" == "$HOST_ARCH" ]]; then
  echo
  echo "Verifying bundled kernel:"
  docker run --rm --entrypoint /usr/local/bin/mihomo "$IMAGE_TAG" -v
else
  echo
  echo "Skipped runtime verification: image is for $DOCKER_ARCH, host is $HOST_ARCH."
fi

if [[ -n "$SAVE_FILE" ]]; then
  echo
  echo "Saving image to $SAVE_FILE..."
  case "$SAVE_FILE" in
    *.gz)
      docker save "$IMAGE_TAG" | gzip >"$SAVE_FILE"
      ;;
    *)
      docker save -o "$SAVE_FILE" "$IMAGE_TAG"
      ;;
  esac
  echo "Saved $SAVE_FILE"
fi

echo
echo "Built $IMAGE_TAG"
