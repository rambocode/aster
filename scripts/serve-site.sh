#!/bin/bash
# 本地预览官网：./scripts/serve-site.sh [端口]，默认 http://localhost:4321
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-4321}"
echo "Serving site/ → http://localhost:${PORT}  (Ctrl+C 停止)"
exec python3 -m http.server "${PORT}" --directory site
