#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")/build/Bassline.app"

"$SCRIPT_DIR/build_app.sh"

# Replace a running copy so the new build is the one that starts.
pkill -x Bassline 2>/dev/null || true

echo "Launching Bassline..."
open "$APP_DIR"
