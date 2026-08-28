import Foundation

/// 逻辑键名 → 终端字节。`agent.send_keys` / `pane.send_keys` 与旧 `pane send-keys` 共用。
/// 键名不区分大小写；tmux 风格 `C-x` / `ctrl-x` / `control-x` 映射为对应控制字节；
/// `M-x` / `alt-x` 映射为 ESC 前缀。方向键与功能键固定用 xterm 普通模式序列
/// （不跟随应用光标键模式，与旧 AppModel 表保持一致）。
public enum AsterControlKeyEncoder {
  public enum EncodeError: Error, Equatable, Sendable {
    case unknownKey(String)
  }

  /// 固定键名表。
  private static let namedKeys: [String: [UInt8]] = [
    "enter": [13], "return": [13], "cr": [13],
    "tab": [9],
    "escape": [27], "esc": [27],
    "backspace": [127], "bspace": [127],
    "space": [32],
    "delete": Array("\u{1B}[3~".utf8), "del": Array("\u{1B}[3~".utf8), "dc": Array("\u{1B}[3~".utf8),
    "insert": Array("\u{1B}[2~".utf8), "ic": Array("\u{1B}[2~".utf8),
    "up": Array("\u{1B}[A".utf8),
    "down": Array("\u{1B}[B".utf8),
    "right": Array("\u{1B}[C".utf8),
    "left": Array("\u{1B}[D".utf8),
    "home": Array("\u{1B}[H".utf8),
    "end": Array("\u{1B}[F".utf8),
    "pageup": Array("\u{1B}[5~".utf8), "pgup": Array("\u{1B}[5~".utf8), "ppage": Array("\u{1B}[5~".utf8),
    "pagedown": Array("\u{1B}[6~".utf8), "pgdn": Array("\u{1B}[6~".utf8), "npage": Array("\u{1B}[6~".utf8),
    "f1": Array("\u{1B}OP".utf8), "f2": Array("\u{1B}OQ".utf8),
    "f3": Array("\u{1B}OR".utf8), "f4": Array("\u{1B}OS".utf8),
    "f5": Array("\u{1B}[15~".utf8), "f6": Array("\u{1B}[17~".utf8),
    "f7": Array("\u{1B}[18~".utf8), "f8": Array("\u{1B}[19~".utf8),
    "f9": Array("\u{1B}[20~".utf8), "f10": Array("\u{1B}[21~".utf8),
    "f11": Array("\u{1B}[23~".utf8), "f12": Array("\u{1B}[24~".utf8),
    // 常用组合的显式别名，保证 `ctrl-c` 这类旧写法零改动。
    "ctrl-c": [3], "control-c": [3], "c-c": [3],
    "ctrl-d": [4], "control-d": [4], "c-d": [4],
  ]

  /// 键名是否可编码（用于 params.validate 提前拒绝）。
  public static func isKnown(_ name: String) -> Bool {
    (try? encode(name)) != nil
  }

  /// 单个键名 → 字节。
  public static func encode(_ name: String) throws -> [UInt8] {
    // herdr 风格 `ctrl+c` / `alt+x`：把连接符 `+` 归一为 `-`；末尾的 `+` 是键本身（如 `C-+`），不动。
    var key = name.lowercased()
    if key.count > 1, key.hasSuffix("+") == false, key.contains("+") {
      key = key.replacingOccurrences(of: "+", with: "-")
    }
    if let bytes = namedKeys[key] { return bytes }
    // 控制组合：C-x / ctrl-x / control-x，x 为字母、`[` `\` `]` `^` `_` `@`。
    if let letter = controlLetter(key, prefixes: ["c-", "ctrl-", "control-"]) {
      return [letter & 0x1F]
    }
    // Alt/Meta 组合：M-x / alt-x / meta-x → ESC + x（xterm 默认 metaSendsEscape）。
    if let letter = controlLetter(key, prefixes: ["m-", "alt-", "meta-"], allowAny: true) {
      return [27, letter]
    }
    throw EncodeError.unknownKey(name)
  }

  /// 多个键名 → 拼接字节，任一未知即整体失败，避免半截按键写进 PTY。
  public static func encode(_ names: [String]) throws -> [UInt8] {
    try names.flatMap(encode)
  }

  /// 剥前缀取单字符；控制组合限定为能产生合法控制字节的 ASCII 字符。
  private static func controlLetter(
    _ key: String, prefixes: [String], allowAny: Bool = false
  ) -> UInt8? {
    for prefix in prefixes where key.hasPrefix(prefix) {
      let rest = key.dropFirst(prefix.count)
      guard rest.count == 1, let scalar = rest.unicodeScalars.first, scalar.isASCII else {
        return nil
      }
      let byte = UInt8(scalar.value)
      if allowAny { return byte }
      // 0x40...0x5F 与 a-z 才有对应控制字节（@ A-Z [ \ ] ^ _）。
      let normalized = (byte >= 0x61 && byte <= 0x7A) ? byte - 0x20 : byte
      guard normalized >= 0x40, normalized <= 0x5F else { return nil }
      return normalized
    }
    return nil
  }
}
