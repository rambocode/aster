// 界面文字缩放的应用层入口：把配置里的档位变成字体与尺寸。所有界面字号都从这里取，
// 不在视图里直接写死 `NSFont.systemFont(ofSize:)`。

import AppKit
import AsterCore
import os

/// 当前生效的界面缩放。启动时 `install` 一次，之后进程内不变：字体和行高在视图创建时
/// 就烤进去了，运行中改档位只写配置，重启后整体生效（与界面语言同一套做法）。
/// 设置页是网页，用 `pageZoom` 就地缩放，不受这条限制。
enum InterfaceScale {
  /// 字体可能在任意线程的 `static let` 里首次求值，所以倍数放在锁里而不是主线程隔离。
  private static let storage = OSAllocatedUnfairLock(initialState: InterfaceTextScale.standard)

  /// 当前生效的档位；未 `install` 时是默认档，测试因此不受用户配置影响。
  static var current: InterfaceTextScale { storage.withLock { $0 } }

  /// 当前倍数。
  static var factor: CGFloat { CGFloat(current.factor) }

  /// 安装档位。必须在任何窗口、菜单创建之前调用。
  static func install(_ scale: InterfaceTextScale) {
    storage.withLock { $0 = scale }
  }

  /// 缩放字号。取整到 0.5pt：系统字体在半点上仍有清晰的 hinting，再细就没有意义。
  static func font(_ size: CGFloat) -> CGFloat {
    (size * factor * 2).rounded() / 2
  }

  /// 缩放「装文字的尺寸」：行高、文字控件的固定宽高、以文字为主的浮层尺寸。
  /// 间距、圆角、描边、图标不要走这里——它们放大后只会挤掉内容，不会更好读。
  static func length(_ value: CGFloat) -> CGFloat {
    (value * factor).rounded()
  }

  /// 同 `length`，但不超过 `limit`。用于被外部几何卡住的尺寸（例如 28pt 标题栏）。
  static func length(_ value: CGFloat, max limit: CGFloat) -> CGFloat {
    min(length(value), limit)
  }

  /// 新档位与当前生效档位不同才需要重启。
  static func relaunchRequired(for scale: InterfaceTextScale) -> Bool {
    scale != current
  }

  /// 档位改动后的提示：让用户选择立即重启或稍后。挂在设置窗口上作为 sheet。
  @MainActor
  static func promptRelaunchIfNeeded(for scale: InterfaceTextScale, in window: NSWindow?) {
    guard relaunchRequired(for: scale) else { return }
    let alert = NSAlert()
    alert.messageText = L("界面字号将在重新启动 Aster 后生效")
    alert.informativeText = L(
      "设置页已经按新字号显示。现在重新启动 Aster，让侧栏和面板也用新字号？打开的终端与标签会按你的关闭确认设置处理，稍后也可以手动退出再打开。")
    alert.alertStyle = .informational
    alert.addButton(withTitle: L("立即重启"))
    alert.addButton(withTitle: L("稍后"))
    let relaunch = { (response: NSApplication.ModalResponse) in
      guard response == .alertFirstButtonReturn else { return }
      (NSApp.delegate as? AsterAppDelegate)?.relaunchApplication()
    }
    if let window {
      alert.beginSheetModal(for: window, completionHandler: relaunch)
    } else {
      relaunch(alert.runModal())
    }
  }
}

extension NSFont {
  /// 界面用系统字体：`size` 是默认档下的字号，返回值已按当前档位缩放。
  static func interface(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: InterfaceScale.font(size), weight: weight)
  }

  /// 界面用等宽系统字体（路径、命令、哈希等），按当前档位缩放。
  static func interfaceMonospaced(ofSize size: CGFloat, weight: NSFont.Weight = .regular)
    -> NSFont
  {
    .monospacedSystemFont(ofSize: InterfaceScale.font(size), weight: weight)
  }

  /// 界面用等宽数字系统字体（计数、用量、时间），按当前档位缩放。
  static func interfaceMonospacedDigit(ofSize size: CGFloat, weight: NSFont.Weight = .regular)
    -> NSFont
  {
    .monospacedDigitSystemFont(ofSize: InterfaceScale.font(size), weight: weight)
  }
}
