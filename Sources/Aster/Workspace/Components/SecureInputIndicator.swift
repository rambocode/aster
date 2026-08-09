import AppKit

/// 工作区标题栏中的安全输入状态胶囊。它只在 Carbon Secure Event Input 已真实启用时
/// 出现；视图本身不切换安全状态，避免一个展示控件成为第二个状态所有者。
@MainActor
final class SecureInputIndicatorView: NSView {
  static let secureBackgroundColor = NSColor.systemBlue

  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "SECURE INPUT")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous

    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    icon.image = NSImage(
      systemSymbolName: "lock.shield.fill",
      accessibilityDescription: "安全键盘输入已开启"
    )?.withSymbolConfiguration(symbolConfiguration)
    icon.imageScaling = .scaleProportionallyDown

    label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    label.lineBreakMode = .byClipping
    label.maximumNumberOfLines = 1

    addSubview(icon)
    addSubview(label)
    icon.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 22),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 11),
      icon.heightAnchor.constraint(equalToConstant: 11),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("安全键盘输入已开启")
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  private func applyAppearance() {
    // 状态胶囊必须始终保持系统蓝色，不能跟随主题 accent 变成黑色或其它装饰色；蓝色
    // 是用户判断 Secure Event Input 已真实生效的稳定视觉信号。
    layer?.backgroundColor = Self.secureBackgroundColor.cgColor
    let foreground = NSColor.selectedMenuItemTextColor
    icon.contentTintColor = foreground
    label.textColor = foreground
  }
}
