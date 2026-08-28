#!/usr/bin/env python3
"""把 herdr 的 Agent 屏幕检测清单（TOML）转换成 AsterCore 内置的 Swift 常量表。

Aster 的 Agent 状态检测引擎移植自 herdr（Rust）。herdr 用 TOML 描述每个 Agent 的
屏幕匹配规则；Swift 侧没有 TOML 解析器，且 Foundation 的 JSONDecoder 已经够用，
因此这里在构建前把 TOML 转成 JSON 字符串，内嵌到
`Sources/AsterCore/AgentDetection/AgentDetectionBundledManifests.swift`。

转换前先做一遍与 herdr `validate_manifest` 同等级别的粗校验（未知字段、空 rules、
region 名、上限常量、正则粗检），避免把坏清单带进仓库；Swift 侧 `validate()` 会再
做一次精确校验（含 NSRegularExpression 编译）。

JSON 键保持 snake_case 且按 key 排序，方便 diff；Swift 模型用 CodingKeys 映射。

用法（清单更新时才需要重跑，生成物要一起提交）：
    python3 scripts/convert-agent-manifests.py [--source /path/to/herdr/src/detect/manifests]
"""
import argparse
import json
import pathlib
import re
import sys
import tomllib

# 源码基线：herdr 仓库提交 7b675f4（src/detect/manifests/*.toml）。
HERDR_COMMIT = "7b675f4"
DEFAULT_SOURCE = pathlib.Path("/tmp/herdr-src/src/detect/manifests")

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources" / "AsterCore" / "AgentDetection" / "AgentDetectionBundledManifests.swift"

# 与 herdr manifest.rs 的上限常量保持一致。
MAX_RULES_PER_MANIFEST = 128
MAX_GATE_DEPTH = 8
MAX_TOTAL_GATES = 512
MAX_MATCHERS_PER_GATE = 32
MAX_TOTAL_MATCHERS = 1024
MAX_MATCHER_CHARS = 512

MANIFEST_KEYS = {"id", "version", "min_engine_version", "updated_at", "aliases", "rules"}
RULE_KEYS = {
    "id", "state", "priority", "region",
    "visible_idle", "visible_blocker", "visible_working", "skip_state_update",
    "all", "any", "not", "contains", "regex", "line_regex",
}
GATE_KEYS = {"all", "any", "not", "contains", "regex", "line_regex"}
STATES = {"idle", "working", "blocked", "unknown"}
PLAIN_REGIONS = {
    "whole_recent", "after_last_prompt_marker", "before_current_prompt_marker",
    "whole_recent_without_current_prompt_marker", "current_prompt_block_marker",
    "after_current_prompt_block_marker", "prompt_box_body", "above_prompt_box",
    "last_non_empty_above_prompt_box", "after_last_horizontal_rule",
    "osc_title", "osc_progress",
}
COUNTED_REGION = re.compile(r"^(bottom_lines|bottom_non_empty_lines|top_non_empty_lines)\((\d+)\)$")


class ManifestError(Exception):
    """清单不符合 herdr 约束时抛出，携带文件名与原因。"""


def check_keys(obj: dict, allowed: set, context: str) -> None:
    """拒绝未知字段：herdr 用 serde deny_unknown_fields，拼错的键会静默失效，必须硬失败。"""
    unknown = set(obj) - allowed
    if unknown:
        raise ManifestError(f"{context} has unknown keys: {sorted(unknown)}")


def check_region(spec: str) -> None:
    """region 名校验，等价于 herdr validate_region_name。"""
    trimmed = spec.strip()
    if trimmed in PLAIN_REGIONS:
        return
    match = COUNTED_REGION.match(trimmed)
    if not match:
        raise ManifestError(f"invalid region {spec!r}")
    # top_non_empty_lines 的计数必须是规范正整数（无前导零，≤ u16::MAX）。
    if match.group(1) == "top_non_empty_lines":
        count = match.group(2)
        if count.startswith("0") or int(count) > 0xFFFF:
            raise ManifestError(f"invalid top_non_empty_lines count {count!r}")


def check_regex_syntax(pattern: str, context: str) -> None:
    """正则粗检：Python re 与 ICU 语法不完全一致，这里只用它抓明显的括号/量词错误。

    herdr 的 `\\x{2800}` / `\\p{Alphabetic}` / `\\u{fe0e}` Python 不认识，先替换成
    占位字符再编译；精确的 ICU 编译由 Swift 测试兜底。
    """
    approx = re.sub(r"\\x\{[0-9A-Fa-f]+\}|\\u\{[0-9A-Fa-f]+\}|\\p\{\w+\}", "x", pattern)
    approx = approx.replace("\\A", "^").replace("\\z", "$")
    try:
        re.compile(approx)
    except re.error as err:
        raise ManifestError(f"{context} has invalid regex {pattern!r}: {err}") from err


class Complexity:
    """累计整份清单的 gate / matcher 数量，对应 herdr ManifestComplexity。"""

    def __init__(self) -> None:
        self.total_gates = 0
        self.total_matchers = 0


def matcher_limits(gate: dict, context: str, complexity: Complexity) -> None:
    """单个 gate 的 matcher 数量与长度上限，对应 validate_matcher_limits。"""
    matchers = gate.get("contains", []) + gate.get("regex", []) + gate.get("line_regex", [])
    if len(matchers) > MAX_MATCHERS_PER_GATE:
        raise ManifestError(f"{context} has {len(matchers)} matchers, max is {MAX_MATCHERS_PER_GATE}")
    complexity.total_matchers += len(matchers)
    if complexity.total_matchers > MAX_TOTAL_MATCHERS:
        raise ManifestError(f"manifest exceeds max matcher count {MAX_TOTAL_MATCHERS}")
    for value in matchers:
        if not isinstance(value, str):
            raise ManifestError(f"{context} matcher must be a string: {value!r}")
        if len(value) > MAX_MATCHER_CHARS:
            raise ManifestError(f"{context} matcher exceeds max length {MAX_MATCHER_CHARS}")


def has_positive_matcher(gate: dict) -> bool:
    """gate 是否含正向条件（contains/regex/line_regex/all/any 任一非空）。"""
    return any(gate.get(key) for key in ("contains", "regex", "line_regex", "all", "any"))


def has_any_matcher(gate: dict) -> bool:
    """gate 是否含任意条件（含 not）。"""
    return has_positive_matcher(gate) or bool(gate.get("not"))


def validate_gate(gate: dict, context: str, depth: int, complexity: Complexity) -> None:
    """正向 gate 校验：深度、数量、必须含正向 matcher、子 gate 递归。对应 validate_gate。"""
    if depth > MAX_GATE_DEPTH:
        raise ManifestError(f"{context} exceeds max gate depth {MAX_GATE_DEPTH}")
    check_keys(gate, GATE_KEYS, context)
    complexity.total_gates += 1
    if complexity.total_gates > MAX_TOTAL_GATES:
        raise ManifestError(f"manifest exceeds max gate count {MAX_TOTAL_GATES}")
    matcher_limits(gate, context, complexity)
    if not has_positive_matcher(gate):
        raise ManifestError(f"{context} must contain a positive matcher")
    for pattern in gate.get("regex", []) + gate.get("line_regex", []):
        check_regex_syntax(pattern, context)
    for nested in gate.get("all", []):
        validate_gate(nested, "all gate", depth + 1, complexity)
    for nested in gate.get("any", []):
        validate_gate(nested, "any gate", depth + 1, complexity)
    for nested in gate.get("not", []):
        if not has_any_matcher(nested):
            raise ManifestError(f"{context} contains an empty not gate")
        validate_not_gate(nested, depth + 1, complexity)


def validate_not_gate(gate: dict, depth: int, complexity: Complexity) -> None:
    """not gate 校验：允许只含 not，但不能为空。对应 validate_not_gate。"""
    if depth > MAX_GATE_DEPTH:
        raise ManifestError(f"not gate exceeds max gate depth {MAX_GATE_DEPTH}")
    check_keys(gate, GATE_KEYS, "not gate")
    complexity.total_gates += 1
    if complexity.total_gates > MAX_TOTAL_GATES:
        raise ManifestError(f"manifest exceeds max gate count {MAX_TOTAL_GATES}")
    matcher_limits(gate, "not gate", complexity)
    if not has_any_matcher(gate):
        raise ManifestError("not gate must contain a matcher")
    for pattern in gate.get("regex", []) + gate.get("line_regex", []):
        check_regex_syntax(pattern, "not gate")
    for nested in gate.get("all", []):
        validate_gate(nested, "not all gate", depth + 1, complexity)
    for nested in gate.get("any", []):
        validate_gate(nested, "not any gate", depth + 1, complexity)
    for nested in gate.get("not", []):
        validate_not_gate(nested, depth + 1, complexity)


def validate_manifest(manifest: dict) -> None:
    """整份清单校验，对应 herdr validate_manifest。"""
    check_keys(manifest, MANIFEST_KEYS, "manifest")
    if not isinstance(manifest.get("id"), str) or not manifest["id"]:
        raise ManifestError("manifest id must be a non-empty string")
    rules = manifest.get("rules", [])
    if not rules:
        raise ManifestError("manifest must contain at least one rule")
    if len(rules) > MAX_RULES_PER_MANIFEST:
        raise ManifestError(f"manifest contains {len(rules)} rules, max is {MAX_RULES_PER_MANIFEST}")
    complexity = Complexity()
    for rule in rules:
        check_keys(rule, RULE_KEYS, f"rule {rule.get('id')!r}")
        rule_id = rule.get("id", "")
        if not isinstance(rule_id, str) or not rule_id.strip():
            raise ManifestError("manifest rule id must not be empty")
        state = rule.get("state")
        if state is not None and state not in STATES:
            raise ManifestError(f"rule {rule_id} has invalid state {state!r}")
        # skip_state_update 规则必须是 unknown 且不带任何 visible 证据，保持“中性”。
        if rule.get("skip_state_update"):
            if state != "unknown":
                raise ManifestError(f'rule {rule_id} uses skip_state_update without state = "unknown"')
            if rule.get("visible_idle") or rule.get("visible_blocker") or rule.get("visible_working"):
                raise ManifestError(f"rule {rule_id} uses skip_state_update with visible state evidence")
        region = rule.get("region", "whole_recent")
        try:
            check_region(region)
        except ManifestError as err:
            raise ManifestError(f"rule {rule_id} uses invalid region: {err}") from err
        if region.strip().startswith("top_non_empty_lines(") and manifest.get("min_engine_version", 3) < 3:
            raise ManifestError(f"rule {rule_id} uses top_non_empty_lines but min_engine_version is below 3")
        gate = {key: rule[key] for key in GATE_KEYS if key in rule}
        try:
            validate_gate(gate, "rule", 0, complexity)
        except ManifestError as err:
            raise ManifestError(f"rule {rule_id} has invalid matcher gates: {err}") from err


def swift_raw_string(text: str) -> str:
    """把任意文本包成 Swift 原始字符串字面量，自动选择足够多的 # 防止提前闭合。"""
    hashes = "#"
    while f'"{hashes}' in text or f"{hashes}\"" in text:
        hashes += "#"
    return f'{hashes}"{text}"{hashes}'


def main() -> int:
    """读取全部 TOML → 校验 → 写出 Swift 文件。"""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=pathlib.Path, default=DEFAULT_SOURCE, help="herdr manifests 目录")
    args = parser.parse_args()

    files = sorted(args.source.glob("*.toml"))
    if not files:
        print(f"no .toml manifests under {args.source}", file=sys.stderr)
        return 1

    entries = []  # (id, version, source file, json)
    for path in files:
        try:
            manifest = tomllib.loads(path.read_text(encoding="utf-8"))
            validate_manifest(manifest)
        except (tomllib.TOMLDecodeError, ManifestError) as err:
            print(f"{path.name}: {err}", file=sys.stderr)
            return 1
        # ensure_ascii=False 保留盲文/符号原样，可读且与 TOML 一致；Swift 原始字符串不转义。
        payload = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        entries.append((manifest["id"], manifest.get("version", "-"), path.name, payload))

    ids = [entry[0] for entry in entries]
    if len(ids) != len(set(ids)):
        print(f"duplicate manifest ids: {ids}", file=sys.stderr)
        return 1
    entries.sort(key=lambda entry: entry[0])

    lines = [
        "// GENERATED FILE — DO NOT EDIT BY HAND.",
        "// 由 scripts/convert-agent-manifests.py 从 herdr src/detect/manifests/*.toml 生成。",
        f"// 上游基线：herdr commit {HERDR_COMMIT}。",
        "//",
        "// 各清单版本：",
    ]
    for manifest_id, version, name, _ in entries:
        lines.append(f"//   {manifest_id:<10} {version:<14} ({name})")
    lines += [
        "",
        "/// 内置 Agent 屏幕检测清单：清单 id → JSON 字符串（snake_case 键，与 herdr TOML 同构）。",
        "public enum AgentDetectionBundledManifests {",
        "  /// 全部内置清单，按 id 索引。",
        "  public static let all: [String: String] = [",
    ]
    for manifest_id, _, _, payload in entries:
        lines.append(f"    {json.dumps(manifest_id)}: {swift_raw_string(payload)},")
    lines += ["  ]", "}", ""]

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {len(entries)} manifests to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
