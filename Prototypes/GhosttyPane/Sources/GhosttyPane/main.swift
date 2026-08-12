import AppKit

private final class PrototypeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private var terminalView: GhosttySurfaceView?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard GhosttyApp.shared.isReady else {
      presentStartupFailure()
      return
    }

    let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Aster · libghostty 单 Pane PoC"
    window.center()
    window.delegate = self

    let options = PrototypeOptions(arguments: CommandLine.arguments)
    let terminalView = GhosttySurfaceView(
      workingDirectory: options.workingDirectory,
      command: options.command
    )
    terminalView.onTitleChange = { [weak window] title in
      window?.title = title.isEmpty ? "Aster · libghostty 单 Pane PoC" : title
    }
    terminalView.onProcessExit = { [weak self] in
      self?.window?.close()
    }
    window.contentView = terminalView
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminalView)

    self.window = window
    self.terminalView = terminalView
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    terminalView?.destroySurface()
    terminalView = nil
    window = nil
    NSApp.terminate(nil)
  }

  private func presentStartupFailure() {
    let alert = NSAlert()
    alert.messageText = "libghostty 初始化失败"
    alert.informativeText = "请从仓库根目录重新运行 scripts/setup-ghostty-poc.sh。"
    alert.runModal()
    NSApp.terminate(nil)
  }
}

/// Minimal launch options keep the PoC scriptable without introducing a CLI dependency.
/// Unknown or value-less options are ignored because this is a developer-only executable;
/// the default remains an interactive login shell in the caller's current directory.
private struct PrototypeOptions {
  var workingDirectory = FileManager.default.currentDirectoryPath
  var command: String?

  init(arguments: [String]) {
    var index = 1
    while index < arguments.count {
      guard index + 1 < arguments.count else { break }
      switch arguments[index] {
      case "--working-directory":
        workingDirectory = arguments[index + 1]
        index += 2
      case "--command":
        command = arguments[index + 1]
        index += 2
      default:
        index += 1
      }
    }
  }
}

let application = NSApplication.shared
private let delegate = PrototypeAppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
