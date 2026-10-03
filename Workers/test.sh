#!/usr/bin/env bash
set -euo pipefail

STUDIO_WORKER_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
STUDIO_RUNTIME_ROOT="${MIDNIGHT_RUNTIME_PATH:-$STUDIO_WORKER_ROOT/../../midnight}"
export MIDNIGHT_RUNTIME_PATH="$(cd "$STUDIO_RUNTIME_ROOT" && pwd -P)"
"$STUDIO_WORKER_ROOT/build.sh"
STUDIO_WORKER_CONFIGURATION="${STUDIO_WORKER_BUILD_CONFIGURATION:-release}"
STUDIO_WORKER_JOBS="${STUDIO_WORKER_BUILD_JOBS:-2}"
swift build --package-path "$STUDIO_WORKER_ROOT" \
  --configuration "$STUDIO_WORKER_CONFIGURATION" --jobs "$STUDIO_WORKER_JOBS" --build-tests
STUDIO_WORKER_BIN_DIR="$(swift build --package-path "$STUDIO_WORKER_ROOT" --configuration "$STUDIO_WORKER_CONFIGURATION" --show-bin-path)"
# XCTest runs its executable inside a bundle; MLX searches beside that binary.
cp "$STUDIO_WORKER_BIN_DIR/mlx.metallib" \
  "$STUDIO_WORKER_BIN_DIR/MidnightStudioWorkersPackageTests.xctest/Contents/MacOS/mlx.metallib"
swift test --package-path "$STUDIO_WORKER_ROOT" \
  --configuration "$STUDIO_WORKER_CONFIGURATION" --jobs "$STUDIO_WORKER_JOBS" \
  --skip-build --no-parallel "$@"
