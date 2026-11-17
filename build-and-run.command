#!/bin/bash
# Development helper. Release artifact: dist/Inij-0.3.3-arm64.dmg.
set -euo pipefail
cd "$(dirname "$0")"
bash scripts/build-app.sh
open "build/Inij.app"
