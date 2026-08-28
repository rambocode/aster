#!/bin/bash
# 本地预览官网：./scripts/serve-site.sh [端口]，默认 http://localhost:4321
#
# 不能直接用 `python3 -m http.server`：文档站开了 VitePress 的 cleanUrls，站内链接
# 是 /docs/faq 这种无后缀形式，线上由 Cloudflare Pages 映射到 faq.html。裸的
# http.server 没有这个映射，本地点任何文档链接都会 404。下面的 handler 补上同样的
# 回退规则，让本地预览和线上表现一致。
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-4321}"
echo "Serving site/ → http://localhost:${PORT}  (Ctrl+C 停止)"
exec python3 - "$PORT" <<'PY'
import functools, http.server, os, socketserver, sys

class CleanURLHandler(http.server.SimpleHTTPRequestHandler):
    """无后缀路径找不到时回退到同名 .html，对齐 Cloudflare Pages 的行为。"""

    def translate_path(self, path):
        full = super().translate_path(path)
        if not os.path.exists(full) and not path.endswith("/"):
            candidate = full + ".html"
            if os.path.isfile(candidate):
                return candidate
        return full

port = int(sys.argv[1])
handler = functools.partial(CleanURLHandler, directory="site")
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", port), handler) as httpd:
    httpd.serve_forever()
PY
