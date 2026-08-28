import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

// 控制协议测试共用的夹具：隔离 defaults 的 AppModel/AppPreferences、假客户端、阻塞式 socket 客户端。

/// 隔离 UserDefaults 域，避免测试写入用户真实工作区快照。
@MainActor
struct ControlTestWorkspace {
  let suiteName: String
  let defaults: UserDefaults
  let preferences: AppPreferences
  let model: AppModel

  init() throws {
    suiteName = "AsterControlTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    preferences = AppPreferences(defaults: defaults)
    model = AppModel(defaults: defaults)
    model.beginApplicationSession(launchBehavior: .newWindow)
    // `.newWindow` 不会自动建标签；夹具显式建第一个标签，短 ID 从 w1:t1 / w1:p1 起。
    if model.tabs.isEmpty { model.newTab(workingDirectory: "/tmp") }
  }

  func tearDown() {
    for tab in model.tabs { tab.stop(immediately: true) }
    defaults.removePersistentDomain(forName: suiteName)
  }

  /// 为当前选中标签的活动 pane 创建真实终端视图（SwiftTerm 回归路径，会启动 PTY）。
  func makeActiveTerminalView() throws -> (TerminalSession, AsterTerminalView) {
    let session = try #require(model.selectedTab?.activeSession)
    let view = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
    return (session, view)
  }
}

/// dispatcher 的假客户端：记录推送的事件。
@MainActor
final class ControlFakeClient: AsterControlClient {
  let clientID = UUID()
  var pendingWaits = 0
  private(set) var events: [AsterControlEvent] = []

  func sendEvent(_ event: AsterControlEvent) { events.append(event) }
}

/// 让 `DispatchQueue.main.async` 延后的桥事件得到派发。
@MainActor
func pumpControlEvents(milliseconds: Int = 30) async {
  try? await Task.sleep(for: .milliseconds(milliseconds))
}

/// 构造请求的便捷方法。
func controlRequest(_ method: String, _ params: JSONValue? = nil, id: JSONValue = 1) -> AsterControlRequest {
  AsterControlRequest(id: id, method: method, params: params)
}

/// 阻塞式 Unix socket 客户端（测试专用）：连接、写一行、按超时读一行。
final class ControlSocketClient {
  private let fd: Int32

  init?(path: String) {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = AsterControlServer.makeAddress(path)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      Darwin.close(fd)
      return nil
    }
  }

  deinit { Darwin.close(fd) }

  func write(_ data: Data) {
    var remaining = data
    while !remaining.isEmpty {
      let written = remaining.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      guard written > 0 else { return }
      remaining.removeFirst(written)
    }
  }

  func writeLine(_ text: String) { write(Data((text + "\n").utf8)) }

  /// 读到一行（不含换行）或超时返回 nil；对端关闭返回已缓冲内容或 nil。
  func readLine(timeoutMilliseconds: Int = 3_000) -> String? {
    var buffer = Data()
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    while Date() < deadline {
      var pollfd = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
      guard Darwin.poll(&pollfd, 1, remaining) > 0 else { continue }
      var byte: UInt8 = 0
      let count = Darwin.read(fd, &byte, 1)
      if count <= 0 { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
      if byte == 0x0A { return String(decoding: buffer, as: UTF8.self) }
      buffer.append(byte)
    }
    return nil
  }

  func readResponse(timeoutMilliseconds: Int = 3_000) -> AsterControlResponse? {
    guard let line = readLine(timeoutMilliseconds: timeoutMilliseconds) else { return nil }
    return try? JSONDecoder().decode(AsterControlResponse.self, from: Data(line.utf8))
  }

  /// 对端是否已关闭（读到 EOF）。
  func isClosed(timeoutMilliseconds: Int = 1_000) -> Bool {
    var pollfd = Darwin.pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&pollfd, 1, Int32(timeoutMilliseconds)) > 0 else { return false }
    var byte: UInt8 = 0
    return Darwin.read(fd, &byte, 1) <= 0
  }
}

/// 临时 socket 路径（短，满足 sun_path 上限）。
func temporaryControlSocketPath() -> String {
  let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("aster-ctl-\(UUID().uuidString.prefix(8))")
  return (directory as NSString).appendingPathComponent("aster.sock")
}
