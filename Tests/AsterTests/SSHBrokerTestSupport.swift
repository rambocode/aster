import AsterCore
import Foundation
import Testing

@testable import Aster

// SSHBrokerSupervisor 测试的共用夹具。broker 用临时目录里的 /bin/sh 假脚本代替：
// 它按 PROTOCOL.md §4 说 JSON Lines，把收到的每一行追加到 received-<次数> 文件，
// 并能按标记文件模拟崩溃、不报 ready 与预置事件。全程不碰真实 hosts.json、钥匙串与网络。

/// 一次测试用的假 broker 环境。
struct FakeSSHBroker {
  let directory: URL
  let executable: URL

  /// 生成脚本。`$3` 是 `broker --socket <path>` 里的 socket 路径。
  init() throws {
    directory = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("aster-fake-broker-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    executable = directory.appendingPathComponent("aster-ssh")
    let script = """
      #!/bin/sh
      DIR='\(directory.path)'
      if [ "$1" = "config" ]; then
        cat "$DIR/config.json"
        exit 0
      fi
      n=$(cat "$DIR/count" 2>/dev/null || echo 0)
      n=$((n+1))
      echo "$n" > "$DIR/count"
      if [ -f "$DIR/no-ready" ]; then
        rm -f "$DIR/no-ready"
        exec sleep 30
        exit 0
      fi
      printf '{"type":"ready","socket":"%s","version":"fake-%s"}\\n' "$3" "$n"
      if [ -f "$DIR/crash-once" ]; then
        rm -f "$DIR/crash-once"
        exit 3
      fi
      if [ -f "$DIR/events" ]; then
        cat "$DIR/events"
      fi
      while IFS= read -r line; do
        printf '%s\\n' "$line" >> "$DIR/received-$n"
        case "$line" in
          *'"type":"shutdown"'*) exit 0 ;;
        esac
      done
      exit 0
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  }

  /// 放一个标记文件（crash-once、no-ready）。
  func mark(_ name: String) throws {
    try Data().write(to: directory.appendingPathComponent(name))
  }

  /// 预置 broker 启动后立刻输出的事件行。
  func setEvents(_ lines: [String]) throws {
    try (lines.joined(separator: "\n") + "\n").write(
      to: directory.appendingPathComponent("events"), atomically: true, encoding: .utf8)
  }

  /// 第 n 个 broker 实例收到的全部行。
  func received(_ instance: Int = 1) -> [String] {
    let url = directory.appendingPathComponent("received-\(instance)")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// 回答固定内容并记录调用的假认证协调者。
@MainActor
final class FakeSSHAuthCoordinator: SSHAuthCoordinating {
  var results: [(String, Bool)] = []
  var answeredRequests: [String] = []

  func answer(_ request: SSHAuthRequest) async -> SSHBrokerCommand {
    answeredRequests.append(request.id)
    return .authAnswer(id: request.id, secret: "pw-\(request.id)", responses: nil)
  }

  func handleResult(id: String, accepted: Bool) { results.append((id, accepted)) }

  func confirmHostKey(_ request: SSHHostKeyRequest) async -> SSHBrokerCommand {
    .hostKeyAnswer(id: request.id, accept: true)
  }
}

/// 在主线程上轮询条件，最多等 `seconds` 秒。
@MainActor
func sshBrokerEventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}

/// 私有主机目录（临时 hosts.json）。
@MainActor
func makeTemporaryHostDirectory() -> (SSHHostDirectory, URL) {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AsterSSHBrokerTests.\(UUID().uuidString)")
    .appendingPathComponent("hosts.json")
  return (SSHHostDirectory(store: SSHHostStore(fileURL: url)), url)
}

/// 用假 broker 构造监管者。退避与超时调小，用例不等真实秒数。
@MainActor
func makeFakeBrokerSupervisor(
  _ broker: FakeSSHBroker, directory: SSHHostDirectory, routing: SSHEngineRouting,
  environment: [String: String] = ["PATH": "/usr/bin:/bin"],
  readyTimeout: Duration = .seconds(5),
  linkStates: ((SSHLinkStateEvent) -> Void)? = nil
) -> SSHBrokerSupervisor {
  var tuning = SSHBrokerSupervisor.Tuning()
  tuning.readyTimeout = readyTimeout
  tuning.restartDelays = [0.05]
  let executable = broker.executable
  return SSHBrokerSupervisor(
    routing: routing, hostDirectory: { directory }, linkStateHandler: linkStates,
    environment: environment, tuning: tuning, locateExecutable: { executable })
}
