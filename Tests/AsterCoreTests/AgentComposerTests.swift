import Foundation
import Testing

@testable import AsterCore

@Test func composerCancelAndDockPreserveDraftAttachmentsAndPinPreference() throws {
  var composer = AgentComposerState()
  composer.updateDraft("Investigate the screenshot")
  try composer.addAttachment(
    AgentAttachmentCandidate(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      fileURL: URL(fileURLWithPath: "/tmp/screenshot.png"),
      displayName: "screenshot.png",
      byteCount: 1_024,
      isRegularFile: true
    )
  )
  composer.setPinned(true)
  composer.float()
  composer.cancel()

  #expect(composer.draft == "Investigate the screenshot")
  #expect(composer.attachments.count == 1)
  #expect(composer.isPinned)
  #expect(composer.presentation == .docked)
}

@Test func composerSendReturnsSubmissionThenClearsAndDocksState() throws {
  var composer = AgentComposerState(draft: "Ship it")
  composer.float()

  let submission = try composer.send()

  #expect(submission.text == "Ship it")
  #expect(submission.attachments.isEmpty)
  #expect(composer.draft.isEmpty)
  #expect(composer.attachments.isEmpty)
  #expect(composer.presentation == .docked)
  #expect(throws: AgentComposerError.emptySubmission) {
    try composer.send()
  }
}

@Test func composerRejectsUnsafeOrOversizedAttachmentsBeforeStateMutation() {
  var composer = AgentComposerState(
    limits: AgentComposerLimits(
      maximumDraftBytes: 100,
      maximumAttachments: 2,
      maximumAttachmentBytes: 10,
      maximumTotalAttachmentBytes: 15
    )
  )

  #expect(throws: AgentComposerError.attachmentNotRegularFile) {
    try composer.addAttachment(
      AgentAttachmentCandidate(
        fileURL: URL(fileURLWithPath: "/tmp/pipe"),
        displayName: "pipe",
        byteCount: 1,
        isRegularFile: false
      )
    )
  }
  #expect(throws: AgentComposerError.attachmentTooLarge(maximumBytes: 10)) {
    try composer.addAttachment(
      AgentAttachmentCandidate(
        fileURL: URL(fileURLWithPath: "/tmp/large.png"),
        displayName: "large.png",
        byteCount: 11,
        isRegularFile: true
      )
    )
  }
  #expect(composer.attachments.isEmpty)
}

@Test func composerRoutesEachNonBlankLineToTheQueueAndOnlyThenClearsDraft() throws {
  var composer = AgentComposerState(draft: " build\n\n test \n   \ncommit")

  let prompts = try composer.takeQueuePrompts()

  #expect(prompts == ["build", "test", "commit"])
  #expect(composer.draft.isEmpty)
}
