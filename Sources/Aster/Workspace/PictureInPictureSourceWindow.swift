import AppKit
import AVKit

/// AVKit 在 macOS 通过 CALayerHost 镜像源窗口。独立透明承载窗口避免系统的占位图
/// 覆盖真实终端，并允许源视频层跟随 PiP 尺寸，绕开 macOS 26 的 1:1 裁剪问题。
@MainActor
final class PictureInPictureSourceWindow {
  private let window: NSWindow
  private let layer: AVSampleBufferDisplayLayer
  private weak var pipWindow: NSWindow?
  private var fallbackSize: CGSize?
  private var hiddenOverlays: [(view: NSView, wasHidden: Bool)] = []

  init(layer: AVSampleBufferDisplayLayer, size: CGSize) {
    self.layer = layer
    window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
    let host = NSView(frame: NSRect(origin: .zero, size: size))
    host.wantsLayer = true
    window.contentView = host
    host.layer?.addSublayer(layer)
    layer.opacity = 1
    layout(size: size)
    // 源窗口保持已展示状态，但完全透明且不接收事件，不改变工作区的 key window。
    window.orderFront(nil)
  }

  func updateFallbackRenderSize(_ pixels: CGSize) {
    let scale = pipWindow?.backingScaleFactor ?? window.backingScaleFactor
    fallbackSize = CGSize(width: pixels.width / scale, height: pixels.height / scale)
    synchronize(active: true)
  }

  func synchronize(active: Bool) {
    guard active else { return }
    // 只检查本进程由 AVKit 创建的系统 PiP 窗口；不读取其他应用窗口，也不加载私有框架。
    if pipWindow?.isVisible != true {
      pipWindow = NSApp.windows.first {
        String(describing: type(of: $0)) == "PIPPanel" && $0.isVisible
      }
    }
    if let size = pipWindow?.contentView?.bounds.size ?? fallbackSize {
      layout(size: size)
    }
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
      let content = pipWindow?.contentView
    {
      suppressEmptySystemOverlay(in: content)
    }
  }

  func close() {
    for record in hiddenOverlays { record.view.isHidden = record.wasHidden }
    hiddenOverlays.removeAll()
    layer.removeFromSuperlayer()
    window.orderOut(nil)
    window.close()
  }

  private func layout(size: CGSize) {
    guard size.width.isFinite, size.height.isFinite,
      size.width >= 1, size.height >= 1, size.width <= 16_384, size.height <= 16_384
    else { return }
    if window.contentView?.bounds.size != size { window.setContentSize(size) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // 系统浮窗会裁圆角，给内容留出内边距，避免终端首行与第一列被圆角切掉。
    let inset = min(12, min(size.width, size.height) / 8)
    layer.frame = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
    layer.contentsScale = pipWindow?.backingScaleFactor ?? window.backingScaleFactor
    CATransaction.commit()
  }

  private func suppressEmptySystemOverlay(in view: NSView) {
    // macOS 26 的 sample-buffer 路径多盖了一层没有内容的 AVPlayerLayer 镜像占位。
    // 只处理精确类名且确实为空的叶图层；未来系统若在此处承载真实内容则保持原样。
    if String(describing: type(of: view)) == "AVPictureInPictureCALayerHostView",
      let layer = view.layer, layer.contents == nil, layer.sublayers?.isEmpty != false,
      !hiddenOverlays.contains(where: { $0.view === view })
    {
      hiddenOverlays.append((view, view.isHidden))
      view.isHidden = true
    }
    for child in view.subviews { suppressEmptySystemOverlay(in: child) }
  }
}
