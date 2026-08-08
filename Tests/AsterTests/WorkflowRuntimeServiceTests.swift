import Foundation
import Testing

@testable import Aster

@Test("CLI send-text 精确解码 C-style 控制字节")
func workflowCLIInputDecoderHandlesDocumentedEscapes() throws {
  #expect(
    try WorkflowCLIInputDecoder.decode(#"git status\n\x03\\"#)
      == Array("git status".utf8) + [10, 3, 92]
  )
  #expect(throws: WorkflowCLIInputDecodeError.invalidEscape) {
    try WorkflowCLIInputDecoder.decode(#"\q"#)
  }
  #expect(throws: WorkflowCLIInputDecodeError.invalidEscape) {
    try WorkflowCLIInputDecoder.decode(#"\x0"#)
  }
}

@Test("CLI argv 的 shell 编码不能被参数内容改变命令结构")
func workflowShellCommandEncoderQuotesEveryArgument() {
  #expect(
    WorkflowShellCommandEncoder.encode(["printf", "%s", "a'; touch /tmp/pwn; '"])
      == "'printf' '%s' 'a'\\''; touch /tmp/pwn; '\\'''"
  )
  #expect(WorkflowShellCommandEncoder.encode(["", "two words"]) == "'' 'two words'")
}

@Test("CLI 传输保持 stdout 与 stderr 分离并把超限结果转为确定失败")
func workflowCLITransportResponseEncoderPreservesStreamsAndBounds() {
  let response = WorkflowCLITransportResponseEncoder.encode(.init(
    exitCode: 7,
    standardOutput: "stdout\n",
    standardError: "stderr\n"
  ))
  #expect(response.exitCode == 7)
  #expect(response.standardOutput == Data("stdout\n".utf8))
  #expect(response.standardError == Data("stderr\n".utf8))

  let oversized = WorkflowCLITransportResponseEncoder.encode(.success(
    String(repeating: "x", count: AsterCLIRequestService.maximumResponseStreamBytes + 1)
  ))
  #expect(oversized.exitCode == 74)
  #expect(oversized.standardOutput.isEmpty)
  #expect(String(decoding: oversized.standardError, as: UTF8.self).contains("size limit"))
}

@Test("CLI exec 输出读取区分空文件、读取失败与超限文件")
func workflowCLIOutputReaderRejectsOversizedFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-cli-output-reader-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }

  let empty = root.appendingPathComponent("empty")
  try Data().write(to: empty)
  #expect(try WorkflowCLIOutputReader.read(empty, maximumBytes: 4) == "")

  let oversized = root.appendingPathComponent("oversized")
  try Data("12345".utf8).write(to: oversized)
  #expect(throws: WorkflowCLIOutputReadError.outputTooLarge(maximumBytes: 4)) {
    try WorkflowCLIOutputReader.read(oversized, maximumBytes: 4)
  }
  #expect(throws: WorkflowCLIOutputReadError.invalidOutputFile) {
    try WorkflowCLIOutputReader.read(root.appendingPathComponent("missing"), maximumBytes: 4)
  }
}

@Test("Recipe 命令审查文本完整展示全部命令并标明总数")
func workflowRecipeReviewTextDoesNotHideCommandsAfterTwenty() {
  let commands = (1...128).map { "command-\($0)" }
  let text = WorkflowRecipeCommandReview.text(commands: commands)

  #expect(text.contains("共 128 条命令"))
  #expect(text.contains("20. command-20"))
  #expect(text.contains("21. command-21"))
  #expect(text.contains("128. command-128"))
}

@Test("AppModel 使用同步后的 Recipe 重放设置")
@MainActor
func appModelBuildsRecipeReplaySettingsFromConfiguration() {
  let model = AppModel(defaults: UserDefaults(suiteName: "AsterRecipeModeTests.\(UUID().uuidString)")!)
  model.recipeReplayMode = .skip

  #expect(model.workflowRecipeReplaySettings.recipeFiles == .skip)
  #expect(model.workflowRecipeReplaySettings.savedRecipes == .automatic)
}

@Test("Recipe 逐条确认计划不会退化为一次性批量授权")
func workflowRecipeReplayExecutionPolicyPreservesOneByOneMode() {
  #expect(WorkflowRecipeReplayExecutionPolicy.confirmsEveryCommand(.oneByOne(commands: ["a"])))
  #expect(!WorkflowRecipeReplayExecutionPolicy.confirmsEveryCommand(.confirmOnce(batches: [["a"]])))
  #expect(!WorkflowRecipeReplayExecutionPolicy.confirmsEveryCommand(.automatic(batches: [["a"]])))
}
