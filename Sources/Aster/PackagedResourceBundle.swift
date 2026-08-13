import Foundation

/// 定位随已签名 `.app` 分发的 SwiftPM 资源 Bundle。
///
/// SwiftPM 为 executable target 生成的 `Bundle.module` 在 macOS App 中只尝试
/// `Bundle.main.bundleURL/<name>` 和编译机的绝对 `.build` 路径，不会检查标准的
/// `Contents/Resources`。这里显式覆盖发布 App、命令行构建和 SwiftPM 测试三种布局；
/// 找不到时返回 `nil`，由调用方提供领域错误，禁止让资源缺失升级为进程级 fatalError。
enum PackagedResourceBundle {
  /// 返回第一个真实可加载的资源 Bundle。候选顺序优先标准 App 资源目录，确保开发机
  /// 也走与新电脑相同的发布路径，而不是被旁边的 `.build` 产物掩盖打包错误。
  static func locate(
    named bundleName: String,
    mainBundle: Bundle = .main,
    arguments: [String] = CommandLine.arguments
  ) -> Bundle? {
    candidateURLs(
      named: bundleName,
      mainBundleURL: mainBundle.bundleURL,
      mainResourceURL: mainBundle.resourceURL,
      testBundleURL: testBundleURL(from: arguments)
    ).lazy.compactMap(Bundle.init(url:)).first
  }

  /// 生成确定性的候选顺序，供回归测试覆盖发布 App 和 `.xctest` 布局。
  /// 输入均为 URL，不读取任意用户参数；测试路径只接受 SwiftPM 的结构化 flag。
  static func candidateURLs(
    named bundleName: String,
    mainBundleURL: URL,
    mainResourceURL: URL?,
    testBundleURL: URL?
  ) -> [URL] {
    var candidates = [
      mainResourceURL?.appendingPathComponent(bundleName, isDirectory: true),
      mainBundleURL.appendingPathComponent(bundleName, isDirectory: true),
      mainBundleURL.deletingLastPathComponent()
        .appendingPathComponent(bundleName, isDirectory: true),
      testBundleURL?.deletingLastPathComponent()
        .appendingPathComponent(bundleName, isDirectory: true),
    ].compactMap { $0?.standardizedFileURL }

    var seen: Set<URL> = []
    candidates.removeAll { !seen.insert($0).inserted }
    return candidates
  }

  /// SwiftPM 测试运行器通过该 flag 传递真实 `.xctest` 路径。只识别这个结构化入口，
  /// 避免把普通用户参数当成资源搜索根目录。
  private static func testBundleURL(from arguments: [String]) -> URL? {
    guard let flagIndex = arguments.firstIndex(of: "--test-bundle-path"),
      arguments.indices.contains(flagIndex + 1)
    else { return nil }

    var url = URL(fileURLWithPath: arguments[flagIndex + 1])
    while url.pathExtension != "xctest", url.pathComponents.count > 1 {
      url.deleteLastPathComponent()
    }
    return url.pathExtension == "xctest" ? url : nil
  }
}
