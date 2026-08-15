import AsterCore
import Foundation
import Testing

@testable import AsterMemory

/// 检索质量的确定性 eval（借鉴 zero-mem 的 eval 形态：种子事实 + 干扰项 +
/// hard-negative + 弱池），锁住 recall 底线。任何改动检索排序、门控阈值或
/// FTS 查询构造的提交都必须让本套件保持绿——检索质量不能靠拍脑袋。
///
/// 语料刻意超过 `minimumGatedCorpus`，让弱池门控处于启用状态下接受检验。
@MainActor
@Suite struct RetrievalQualityTests {
  private static let projectPath = "/tmp/eval-project"

  /// 目标事实：查询（事实词的子集）应把它带进 top-5。
  private static let facts: [(command: String, output: String)] = [
    ("cargo test websocket_reconnect", "error: reconnect timed out after 30s"),
    ("npm run oauth-refresh", "token refresh succeeded with rotation"),
    ("swift build --target AsterMemory", "Build complete for AsterMemory"),
    ("kubectl rollout status deployment/gateway", "deployment gateway successfully rolled out"),
    ("psql -c 'vacuum analyze invoices'", "VACUUM on table invoices done"),
  ]

  /// hard-negative 对：两条只差一个值（zero-mem eval-hard 的形态），
  /// 查询里带上区分值时必须把正确的一条排在兄弟前面。
  private static let hardNegatives: [(a: String, b: String)] = [
    ("deploy release to staging cluster", "deploy release to production cluster"),
    ("open tunnel on port 8080 for grafana", "open tunnel on port 9090 for grafana"),
  ]

  /// 干扰项：普通构建噪音，任何查询都不该把它们顶到目标前面。
  private static let distractors = [
    "make clean", "make all", "git status", "git log --oneline", "ls -la",
    "cd src", "cat README.md", "brew update", "brew upgrade", "df -h",
    "top -l 1", "uptime", "whoami", "date", "echo done",
  ]

  /// 建一座含全部语料的临时库。
  private func seededLocation() async throws -> MemoryStoreLocation {
    let location = MemoryStoreLocation(
      rootDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("retrieval-eval-\(UUID().uuidString)", isDirectory: true))
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID, projectPath: Self.projectPath, shell: "zsh", startedAt: base)))
    var sequence = 0
    func add(command: String?, output: String? = nil, exit: Int? = nil) async {
      sequence += 1
      await writer.record(
        .appendEvent(
          RecordedEvent(
            sessionID: sessionID, sequence: sequence,
            timestamp: base.addingTimeInterval(Double(sequence)),
            kind: command != nil ? .shellCommand : .commandOutput,
            command: command, workingDirectory: Self.projectPath,
            exitStatus: exit, outputExcerpt: output)))
    }
    for fact in Self.facts {
      await add(command: fact.command)
      await add(command: nil, output: fact.output, exit: 0)
    }
    for pair in Self.hardNegatives {
      await add(command: pair.a)
      await add(command: pair.b)
    }
    for distractor in Self.distractors {
      await add(command: distractor)
    }
    await writer.flush()
    return location
  }

  @Test("每个种子事实的查询都在 top-5 内（recall@5 = 1.0）")
  func factRecall() async throws {
    let location = try await seededLocation()
    defer { try? FileManager.default.removeItem(at: location.rootDirectory) }
    let reader = try MemoryStoreReader(location: location)
    // 查询 = 事实的部分词，覆盖命令词与输出词两种入口。
    let queries: [(query: String, expected: String)] = [
      ("websocket reconnect", "cargo test websocket_reconnect"),
      ("reconnect timed out", "reconnect timed out"),
      ("oauth refresh", "npm run oauth-refresh"),
      ("token rotation", "token refresh succeeded"),
      ("rollout gateway", "kubectl rollout status"),
      ("vacuum invoices", "vacuum analyze invoices"),
    ]
    for probe in queries {
      let hits = try reader.search(query: probe.query, projectPath: Self.projectPath, limit: 5)
      let joined = hits.map { "\($0.title)\n\($0.detail)" }.joined(separator: "\n")
      #expect(
        joined.localizedCaseInsensitiveContains(probe.expected),
        "查询「\(probe.query)」的 top-5 未包含目标「\(probe.expected)」")
    }
  }

  @Test("hard-negative：带区分值的查询把正确版本排在兄弟前面")
  func hardNegativeOrdering() async throws {
    let location = try await seededLocation()
    defer { try? FileManager.default.removeItem(at: location.rootDirectory) }
    let reader = try MemoryStoreReader(location: location)
    let probes: [(query: String, want: String, sibling: String)] = [
      ("deploy production cluster", "production", "staging"),
      ("tunnel port 9090", "9090", "8080"),
    ]
    for probe in probes {
      let hits = try reader.search(query: probe.query, projectPath: Self.projectPath, limit: 5)
      let titles = hits.map(\.title)
      let wantIndex = titles.firstIndex { $0.contains(probe.want) }
      let siblingIndex = titles.firstIndex { $0.contains(probe.sibling) }
      let resolvedWant = try #require(wantIndex, "查询「\(probe.query)」未召回目标")
      // 兄弟可以出现（共享大部分词），但绝不能排在正确版本前面。
      if let siblingIndex {
        #expect(resolvedWant < siblingIndex, "查询「\(probe.query)」把错误版本排在了前面")
      }
    }
  }

  @Test("弱池门控：全库高频词的查询返回空而不是垃圾")
  func weakPoolReturnsNothing() async throws {
    let location = try await seededLocation()
    defer { try? FileManager.default.removeItem(at: location.rootDirectory) }
    // 再插入一批都含 "run" 的记录，使其超过半数文档 → idf clamp。
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID, projectPath: Self.projectPath, shell: "zsh", startedAt: Date())))
    for index in 0..<40 {
      await writer.record(
        .appendEvent(
          RecordedEvent(
            sessionID: sessionID, sequence: index + 1, timestamp: Date(),
            kind: .shellCommand, command: "run job \(index)",
            workingDirectory: Self.projectPath)))
    }
    await writer.flush()

    let reader = try MemoryStoreReader(location: location)
    let gated = try reader.search(query: "run", projectPath: Self.projectPath, limit: 5)
    #expect(gated.isEmpty, "全库高频词应被弱池门控拦下")
    // 关闭门控（浏览器 UI 场景）时仍能看到全部命中。
    let ungated = try reader.search(
      query: "run", projectPath: Self.projectPath, limit: 5, applyRelevanceGate: false)
    #expect(!ungated.isEmpty)
    // 稀有词不受影响。
    let rare = try reader.search(query: "websocket", projectPath: Self.projectPath, limit: 5)
    #expect(!rare.isEmpty)
  }

  @Test("小库豁免：语料低于阈值时门控不启用")
  func tinyCorpusIsExempt() async throws {
    let location = MemoryStoreLocation(
      rootDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("retrieval-tiny-\(UUID().uuidString)", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: location.rootDirectory) }
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID, projectPath: Self.projectPath, shell: "zsh", startedAt: Date())))
    // 3 条记录、2 条含目标词：超半数 → FTS 会 clamp，但小库必须豁免。
    for (index, command) in ["cargo reconnect", "test reconnect", "ls"].enumerated() {
      await writer.record(
        .appendEvent(
          RecordedEvent(
            sessionID: sessionID, sequence: index + 1, timestamp: Date(),
            kind: .shellCommand, command: command, workingDirectory: Self.projectPath)))
    }
    await writer.flush()
    let reader = try MemoryStoreReader(location: location)
    let hits = try reader.search(query: "reconnect", projectPath: Self.projectPath, limit: 5)
    #expect(hits.count == 2, "小库不该被门控清空")
  }

  @Test("federation 回落：项目内零命中才触发且带跨项目标注")
  func federationFallback() async throws {
    let location = try await seededLocation()
    defer { try? FileManager.default.removeItem(at: location.rootDirectory) }
    let reader = try MemoryStoreReader(location: location)
    // 其它项目路径查询：项目内为空 → 回落到全库，命中标 cross-project。
    let fallback = try reader.search(
      query: "websocket reconnect", projectPath: "/elsewhere", limit: 5,
      fallbackAcrossProjects: true)
    #expect(!fallback.isEmpty)
    let allCross = fallback.allSatisfy { $0.isCrossProject }
    #expect(allCross)
    // 项目内有命中时绝不触发回落标注。
    let local = try reader.search(
      query: "websocket reconnect", projectPath: Self.projectPath, limit: 5,
      fallbackAcrossProjects: true)
    #expect(local.allSatisfy { !$0.isCrossProject })
    // 未开启回落时保持零命中。
    let strict = try reader.search(
      query: "websocket reconnect", projectPath: "/elsewhere", limit: 5)
    #expect(strict.isEmpty)
  }
}
