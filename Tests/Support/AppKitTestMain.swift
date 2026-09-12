import AppKit
import Darwin
import Testing

/// 独立同步测试宿主：只加载 test bundle，不调用 SwiftPM 生成的 async main。
/// 主事件循环持续运行，最终退出状态由 Swift Testing 决定。
@main
@MainActor
struct AppKitTestMain {
  static func main() {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--test-bundle-path"),
      arguments.indices.contains(index + 1),
      dlopen(arguments[index + 1], RTLD_NOW | RTLD_GLOBAL) != nil
    else {
      let reason = dlerror().map { String(cString: $0) } ?? "--test-bundle-path is missing"
      fputs("test bundle load failed: \(reason)\n", stderr)
      exit(2)
    }
    let application = NSApplication.shared
    Task {
      let status: CInt = await Testing.__swiftPMEntryPoint()
      exit(status)
    }
    application.run()
    fputs("AppKit test loop ended before Swift Testing completed\n", stderr)
    exit(2)
  }
}
