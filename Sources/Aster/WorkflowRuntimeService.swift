import AsterCore
import Foundation

/// CLI 请求的统一结果。同步动作立即返回；`pane run/exec` 在 Shell Integration 报告
/// 完成后再调用请求层写回，因此不会用轮询屏幕文本猜测退出状态。
struct WorkflowCLIExecutionResponse: Equatable {
  let exitCode: Int32
  let standardOutput: String
  let standardError: String

  /// 保留统一文本视图，供状态提示或日志使用；传输层仍必须分别写回 stdout/stderr。
  var output: String { standardOutput + standardError }

  init(exitCode: Int32, output: String) {
    self.init(exitCode: exitCode, standardOutput: output, standardError: "")
  }

  init(exitCode: Int32, standardOutput: String, standardError: String) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  static func success(_ output: String = "") -> Self {
    Self(exitCode: 0, standardOutput: output, standardError: "")
  }

  static func failure(_ output: String, exitCode: Int32 = 1) -> Self {
    Self(exitCode: exitCode, standardOutput: "", standardError: output)
  }
}

/// 把业务执行结果转换为 CLI 文件协议响应。编码前执行字节级上限，避免一个过大的
/// Pane 快照导致 `respond` 抛错后调用方只能等待超时；超限时返回确定的 EX_IOERR。
enum WorkflowCLITransportResponseEncoder {
  static func encode(_ result: WorkflowCLIExecutionResponse) -> AsterCLIResponse {
    let standardOutput = Data(result.standardOutput.utf8)
    let standardError = Data(result.standardError.utf8)
    guard standardOutput.count <= AsterCLIRequestService.maximumResponseStreamBytes,
      standardError.count <= AsterCLIRequestService.maximumResponseStreamBytes
    else {
      return AsterCLIResponse(
        standardOutput: Data(),
        standardError: Data("aster: CLI response exceeds size limit\n".utf8),
        exitCode: 74
      )
    }
    return AsterCLIResponse(
      standardOutput: standardOutput,
      standardError: standardError,
      exitCode: result.exitCode
    )
  }
}

enum WorkflowCLIInputDecodeError: Error, Equatable {
  case invalidEscape
  case outputTooLarge
}

enum WorkflowCLIOutputReadError: Error, Equatable, LocalizedError {
  case invalidOutputFile
  case outputTooLarge(maximumBytes: Int)

  var errorDescription: String? {
    switch self {
    case .invalidOutputFile:
      "CLI 输出缓冲不存在、不是普通文件或读取期间发生变化。"
    case .outputTooLarge(let maximumBytes):
      "CLI 输出超过大小上限（\(maximumBytes) bytes）。"
    }
  }
}

/// 读取 `pane exec` 的临时输出文件。空文件是合法输出；缺失、符号链接、读取竞态和
/// 超限必须是显式错误，不能静默伪装成成功命令的空 stdout/stderr。
enum WorkflowCLIOutputReader {
  static func read(_ url: URL, maximumBytes: Int) throws -> String {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
    } catch {
      throw WorkflowCLIOutputReadError.invalidOutputFile
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize
    else { throw WorkflowCLIOutputReadError.invalidOutputFile }
    guard size <= maximumBytes else {
      throw WorkflowCLIOutputReadError.outputTooLarge(maximumBytes: maximumBytes)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
      throw WorkflowCLIOutputReadError.invalidOutputFile
    }
    guard data.count == size else { throw WorkflowCLIOutputReadError.invalidOutputFile }
    return String(decoding: data, as: UTF8.self)
  }
}

/// 把领域 Replay 计划投影为执行层授权粒度，防止 `.oneByOne` 在 UI 层被合并成一次
/// 批量确认。命令内容和队列仍由领域计划提供，此处不重新解释 shell 文本。
enum WorkflowRecipeReplayExecutionPolicy {
  static func confirmsEveryCommand(_ plan: WorkflowRecipeReplayPlan) -> Bool {
    if case .oneByOne = plan { return true }
    return false
  }
}

/// `pane send-text` 的 C-style escape 解码器。只支持文档承诺的常见字节转义，并在
/// 生成过程中执行硬上限；未知、截断或非字节 `\x` 输入一律拒绝，不做宽松猜测。
enum WorkflowCLIInputDecoder {
  static let maximumBytes = 1 * 1_024 * 1_024

  static func decode(_ value: String) throws -> [UInt8] {
    let scalars = Array(value.unicodeScalars)
    var output: [UInt8] = []
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      guard scalar == "\\" else {
        try append(String(scalar).utf8, to: &output)
        index += 1
        continue
      }
      guard index + 1 < scalars.count else { throw WorkflowCLIInputDecodeError.invalidEscape }
      let escaped = scalars[index + 1]
      switch escaped {
      case "a": try append([7], to: &output)
      case "b": try append([8], to: &output)
      case "e", "E": try append([27], to: &output)
      case "f": try append([12], to: &output)
      case "n": try append([10], to: &output)
      case "r": try append([13], to: &output)
      case "t": try append([9], to: &output)
      case "v": try append([11], to: &output)
      case "\\": try append([92], to: &output)
      case "'": try append([39], to: &output)
      case "\"": try append([34], to: &output)
      case "x":
        guard index + 3 < scalars.count,
          let byte = UInt8(
            scalars[(index + 2)...(index + 3)].map(String.init).joined(), radix: 16)
        else { throw WorkflowCLIInputDecodeError.invalidEscape }
        try append([byte], to: &output)
        index += 2
      default:
        throw WorkflowCLIInputDecodeError.invalidEscape
      }
      index += 2
    }
    return output
  }

  private static func append<S: Sequence>(_ bytes: S, to output: inout [UInt8]) throws
  where S.Element == UInt8 {
    for byte in bytes {
      guard output.count < maximumBytes else { throw WorkflowCLIInputDecodeError.outputTooLarge }
      output.append(byte)
    }
  }
}

/// 把结构化 argv 编码成一个 POSIX shell 命令。每个参数独立单引号包裹，命令替换、
/// 分号、换行和空格都只能成为参数正文，不能改变 `run/exec` 的命令结构。
enum WorkflowShellCommandEncoder {
  static func encode(_ arguments: [String]) -> String {
    arguments.map(quote).joined(separator: " ")
  }

  static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
