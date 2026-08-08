import Foundation

public struct AgentComposerLimits: Equatable, Sendable {
  public static let `default` = AgentComposerLimits()

  public let maximumDraftBytes: Int
  public let maximumAttachments: Int
  public let maximumAttachmentBytes: Int
  public let maximumTotalAttachmentBytes: Int

  public init(
    maximumDraftBytes: Int = 256 * 1_024,
    maximumAttachments: Int = 16,
    maximumAttachmentBytes: Int = 10 * 1_024 * 1_024,
    maximumTotalAttachmentBytes: Int = 32 * 1_024 * 1_024
  ) {
    self.maximumDraftBytes = max(maximumDraftBytes, 1)
    self.maximumAttachments = max(maximumAttachments, 1)
    self.maximumAttachmentBytes = max(maximumAttachmentBytes, 1)
    self.maximumTotalAttachmentBytes = max(maximumTotalAttachmentBytes, 1)
  }
}

/// 文件元数据由安全的文件访问层采集。Composer 只接受明确确认是普通文件的候选项，
/// 从领域边界阻止 FIFO、设备文件和目录进入后续上传/读取流程。
public struct AgentAttachmentCandidate: Equatable, Sendable {
  public let id: UUID
  public let fileURL: URL
  public let displayName: String
  public let byteCount: Int
  public let isRegularFile: Bool

  public init(
    id: UUID = UUID(),
    fileURL: URL,
    displayName: String,
    byteCount: Int,
    isRegularFile: Bool
  ) {
    self.id = id
    self.fileURL = fileURL
    self.displayName = displayName
    self.byteCount = byteCount
    self.isRegularFile = isRegularFile
  }
}

/// 已通过普通文件、名称和大小校验的附件引用；真正读取仍应在发送时重新核验文件类型
/// 与大小，以防候选检查和读取之间发生替换。
public struct AgentComposerAttachment: Equatable, Sendable {
  public let id: UUID
  public let fileURL: URL
  public let displayName: String
  public let byteCount: Int
}

public enum AgentComposerPresentation: Equatable, Sendable {
  case docked
  case floating
}

public struct AgentComposerSubmission: Equatable, Sendable {
  public let text: String
  public let attachments: [AgentComposerAttachment]
}

public enum AgentComposerError: Error, Equatable {
  case emptySubmission
  case attachmentNotFileURL
  case attachmentNotRegularFile
  case invalidAttachmentSize
  case invalidAttachmentName
  case attachmentTooLarge(maximumBytes: Int)
  case tooManyAttachments(maximum: Int)
  case totalAttachmentBytesExceeded(maximumBytes: Int)
  case attachmentsCannotBeQueued
}

/// Composer 的纯领域状态。Pin 是跨 tab 偏好，Float 是临时呈现状态；draft 与附件
/// 独立于两者，因此切换 tab、关闭浮层或误按 Escape 都不会丢失输入。
public struct AgentComposerState: Equatable, Sendable {
  public private(set) var draft: String
  public private(set) var attachments: [AgentComposerAttachment]
  public private(set) var isPinned: Bool
  public private(set) var presentation: AgentComposerPresentation
  public let limits: AgentComposerLimits

  public init(
    draft: String = "",
    attachments: [AgentComposerAttachment] = [],
    isPinned: Bool = false,
    presentation: AgentComposerPresentation = .docked,
    limits: AgentComposerLimits = .default
  ) {
    self.limits = limits
    self.draft = boundedUTF8(draft, maximumBytes: limits.maximumDraftBytes).value
    self.attachments = Array(attachments.prefix(limits.maximumAttachments))
    self.isPinned = isPinned
    self.presentation = presentation
  }

  /// 超限草稿保持原值并返回 false，使输入层可以给用户反馈，而不是静默丢掉末尾内容。
  @discardableResult
  public mutating func updateDraft(_ value: String) -> Bool {
    guard value.utf8.count <= limits.maximumDraftBytes else { return false }
    draft = value
    return true
  }

  public mutating func addAttachment(_ candidate: AgentAttachmentCandidate) throws {
    guard candidate.fileURL.isFileURL else { throw AgentComposerError.attachmentNotFileURL }
    guard candidate.isRegularFile else { throw AgentComposerError.attachmentNotRegularFile }
    guard candidate.byteCount >= 0 else { throw AgentComposerError.invalidAttachmentSize }
    guard !candidate.displayName.isEmpty,
      candidate.displayName.utf8.count <= 255,
      !candidate.displayName.contains("\0")
    else { throw AgentComposerError.invalidAttachmentName }
    guard candidate.byteCount <= limits.maximumAttachmentBytes else {
      throw AgentComposerError.attachmentTooLarge(maximumBytes: limits.maximumAttachmentBytes)
    }
    guard attachments.count < limits.maximumAttachments else {
      throw AgentComposerError.tooManyAttachments(maximum: limits.maximumAttachments)
    }
    let currentBytes = attachments.reduce(0) { $0 + $1.byteCount }
    guard currentBytes <= limits.maximumTotalAttachmentBytes - candidate.byteCount else {
      throw AgentComposerError.totalAttachmentBytesExceeded(
        maximumBytes: limits.maximumTotalAttachmentBytes
      )
    }
    attachments.append(
      AgentComposerAttachment(
        id: candidate.id,
        fileURL: candidate.fileURL,
        displayName: candidate.displayName,
        byteCount: candidate.byteCount
      )
    )
  }

  @discardableResult
  public mutating func removeAttachment(id: UUID) -> AgentComposerAttachment? {
    guard let index = attachments.firstIndex(where: { $0.id == id }) else { return nil }
    return attachments.remove(at: index)
  }

  public mutating func setPinned(_ value: Bool) {
    isPinned = value
  }

  public mutating func float() {
    presentation = .floating
  }

  /// Cancel/关闭浮层只回到 pane，不清空 draft 或附件。
  public mutating func cancel() {
    presentation = .docked
  }

  public mutating func send() throws -> AgentComposerSubmission {
    guard
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.isEmpty
    else { throw AgentComposerError.emptySubmission }

    let submission = AgentComposerSubmission(text: draft, attachments: attachments)
    draft = ""
    attachments.removeAll(keepingCapacity: true)
    presentation = .docked
    return submission
  }

  /// Queue 的官方语义是“每个非空行成为一个 prompt”。附件不能无损映射到多行队列，
  /// 因而有附件时拒绝操作并完整保留 Composer 状态。
  public mutating func takeQueuePrompts() throws -> [String] {
    guard attachments.isEmpty else { throw AgentComposerError.attachmentsCannotBeQueued }
    let prompts = draft.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !prompts.isEmpty else { throw AgentComposerError.emptySubmission }
    draft = ""
    presentation = .docked
    return prompts
  }
}
