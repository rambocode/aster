// 用真实 Shell 历史离线回放补全，量化首选命中率；只在显式提供历史文件时运行。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 按输入法的调参方法论评估补全：冻结一份历史，从空学习库开始按顺序回放，
/// 每条命令先查询、再学习，统计首选（Top-1）与前三（Top-3）命中率。
///
/// 默认直接通过，不读任何文件。评估时这样运行：
/// `ASTER_AUTOCOMPLETE_REPLAY=~/.zsh_history ./scripts/test.sh --no-parallel --filter autocompleteReplayEvaluation`
/// 结果只打印到标准输出（每行以 `REPLAY` 开头），学习状态写在临时目录，不碰真实数据。
@Test("补全离线回放评估（需设置 ASTER_AUTOCOMPLETE_REPLAY）")
@MainActor
func autocompleteReplayEvaluation() throws {
  guard let path = ProcessInfo.processInfo.environment["ASTER_AUTOCOMPLETE_REPLAY"],
    !path.isEmpty
  else { return }
  let text = try String(
    contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8)
  let commands = ReplayHistory.commands(from: text)
  let state = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-replay-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: state) }
  let service = try AutocompleteService(
    baseDirectory: state,
    bundledSpecURL: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/autocomplete/fig-specs.json"))
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  var cwd = home
  var metrics = ReplayMetrics()
  let warmIndex = commands.count * 3 / 10

  for (index, command) in commands.enumerated() {
    let phase = index < warmIndex ? "冷" : "热"
    func top(_ line: String) -> [String] {
      let start = DispatchTime.now().uptimeNanoseconds
      let result = service.suggestions(
        line: line, directory: cwd, sessionIdentifier: "replay", controls: .init())
      metrics.addLatency(DispatchTime.now().uptimeNanoseconds - start)
      return result.candidates.prefix(3).compactMap { $0.resultingLine(from: line) }
    }
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard let first = tokens.first, !first.isEmpty else { continue }

    // M1：命令名打 1 个字。
    let nameResults = top(String(command.prefix(1)))
    metrics.add("M1 命令名(打1字)", phase: phase, results: nameResults.map {
      ShellCommandTokenizer.tokenize($0).tokens.first == first
    })
    // M4：整行打 2 个字。
    if command.count > 2 {
      let lineResults = top(String(command.prefix(2)))
      metrics.add("M4 整行(打2字)", phase: phase, results: lineResults.map {
        $0.trimmingCharacters(in: .whitespaces) == command
      })
    }
    // M2 / M3：后续 token。含引号或转义的命令无法按 token 原样重建，跳过。
    if !command.contains(where: { "'\"\\".contains($0) }) {
      for k in tokens.indices.dropFirst() where !tokens[k].isEmpty {
        let head = tokens[..<k].joined(separator: " ") + " "
        func hits(_ line: String) -> [Bool] {
          top(line).map { resulting in
            let parts = ShellCommandTokenizer.tokenize(resulting).tokens
            return parts.count > k && parts[k] == tokens[k]
          }
        }
        metrics.add("M2 后续token(打1字)", phase: phase, results: hits(head + tokens[k].prefix(1)))
        metrics.add("M3 后续token(打0字)", phase: phase, results: hits(head))
      }
    }

    service.record(
      command: command, directory: cwd, exitStatus: 0, ignorePatterns: [], knownOptions: [],
      sessionIdentifier: "replay")
    if first == "cd" { cwd = ReplayHistory.changeDirectory(tokens, from: cwd, home: home) }
  }
  metrics.print(commandCount: commands.count)
}

/// 历史文件解析与 `cd` 模拟。
private enum ReplayHistory {
  /// 支持普通行与 zsh 扩展格式 `: <时间>:<耗时>;<命令>`，合并反斜杠续行，丢掉自动化噪声。
  static func commands(from text: String) -> [String] {
    var result: [String] = []
    var pending = ""
    for rawLine in text.components(separatedBy: "\n") {
      var line = rawLine
      if pending.isEmpty, line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
        line = String(line[line.index(after: semicolon)...])
      }
      if line.hasSuffix("\\") {
        pending += String(line.dropLast()) + " "
        continue
      }
      let command = (pending + line).trimmingCharacters(in: .whitespaces)
      pending = ""
      guard !command.isEmpty, command.count <= 300, !command.hasPrefix("exec "),
        !command.contains("ASTER_"), !command.contains("/var/folders/"),
        !command.contains("aster-silent-agent")
      else { continue }
      result.append(command)
    }
    return result
  }

  /// 目标存在才切换目录；不存在或无法静态解析时保持原目录。
  static func changeDirectory(_ tokens: [String], from cwd: String, home: String) -> String {
    guard tokens.count >= 2 else { return home }
    let target = tokens[1]
    let path: String
    if target.hasPrefix("/") {
      path = target
    } else if target == "~" || target.hasPrefix("~/") {
      path = NSString(string: target).expandingTildeInPath
    } else {
      path = URL(fileURLWithPath: cwd).appendingPathComponent(target).standardizedFileURL.path
    }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue ? path : cwd
  }
}

/// 各指标按冷（前 30%）/ 热（后 70%）分段累计 Top-1 与 Top-3 命中。
private struct ReplayMetrics {
  private var counts: [String: (total: Int, top1: Int, top3: Int)] = [:]
  private var order: [String] = []
  private var latencies: [UInt64] = []

  /// 记录单次查询耗时（纳秒）。第一次查询包含惰性构建，也计入，反映按键后的真实等待。
  mutating func addLatency(_ nanoseconds: UInt64) { latencies.append(nanoseconds) }

  mutating func add(_ metric: String, phase: String, results: [Bool]) {
    for key in [metric + " 全部", metric + " " + phase] {
      if counts[key] == nil { order.append(key) }
      var value = counts[key] ?? (0, 0, 0)
      value.total += 1
      if results.first == true { value.top1 += 1 }
      if results.contains(true) { value.top3 += 1 }
      counts[key] = value
    }
  }

  func print(commandCount: Int) {
    Swift.print("REPLAY 命令数 \(commandCount)")
    let sorted = latencies.sorted()
    if !sorted.isEmpty {
      func ms(_ value: UInt64) -> String { String(format: "%.2f", Double(value) / 1_000_000) }
      Swift.print(
        "REPLAY 查询耗时 中位 \(ms(sorted[sorted.count / 2]))ms  "
          + "P95 \(ms(sorted[sorted.count * 95 / 100]))ms  最大 \(ms(sorted[sorted.count - 1]))ms")
    }
    for key in order.sorted() {
      guard let value = counts[key], value.total > 0 else { continue }
      let top1 = String(format: "%.1f", Double(value.top1) * 100 / Double(value.total))
      let top3 = String(format: "%.1f", Double(value.top3) * 100 / Double(value.total))
      Swift.print("REPLAY \(key)  样本 \(value.total)  Top1 \(top1)%  Top3 \(top3)%")
    }
  }
}
