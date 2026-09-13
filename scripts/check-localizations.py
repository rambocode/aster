#!/usr/bin/env python3
"""界面文案本地化工具。

check: 扫描 Sources/**/*.swift 里的 `L("…")` 调用，推导 .strings 的 key，
       核对每个 <lang>.lproj/Localizable.strings 是否都有翻译；缺失即失败。
merge: 把 l10n-work/*.json（key → {lang: value}）合并写入各语言的 .strings（按 key 排序）。

key 规则：Swift 字面量原文，`\\(…)` 插值处写 `%@`；带插值的文案里字面 `%` 写作 `%%`，
无插值的文案 `%` 保持单个（Foundation 只对带插值的字面量做格式化）；
Swift 转义（\\n、\\"、\\\\）按原样保留，.strings 语法与之兼容。
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LPROJ_DIR = os.path.join(ROOT, "Sources/Aster/Localization")
LANGS = ["en", "ja", "fr", "de", "zh-Hant"]
SOURCE_DIRS = ["Sources/Aster", "Sources/AsterCore", "Sources/AsterMemory"]


def extract_keys(text, path):
    """从 Swift 源码里找出所有 `L("…")` 的 key；无法静态推导的（动态 key、多行字面量）报错。"""
    keys, problems = [], []
    # 注释行里的示例（如文档注释写的 `L("…")`）不是真实调用，先剔除。
    text = "\n".join("" if ln.lstrip().startswith("//") else ln for ln in text.split("\n"))
    i, n = 0, len(text)
    while True:
        m = re.compile(r'(?<![A-Za-z0-9_.])L\(\s*').search(text, i)
        if not m:
            break
        i = m.end()
        if text.startswith('"""', i):
            problems.append(f"{path}: L() 不支持多行字面量（offset {i}）")
            continue
        if text[i] != '"':
            # L(String.LocalizationValue(x)) 之类的动态 key：交由人工保证表里有对应项。
            continue
        j = i + 1
        out = []
        while j < n:
            c = text[j]
            if c == "\\":
                nxt = text[j + 1]
                if nxt == "(":
                    depth, k = 1, j + 2
                    while k < n and depth:
                        if text[k] == "(":
                            depth += 1
                        elif text[k] == ")":
                            depth -= 1
                        elif text[k] == '"':
                            k += 1
                            while k < n and text[k] != '"':
                                k += 2 if text[k] == "\\" else 1
                        k += 1
                    out.append("%@")
                    j = k
                    continue
                out.append(c + nxt)
                j += 2
                continue
            if c == '"':
                break
            if c == "%":
                out.append("%%")
            else:
                out.append(c)
            j += 1
        key = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), "".join(out))
        # Foundation 只在字面量带插值时把它当格式串（字面 % 需写成 %%）；
        # 无插值的文案按原文逐字查表，% 保持单个。
        if "%@" not in key:
            key = key.replace("%%", "%")
        keys.append(key)
        i = j + 1
    return keys, problems


def parse_strings(path):
    """读取 .strings：返回 key → value（保留转义原文）。"""
    table = {}
    if not os.path.exists(path):
        return table
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M):
        table[m.group(1)] = m.group(2)
    return table


def normalize_text(text):
    """把子代理 JSON 里的 key/value 统一成 .strings 写法：
    Swift 的 `\\u{XXXX}` 换成真实字符（Foundation 生成的 key 是真实字符）；
    引号一律重新转义，避免原文里裸露的 `"` 破坏整个 .strings 文件。"""
    text = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), text)
    text = text.replace('\\"', '"').replace('"', '\\"')
    return text


def strings_path(lang):
    return os.path.join(LPROJ_DIR, f"{lang}.lproj", "Localizable.strings")


def all_source_keys():
    keys, problems = {}, []
    for d in SOURCE_DIRS:
        for path in glob.glob(os.path.join(ROOT, d, "**/*.swift"), recursive=True):
            ks, ps = extract_keys(open(path, encoding="utf-8").read(), os.path.relpath(path, ROOT))
            problems += ps
            for k in ks:
                keys.setdefault(k, os.path.relpath(path, ROOT))
    return keys, problems


def cmd_check(args):
    keys, problems = all_source_keys()
    extra = set()
    for f in args:  # 额外的 key 清单（如动态 key）
        extra |= set(json.load(open(f)))
    failed = bool(problems)
    for p in problems:
        print("ERROR", p)
    for lang in LANGS:
        table = parse_strings(strings_path(lang))
        missing = [k for k in keys if k not in table]
        unused = [k for k in table if k not in keys and k not in extra]
        print(f"[{lang}] keys={len(table)} missing={len(missing)} unused={len(unused)}")
        for k in missing:
            print(f"  MISSING ({keys[k]}): {k}")
            failed = True
        for k in unused[: 20 if "-v" not in sys.argv else None]:
            print(f"  unused: {k}")
    print(f"source keys: {len(keys)}")
    sys.exit(1 if failed else 0)


def cmd_merge(args):
    tables = {lang: parse_strings(strings_path(lang)) for lang in LANGS}
    files = args or sorted(glob.glob(os.path.join(ROOT, "l10n-work", "*.json")))
    for f in files:
        data = json.load(open(f, encoding="utf-8"))
        if not isinstance(data, dict):
            continue  # 只认 key → {lang: value} 的映射；其它中间文件跳过
        for key, translations in data.items():
            # 与 extract_keys 同一规则：无插值的 key/value 里 %% 归一成 %。
            key = normalize_text(key)
            if "%@" not in key:
                key = key.replace("%%", "%")
            for lang in LANGS:
                value = translations.get(lang)
                if value:
                    value = normalize_text(value)
                    tables[lang][key] = value.replace("%%", "%") if "%@" not in key else value
    for lang in LANGS:
        os.makedirs(os.path.dirname(strings_path(lang)), exist_ok=True)
        with open(strings_path(lang), "w", encoding="utf-8") as out:
            out.write(f"/* Aster 界面文案（{lang}）。key 为简体中文原文，插值处写 %@，字面 % 写作 %%。 */\n")
            for key in sorted(tables[lang]):
                out.write(f'"{key}" = "{tables[lang][key]}";\n')
        print(f"[{lang}] wrote {len(tables[lang])} entries")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    rest = [a for a in sys.argv[2:] if a != "-v"]
    {"check": cmd_check, "merge": cmd_merge}[cmd](rest)
