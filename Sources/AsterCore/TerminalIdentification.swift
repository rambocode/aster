import Foundation

/// 用户配置的 TERM 经过校验后的启动结果。`warning` 只描述安全回退原因，绝不包含
/// 子进程输出或环境变量值，调用方可以直接记录而不会泄露敏感数据。
public struct TerminalIdentityResolution: Equatable, Sendable {
  public let term: String
  public let warning: String?

  public init(term: String, warning: String? = nil) {
    self.term = term
    self.warning = warning
  }
}

/// 将面向用户的语义版本转换成传统 DA2 使用的单个整数。
///
/// 编码规则为 `major * 10000 + minor * 100 + patch`。预发布后缀不参与编码；缺失的
/// minor/patch 按 0 处理，无法解析时返回 0，让终端仍能完成保守的身份握手。
public struct TerminalProductVersion: Equatable, Sendable {
  public let rawValue: String
  public let deviceAttributesValue: Int

  public init(_ rawValue: String) {
    self.rawValue = rawValue
    let stablePart = rawValue.split(separator: "-", maxSplits: 1).first.map(String.init) ?? rawValue
    let components = stablePart.split(separator: ".", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.count <= 3,
      let major = Int(components[0]), major >= 0
    else {
      deviceAttributesValue = 0
      return
    }
    let minor = components.count > 1 ? Int(components[1]) : 0
    let patch = components.count > 2 ? Int(components[2]) : 0
    guard let minor, let patch, (0...99).contains(minor), (0...99).contains(patch) else {
      deviceAttributesValue = 0
      return
    }
    let (majorValue, majorOverflow) = major.multipliedReportingOverflow(by: 10_000)
    let (minorValue, minorOverflow) = minor.multipliedReportingOverflow(by: 100)
    let (majorAndMinor, firstAdditionOverflow) = majorValue.addingReportingOverflow(minorValue)
    let (encoded, secondAdditionOverflow) = majorAndMinor.addingReportingOverflow(patch)
    guard !majorOverflow, !minorOverflow, !firstAdditionOverflow, !secondAdditionOverflow else {
      deviceAttributesValue = 0
      return
    }
    deviceAttributesValue = encoded
  }
}

/// 注入到每个 Pane 子进程环境的控制协议上下文，让 pane 内运行的 agent/CLI 知道自己是谁、
/// socket 在哪。字段全部是短 ID（`w1` / `w1:t2` / `w1:p5`），不含 UUID。
public struct TerminalControlContext: Equatable, Sendable {
  public static let environmentFlagKey = "ASTER_ENV"
  public static let socketPathKey = "ASTER_SOCKET_PATH"
  public static let binaryPathKey = "ASTER_BIN_PATH"
  public static let windowIDKey = "ASTER_WINDOW_ID"
  public static let tabIDKey = "ASTER_TAB_ID"
  public static let paneIDKey = "ASTER_PANE_ID"

  public let windowID: String
  public let tabID: String
  public let paneID: String
  public let socketPath: String
  /// `aster-cli` 二进制路径；开发构建（swift run）可能没有，此时不注入 ASTER_BIN_PATH。
  public let binaryPath: String?

  public init(windowID: String, tabID: String, paneID: String, socketPath: String, binaryPath: String?) {
    self.windowID = windowID
    self.tabID = tabID
    self.paneID = paneID
    self.socketPath = socketPath
    self.binaryPath = binaryPath
  }

  /// 写入环境字典。`ASTER_PANE_ID` 从 0.4.x 的 UUID 升级为短 ID；`ASTER_SESSION_ID` 保留 UUID
  /// 供旧脚本使用，两者由服务端 selector 解析同时兼容。
  public func apply(to environment: inout [String: String]) {
    environment[Self.environmentFlagKey] = "1"
    environment[Self.socketPathKey] = socketPath
    environment[Self.windowIDKey] = windowID
    environment[Self.tabIDKey] = tabID
    environment[Self.paneIDKey] = paneID
    if let binaryPath { environment[Self.binaryPathKey] = binaryPath }
  }
}

/// Aster 的 TERM 与进程身份策略。这里保持纯函数边界：系统 terminfo 探测由交付层注入，
/// 因而配置迁移、回退和环境拼接无需启动外部进程即可完整测试。
public enum TerminalIdentityPolicy {
  public static let automaticName = "auto"
  /// 产品终端由 GhosttyKit 承载，`xterm-ghostty` 是与引擎能力一致的首选身份；
  /// 打包时 build-app.sh 会把该条目编译进 App 内置 terminfo 目录。
  public static let preferredTerm = "xterm-ghostty"
  public static let fallbackTerm = "xterm-256color"

  /// terminfo 名称只能由数据库名称常用的安全字符组成。路径分隔符和空白均被拒绝，
  /// 首字符还必须是字母或数字，避免 `infocmp` 把名称解释成命令选项。
  public static func isSyntacticallyValid(_ name: String) -> Bool {
    guard let first = name.utf8.first, name.utf8.count <= 64,
      isASCIIAlphanumeric(first)
    else { return false }
    return name.utf8.dropFirst().allSatisfy { byte in
      isASCIIAlphanumeric(byte)
        || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "+")
    }
  }

  private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
      || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
  }

  /// 解析用户配置。`auto` 优先使用与 Ghostty 引擎能力一致的 `xterm-ghostty`，条目
  /// 不可用时静默回退到跨 Unix 环境都可用的 `xterm-256color`；自定义值必须通过
  /// 语法检查并由调用方确认存在对应 terminfo 条目。
  public static func resolve(
    configuredName: String,
    entryExists: (String) -> Bool
  ) -> TerminalIdentityResolution {
    if configuredName == automaticName || configuredName.isEmpty {
      // 开发构建（swift run）或异常裁剪的安装可能没有内置条目；auto 的回退是预期
      // 行为而非配置错误，因此不产生 warning。
      let term = entryExists(preferredTerm) ? preferredTerm : fallbackTerm
      return TerminalIdentityResolution(term: term)
    }
    guard isSyntacticallyValid(configuredName) else {
      return TerminalIdentityResolution(
        term: fallbackTerm,
        warning: "TERM 名称非法，已回退到 \(fallbackTerm)。"
      )
    }
    guard entryExists(configuredName) else {
      return TerminalIdentityResolution(
        term: fallbackTerm,
        warning: "找不到 TERM=\(configuredName) 的 terminfo 条目，已回退到 \(fallbackTerm)。"
      )
    }
    return TerminalIdentityResolution(term: configuredName)
  }

  /// 生成每个 Pane 的完整子进程环境。保留继承环境，仅覆盖终端能力与品牌标识；应用
  /// 内置 terminfo 目录按传入顺序排在最前，系统目录始终保留为最后的兼容回退。
  public static func environment(
    inherited: [String: String],
    term: String,
    version: String,
    paneIdentifier: String,
    bundledTerminfoDirectories: [String],
    controlContext: TerminalControlContext? = nil
  ) -> [String: String] {
    var result = inherited
    result["TERM"] = term
    result["COLORTERM"] = "truecolor"
    result["TERM_PROGRAM"] = "aster"
    result["TERM_PROGRAM_VERSION"] = version
    result["CW_TERM"] = "aster"
    result["ASTER_PANE_ID"] = paneIdentifier
    // 0.4.x 已公开 ASTER_SESSION_ID；保留别名避免现有脚本升级后失效。
    result["ASTER_SESSION_ID"] = paneIdentifier
    // 控制协议上下文最后写入：它会用短 ID 覆盖 ASTER_PANE_ID。第二实例（socket 被占）
    // 不提供 context，则不注入 ASTER_ENV，CLI 会拒绝 agent.* 调用。
    controlContext?.apply(to: &result)

    var terminfoDirectories: [String] = bundledTerminfoDirectories.filter { !$0.isEmpty }
    if let inheritedDirectories = inherited["TERMINFO_DIRS"] {
      terminfoDirectories.append(contentsOf: inheritedDirectories.split(separator: ":").map(String.init))
    }
    terminfoDirectories.append("/usr/share/terminfo")
    var seen: Set<String> = []
    result["TERMINFO_DIRS"] = terminfoDirectories.filter {
      !$0.isEmpty && seen.insert($0).inserted
    }.joined(separator: ":")
    return result
  }
}
