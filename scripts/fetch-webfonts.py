#!/usr/bin/env python3
"""从 Google Fonts 抓取落地页用到的网页字体，落到 site/assets/fonts/ 并生成 fonts.css。

官网原先直接 <link> 到 fonts.googleapis.com。该域名在中国大陆不可达，大陆访客
要等到连接超时才会回退系统字体，首屏因此明显变慢且字形与设计不符。改成自托管后
字体随站点走 Cloudflare CDN，没有外部依赖。

只保留 latin / latin-ext 子集：本站正文是中英文，希腊语、西里尔、越南语字形用不到。
中文不抓取 webfont —— 目标用户全是 macOS，系统自带 Songti SC 与 PingFang SC，
回退链见 site/assets/style.css 的 --font-serif / --font-body。

用法（字体清单或字重变化时才需要重跑）：
    python3 scripts/fetch-webfonts.py
"""
import re
import pathlib
import urllib.request

# 与落地页设计一致的字体清单；Newsreader 与 JetBrains Mono 都是可变字体，
# 因此这里请求的是字重区间而非离散字重。
GOOGLE_CSS_URL = (
    "https://fonts.googleapis.com/css2"
    "?family=Newsreader:ital,opsz,wght@0,6..72,400..700;1,6..72,400..700"
    "&family=Noto+Serif+SC:wght@500;600;700"
    "&family=JetBrains+Mono:wght@400;500;600"
    "&display=swap"
)

# 必须伪装成现代浏览器：Google 按 User-Agent 决定返回 woff2 还是老格式 ttf。
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

KEEP_FAMILIES = {"Newsreader", "JetBrains Mono"}
KEEP_SUBSETS = {"latin", "latin-ext"}

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT_DIR = ROOT / "site" / "assets" / "fonts"
CSS_PATH = ROOT / "site" / "assets" / "fonts.css"

HEADER = """/* 自托管网页字体：Newsreader（衬线标题）与 JetBrains Mono（等宽）。
 *
 * 原先从 fonts.googleapis.com 加载，但该域名在中国大陆不可达，大陆访客要一直等到
 * 超时才会回退到系统字体。字体文件直接随站点走 Cloudflare CDN，去掉这个外部依赖。
 *
 * 只保留 latin 与 latin-ext 两个子集：本站正文是中英文，希腊语/西里尔/越南语字形
 * 用不到。中文不再加载 Noto Serif SC——目标用户全是 macOS，系统自带 Songti SC 与
 * PingFang SC，见 style.css 里 --font-serif / --font-body 的回退链。
 *
 * 本文件由 scripts/fetch-webfonts.py 生成，不要手改。
 */
"""


def fetch_google_css() -> str:
    """取回 Google 的 @font-face 清单（带 UA，否则拿不到 woff2）。"""
    req = urllib.request.Request(GOOGLE_CSS_URL, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8")


def main() -> None:
    """下载选中子集的 woff2，改写 src 指向本地路径，重新生成 fonts.css。"""
    css = fetch_google_css()
    # Google 在每个 @font-face 前用注释标注子集名，这是判断 latin/greek 的唯一依据。
    blocks = re.findall(r"/\*\s*([\w\-\[\]]+)\s*\*/\s*@font-face\s*\{(.*?)\}", css, re.S)

    FONT_DIR.mkdir(parents=True, exist_ok=True)
    downloaded: dict[str, str] = {}  # 远端 URL -> 本地文件名
    rules: list[str] = []

    for subset, body in blocks:
        family = re.search(r"font-family:\s*'([^']+)'", body).group(1)
        if family not in KEEP_FAMILIES or subset not in KEEP_SUBSETS:
            continue

        style = re.search(r"font-style:\s*([^;]+)", body).group(1).strip()
        weight = re.search(r"font-weight:\s*([^;]+)", body).group(1).strip()
        urange = re.search(r"unicode-range:\s*([^;]+)", body).group(1).strip()
        url = re.search(r"url\((https://[^)]+)\)", body).group(1)

        # 可变字体的多个字重会共用同一个文件，按 URL 去重避免重复下载。
        if url not in downloaded:
            slug = family.lower().replace(" ", "-")
            variant = "italic" if style == "italic" else "roman"
            name = f"{slug}-{variant}-{subset}.woff2"
            urllib.request.urlretrieve(url, FONT_DIR / name)
            downloaded[url] = name

        rules.append(
            "@font-face {\n"
            f"  font-family: '{family}';\n"
            f"  font-style: {style};\n"
            f"  font-weight: {weight};\n"
            "  font-display: swap;\n"
            f"  src: url('fonts/{downloaded[url]}') format('woff2');\n"
            f"  unicode-range: {urange};\n"
            "}"
        )

    if not rules:
        raise SystemExit("没有匹配到任何 @font-face —— Google 的返回格式可能变了")

    CSS_PATH.write_text(HEADER + "\n" + "\n".join(rules) + "\n")
    print(f"下载 {len(downloaded)} 个 woff2 → {FONT_DIR.relative_to(ROOT)}")
    print(f"生成 {len(rules)} 条 @font-face → {CSS_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
