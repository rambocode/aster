import Foundation
import Testing
@testable import AsterCore

@Test func oscNineProgressParsesEverySupportedStateWithoutTreatingPauseAsProgress() {
  #expect(TerminalProgressParser.parseOSC9("4;0") == .clear)
  #expect(TerminalProgressParser.parseOSC9("4;1;40") == .determinate(percent: 40))
  #expect(TerminalProgressParser.parseOSC9("4;1;140") == .determinate(percent: 100))
  #expect(TerminalProgressParser.parseOSC9("4;2") == .error(percent: nil))
  #expect(TerminalProgressParser.parseOSC9("4;2;-20") == .error(percent: 0))
  #expect(TerminalProgressParser.parseOSC9("4;3") == .indeterminate)
  #expect(TerminalProgressParser.parseOSC9("4;4;50") == nil)
  #expect(TerminalProgressParser.parseOSC9("4;5;0;watch") == .finished(exitCode: 0, watched: true))
  #expect(TerminalProgressParser.parseOSC9("4;5;9") == .finished(exitCode: 9, watched: false))
  #expect(
    TerminalProgressParser.parseOSC9("4;5;0;watch;quiet")
      == .finished(exitCode: 0, watched: true, notificationSuppressed: true)
  )
  #expect(TerminalProgressParser.parseOSC9("4;1;invalid") == nil)
  #expect(TerminalProgressParser.parseOSC9("4;2;invalid") == nil)
  #expect(TerminalProgressParser.parseOSC9("Build finished") == nil)
}

@Test func directBadgeProtocolAcceptsOnlyDocumentedKinds() {
  #expect(TerminalBadgeDirective(payload: "Badge=running") == .set(.running(percent: nil)))
  #expect(TerminalBadgeDirective(payload: "Badge=completed") == .set(.completed))
  #expect(TerminalBadgeDirective(payload: "Badge=unread") == .set(.finished))
  #expect(TerminalBadgeDirective(payload: "Badge=awaiting-input") == .set(.awaitingInput))
  #expect(TerminalBadgeDirective(payload: "Badge=clear") == .clear)
  #expect(TerminalBadgeDirective(payload: "Badge=sudo") == nil)
}

@Test func automaticProgressMatchesWhitespaceDelimitedPrefixesOnly() {
  let matcher = AutomaticProgressMatcher(prefixes: ["git push", "curl", "npm install"])

  #expect(matcher.matches(" git   push origin main "))
  #expect(matcher.matches("curl https://example.com"))
  #expect(matcher.matches("npm install"))
  #expect(!matcher.matches("git status"))
  #expect(!matcher.matches("git pushd origin"))
  #expect(!AutomaticProgressMatcher(prefixes: []).matches("curl example.com"))
}

@Test func awaitingInputRequiresAnInteractivePromptAtTheOutputTail() {
  #expect(AwaitingInputPromptDetector.matches("Continue? [y/N] "))
  #expect(AwaitingInputPromptDetector.matches("Password:"))
  #expect(AwaitingInputPromptDetector.matches("Press ENTER to continue"))
  #expect(AwaitingInputPromptDetector.matches("Do you want to proceed (yes/no)?"))
  #expect(!AwaitingInputPromptDetector.matches("Continue? [y/N]\nDownloading package"))
  #expect(!AwaitingInputPromptDetector.matches("the documentation says Password: is a prompt\n$ "))
}

@Test func legacyNotificationProtocolsAreBoundedAndSanitized() {
  #expect(
    TerminalNotificationParser.parseOSC9("Build\u{1B}[31m finished")
      == TerminalNotification(title: "Aster", body: "Build[31m finished", urgency: .normal)
  )
  #expect(
    TerminalNotificationParser.parseOSC777("notify;Deploy;Production;is live")
      == TerminalNotification(title: "Deploy", body: "Production;is live", urgency: .normal)
  )
  #expect(TerminalNotificationParser.parseOSC777("broken;Deploy;Done") == nil)
  #expect(TerminalNotificationParser.parseOSC9(String(repeating: "x", count: 8_193)) == nil)
}

@Test func kittyNotificationReassemblesChunksAndPreservesReplacementIdentifier() {
  var assembler = KittyNotificationAssembler()

  #expect(assembler.consume("i=42:p=title:d=0;Build finished") == nil)
  #expect(
    assembler.consume("i=42:p=body;42 files compiled")
      == .notification(
        TerminalNotification(
          identifier: "42",
          title: "Build finished",
          body: "42 files compiled",
          urgency: .normal
        )
      )
  )

  let encoded = Data("Compile failed".utf8).base64EncodedString()
  #expect(
    assembler.consume("i=err:u=2:e=1;\(encoded)")
      == .notification(
        TerminalNotification(
          identifier: "err",
          title: "Compile failed",
          body: "",
          urgency: .critical
        )
      )
  )
}

@Test func kittyNotificationSupportsCapabilityQueriesAndRejectsOversizedOrInvalidChunks() {
  var assembler = KittyNotificationAssembler()

  #expect(
    assembler.consume("i=ping:p=?;")
      == .response("\u{1B}]99;i=ping:p=?;ok\u{1B}\\")
  )
  #expect(assembler.consume("i=large;\(String(repeating: "x", count: 8_193))") == nil)
  #expect(assembler.consume("i=bad:e=1;not base64!") == nil)
  #expect(assembler.pendingNotificationCount == 0)
}

@Test func kittyNotificationBoundsConcurrentIncompleteMessages() {
  var assembler = KittyNotificationAssembler()

  for index in 0..<KittyNotificationAssembler.maximumPendingNotifications {
    #expect(assembler.consume("i=\(index):d=0;x") == nil)
  }
  #expect(
    assembler.pendingNotificationCount == KittyNotificationAssembler.maximumPendingNotifications
  )

  #expect(assembler.consume("i=overflow:d=0;x") == nil)
  #expect(
    assembler.pendingNotificationCount == KittyNotificationAssembler.maximumPendingNotifications
  )
  #expect(
    assembler.consume("i=0;done")
      == .notification(
        TerminalNotification(identifier: "0", title: "xdone", body: "", urgency: .normal)
      )
  )
}

@Test func notificationDeliveryHonorsForegroundBounceAndSoundPolicy() {
  let policy = TerminalNotificationPolicy(
    shellControlled: true,
    foregroundPolicy: .tabUnfocused,
    bounceDockIcon: true,
    soundCategories: [.errorExit, .application]
  )

  #expect(
    policy.decision(category: .application, applicationIsActive: true, sourceTabIsFocused: true)
      == nil
  )
  #expect(
    policy.decision(category: .application, applicationIsActive: true, sourceTabIsFocused: false)
      == NotificationDeliveryDecision(playsSound: true, bouncesDockIcon: false)
  )
  #expect(
    policy.decision(category: .errorExit, applicationIsActive: false, sourceTabIsFocused: true)
      == NotificationDeliveryDecision(playsSound: true, bouncesDockIcon: true)
  )

  let blocked = TerminalNotificationPolicy(shellControlled: false)
  #expect(
    blocked.decision(category: .application, applicationIsActive: false, sourceTabIsFocused: false)
      == nil
  )
  #expect(
    blocked.decision(category: .commandFinish, applicationIsActive: false, sourceTabIsFocused: false)
      != nil
  )
}

@Test func badgeResolutionUsesSafetyFirstPriority() {
  #expect(
    TerminalBadgeResolver.resolve(
      progress: .determinate(percent: 80), awaitingInput: true, lastExitCode: 0
    ) == .awaitingInput
  )
  #expect(
    TerminalBadgeResolver.resolve(
      progress: .error(percent: 75), awaitingInput: true, lastExitCode: 0
    ) == .error
  )
  #expect(
    TerminalBadgeResolver.resolve(progress: .clear, awaitingInput: false, lastExitCode: 0)
      == .finished
  )
  #expect(
    TerminalBadgeResolver.resolve(progress: .clear, awaitingInput: false, lastExitCode: 7)
      == .error
  )
}

@Test func dockActivityAggregatesAcrossTabsAndHonorsAppearanceToggles() {
  #expect(
    DockActivityResolver.resolve(
      badges: [.running(percent: 20), .finished], animateOnProgress: true, redOnError: true
    ) == .working
  )
  #expect(
    DockActivityResolver.resolve(
      badges: [.running(percent: nil), .error], animateOnProgress: true, redOnError: true
    ) == .error
  )
  #expect(
    DockActivityResolver.resolve(
      badges: [.running(percent: nil), .error], animateOnProgress: false, redOnError: false
    ) == .idle
  )
}
