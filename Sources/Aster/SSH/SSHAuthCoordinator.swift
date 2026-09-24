import AsterCore
import Foundation

// broker 凭证与主机密钥请求的协调者：先查钥匙串，查不到再排队弹窗，
// 等 broker 报告结果后决定是否写入或删除钥匙串条目。
// 弹窗通过 `SSHAuthPresenting` 注入，测试用替身，不弹真实窗口。

// MARK: - 弹窗边界

/// 口令 / passphrase 输入框的展示内容。
struct SSHSecretPrompt: Equatable, Sendable {
  /// 要什么秘密。
  enum Subject: Equatable, Sendable {
    /// `user@host:port` 的登录口令。
    case password(endpoint: String)
    /// 私钥的 passphrase；路径可能缺失（broker 没给）。
    case passphrase(keyFile: String?)
  }

  var subject: Subject
  /// 上一次回答被拒绝（attempt > 1），界面要提示重试。
  var isRetry: Bool
  /// 能否记到钥匙串：passphrase 缺少 keyDigest 时没有账户名可存，不显示勾选框。
  var canRemember: Bool
}

/// 用户在口令 / passphrase 输入框里的回答。
struct SSHSecretPromptResponse: Equatable, Sendable {
  var secret: String
  /// 「记住到钥匙串」勾选状态。
  var remember: Bool
}

/// 键盘交互认证（2FA 等）的展示内容。
struct SSHKeyboardInteractivePrompt: Equatable, Sendable {
  var endpoint: String
  var name: String
  var instruction: String
  var prompts: [SSHAuthPrompt]
  var isRetry: Bool
}

/// 认证相关弹窗。实现负责选择挂靠窗口；返回 nil / false 表示用户取消。
@MainActor
protocol SSHAuthPresenting: AnyObject {
  /// 询问口令或 passphrase。
  func promptSecret(_ prompt: SSHSecretPrompt) async -> SSHSecretPromptResponse?
  /// 按 prompts 逐项询问；返回值与 prompts 一一对应。
  func promptKeyboardInteractive(_ prompt: SSHKeyboardInteractivePrompt) async -> [String]?
  /// 确认主机密钥；true 表示信任。
  func confirmHostKey(_ request: SSHHostKeyRequest) async -> Bool
}

// MARK: - 弹窗队列

/// 保证同一时间只显示一个认证弹窗（对应 tty7 `AuthSheetQueue`）。
///
/// 后到的请求按到达顺序挂起，前一个弹窗关闭后才轮到它；否则多个 Pane 同时连同一台主机时
/// 会叠出多层 sheet，用户分不清哪个框属于哪次连接。
@MainActor
final class SSHAuthSheetQueue {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// 等到轮到自己。返回后调用方持有弹窗权，用完必须 `release()`。
  func acquire() async {
    guard busy else {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  /// 交出弹窗权：有人排队就直接移交（busy 保持 true），否则空闲。
  func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  /// 正在排队的请求数（不含当前持有者）。
  var waitingCount: Int { waiters.count }
}

// MARK: - 协调者

/// `SSHAuthCoordinating` 的实现：钥匙串 + 排队弹窗。
@MainActor
final class SSHAuthCoordinator: SSHAuthCoordinating {
  static let shared = SSHAuthCoordinator()

  /// 已回答但尚未收到 `auth.result` 的秘密最多留在内存里的时间。
  static let pendingSecretLifetime: TimeInterval = 60

  /// 钥匙串里的一条账户。
  enum CredentialAccount: Equatable, Sendable {
    case password(endpoint: String)
    case passphrase(digest: String)
  }

  /// 等待 broker 结果的一次回答。
  private struct PendingSecret {
    var account: CredentialAccount
    /// 用户勾选「记住」时输入的秘密；来自钥匙串时为 nil（不需要再写）。
    var secretToRemember: String?
    var fromKeychain: Bool
    var createdAt: Date
  }

  private let store: any SSHCredentialStoring
  private let presenter: any SSHAuthPresenting
  private let now: () -> Date
  private let sheetQueue = SSHAuthSheetQueue()
  private var pending: [String: PendingSecret] = [:]
  /// 钥匙串读写串成一条链：读总在之前的写 / 删完成之后，避免拿到过期口令。
  private var keychainTail: Task<Void, Never>?

  init(
    store: any SSHCredentialStoring = SSHCredentialStore(),
    presenter: (any SSHAuthPresenting)? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.store = store
    self.presenter = presenter ?? SSHAuthWindowPresenter()
    self.now = now
  }

  // MARK: 凭证请求

  /// 回答一次凭证请求。
  func answer(_ request: SSHAuthRequest) async -> SSHBrokerCommand {
    prunePending()
    switch request.kind {
    case .password, .passphrase:
      return await answerSecret(request)
    case .keyboardInteractive:
      return await answerKeyboardInteractive(request)
    }
  }

  /// 口令与 passphrase：第一次尝试先查钥匙串，查不到且可交互时排队弹窗。
  private func answerSecret(_ request: SSHAuthRequest) async -> SSHBrokerCommand {
    let cancel = SSHBrokerCommand.authAnswer(id: request.id, secret: nil, responses: nil)
    let account = Self.account(for: request)
    // 只在第一次尝试用钥匙串：之后的尝试说明钥匙串里的值刚被拒绝（已删除）或用户手输错了。
    let usesKeychain = request.attempt <= 1 && account != nil
    if usesKeychain, let account, let saved = await readSaved(account) {
      return answerFromKeychain(saved, account: account, id: request.id)
    }
    guard request.interactive else { return cancel }

    await sheetQueue.acquire()
    defer { sheetQueue.release() }
    // 排队期间前一个弹窗可能已把同一账户的口令记进钥匙串，轮到自己时再查一次。
    if usesKeychain, let account, let saved = await readSaved(account) {
      return answerFromKeychain(saved, account: account, id: request.id)
    }
    let subject: SSHSecretPrompt.Subject =
      request.kind == .password
      ? .password(endpoint: request.endpoint) : .passphrase(keyFile: request.keyFile)
    let prompt = SSHSecretPrompt(
      subject: subject, isRetry: request.attempt > 1, canRemember: account != nil)
    guard let response = await presenter.promptSecret(prompt) else { return cancel }
    if response.remember, let account {
      remember(
        PendingSecret(
          account: account, secretToRemember: response.secret, fromKeychain: false,
          createdAt: now()),
        id: request.id)
    }
    return .authAnswer(id: request.id, secret: response.secret, responses: nil)
  }

  /// 记下「这次的秘密来自钥匙串」，被拒时才知道要删哪条。
  private func answerFromKeychain(
    _ secret: String, account: CredentialAccount, id: String
  ) -> SSHBrokerCommand {
    remember(
      PendingSecret(account: account, secretToRemember: nil, fromKeychain: true, createdAt: now()),
      id: id)
    return .authAnswer(id: id, secret: secret, responses: nil)
  }

  /// 键盘交互：答案通常是一次性验证码，不存钥匙串。
  ///
  /// 没有提示项时（RFC 4256 允许只下发说明）直接回空数组，不打扰用户。
  /// 取消时 secret 与 responses 都为 null。
  private func answerKeyboardInteractive(_ request: SSHAuthRequest) async -> SSHBrokerCommand {
    if request.prompts.isEmpty {
      return .authAnswer(id: request.id, secret: nil, responses: [])
    }
    let cancel = SSHBrokerCommand.authAnswer(id: request.id, secret: nil, responses: nil)
    guard request.interactive else { return cancel }
    await sheetQueue.acquire()
    defer { sheetQueue.release() }
    let prompt = SSHKeyboardInteractivePrompt(
      endpoint: request.endpoint, name: request.name ?? "", instruction: request.instruction ?? "",
      prompts: request.prompts, isRetry: request.attempt > 1)
    guard let responses = await presenter.promptKeyboardInteractive(prompt),
      responses.count == request.prompts.count
    else { return cancel }
    return .authAnswer(id: request.id, secret: nil, responses: responses)
  }

  // MARK: 结果

  /// broker 报告上一次回答是否被接受。
  func handleResult(id: String, accepted: Bool) {
    settle(id: id, accepted: accepted)
  }

  /// `handleResult` 的实现；返回钥匙串后台任务，测试可以等它完成。
  @discardableResult
  func settle(id: String, accepted: Bool) -> Task<Void, Never>? {
    prunePending()
    // 取出即丢弃：无论接受与否，秘密都不再留在内存里。
    guard let entry = pending.removeValue(forKey: id) else { return nil }
    let store = store
    if accepted, let secret = entry.secretToRemember {
      let account = entry.account
      return enqueueKeychain {
        do {
          switch account {
          case .password(let endpoint): try store.setPassword(secret, for: endpoint)
          case .passphrase(let digest): try store.setPassphrase(secret, forKeyDigest: digest)
          }
        } catch {
          Self.recordKeychainFailure("ssh.keychain.save-failed", account: account, error: error)
        }
      }
    }
    if !accepted, entry.fromKeychain {
      let account = entry.account
      return enqueueKeychain {
        do {
          try Self.delete(account, in: store)
        } catch {
          Self.recordKeychainFailure("ssh.keychain.delete-failed", account: account, error: error)
        }
      }
    }
    return nil
  }

  /// 保存一条待结果的回答，并在寿命到期后自动丢弃（broker 可能永远不回 `auth.result`）。
  private func remember(_ entry: PendingSecret, id: String) {
    pending[id] = entry
    let lifetime = Self.pendingSecretLifetime
    Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(lifetime))
      } catch {
        return
      }
      self?.prunePending()
    }
  }

  /// 丢弃超过寿命的待结果秘密。以注入的时钟为准，测试可以快进。
  private func prunePending() {
    let deadline = now().addingTimeInterval(-Self.pendingSecretLifetime)
    pending = pending.filter { $0.value.createdAt > deadline }
  }

  /// 当前等待结果的回答数（测试用）。
  var pendingCount: Int { pending.count }

  // MARK: 主机密钥

  /// 回答一次主机密钥确认。非交互请求一律拒绝，后台重连不能替用户接受新密钥。
  func confirmHostKey(_ request: SSHHostKeyRequest) async -> SSHBrokerCommand {
    guard request.interactive else { return .hostKeyAnswer(id: request.id, accept: false) }
    await sheetQueue.acquire()
    defer { sheetQueue.release() }
    let accept = await presenter.confirmHostKey(request)
    return .hostKeyAnswer(id: request.id, accept: accept)
  }

  // MARK: 设置页辅助

  /// 是否已为某个 `user@host:port` 保存口令。只查属性，不读秘密。
  func hasSavedPassword(endpoint: String) -> Bool {
    store.hasPassword(for: endpoint)
  }

  /// 删除某个 `user@host:port` 的已保存口令，并丢掉内存里对应的待写入秘密，
  /// 避免稍后到达的 `auth.result` 又把它写回去。
  func forgetPassword(endpoint: String) throws {
    pending = pending.filter { $0.value.account != .password(endpoint: endpoint) }
    try store.deletePassword(for: endpoint)
  }

  // MARK: 钥匙串访问

  /// 请求对应的钥匙串账户；passphrase 缺少 keyDigest 时没有可用账户。
  private static func account(for request: SSHAuthRequest) -> CredentialAccount? {
    switch request.kind {
    case .password: .password(endpoint: request.endpoint)
    case .passphrase: request.keyDigest.map { .passphrase(digest: $0) }
    case .keyboardInteractive: nil
    }
  }

  /// 在后台读取已保存的秘密。读失败（钥匙串锁定、用户拒绝授权）按「没有」处理，转去弹窗。
  private func readSaved(_ account: CredentialAccount) async -> String? {
    await keychainTail?.value
    let store = store
    let result = await Task.detached { () -> Result<String?, Error> in
      Result {
        switch account {
        case .password(let endpoint): try store.password(for: endpoint)
        case .passphrase(let digest): try store.passphrase(forKeyDigest: digest)
        }
      }
    }.value
    switch result {
    case .success(let secret):
      return secret
    case .failure(let error):
      Self.recordKeychainFailure("ssh.keychain.read-failed", account: account, error: error)
      return nil
    }
  }

  /// 把钥匙串写 / 删操作接到串行链尾，在后台执行。
  private func enqueueKeychain(_ work: @escaping @Sendable () -> Void) -> Task<Void, Never> {
    let previous = keychainTail
    let task = Task.detached {
      await previous?.value
      work()
    }
    keychainTail = task
    return task
  }

  /// 删除一条钥匙串条目。
  nonisolated private static func delete(
    _ account: CredentialAccount, in store: any SSHCredentialStoring
  ) throws {
    switch account {
    case .password(let endpoint): try store.deletePassword(for: endpoint)
    case .passphrase(let digest): try store.deletePassphrase(forKeyDigest: digest)
    }
  }

  /// 记录钥匙串失败。只记类别与 OSStatus，不记账户名与秘密。
  nonisolated private static func recordKeychainFailure(
    _ event: String, account: CredentialAccount, error: Error
  ) {
    let kind =
      switch account {
      case .password: "password"
      case .passphrase: "passphrase"
      }
    var attributes = ["kind": kind]
    if case SSHCredentialStoreError.keychain(let status) = error {
      attributes["status"] = String(status)
    }
    DiagnosticsCenter.shared.record(
      event, level: .warning, category: .integration, attributes: attributes)
  }
}
