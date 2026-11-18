#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the pinned local sources before CI spends time building images.

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() {
  echo "preflight: $*" >&2
  exit 1
}

cd "$REPO_DIR"

for path in \
  install-mihomo-bypass-router.sh \
  docker/Dockerfile.local \
  docker/patch-offline-fonts.mjs \
  scripts/build-local-image.sh \
  scripts/package-pi-image.sh \
  metacubexd/pnpm-lock.yaml \
  metacubexd/package.json \
  mihomo/go.mod; do
  [[ -e "$path" ]] || die "missing $path"
done

grep -q '^module github.com/metacubex/mihomo$' mihomo/go.mod ||
  die "mihomo/go.mod is not the Go kernel source"

git -C mihomo rev-parse --git-dir >/dev/null 2>&1 ||
  die "mihomo is not a git checkout"
git -C metacubexd rev-parse --git-dir >/dev/null 2>&1 ||
  die "metacubexd is not a git checkout"

[[ -z "$(git -C mihomo status --porcelain)" ]] ||
  die "mihomo worktree is dirty; commit or revert local changes"
[[ -z "$(git -C metacubexd status --porcelain)" ]] ||
  die "metacubexd worktree is dirty; commit or revert local changes"

MIHOMO_TAG=$(git -C mihomo describe --tags --exact-match 2>/dev/null ||
  git -C mihomo describe --tags --always 2>/dev/null || true)
[[ -n "$MIHOMO_TAG" ]] || die "could not determine the mihomo revision"

METACUBEXD_DESC=$(git -C metacubexd describe --tags --always 2>/dev/null || true)
METACUBEXD_VERSION=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' \
  metacubexd/package.json | head -n1)

for script in install-mihomo-bypass-router.sh scripts/*.sh; do
  bash -n "$script" || die "shell syntax error in $script"
done

echo "preflight: OK"
echo "  mihomo:     ${MIHOMO_TAG}"
echo "  metacubexd: ${METACUBEXD_VERSION} (${METACUBEXD_DESC})"
