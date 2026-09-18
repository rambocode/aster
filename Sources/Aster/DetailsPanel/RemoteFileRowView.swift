// 远端 Files 页的表格行视图，以及远端两页共用的数值格式化。

import AppKit
import AsterCore
import Foundation

/// 远端面板的数值格式化。字节、时间与百分比在 Files 与 Info 两页都要用同一套写法。
///
/// 标为 `@MainActor`：内部缓存的 `Formatter` 不是 `Sendable`，而调用点全部在界面线程，
/// 与其为每行新建一个 formatter，不如把类型本身绑到主线程。
@MainActor
enum RemoteInspectionFormat {
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter
  }()

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
  }()

  /// 字节数。
  static func bytes(_ value: Int64) -> String {
    byteFormatter.string(fromByteCount: max(0, value))
  }

  /// KiB 计数（监控脚本的内存、磁盘单位）。
  static func kibibytes(_ value: UInt64) -> String {
    bytes(Int64(clamping: value &* 1_024))
  }

  /// 修改时间。远端与本地时区不一定相同，这里按本机时区展示，只精确到分钟。
  static func timestamp(_ date: Date) -> String {
    timestampFormatter.string(from: date)
  }

  /// 运行时长，按「天 小时 分钟」取最粗的两级。
  static func duration(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    let days = String(total / 86_400)
    let hours = String((total % 86_400) / 3_600)
    let minutes = String((total % 3_600) / 60)
    if total >= 86_400 { return L("\(days) 天 \(hours) 小时") }
    if total >= 3_600 { return L("\(hours) 小时 \(minutes) 分钟") }
    return L("\(minutes) 分钟")
  }

  /// 百分比；无法计算（首个 CPU 采样）时显示破折号而不是 0。
  static func percent(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.1f%%", max(0, min(100, value)))
  }
}

/// 远端 Files 页的可复用行：图标 + 名称 + 右侧「大小 · 修改时间」。
///
/// 与本地 Files 行的区别只有两点：没有展开箭头（远端一次只列一层目录），
/// 以及名字有损解码的条目要显式标成不可用——那种名字回传远端已经不是原文件。
@MainActor
final class RemoteFileRowView: HoverHighlightRowView {
  private let iconView = NSImageView()
  private let nameButton = PointingHandButton()
  private let metadataLabel = NSTextField(labelWithString: "")
  private var onOpen: (() -> Void)?
  /// 当前条目的两种元数据文案；窄栏只留大小，宽栏加上修改时间。
  private var compactMetadata = ""
  private var regularMetadata = ""
  private var appliedMode: RemoteInspectorLayout.Mode?

  /// 图标色与本地 Files 页保持一致，避免两种模式看起来像两个功能。
  private static let iconTint = NSColor(
    srgbRed: 0x5F / 255, green: 0xAB / 255, blue: 0xF3 / 255, alpha: 1)

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    hoverHorizontalInset = 0

    iconView.imageScaling = .scaleProportionallyDown
    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    nameButton.isBordered = false
    nameButton.alignment = .left
    nameButton.imagePosition = .noImage
    nameButton.lineBreakMode = .byTruncatingTail
    nameButton.activatesOnDoubleClickOnly = true
    nameButton.target = self
    nameButton.action = #selector(openItem)
    nameButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(nameButton)

    metadataLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    metadataLabel.textColor = AsterTheme.tertiaryInk
    metadataLabel.lineBreakMode = .byTruncatingTail
    metadataLabel.alignment = .right
    metadataLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    metadataLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(metadataLabel)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 13),
      iconView.heightAnchor.constraint(equalToConstant: 13),
      nameButton.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
      nameButton.topAnchor.constraint(equalTo: topAnchor),
      nameButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      nameButton.trailingAnchor.constraint(
        lessThanOrEqualTo: metadataLabel.leadingAnchor, constant: -6),
      metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      metadataLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 渲染一条远端目录项。`onOpen` 只在条目可进入时被调用。
  func configure(entry: RemoteDirectoryEntry, onOpen: @escaping () -> Void) {
    let symbol: String
    switch entry.kind {
    case .directory: symbol = "folder"
    case .symlink: symbol = "arrow.up.forward.square"
    case .file, .other: symbol = "doc"
    }
    iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    iconView.contentTintColor = Self.iconTint

    let nameColor = entry.nameDecodedLossy ? AsterTheme.tertiaryInk : AsterTheme.ink
    nameButton.attributedTitle = NSAttributedString(
      string: entry.name,
      attributes: [
        .foregroundColor: nameColor,
        .font: NSFont.systemFont(ofSize: 12),
      ])
    nameButton.isEnabled = entry.isNavigable
    nameButton.toolTip = entry.nameDecodedLossy
      ? L("文件名不是合法 UTF-8，无法进入或下载") : entry.name

    let size = entry.kind == .directory ? "" : RemoteInspectionFormat.bytes(entry.size)
    let time = RemoteInspectionFormat.timestamp(entry.modifiedAt)
    compactMetadata = size
    regularMetadata = size.isEmpty ? time : "\(size) · \(time)"
    appliedMode = nil
    applyMetadataForCurrentWidth()

    self.onOpen = onOpen
  }

  /// 行宽变化时切换元数据详略。修改时间比文件名次要得多，窄栏让它先让位，
  /// 免得名称被压到只剩两三个字。
  override func layout() {
    super.layout()
    applyMetadataForCurrentWidth()
  }

  private func applyMetadataForCurrentWidth() {
    let mode = RemoteInspectorLayout.mode(forWidth: Double(bounds.width))
    guard appliedMode != mode else { return }
    appliedMode = mode
    metadataLabel.stringValue = mode == .compact ? compactMetadata : regularMetadata
  }

  @objc private func openItem() { onOpen?() }
}
