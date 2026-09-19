import Foundation

/// 标签标题配色的领域定义：内置调色板与「尽量不重复」的自动分配规则。
///
/// 颜色本身是 UI 概念，但「同一窗口里的标签不要撞色」是一条可测试的分配规则，
/// 因此放在 Core，由 AppKit 层只负责渲染。
public enum TabTitleColorPalette {
  /// 调色板条目：颜色本身与菜单里显示的名字。
  public struct Option: Equatable, Sendable {
    public let color: HexColor
    public let name: String

    public init(color: HexColor, name: String) {
      self.color = color
      self.name = name
    }
  }

  /// 内置调色板。取值在浅色与深色主题上都保持可读（中等明度、饱和度不过高），
  /// 顺序即菜单里的展示顺序；索引会写进工作区快照，**只能追加，不要重排**。
  public static let options: [Option] = [
    Option(color: HexColor(red: 0xE5, green: 0x53, blue: 0x4B), name: L("红")),
    Option(color: HexColor(red: 0xE0, green: 0x8C, blue: 0x3B), name: L("橙")),
    Option(color: HexColor(red: 0xC9, green: 0xA2, blue: 0x27), name: L("金")),
    Option(color: HexColor(red: 0x57, green: 0xA6, blue: 0x4A), name: L("绿")),
    Option(color: HexColor(red: 0x3F, green: 0xA6, blue: 0xA0), name: L("青")),
    Option(color: HexColor(red: 0x4A, green: 0x9E, blue: 0xEA), name: L("蓝")),
    Option(color: HexColor(red: 0x7C, green: 0x6B, blue: 0xE8), name: L("靛")),
    Option(color: HexColor(red: 0xB3, green: 0x6B, blue: 0xE0), name: L("紫")),
    Option(color: HexColor(red: 0xE3, green: 0x6A, blue: 0xA8), name: L("粉")),
    Option(color: HexColor(red: 0xC4, green: 0x70, blue: 0x3B), name: L("赭")),
    Option(color: HexColor(red: 0x5F, green: 0xB0, blue: 0x7A), name: L("薄荷")),
    // 这一格早先是灰蓝，但它和默认前景太像，用户看不出标签「上了色」；换成青柠。
    Option(color: HexColor(red: 0x8F, green: 0xB2, blue: 0x33), name: L("青柠")),
  ]

  /// 调色板里第 `index` 个颜色；越界（旧配置、手工改过的快照）返回 nil 而不是崩溃或回绕。
  public static func color(atIndex index: Int) -> HexColor? {
    options.indices.contains(index) ? options[index].color : nil
  }

  /// 为新标签挑一个自动颜色索引。
  ///
  /// 「不重复」的语义是：只要还有没被占用的颜色，就一定先用它；调色板被用光之后，
  /// 从当前占用次数最少的那一组里随机取一个，保证撞色均匀扩散而不是全挤在一个颜色上。
  /// - Parameters:
  ///   - used: 当前已占用的索引（同一窗口内的全部标签），越界值会被忽略。
  ///   - randomSource: 返回 `0..<上界` 的随机下标；测试注入确定值。
  public static func allocateIndex(
    used: [Int],
    randomSource: (Int) -> Int = { Int.random(in: 0..<$0) }
  ) -> Int {
    var counts = [Int](repeating: 0, count: options.count)
    for index in used where options.indices.contains(index) { counts[index] += 1 }
    let minimum = counts.min() ?? 0
    let candidates = options.indices.filter { counts[$0] == minimum }
    guard !candidates.isEmpty else { return 0 }
    let pick = randomSource(candidates.count)
    // 注入的随机源不可信（测试或未来调用方可能返回越界值），这里夹紧到候选范围内。
    return candidates[min(max(pick, 0), candidates.count - 1)]
  }

  /// 换一个颜色：在「不等于当前值」的前提下复用同一套分配规则，
  /// 避免用户点「换一个」却随机到原来那个颜色，看起来像没反应。
  public static func reallocateIndex(
    current: Int?,
    used: [Int],
    randomSource: (Int) -> Int = { Int.random(in: 0..<$0) }
  ) -> Int {
    guard let current, options.indices.contains(current) else {
      return allocateIndex(used: used, randomSource: randomSource)
    }
    // 把当前颜色的占用次数抬高，使它在「占用最少」的候选集里排在最后；
    // 只有调色板只剩它一个可选时才会原地不动。
    let inflated = used + [Int](repeating: current, count: options.count + used.count)
    return allocateIndex(used: inflated, randomSource: randomSource)
  }
}
