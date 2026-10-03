#!/usr/bin/env bash
set -euo pipefail

STUDIO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
"$STUDIO_ROOT/build.sh"
STUDIO_BIN_DIR="$(swift build --package-path "$STUDIO_ROOT" --configuration "${STUDIO_BUILD_CONFIGURATION:-release}" --show-bin-path)"
exec "$STUDIO_BIN_DIR/midnight-studio" "$@"
