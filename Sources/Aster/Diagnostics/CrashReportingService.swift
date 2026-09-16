import AsterCore
import Foundation

/// 崩溃与异常退出的上报服务（Sentry）。
///
/// 为什么不用 sentry-cocoa 的崩溃处理器：它会给进程装 Mach 异常端口，终端里启动的所有子进程
/// 都会继承；它不区分外部任务，子进程一段错误就会被当成 Aster 自己的致命崩溃记录并禁用处理器
/// （见 docs/developer/child-crash-exit.md）。Aster 已经有 GhosttyKit 内置 Breakpad 写下的
/// minidump，这里只负责两件事：把上次会话的异常结束发成事件，把 Ghostty 的崩溃 envelope
/// 改写成 Aster 的 release 后上传。全部动作只在用户打开开关后发生。
final class CrashReportingService: @unchecked Sendable {
  static let shared = CrashReportingService()

  /// 项目公开 DSN；只含 public key，不是 secret。
  static let dsnString = "https://14dd62a3fd75f57b9a9e38bc66371c58@o4506614047703040.ingest.us.sentry.io/4512096853098496"

  private struct SessionRecovery {
    let reason: String
    let crashCount: Int
    let decision: String
    let abnormal: Bool
  }

  private let queue = DispatchQueue(label: "io.local.aster-terminal.crash-reporting", qos: .utility)
  private let session: URLSession
  private let fileManager: FileManager
  private let dsn: SentryDSN?
  private var enabled = false
  private var recovery: SessionRecovery?
  private var didReportRecovery = false
  private var isUploading = false

  init(session: URLSession = .shared, fileManager: FileManager = .default) {
    self.session = session
    self.fileManager = fileManager
    dsn = SentryDSN(string: Self.dsnString)
  }

  /// 由 `AppModel.beginApplicationSession` 在决定恢复策略时调用；只记录，不发送。
  func noteSessionRecovery(reason: String, crashCount: Int, decision: String) {
    let abnormal = reason == "crash" || reason == "forceQuit"
    queue.async {
      self.recovery = SessionRecovery(reason: reason, crashCount: crashCount, decision: decision, abnormal: abnormal)
    }
  }

  /// 应用启动完成后调用。开关打开时延迟几秒再上传，把启动阶段的带宽和 CPU 留给工作区恢复。
  func start(enabled: Bool) {
    setEnabled(enabled, delay: 5)
  }

  /// 设置页切换开关时调用；打开即尝试上传积压的报告。
  func setEnabled(_ enabled: Bool, delay: TimeInterval = 0) {
    queue.async {
      self.enabled = enabled
      guard enabled else { return }
      self.queue.asyncAfter(deadline: .now() + delay) { self.uploadPendingIfNeeded() }
    }
  }

  // MARK: - 上传

  private func uploadPendingIfNeeded() {
    guard enabled, !isUploading, let dsn else { return }
    isUploading = true
    let context = Self.makeContext()
    var envelopes: [(kind: String, name: String?, data: Data)] = []

    let pendingMinidumps = pendingGhosttyCrashFiles()
    for url in pendingMinidumps {
      guard let raw = try? Data(contentsOf: url) else { continue }
      do {
        let rewritten = try GhosttyCrashEnvelope.rewrite(raw, context: context)
        envelopes.append((kind: "minidump", name: url.lastPathComponent, data: rewritten))
      } catch {
        DiagnosticsCenter.shared.record(
          "crash_reporting.rewrite_failed", level: .warning, category: .lifecycle, error: error)
        // 改写失败的文件记为已处理，避免每次启动重复失败。
        markUploaded(url.lastPathComponent)
      }
    }

    if let recovery, recovery.abnormal, !didReportRecovery {
      didReportRecovery = true
      let lines = DiagnosticsCenter.shared.previousSessionRecordLines(limit: AbnormalExitEvent.maximumBreadcrumbs)
      let envelope = AbnormalExitEvent.makeEnvelope(
        reason: recovery.reason, crashCount: recovery.crashCount, decision: recovery.decision,
        pendingMinidumps: pendingMinidumps.count, breadcrumbLines: lines, context: context)
      envelopes.append((kind: "abnormal_exit", name: nil, data: envelope))
    }

    guard !envelopes.isEmpty else {
      isUploading = false
      return
    }
    sendSequentially(envelopes[...], dsn: dsn, context: context)
  }

  private func sendSequentially(
    _ envelopes: ArraySlice<(kind: String, name: String?, data: Data)>, dsn: SentryDSN, context: CrashReportContext
  ) {
    guard let current = envelopes.first else {
      isUploading = false
      return
    }
    let rest = envelopes.dropFirst()
    var request = URLRequest(url: dsn.envelopeURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
    request.setValue(dsn.authorizationHeader(clientVersion: context.appVersion), forHTTPHeaderField: "X-Sentry-Auth")
    let task = session.uploadTask(with: request, from: current.data) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, (200..<300).contains(status) {
          if let name = current.name { self.markUploaded(name) }
          DiagnosticsCenter.shared.record(
            "crash_reporting.uploaded", level: .notice, category: .lifecycle,
            attributes: ["kind": current.kind, "bytes": String(current.data.count)])
        } else {
          DiagnosticsCenter.shared.record(
            "crash_reporting.upload_failed", level: .warning, category: .lifecycle,
            attributes: ["kind": current.kind, "status": String(status)], error: error)
          // 服务端明确拒绝（4xx，非限流）的文件不再重试；网络错误或限流留到下次启动。
          if let name = current.name, (400..<500).contains(status), status != 429 { self.markUploaded(name) }
        }
        self.sendSequentially(rest, dsn: dsn, context: context)
      }
    }
    task.resume()
  }

  // MARK: - Ghostty 崩溃文件

  /// libghostty 的崩溃目录：XDG state 目录下的 `ghostty/crash`，与 `src/crash/dir.zig` 一致。
  static func ghosttyCrashDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    let state: URL
    if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty, xdg.hasPrefix("/") {
      state = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
      state = home.appendingPathComponent(".local/state", isDirectory: true)
    }
    return state.appendingPathComponent("ghostty/crash", isDirectory: true)
  }

  private func pendingGhosttyCrashFiles() -> [URL] {
    let directory = Self.ghosttyCrashDirectory()
    guard let urls = try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles])
    else { return [] }
    let candidates = urls.compactMap { url -> CrashReportUploadPolicy.Candidate? in
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
        values.isRegularFile == true
      else { return nil }
      return CrashReportUploadPolicy.Candidate(
        name: url.lastPathComponent, byteCount: values.fileSize ?? 0, modifiedAt: values.contentModificationDate ?? .distantPast)
    }
    let selected = CrashReportUploadPolicy.select(candidates, alreadyUploaded: uploadedNames())
    return selected.map { directory.appendingPathComponent($0.name) }
  }

  // MARK: - 已上传登记

  /// 已上传文件名登记在 Aster 自己的 Application Support 下；不改动也不删除 Ghostty 的文件，
  /// `ghostty +crash-report` 仍然可用。
  private var registryURL: URL {
    let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? fileManager.temporaryDirectory
    return support.appendingPathComponent("Aster/CrashReports/uploaded.json")
  }

  private func uploadedNames() -> Set<String> {
    guard let data = try? Data(contentsOf: registryURL), let names = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return Set(names)
  }

  private func markUploaded(_ name: String) {
    var names = uploadedNames()
    names.insert(name)
    let url = registryURL
    try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(names.sorted()) {
      try? data.write(to: url, options: .atomic)
    }
  }

  // MARK: - 环境

  static func makeContext() -> CrashReportContext {
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if DEBUG
    let environment = "debug"
    #else
    let environment = "release"
    #endif
    #if arch(arm64)
    let architecture = "arm64"
    #else
    let architecture = "x86_64"
    #endif
    return CrashReportContext(
      appVersion: version, appBuild: build, environment: environment,
      osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture)
  }
}
