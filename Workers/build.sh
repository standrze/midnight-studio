#!/usr/bin/env bash
set -euo pipefail

STUDIO_WORKER_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
STUDIO_RUNTIME_ROOT="${MIDNIGHT_RUNTIME_PATH:-$STUDIO_WORKER_ROOT/../../midnight}"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Studio native workers are currently validated on macOS/Metal only.' >&2
  exit 2
fi
if [[ ! -f "$STUDIO_RUNTIME_ROOT/Package.swift" || ! -x "$STUDIO_RUNTIME_ROOT/build.sh" ]]; then
  echo 'Studio workers require the sibling Midnight checkout. Set MIDNIGHT_RUNTIME_PATH for another location.' >&2
  exit 2
fi
STUDIO_RUNTIME_ROOT="$(cd "$STUDIO_RUNTIME_ROOT" && pwd -P)"
export MIDNIGHT_RUNTIME_PATH="$STUDIO_RUNTIME_ROOT"
export MODEL_RUNNER_BUILD_PACKAGE_ROOT="$STUDIO_WORKER_ROOT"
export MODEL_RUNNER_BUILD_PRODUCT=midnight-studio-worker
export MODEL_RUNNER_BUILD_CONFIGURATION="${STUDIO_WORKER_BUILD_CONFIGURATION:-release}"
export MODEL_RUNNER_BUILD_JOBS="${STUDIO_WORKER_BUILD_JOBS:-2}"
# Midnight applies its reviewed dependency patches to this package's checkouts
# and builds the matching mlx.metallib beside the worker executable.
exec "$STUDIO_RUNTIME_ROOT/build.sh"
