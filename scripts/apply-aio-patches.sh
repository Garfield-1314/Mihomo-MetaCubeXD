#!/usr/bin/env bash
set -Eeuo pipefail

# Apply the AIO router-mode patch to the metacubexd submodule working tree.
# Docker builds do this automatically (see docker/Dockerfile.local); this helper
# is for running the TypeScript tests/typecheck locally.
#
#   bash scripts/apply-aio-patches.sh
#
# The patch is intentionally applied only to the working tree. Do not commit the
# submodule pointer: metacubexd still tracks upstream.

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PATCH_FILE=$REPO_DIR/docker/router-mode.patch
TARGET_DIR=$REPO_DIR/metacubexd

[[ -f "$PATCH_FILE" ]] || {
  echo "error: missing $PATCH_FILE" >&2
  exit 1
}
[[ -d "$TARGET_DIR/.git" || -f "$TARGET_DIR/.git" ]] || {
  echo "error: $TARGET_DIR is not a git checkout" >&2
  exit 1
}

git -C "$TARGET_DIR" apply --check "$PATCH_FILE"
git -C "$TARGET_DIR" apply "$PATCH_FILE"
echo "Applied $(basename "$PATCH_FILE") to $TARGET_DIR"
