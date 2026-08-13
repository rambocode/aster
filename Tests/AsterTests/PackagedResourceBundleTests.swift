import Foundation
import Testing

@testable import Aster
@testable import Highlighter

@Test("发布包资源不得触发 SwiftPM 的构建机绝对路径回退")
func packagedResourcesAvoidFatalSwiftPMBundleAccessor() throws {
  let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let ghosttyApp = try String(
    contentsOf: repository.appendingPathComponent("Sources/Aster/Ghostty/GhosttyApp.swift"),
    encoding: .utf8
  )
  let highlighter = try String(
    contentsOf: repository.appendingPathComponent(
      "Vendor/HighlighterSwift/Sources/Highlighter/Highlighter.swift"),
    encoding: .utf8
  )

  // SwiftPM 为 executable target 生成的 `Bundle.module` 只检查 App 根目录和
  // 构建机绝对路径；DMG 中的标准 `Contents/Resources` 布局因此会在新电脑 fatalError。
  #expect(!ghosttyApp.contains("Bundle.module.resourceURL"))
  #expect(!highlighter.contains("let bundle = Bundle.module"))
}

@Test("发布 App 优先从 Contents/Resources 定位 SwiftPM Bundle")
func packagedResourceCandidatesPreferStandardAppResources() {
  let app = URL(fileURLWithPath: "/Applications/Aster.app", isDirectory: true)
  let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
  let testBundle = URL(
    fileURLWithPath: "/tmp/build/AsterTerminalPackageTests.xctest", isDirectory: true)

  let asterCandidates = PackagedResourceBundle.candidateURLs(
    named: "AsterTerminal_Aster.bundle",
    mainBundleURL: app,
    mainResourceURL: resources,
    testBundleURL: testBundle
  )
  let highlighterCandidates = HighlighterResourceBundle.candidateURLs(
    mainBundleURL: app,
    mainResourceURL: resources,
    testBundleURL: testBundle
  )

  #expect(
    asterCandidates.first?.path
      == "/Applications/Aster.app/Contents/Resources/AsterTerminal_Aster.bundle")
  #expect(
    highlighterCandidates.first?.path
      == "/Applications/Aster.app/Contents/Resources/Highlighter_Highlighter.bundle")
  #expect(
    asterCandidates.last?.path == "/tmp/build/AsterTerminal_Aster.bundle")
  #expect(
    highlighterCandidates.last?.path == "/tmp/build/Highlighter_Highlighter.bundle")
}
