import AppKit
import AsterCore

/// 主题色板专用的轻量取色器。
///
/// 不用 `NSColorPanel`：系统面板是一个带色轮、调色板、图像取样、收藏夹的全功能窗口，
/// 对「把某个 token 从灰改成另一种灰」这件事过重，而且它是全局单例——多个入口共用
/// 同一个面板，回调里不带上下文，还会浮在设置窗口之外。这里只提供改一个颜色真正需要
/// 的三件东西：饱和度/明度色域、色相条、以及可直接粘贴的 hex 输入。
@MainActor
final class InlineColorPickerViewController: NSViewController {
  private let onChange: (NSColor) -> Void
  private let titleText: String
  /// HSB 是取色器的内部真值：从 NSColor 反推 hue 在灰阶（饱和度为 0）时不稳定，
  /// 每次拖动都重新反推会让色相条自己跳回红色。
  private var hue: CGFloat
  private var saturation: CGFloat
  private var brightness: CGFloat
  private var alpha: CGFloat

  private var field: SaturationBrightnessField?
  private var hueSlider: ColorComponentSlider?
  private var alphaSlider: ColorComponentSlider?
  private var hexField: HexInputField?
  private var preview: NSView?
  /// popover 关闭回调：调用方据此把色板重建一次（斜线底、tooltip 都要跟上新值）。
  var onClose: (() -> Void)?

  init(title: String, color: NSColor, onChange: @escaping (NSColor) -> Void) {
    self.titleText = title
    self.onChange = onChange
    let hsb = (color.usingColorSpace(.sRGB) ?? color)
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 1
    hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    hue = h
    saturation = s
    brightness = b
    alpha = a
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    onClose?()
  }

  var currentColor: NSColor {
    NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
  }

  override func loadView() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 262))

    let swatch = NSView()
    swatch.wantsLayer = true
    swatch.layer?.cornerRadius = 4
    swatch.layer?.borderWidth = 1
    swatch.layer?.borderColor = SettingsTheme.hairline.cgColor
    swatch.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      swatch.widthAnchor.constraint(equalToConstant: 16),
      swatch.heightAnchor.constraint(equalToConstant: 16),
    ])
    preview = swatch

    let label = makeLabel(titleText, size: 11.5, weight: .medium, color: SettingsTheme.ink)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let close = IconHoverButton(symbol: "xmark", accessibilityDescription: "关闭取色器") {
      [weak self] in
      self?.dismissPicker()
    }
    close.identifier = NSUserInterfaceItemIdentifier("inline-color-picker-close")
    close.restingTint = SettingsTheme.secondaryInk
    close.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      close.widthAnchor.constraint(equalToConstant: 20),
      close.heightAnchor.constraint(equalToConstant: 20),
    ])
    let header = NSStackView(views: [swatch, label, NSView(), close])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6

    let field = SaturationBrightnessField { [weak self] saturation, brightness in
      guard let self else { return }
      self.saturation = saturation
      self.brightness = brightness
      self.publish(updatingHexField: true)
    }
    field.translatesAutoresizingMaskIntoConstraints = false
    field.heightAnchor.constraint(equalToConstant: 128).isActive = true
    self.field = field

    let hueSlider = ColorComponentSlider(kind: .hue) { [weak self] value in
      guard let self else { return }
      self.hue = value
      self.publish(updatingHexField: true)
    }
    let alphaSlider = ColorComponentSlider(kind: .alpha) { [weak self] value in
      guard let self else { return }
      self.alpha = value
      self.publish(updatingHexField: true)
    }
    self.hueSlider = hueSlider
    self.alphaSlider = alphaSlider

    // hex 直接可粘贴：从 Otty 主题文件里拷一个色号过来是最常见的改色方式。
    let hex = HexInputField { [weak self] value in
      self?.applyHexInput(value)
    }
    hex.identifier = NSUserInterfaceItemIdentifier("inline-color-picker-hex")
    hexField = hex

    let stack = NSStackView(views: [header, field, hueSlider, alphaSlider, hex])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    root.addSubview(stack)
    stack.pinEdges(to: root)
    view = root
    syncControls()
  }

  private func dismissPicker() {
    // popover 呈现时 presentingViewController 为空，走 dismiss(self) 才关得掉。
    presentingViewController?.dismiss(self) ?? dismiss(self)
  }

  /// 把当前 HSB 推给调用方，并同步取色器自身的各个控件。
  private func publish(updatingHexField: Bool) {
    syncControls(updatingHexField: updatingHexField)
    onChange(currentColor)
  }

  private func syncControls(updatingHexField: Bool = true) {
    field?.update(hue: hue, saturation: saturation, brightness: brightness)
    hueSlider?.update(value: hue, base: currentColor)
    alphaSlider?.update(value: alpha, base: currentColor)
    preview?.layer?.backgroundColor = currentColor.cgColor
    guard updatingHexField else { return }
    // `setDisplayedValue` 自己判断有没有未提交的用户输入；这里不能再用
    // `currentEditor() == nil` 拦一道——popover 打开时输入框就是 first responder，
    // 那样拖完色号永远停在初始值上。
    hexField?.setDisplayedValue(HexColor(nsColor: currentColor).displayString)
  }

  /// 接受 `#rgb` 之外的常见写法：带不带 `#`、6 位或 8 位。解析失败时静默还原，
  /// 不把半截输入当成颜色写进主题。
  private func applyHexInput(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    guard let parsed = HexColor(normalized) else {
      syncControls()
      return
    }
    let color = NSColor(parsed).usingColorSpace(.sRGB) ?? NSColor(parsed)
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 1
    color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    // 灰阶色的 hue 无意义，保留原色相，避免色相条跳回红色。
    if s > 0 { hue = h }
    saturation = s
    brightness = b
    alpha = a
    publish(updatingHexField: false)
  }
}

/// hex 输入框：回车或失焦时提交，解析交给调用方。
@MainActor
private final class HexInputField: NSTextField, NSTextFieldDelegate {
  private let onCommit: (String) -> Void
  /// 用户是否真的敲过字。只靠「结束编辑」提交是不够的：拖动色域会把焦点从这里
  /// 移走，此时输入框里还是拖动前的旧色号，提交它会立刻把刚拖出来的颜色改回去。
  private var hasUserEdits = false

  init(onCommit: @escaping (String) -> Void) {
    self.onCommit = onCommit
    super.init(frame: .zero)
    font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    alignment = .center
    isBezeled = true
    bezelStyle = .roundedBezel
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  /// 由取色器回写色号时用这个方法，不会被当成用户输入。
  func setDisplayedValue(_ value: String) {
    guard !hasUserEdits else { return }
    stringValue = value
  }

  func controlTextDidChange(_ obj: Notification) { hasUserEdits = true }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard hasUserEdits else { return }
    hasUserEdits = false
    onCommit(stringValue)
  }
}

/// 饱和度（横轴）× 明度（纵轴）色域。
@MainActor
private final class SaturationBrightnessField: NSView {
  private let onChange: (CGFloat, CGFloat) -> Void
  private var hue: CGFloat = 0
  private var saturation: CGFloat = 1
  private var brightness: CGFloat = 1

  init(onChange: @escaping (CGFloat, CGFloat) -> Void) {
    self.onChange = onChange
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.masksToBounds = true
  }

  required init?(coder: NSCoder) { nil }

  func update(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
    self.hue = hue
    self.saturation = saturation
    self.brightness = brightness
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    // 两层渐变叠出标准色域：先白→纯色相，再透明→黑。
    let pure = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
    NSGradient(starting: .white, ending: pure)?.draw(in: bounds, angle: 0)
    NSGradient(starting: NSColor.black.withAlphaComponent(0), ending: .black)?
      .draw(in: bounds, angle: -90)
    let point = NSPoint(
      x: bounds.minX + saturation * bounds.width,
      y: bounds.minY + brightness * bounds.height
    )
    drawKnob(at: point, fill: NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
  }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    // 收走 hex 输入框的编辑焦点，否则它会一直占着 field editor，色号停在旧值。
    window?.makeFirstResponder(self)
    track(event)
  }
  override func mouseDragged(with event: NSEvent) { track(event) }

  private func track(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    saturation = min(max((point.x - bounds.minX) / max(bounds.width, 1), 0), 1)
    brightness = min(max((point.y - bounds.minY) / max(bounds.height, 1), 0), 1)
    needsDisplay = true
    onChange(saturation, brightness)
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

/// 色相条 / 透明度条。两者只有底纹不同，交互完全一致。
@MainActor
private final class ColorComponentSlider: NSView {
  enum Kind { case hue, alpha }

  private let kind: Kind
  private let onChange: (CGFloat) -> Void
  private var value: CGFloat = 0
  private var base: NSColor = .black

  init(kind: Kind, onChange: @escaping (CGFloat) -> Void) {
    self.kind = kind
    self.onChange = onChange
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 14).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  func update(value: CGFloat, base: NSColor) {
    self.value = value
    self.base = base
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let track = bounds.insetBy(dx: 0, dy: 1)
    let clip = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    switch kind {
    case .hue:
      let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map {
        NSColor(hue: $0, saturation: 1, brightness: 1, alpha: 1)
      }
      NSGradient(colors: stops)?.draw(in: track, angle: 0)
    case .alpha:
      drawCheckerboard(in: track)
      let opaque = base.withAlphaComponent(1)
      NSGradient(starting: opaque.withAlphaComponent(0), ending: opaque)?.draw(in: track, angle: 0)
    }
    NSGraphicsContext.restoreGraphicsState()
    SettingsTheme.hairline.setStroke()
    clip.lineWidth = 1
    clip.stroke()
    let knobColor: NSColor = kind == .hue
      ? NSColor(hue: value, saturation: 1, brightness: 1, alpha: 1)
      : base.withAlphaComponent(value)
    drawKnob(
      at: NSPoint(x: track.minX + value * track.width, y: track.midY),
      fill: knobColor
    )
  }

  /// 透明度条底下的棋盘格，否则半透明色在浅色背景上看不出「有多透」。
  private func drawCheckerboard(in rect: NSRect) {
    let size: CGFloat = 5
    NSColor.white.setFill()
    rect.fill()
    NSColor(white: 0.85, alpha: 1).setFill()
    var row = 0
    var y = rect.minY
    while y < rect.maxY {
      var x = rect.minX + (row % 2 == 0 ? 0 : size)
      while x < rect.maxX {
        NSRect(x: x, y: y, width: size, height: size).intersection(rect).fill()
        x += size * 2
      }
      y += size
      row += 1
    }
  }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    track(event)
  }
  override func mouseDragged(with event: NSEvent) { track(event) }

  private func track(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    value = min(max((point.x - bounds.minX) / max(bounds.width, 1), 0), 1)
    needsDisplay = true
    onChange(value)
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 色域与滑条共用的白环滑块：深浅背景上都要看得见，因此白环 + 深色描边 + 内填当前色。
@MainActor
private func drawKnob(at point: NSPoint, fill: NSColor) {
  let radius: CGFloat = 5.5
  let circle = NSBezierPath(
    ovalIn: NSRect(
      x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
  fill.setFill()
  circle.fill()
  NSColor.white.setStroke()
  circle.lineWidth = 2
  circle.stroke()
  let outline = NSBezierPath(
    ovalIn: NSRect(
      x: point.x - radius - 1, y: point.y - radius - 1, width: radius * 2 + 2,
      height: radius * 2 + 2))
  NSColor.black.withAlphaComponent(0.25).setStroke()
  outline.lineWidth = 1
  outline.stroke()
}
