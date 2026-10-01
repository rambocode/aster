#!/usr/bin/env python3
# 列出官网首页里需要翻译的中文文本节点与属性值，并核对 i18n.js 词典的覆盖率。
#   python3 scripts/site-i18n-keys.py            # 打印缺失的键（按语言）
#   python3 scripts/site-i18n-keys.py --list     # 只列出全部中文键
# 规则与 site/assets/i18n.js 一致：文本节点 trim 后整体作为键；
# RICH 列表里的元素（含内联标记的标题）按选择器整体替换，不进文本键；
# aria-label / alt / title 属性值作为属性键。
import re, sys, json, pathlib
from html.parser import HTMLParser

ROOT = pathlib.Path(__file__).resolve().parent.parent
HTML = ROOT / "site" / "index.html"
JS = ROOT / "site" / "assets" / "i18n.js"
RICH_IDS = {"hero-title", "workspace-title", "voices-title", "closing-title"}
CJK = re.compile("[\u4e00-\u9fff]")  # 只认汉字，全角符号（＋）不算

class Walker(HTMLParser):
    """收集文本键与属性键；跳过 script/style/noscript 与 RICH 元素子树。"""
    def __init__(self):
        super().__init__()
        self.skip = 0; self.rich = 0; self.stack = []
        self.text = []; self.attrs = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("script", "style", "noscript", "head"): self.skip += 1
        if a.get("id") in RICH_IDS: self.rich += 1
        self.stack.append((tag, a.get("id") in RICH_IDS, tag in ("script", "style", "noscript", "head")))
        for k in ("aria-label", "alt", "title", "placeholder"):
            v = a.get(k)
            if v and CJK.search(v): self.attrs.append(v)
    def handle_endtag(self, tag):
        while self.stack:
            t, rich, skip = self.stack.pop()
            if rich: self.rich -= 1
            if skip: self.skip -= 1
            if t == tag: break
    def handle_data(self, data):
        if self.skip or self.rich: return
        t = data.strip()
        if t and CJK.search(t): self.text.append(t)

w = Walker(); w.feed(HTML.read_text(encoding="utf-8"))
text_keys = list(dict.fromkeys(w.text)); attr_keys = list(dict.fromkeys(w.attrs))
if "--list" in sys.argv:
    print("## 文本键"); print("\n".join(text_keys))
    print("\n## 属性键"); print("\n".join(attr_keys))
    sys.exit(0)

# 从 i18n.js 粗略提取每种语言词典里的键（"中文": 形式）
js = JS.read_text(encoding="utf-8")
missing = {}
for lang in ("en", "ja", "de", "fr"):
    m = re.search(r"\n    %s: \{(.*?)\n    \},?\n" % lang, js, re.S)
    block = m.group(1) if m else ""
    keys = set(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:', block, re.M))
    keys |= set(re.findall(r"^\s*'((?:[^'\\]|\\.)*)'\s*:", block, re.M))
    miss = [k for k in text_keys + attr_keys if k not in keys]
    missing[lang] = miss
total = sum(len(v) for v in missing.values())
for lang, miss in missing.items():
    print(f"{lang}: 缺 {len(miss)} 条")
    for k in miss: print("   ", k)
print(f"文本键 {len(text_keys)} 条，属性键 {len(attr_keys)} 条，缺失合计 {total}")
sys.exit(1 if total else 0)
