import AsterMemory
import Foundation

// aster-memory-mcp：MCP stdio server 入口。
// 逐行读取 stdin 的 JSON-RPC 消息，逐行写回响应；解析失败按协议返回 parse error。
// 数据库以只读方式在每次 tool 调用时打开，主应用（写端）无需在运行。

// ASTER_MEMORY_DIR 允许测试与多环境把 store 指向任意目录；默认生产位置。
let location: MemoryStoreLocation =
  if let override = ProcessInfo.processInfo.environment["ASTER_MEMORY_DIR"], !override.isEmpty {
    MemoryStoreLocation(rootDirectory: URL(fileURLWithPath: override, isDirectory: true))
  } else {
    .standard()
  }
// 启动目录即项目根目录（Claude Code / Codex 都在项目里 spawn server），
// 用作 project_path 缺省值；进程运行期间不再变化，因此只取一次。
let server = MCPServer(
  location: location, defaultProjectPath: FileManager.default.currentDirectoryPath)
let decoder = JSONDecoder()
let encoder = JSONEncoder()
_ = FileHandle.standardOutput  // 强制初始化，避免首包前的懒加载竞争。

func emit(_ response: JSONRPCResponse) {
  guard var data = try? encoder.encode(response) else { return }
  data.append(0x0A)
  FileHandle.standardOutput.write(data)
}

while let line = readLine(strippingNewline: true) {
  guard !line.isEmpty else { continue }
  guard let data = line.data(using: .utf8),
    let request = try? decoder.decode(JSONRPCRequest.self, from: data)
  else {
    emit(
      JSONRPCResponse(
        id: nil, error: JSONRPCError(code: -32700, message: "parse error")))
    continue
  }
  if let response = server.handle(request) {
    emit(response)
  }
}
