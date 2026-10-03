#!/usr/bin/env bash
set -euo pipefail

STUDIO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
STUDIO_CONFIGURATION="${STUDIO_BUILD_CONFIGURATION:-release}"
STUDIO_JOBS="${STUDIO_BUILD_JOBS:-2}"
case "$STUDIO_CONFIGURATION" in
  debug|release) ;;
  *) echo 'STUDIO_BUILD_CONFIGURATION must be debug or release.' >&2; exit 2 ;;
esac
if ! [[ "$STUDIO_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo 'STUDIO_BUILD_JOBS must be a positive integer.' >&2
  exit 2
fi
swift build --package-path "$STUDIO_ROOT" --configuration "$STUDIO_CONFIGURATION" --jobs "$STUDIO_JOBS"
