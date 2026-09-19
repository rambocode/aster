// 会话看板的排序与占用文案：纯逻辑，不依赖 AppKit，也不认识应用层的卡片模型。
import Foundation

/// 排序用的轻量输入。
///
/// 看板的卡片模型 `UsageSessionEntry` 住在应用层，这里只取排序需要的三项，
/// 免得为了一个纯函数把 UI 模型下沉到 Core。
public struct UsageSessionOrderInput: Equatable, Sendable {
  /// Pane 的 UUID，也是座位的身份。
  public var id: UUID
  public var status: AgentControlStatus
  /// 卡片标题；调用方在没有终端标题时传目录最后一段。同级排序靠它。
  public var title: String

  public init(id: UUID, status: AgentControlStatus, title: String) {
    self.id = id
    self.status = status
    self.title = title
  }
}

/// 会话看板的排序、座位冻结与占用文案。
public enum UsageSessionBoardOrder {
  /// 数值缺失时的占位符（CPU / 内存共用）。
  public static let unavailable = "—"

  private static let kib = 1024.0
  private static let mib = 1024.0 * 1024
  private static let gib = 1024.0 * 1024 * 1024

  // MARK: - 排序

  /// 状态优先级，越小越靠前：等待输入的会话最需要人，空闲与未知垫底。
  public static func priority(_ status: AgentControlStatus) -> Int {
    switch status {
    case .blocked: 0
    case .working: 1
    case .done: 2
    case .idle: 3
    case .unknown: 4
    }
  }

  /// 按「状态优先级 → 标题 → id」排序，返回 id 数组。
  ///
  /// 末位比 id 是为了稳定：同状态同标题的两张卡（例如两个同名目录）在相邻两次刷新里
  /// 必须落在同一顺序，否则列表会自己抖动。
  public static func sorted(_ inputs: [UsageSessionOrderInput]) -> [UUID] {
    inputs.sorted { lhs, rhs in
      let left = priority(lhs.status)
      let right = priority(rhs.status)
      if left != right { return left < right }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      return lhs.id.uuidString < rhs.id.uuidString
    }.map(\.id)
  }

  /// 计算这一帧的座位顺序。
  ///
  /// 座位冻结：页面打开期间已有卡片不因状态变化换位。看板上的状态随时在变，如果每次
  /// 都按优先级重排，用户正要点的卡会从手底下跑掉。因此只有页面重新 `activate()`
  /// （`reseat` 为真）时才整体重排；期间新会话一律追加到末尾，消失的会话移除。
  public static func seats(
    previous: [UUID], current: [UsageSessionOrderInput], reseat: Bool
  ) -> [UUID] {
    guard !reseat else { return sorted(current) }
    let alive = Set(current.map(\.id))
    var seats = previous.filter { alive.contains($0) }
    let seated = Set(seats)
    seats.append(contentsOf: sorted(current.filter { !seated.contains($0.id) }))
    return seats
  }

  // MARK: - 占用文案

  /// CPU 占用文案：`12%`；100 以上照实显示（`135%` = 占满 1.35 个核）；缺数据为 `—`。
  public static func cpuText(_ percent: Double?) -> String {
    guard let percent, percent.isFinite else { return unavailable }
    return "\(Int(max(percent, 0).rounded()))%"
  }

  /// 内存文案：`512 MB` / `1.4 GB`；缺数据为 `—`。
  ///
  /// 分档用 1024 进制，和开发者熟悉的 `top` / Activity Monitor 口径一致。MB 档取整、
  /// GB 档留一位小数：进程树的内存本来就在几十 MB 到几 GB 间跳，多给的位数只是噪声。
  public static func memoryText(_ bytes: UInt64?) -> String {
    guard let bytes else { return unavailable }
    let value = Double(bytes)
    if value >= gib { return "\(String(format: "%.1f", value / gib)) GB" }
    if value >= mib {
      let megabytes = (value / mib).rounded()
      // 1023.6 MB 四舍五入成 1024 MB，得进位成 GB，不能写出「1024 MB」。
      if megabytes >= 1024 { return "1.0 GB" }
      return "\(Int(megabytes)) MB"
    }
    return "\(Int((value / kib).rounded())) KB"
  }
}
