// Antigravity（agy）订阅配额：实时问本机 language server 的 Connect RPC 接口并解析成用量窗口。
import AsterCore
import Foundation
import os

/// Antigravity 本地 language server 的连接信息。
///
/// token 只在内存里传递：不落盘、不进日志、不进诊断信息。
struct AntigravityServerEndpoint: Equatable, Sendable {
  let port: Int
  /// CLI 起的实例可能不带 CSRF token，此时不发 `X-Codeium-Csrf-Token` 头。
  let csrfToken: String?
}

/// 一次取数的结果。
struct AntigravityQuotaResult: Equatable, Sendable {
  let windows: [AgentUsageWindow]
  let plan: String?
  let fetchedAt: Date
}

/// 通过 Antigravity 本地 language server 读取订阅配额。
///
/// 为什么必须实时取：Antigravity 不往磁盘写任何配额缓存，唯一的数据源是随 App / CLI 启动的
/// 本地 Connect RPC 服务。服务端点用自签证书跑在 `127.0.0.1` 的随机端口上，所以取数分两步：
/// 先 `locateServer()` 定位并探活，再 `latest(now:endpoint:fetch:)` 依次尝试三个接口。
///
/// 全部是阻塞式网络 IO，调用方必须放在 `Task.detached(priority: .utility)` 里。所有失败
/// 路径一律静默返回 nil：Antigravity 没装、没启动、版本太新拒绝无 token 请求都是常态。
enum AntigravityQuotaClient {
  /// 单次请求超时。对面是本地服务，慢到这个程度就等于不可用，没有重试的意义。
  static let requestTimeout: TimeInterval = 5
  /// 响应体上限；正常配额响应只有几 KB。
  static let maximumResponseBytes = 1 << 20
  /// 面板一张卡片放得下的窗口数上限。
  static let maximumWindows = 4
  /// 档位名的长度上限，防御外部数据。
  static let maximumPlanBytes = 64
  /// `resetTime` 的可信区间：早于 now 7 天或晚于 now 400 天的值当成脏数据丢弃，
  /// 否则面板会显示出「1970 年重置」这种荒唐的倒计时。
  static let resetPastTolerance: TimeInterval = 7 * 86_400
  static let resetFutureTolerance: TimeInterval = 400 * 86_400

  /// 取数入口的可替换 seam：给定端点、方法名与请求体，返回 200 响应体，其余一律 nil。
  typealias Fetcher = @Sendable (AntigravityServerEndpoint, String, Data) -> Data?

  /// Connect RPC 的服务前缀与方法名。
  enum Method {
    static let servicePath = "exa.language_server_pb.LanguageServerService"
    static let unleashData = "GetUnleashData"
    static let quotaSummary = "RetrieveUserQuotaSummary"
    static let userStatus = "GetUserStatus"
    static let commandModelConfigs = "GetCommandModelConfigs"
  }

  // MARK: - 定位与取数

  /// 定位本地 language server：找进程、取端口、逐个探活，返回第一个应答 200 的端点。
  ///
  /// 没装 / 没启动是常态，一律静默返回 nil。定位本身要跑 `ps` 与 `lsof`，**调用方需要自己
  /// 缓存这个结果**（成功与失败都缓存），不要每次刷新都重新定位。
  nonisolated static func locateServer() -> AntigravityServerEndpoint? {
    for endpoint in AntigravityLanguageServerLocator.candidateEndpoints()
    where liveFetch(endpoint, Method.unleashData, Body.empty) != nil {
      return endpoint
    }
    return nil
  }

  /// 取一次配额与订阅档位。返回 nil 表示这台机器上现在拿不到数据，卡片应当消失。
  ///
  /// 三个接口按可信度尝试：`RetrieveUserQuotaSummary` 数据最全但只有 App / CLI 起的服务有；
  /// IDE 侧会 404，于是退到 `GetUserStatus`；再拿不到身份信息时退到 `GetCommandModelConfigs`。
  nonisolated static func latest(
    now: Date,
    endpoint: AntigravityServerEndpoint? = locateServer(),
    fetch: Fetcher = liveFetch
  ) -> AntigravityQuotaResult? {
    guard let endpoint else { return nil }
    if let data = fetch(endpoint, Method.quotaSummary, Body.forceRefresh),
      let parsed = windows(fromQuotaSummary: data, now: now)
    {
      return AntigravityQuotaResult(windows: parsed.windows, plan: parsed.plan, fetchedAt: now)
    }
    for method in [Method.userStatus, Method.commandModelConfigs] {
      guard let data = fetch(endpoint, method, Body.clientMetadata),
        let parsed = windows(fromUserStatus: data, now: now)
      else { continue }
      return AntigravityQuotaResult(windows: parsed.windows, plan: parsed.plan, fetchedAt: now)
    }
    return nil
  }

  // MARK: - 解析：RetrieveUserQuotaSummary

  /// 解析 `RetrieveUserQuotaSummary` 的响应。纯函数，可单测。
  ///
  /// 401（`{"code":"unauthenticated"}`）、空 groups、垃圾 JSON 都走同一条出口：返回 nil。
  nonisolated static func windows(fromQuotaSummary data: Data, now: Date)
    -> (windows: [AgentUsageWindow], plan: String?)?
  {
    guard let root = object(json(from: data)) else { return nil }
    for container in containers(in: root) {
      guard let groups = container["groups"] as? [Any] else { continue }
      var result: [AgentUsageWindow] = []
      for group in groups.compactMap(object) {
        let groupName = string(group["displayName"])
        guard let buckets = group["buckets"] as? [Any] else { continue }
        for bucket in buckets.compactMap(object) {
          guard let window = window(fromBucket: bucket, groupName: groupName, now: now) else {
            continue
          }
          result.append(window)
        }
      }
      guard !result.isEmpty else { continue }
      return (ranked(result), planName(inSummary: container))
    }
    return nil
  }

  /// 单个 bucket 到用量窗口。`disabled` 的 bucket 对当前账号不可用，显示出来只会误导。
  private nonisolated static func window(
    fromBucket bucket: [String: Any], groupName: String?, now: Date
  ) -> AgentUsageWindow? {
    guard boolean(bucket["disabled"]) != true, let fraction = remainingFraction(in: bucket) else {
      return nil
    }
    // bucket 自己的展示名最准；退到 bucketId，再退到所属分组名。
    let label = string(bucket["displayName"]) ?? string(bucket["bucketId"]) ?? groupName
    return AgentUsageWindow(
      kind: .modelWeekly, usedPercent: usedPercent(remainingFraction: fraction),
      resetsAt: resetDate(bucket["resetTime"], now: now), label: label)
  }

  // MARK: - 解析：GetUserStatus / GetCommandModelConfigs

  /// 解析 `GetUserStatus` 与 `GetCommandModelConfigs` 的响应，两者的模型配额结构相同。
  /// 后者没有身份字段，档位取不到时返回 nil 的 plan。
  nonisolated static func windows(fromUserStatus data: Data, now: Date)
    -> (windows: [AgentUsageWindow], plan: String?)?
  {
    guard let root = object(json(from: data)) else { return nil }
    for container in containers(in: root) {
      let status = object(container["userStatus"]) ?? container
      guard let configs = modelConfigs(in: status) ?? modelConfigs(in: container) else { continue }
      var result: [AgentUsageWindow] = []
      for config in configs.compactMap(object) {
        guard let quota = object(config["quotaInfo"]), let fraction = remainingFraction(in: quota)
        else { continue }
        let label = string(config["label"]) ?? string(object(config["modelOrAlias"])?["model"])
        guard
          let window = AgentUsageWindow(
            kind: .modelWeekly, usedPercent: usedPercent(remainingFraction: fraction),
            resetsAt: resetDate(quota["resetTime"], now: now), label: label)
        else { continue }
        result.append(window)
      }
      guard !result.isEmpty else { continue }
      return (ranked(result), plan(fromUserStatus: status))
    }
    return nil
  }

  /// `clientModelConfigs` 在不同接口里嵌套深度不同，按由深到浅试。
  private nonisolated static func modelConfigs(in container: [String: Any]) -> [Any]? {
    if let nested = object(container["cascadeModelConfigData"])?["clientModelConfigs"] as? [Any] {
      return nested
    }
    return container["clientModelConfigs"] as? [Any]
  }

  /// 档位优先取 `userTier.name`（服务端权威枚举），再退到 planInfo 里的几个展示名字段。
  private nonisolated static func plan(fromUserStatus status: [String: Any]) -> String? {
    if let tier = string(object(status["userTier"])?["name"]),
      let normalized = UsagePlanName.normalized(tier, strippingPrefixes: ["tier_"])
    {
      return normalized
    }
    guard let info = object(object(status["planStatus"])?["planInfo"]) else { return nil }
    for key in ["planName", "planDisplayName", "displayName", "productName", "planShortName"] {
      if let value = string(info[key]), let plan = displayablePlan(value) { return plan }
    }
    return nil
  }

  /// 配额汇总里没有专门的身份对象，只有偶尔出现的档位名字段。
  private nonisolated static func planName(inSummary container: [String: Any]) -> String? {
    for key in ["planName", "planDisplayName"] {
      if let value = string(container[key]), let plan = displayablePlan(value) { return plan }
    }
    return nil
  }

  /// 这些字段既可能是 `pro_plan` 这种枚举，也可能是 `Antigravity Pro` 这种成品展示名。
  /// 带空格的一律按展示名原样用，否则套 `UsagePlanName` 的分段大写。
  private nonisolated static func displayablePlan(_ raw: String) -> String? {
    guard raw.utf8.count <= maximumPlanBytes else { return nil }
    return raw.contains(" ") ? raw : UsagePlanName.normalized(raw)
  }

  // MARK: - 字段换算

  /// 服务端给的是**剩余**比例（0…1），面板要的是已用百分比，所以取补集再乘 100
  /// （`remainingFraction` 0.75 表示还剩 75%，即已用 25%）。
  nonisolated static func usedPercent(remainingFraction: Double) -> Double {
    (1 - min(max(remainingFraction, 0), 1)) * 100
  }

  /// `remainingFraction` 在新版本里被包进 oneof 包装（`remaining`），两种形状都要认。
  private nonisolated static func remainingFraction(in container: [String: Any]) -> Double? {
    let raw =
      double(container["remainingFraction"])
      ?? object(container["remaining"]).flatMap { double($0["remainingFraction"]) }
    guard let raw, raw.isFinite else { return nil }
    return raw
  }

  /// `resetTime` 可能是 ISO-8601 字符串，也可能是纯数字（epoch 秒）或数字字符串。
  private nonisolated static func resetDate(_ value: Any?, now: Date) -> Date? {
    var parsed: Date?
    if let seconds = double(value), boolean(value) == nil, seconds > 0 {
      parsed = Date(timeIntervalSince1970: seconds)
    } else if let text = string(value) {
      parsed = parseISO8601(text) ?? Double(text).flatMap {
        $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
      }
    }
    guard let parsed, parsed > now.addingTimeInterval(-resetPastTolerance),
      parsed < now.addingTimeInterval(resetFutureTolerance)
    else { return nil }
    return parsed
  }

  /// 服务端的小数秒位数不固定，`ISO8601DateFormatter` 只认三位，所以先试带小数再退到无小数。
  /// formatter 是非 Sendable 的类，只能每次新建，不能做成静态常量。
  private nonisolated static func parseISO8601(_ text: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: text) { return date }
    let trimmed = text.replacingOccurrences(
      of: #"\.\d+"#, with: "", options: .regularExpression)
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: trimmed)
  }

  /// 按已用比例降序截断到 `maximumWindows` 条。
  ///
  /// 为什么截断：订阅档位高的账号能返回十几个模型 bucket，面板一张卡片放不下，全塞进去会把
  /// 其它 provider 的卡片挤没。已用最多的那几条才是「还能不能干活」的信号，所以留它们。
  /// 并列时按原始顺序稳定排序，避免同样的响应两次刷新排出不同结果。
  private nonisolated static func ranked(_ windows: [AgentUsageWindow]) -> [AgentUsageWindow] {
    let ordered = windows.enumerated().sorted {
      $0.element.usedPercent == $1.element.usedPercent
        ? $0.offset < $1.offset : $0.element.usedPercent > $1.element.usedPercent
    }
    return ordered.prefix(maximumWindows).map(\.element)
  }

  // MARK: - JSON 工具

  /// 同一个接口在不同 agy 版本上有三种壳子：`{"code":..,"response":{…}}`、
  /// `{"code":..,"summary":{…}}`，以及直接把 `groups` 放在顶层。逐个试，谁先有数据就用谁。
  private nonisolated static func containers(in root: [String: Any]) -> [[String: Any]] {
    var result = [root]
    for key in ["response", "summary"] {
      if let nested = object(root[key]) { result.append(nested) }
    }
    return result
  }

  private nonisolated static func json(from data: Data) -> Any? {
    guard !data.isEmpty, data.count <= maximumResponseBytes else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private nonisolated static func object(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private nonisolated static func double(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  /// JSON 的布尔在 `NSNumber` 里和数字同型，只能靠 `CFBoolean` 的类型标记区分。
  private nonisolated static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return nil }
    return number.boolValue
  }

  private nonisolated static func string(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    return text
  }

  // MARK: - 网络

  /// 三个接口的请求体。
  private enum Body {
    static let empty = Data("{}".utf8)
    static let forceRefresh = Data(#"{"forceRefresh":true}"#.utf8)
    static let clientMetadata = Data(
      #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#
        .utf8)
  }

  /// 真正发 Connect RPC 请求的实现；只有 HTTP 200 才返回数据。
  static let liveFetch: Fetcher = { endpoint, method, body in
    guard
      let url = URL(string: "https://127.0.0.1:\(endpoint.port)/\(Method.servicePath)/\(method)")
    else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    // 老版本 CLI 起的服务不带 token；这时发空头会被直接拒，所以干脆不发。
    if let token = endpoint.csrfToken, !token.isEmpty {
      request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
    }
    return send(request)
  }

  /// 同步发一次请求。阻塞等待信号量，所以只能在 detached 任务里调用。
  private nonisolated static func send(_ request: URLRequest) -> Data? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = requestTimeout
    // 本地服务不该沾任何共享状态：不带 cookie、不走系统代理。
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(
      configuration: configuration, delegate: LoopbackTrustDelegate(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let payload = OSAllocatedUnfairLock<Data?>(initialState: nil)
    let finished = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { data, response, _ in
      defer { finished.signal() }
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        let data, data.count <= maximumResponseBytes
      else { return }
      payload.withLock { $0 = data }
    }
    task.resume()
    // 多给一点余量：URLSession 自己的超时到了会以错误回调收尾，走不到这里。
    if finished.wait(timeout: .now() + requestTimeout + 1) == .timedOut { task.cancel() }
    return payload.withLock { $0 }
  }
}

/// 只对 `127.0.0.1` 放行自签证书的 URLSession 委托。
///
/// language server 用自签证书跑在回环地址上，系统信任链必然校验失败。这里**只**对回环主机名
/// 接受服务端证书，其它任何 host 都退回系统默认校验——绝不能为了这一个本地接口把整个进程的
/// TLS 校验关掉。回环地址上的中间人等价于本机已被攻陷，此时放行不会额外扩大攻击面。
private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      challenge.protectionSpace.host == "127.0.0.1",
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}
