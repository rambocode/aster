// SSHAuthCoordinator 的钥匙串优先、非交互、记住 / 删除与弹窗排队逻辑。
// 钥匙串与弹窗都换成替身，不触碰真实钥匙串，也不弹真实窗口。
import AsterCore
import Foundation
import Testing
import os

@testable import Aster

// MARK: - 替身

/// 内存凭证存储。锁保护字典，满足 `Sendable` 而不需要 `@unchecked`。
private final class InMemoryCredentialStore: SSHCredentialStoring {
  private let entries = OSAllocatedUnfairLock(initialState: [String: String]())

  /// 口令键。
  private static func passwordKey(_ endpoint: String) -> String { "password|\(endpoint)" }
  /// passphrase 键。
  private static func passphraseKey(_ digest: String) -> String { "passphrase|\(digest)" }

  func password(for endpoint: String) throws -> String? {
    entries.withLock { $0[Self.passwordKey(endpoint)] }
  }
  func setPassword(_ password: String, for endpoint: String) throws {
    entries.withLock { $0[Self.passwordKey(endpoint)] = password }
  }
  func deletePassword(for endpoint: String) throws {
    _ = entries.withLock { $0.removeValue(forKey: Self.passwordKey(endpoint)) }
  }
  func hasPassword(for endpoint: String) -> Bool {
    entries.withLock { $0[Self.passwordKey(endpoint)] != nil }
  }
  func passphrase(forKeyDigest digest: String) throws -> String? {
    entries.withLock { $0[Self.passphraseKey(digest)] }
  }
  func setPassphrase(_ passphrase: String, forKeyDigest digest: String) throws {
    entries.withLock { $0[Self.passphraseKey(digest)] = passphrase }
  }
  func deletePassphrase(forKeyDigest digest: String) throws {
    _ = entries.withLock { $0.removeValue(forKey: Self.passphraseKey(digest)) }
  }

  /// 条目总数。
  var count: Int { entries.withLock { $0.count } }
}

/// 弹窗替身：记录调用，按脚本作答；`holdsPrompts` 为 true 时挂起，直到测试放行。
@MainActor
private final class RecordingPresenter: SSHAuthPresenting {
  var secretResponse: SSHSecretPromptResponse?
  var keyboardResponses: [String]?
  var hostKeyAccepts = false
  var holdsPrompts = false

  private(set) var secretPrompts: [SSHSecretPrompt] = []
  private(set) var keyboardPrompts: [SSHKeyboardInteractivePrompt] = []
  private(set) var hostKeyRequests: [SSHHostKeyRequest] = []
  /// 当前同时打开的弹窗数，以及出现过的最大值。
  private(set) var openCount = 0
  private(set) var maximumOpenCount = 0
  private var held: [CheckedContinuation<Void, Never>] = []

  func promptSecret(_ prompt: SSHSecretPrompt) async -> SSHSecretPromptResponse? {
    secretPrompts.append(prompt)
    await open()
    return secretResponse
  }

  func promptKeyboardInteractive(_ prompt: SSHKeyboardInteractivePrompt) async -> [String]? {
    keyboardPrompts.append(prompt)
    await open()
    return keyboardResponses
  }

  func confirmHostKey(_ request: SSHHostKeyRequest) async -> Bool {
    hostKeyRequests.append(request)
    await open()
    return hostKeyAccepts
  }

  /// 模拟弹窗打开期间：计数，并在挂起模式下等待放行。
  private func open() async {
    openCount += 1
    maximumOpenCount = max(maximumOpenCount, openCount)
    if holdsPrompts { await withCheckedContinuation { held.append($0) } }
    openCount -= 1
  }

  /// 挂起中的弹窗数。
  var heldCount: Int { held.count }

  /// 关闭最早打开的弹窗。
  func releaseOne() {
    guard !held.isEmpty else { return }
    held.removeFirst().resume()
  }
}

/// 可快进的时钟。
@MainActor
private final class TestClock {
  var now = Date(timeIntervalSince1970: 1_000_000)
}

/// 让出主线程，直到条件成立或约 2 秒后放弃（钥匙串读在后台任务里，需要真实等待）。
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<2_000 where !condition() {
    await pause(milliseconds: 1)
  }
}

/// 睡一小段时间；被取消时提前返回即可。
private func pause(milliseconds: Int) async {
  do {
    try await Task.sleep(for: .milliseconds(milliseconds))
  } catch {
    return
  }
}

@MainActor
private func makeCoordinator(
  store: InMemoryCredentialStore = InMemoryCredentialStore(),
  presenter: RecordingPresenter = RecordingPresenter(),
  clock: TestClock = TestClock()
) -> SSHAuthCoordinator {
  SSHAuthCoordinator(store: store, presenter: presenter, now: { clock.now })
}

private let endpoint = "deploy@10.0.0.5:22"

private func passwordRequest(
  id: String = "a1", attempt: Int = 1, interactive: Bool = true
) -> SSHAuthRequest {
  SSHAuthRequest(
    id: id, endpoint: endpoint, kind: .password,
    prompts: [SSHAuthPrompt(text: "Password:", echo: false)], attempt: attempt,
    interactive: interactive)
}

// MARK: - 口令与 passphrase

/// 第一次尝试命中钥匙串：直接回答，不弹窗。
@MainActor @Test func sshAuthCoordinatorKeychainHitSkipsPrompt() async throws {
  let store = InMemoryCredentialStore()
  try store.setPassword("saved", for: endpoint)
  let presenter = RecordingPresenter()
  let coordinator = makeCoordinator(store: store, presenter: presenter)

  let answer = await coordinator.answer(passwordRequest())

  #expect(answer == .authAnswer(id: "a1", secret: "saved", responses: nil))
  #expect(presenter.secretPrompts.isEmpty)
}

/// 非交互请求且钥匙串里没有：回 secret:nil，不弹窗。
@MainActor @Test func sshAuthCoordinatorNonInteractiveWithoutSavedSecretCancels() async {
  let presenter = RecordingPresenter()
  presenter.secretResponse = SSHSecretPromptResponse(secret: "typed", remember: true)
  let coordinator = makeCoordinator(presenter: presenter)

  let answer = await coordinator.answer(passwordRequest(interactive: false))

  #expect(answer == .authAnswer(id: "a1", secret: nil, responses: nil))
  #expect(presenter.secretPrompts.isEmpty)
}

/// 非交互请求仍然可以用钥匙串作答（后台重连）。
@MainActor @Test func sshAuthCoordinatorNonInteractiveUsesKeychain() async throws {
  let store = InMemoryCredentialStore()
  try store.setPassword("saved", for: endpoint)
  let coordinator = makeCoordinator(store: store)

  let answer = await coordinator.answer(passwordRequest(interactive: false))

  #expect(answer == .authAnswer(id: "a1", secret: "saved", responses: nil))
}

/// 用户勾选记住：broker 接受后写入钥匙串，随后丢掉内存里的秘密。
@MainActor @Test func sshAuthCoordinatorRemembersAcceptedSecret() async throws {
  let store = InMemoryCredentialStore()
  let presenter = RecordingPresenter()
  presenter.secretResponse = SSHSecretPromptResponse(secret: "typed", remember: true)
  let coordinator = makeCoordinator(store: store, presenter: presenter)

  let answer = await coordinator.answer(passwordRequest())
  #expect(answer == .authAnswer(id: "a1", secret: "typed", responses: nil))
  #expect(presenter.secretPrompts == [
    SSHSecretPrompt(subject: .password(endpoint: endpoint), isRetry: false, canRemember: true)
  ])
  // 结果到来之前不写钥匙串。
  #expect(try store.password(for: endpoint) == nil)
  #expect(coordinator.pendingCount == 1)

  await coordinator.settle(id: "a1", accepted: true)?.value

  #expect(try store.password(for: endpoint) == "typed")
  #expect(coordinator.pendingCount == 0)
}

/// 没勾选记住或被拒绝：都不写钥匙串。
@MainActor @Test func sshAuthCoordinatorDoesNotRememberUncheckedOrRejected() async throws {
  let store = InMemoryCredentialStore()
  let presenter = RecordingPresenter()
  let coordinator = makeCoordinator(store: store, presenter: presenter)

  presenter.secretResponse = SSHSecretPromptResponse(secret: "typed", remember: false)
  _ = await coordinator.answer(passwordRequest(id: "a1"))
  #expect(coordinator.settle(id: "a1", accepted: true) == nil)

  presenter.secretResponse = SSHSecretPromptResponse(secret: "wrong", remember: true)
  _ = await coordinator.answer(passwordRequest(id: "a2"))
  #expect(coordinator.settle(id: "a2", accepted: false) == nil)

  #expect(store.count == 0)
  #expect(coordinator.pendingCount == 0)
}

/// 来自钥匙串的秘密被拒：删除该条目；下一次尝试弹窗并提示重试。
@MainActor @Test func sshAuthCoordinatorDeletesRejectedKeychainSecret() async throws {
  let store = InMemoryCredentialStore()
  try store.setPassword("stale", for: endpoint)
  let presenter = RecordingPresenter()
  presenter.secretResponse = SSHSecretPromptResponse(secret: "fresh", remember: true)
  let coordinator = makeCoordinator(store: store, presenter: presenter)

  _ = await coordinator.answer(passwordRequest(id: "a1"))
  await coordinator.settle(id: "a1", accepted: false)?.value
  #expect(try store.password(for: endpoint) == nil)

  let retry = await coordinator.answer(passwordRequest(id: "a2", attempt: 2))
  #expect(retry == .authAnswer(id: "a2", secret: "fresh", responses: nil))
  #expect(presenter.secretPrompts.last?.isRetry == true)
  await coordinator.settle(id: "a2", accepted: true)?.value
  #expect(try store.password(for: endpoint) == "fresh")
}

/// 第二次及以后的尝试不再查钥匙串，避免反复提交同一个错误口令。
@MainActor @Test func sshAuthCoordinatorRetryIgnoresKeychain() async throws {
  let store = InMemoryCredentialStore()
  try store.setPassword("saved", for: endpoint)
  let presenter = RecordingPresenter()
  presenter.secretResponse = SSHSecretPromptResponse(secret: "typed", remember: false)
  let coordinator = makeCoordinator(store: store, presenter: presenter)

  let answer = await coordinator.answer(passwordRequest(attempt: 2))

  #expect(answer == .authAnswer(id: "a1", secret: "typed", responses: nil))
  #expect(presenter.secretPrompts.count == 1)
}

/// passphrase 按 keyDigest 存取；缺少 digest 时不能记住。
@MainActor @Test func sshAuthCoordinatorPassphraseUsesKeyDigest() async throws {
  let store = InMemoryCredentialStore()
  let presenter = RecordingPresenter()
  presenter.secretResponse = SSHSecretPromptResponse(secret: "pp", remember: true)
  let coordinator = makeCoordinator(store: store, presenter: presenter)

  let withDigest = SSHAuthRequest(
    id: "p1", endpoint: endpoint, kind: .passphrase, keyFile: "/Users/me/.ssh/id_ed25519",
    keyDigest: "abc123")
  _ = await coordinator.answer(withDigest)
  await coordinator.settle(id: "p1", accepted: true)?.value
  #expect(try store.passphrase(forKeyDigest: "abc123") == "pp")
  #expect(presenter.secretPrompts.first?.subject == .passphrase(keyFile: "/Users/me/.ssh/id_ed25519"))

  let withoutDigest = SSHAuthRequest(id: "p2", endpoint: endpoint, kind: .passphrase)
  let answer = await coordinator.answer(withoutDigest)
  #expect(answer == .authAnswer(id: "p2", secret: "pp", responses: nil))
  #expect(presenter.secretPrompts.last?.canRemember == false)
  #expect(coordinator.settle(id: "p2", accepted: true) == nil)
}

/// 用户取消：回 secret:nil。
@MainActor @Test func sshAuthCoordinatorCancelledPromptAnswersNil() async {
  let presenter = RecordingPresenter()
  presenter.secretResponse = nil
  let coordinator = makeCoordinator(presenter: presenter)

  let answer = await coordinator.answer(passwordRequest())

  #expect(answer == .authAnswer(id: "a1", secret: nil, responses: nil))
  #expect(coordinator.pendingCount == 0)
}

/// 挂起的秘密超过 60 秒就丢弃，迟到的 auth.result 不会再写钥匙串。
@MainActor @Test func sshAuthCoordinatorExpiresPendingSecrets() async throws {
  let store = InMemoryCredentialStore()
  let presenter = RecordingPresenter()
  presenter.secretResponse = SSHSecretPromptResponse(secret: "typed", remember: true)
  let clock = TestClock()
  let coordinator = makeCoordinator(store: store, presenter: presenter, clock: clock)

  _ = await coordinator.answer(passwordRequest())
  clock.now += SSHAuthCoordinator.pendingSecretLifetime + 1

  #expect(coordinator.settle(id: "a1", accepted: true) == nil)
  #expect(store.count == 0)
}

// MARK: - 键盘交互

/// 键盘交互的回答按 prompts 返回，且不写钥匙串。
@MainActor @Test func sshAuthCoordinatorKeyboardInteractiveNeverStored() async {
  let store = InMemoryCredentialStore()
  let presenter = RecordingPresenter()
  presenter.keyboardResponses = ["123456", "yes"]
  let coordinator = makeCoordinator(store: store, presenter: presenter)
  let request = SSHAuthRequest(
    id: "k1", endpoint: endpoint, kind: .keyboardInteractive, name: "2FA",
    instruction: "Enter code",
    prompts: [SSHAuthPrompt(text: "Code:", echo: false), SSHAuthPrompt(text: "Trust?", echo: true)])

  let answer = await coordinator.answer(request)

  #expect(answer == .authAnswer(id: "k1", secret: nil, responses: ["123456", "yes"]))
  #expect(presenter.keyboardPrompts.first?.prompts == request.prompts)
  #expect(coordinator.settle(id: "k1", accepted: true) == nil)
  #expect(store.count == 0)
}

/// 键盘交互：非交互请求取消；没有提示项时直接回空数组。
@MainActor @Test func sshAuthCoordinatorKeyboardInteractiveEdgeCases() async {
  let presenter = RecordingPresenter()
  presenter.keyboardResponses = ["x"]
  let coordinator = makeCoordinator(presenter: presenter)
  let prompts = [SSHAuthPrompt(text: "Code:", echo: false)]

  let background = await coordinator.answer(
    SSHAuthRequest(
      id: "k1", endpoint: endpoint, kind: .keyboardInteractive, prompts: prompts,
      interactive: false))
  #expect(background == .authAnswer(id: "k1", secret: nil, responses: nil))

  let empty = await coordinator.answer(
    SSHAuthRequest(id: "k2", endpoint: endpoint, kind: .keyboardInteractive, prompts: []))
  #expect(empty == .authAnswer(id: "k2", secret: nil, responses: []))
  #expect(presenter.keyboardPrompts.isEmpty)
}

// MARK: - 排队

/// 两个请求同时到达：一次只开一个弹窗，第二个等第一个关闭后才出现。
@MainActor @Test func sshAuthCoordinatorSerializesConcurrentPrompts() async {
  let presenter = RecordingPresenter()
  presenter.holdsPrompts = true
  presenter.secretResponse = SSHSecretPromptResponse(secret: "typed", remember: false)
  let coordinator = makeCoordinator(presenter: presenter)

  let first = Task { await coordinator.answer(passwordRequest(id: "a1")) }
  let second = Task {
    await coordinator.answer(
      SSHAuthRequest(id: "a2", endpoint: "ops@10.0.0.6:22", kind: .password))
  }
  await waitUntil { presenter.heldCount == 1 }
  // 多等一会儿，让第二个请求走完钥匙串查询、进入排队。
  await pause(milliseconds: 100)
  #expect(presenter.secretPrompts.count == 1)

  presenter.releaseOne()
  #expect(await first.value == .authAnswer(id: "a1", secret: "typed", responses: nil))
  await waitUntil { presenter.heldCount == 1 }
  #expect(presenter.secretPrompts.count == 2)
  presenter.releaseOne()
  #expect(await second.value == .authAnswer(id: "a2", secret: "typed", responses: nil))
  #expect(presenter.maximumOpenCount == 1)
}

// MARK: - 主机密钥

/// 非交互的主机密钥请求一律拒绝，不弹窗。
@MainActor @Test func sshAuthCoordinatorRejectsNonInteractiveHostKey() async {
  let presenter = RecordingPresenter()
  presenter.hostKeyAccepts = true
  let coordinator = makeCoordinator(presenter: presenter)
  let request = SSHHostKeyRequest(
    id: "h1", endpoint: "10.0.0.5:22", algorithm: "ssh-ed25519", fingerprint: "SHA256:abc",
    status: .unknown, interactive: false)

  #expect(await coordinator.confirmHostKey(request) == .hostKeyAnswer(id: "h1", accept: false))
  #expect(presenter.hostKeyRequests.isEmpty)
}

/// 交互的主机密钥请求交给弹窗决定。
@MainActor @Test func sshAuthCoordinatorForwardsInteractiveHostKey() async {
  let presenter = RecordingPresenter()
  presenter.hostKeyAccepts = true
  let coordinator = makeCoordinator(presenter: presenter)
  let request = SSHHostKeyRequest(
    id: "h2", endpoint: "10.0.0.5:22", algorithm: "ssh-ed25519", fingerprint: "SHA256:abc",
    status: .changed)

  #expect(await coordinator.confirmHostKey(request) == .hostKeyAnswer(id: "h2", accept: true))
  #expect(presenter.hostKeyRequests == [request])
}

/// 密钥变更确认词：只接受 yes（忽略首尾空白）。
@MainActor @Test func sshAuthCoordinatorHostKeyConfirmationWord() {
  #expect(SSHHostKeySheet.isConfirmation("yes"))
  #expect(SSHHostKeySheet.isConfirmation(" yes\n"))
  #expect(!SSHHostKeySheet.isConfirmation("YES"))
  #expect(!SSHHostKeySheet.isConfirmation("y"))
  #expect(!SSHHostKeySheet.isConfirmation(""))
}

// MARK: - 设置页辅助

/// 设置页：查询与忘记口令；忘记后迟到的 auth.result 不会把口令写回去。
@MainActor @Test func sshAuthCoordinatorForgetPassword() async throws {
  let store = InMemoryCredentialStore()
  let presenter = RecordingPresenter()
  presenter.secretResponse = SSHSecretPromptResponse(secret: "typed", remember: true)
  let coordinator = makeCoordinator(store: store, presenter: presenter)
  try store.setPassword("old", for: endpoint)
  #expect(coordinator.hasSavedPassword(endpoint: endpoint))

  _ = await coordinator.answer(passwordRequest(attempt: 2))
  try coordinator.forgetPassword(endpoint: endpoint)

  #expect(!coordinator.hasSavedPassword(endpoint: endpoint))
  #expect(coordinator.settle(id: "a1", accepted: true) == nil)
  #expect(try store.password(for: endpoint) == nil)
}
