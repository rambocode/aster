import AsterCore
import Foundation

/// JSON-RPC 2.0 请求。MCP stdio 传输为逐行 JSON；id 可能是数字或字符串。
struct JSONRPCRequest: Decodable {
  let jsonrpc: String
  let id: JSONRPCID?
  let method: String
  let params: JSONValue?
}

/// 请求 id 的两种合法形态。响应必须原样回传。
enum JSONRPCID: Codable, Equatable {
  case number(Int)
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let number = try? container.decode(Int.self) {
      self = .number(number)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }
}

/// JSON-RPC 响应（成功或错误二选一）。
struct JSONRPCResponse: Encodable {
  let jsonrpc = "2.0"
  let id: JSONRPCID?
  var result: JSONValue?
  var error: JSONRPCError?

  private enum CodingKeys: String, CodingKey {
    case jsonrpc, id, result, error
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(jsonrpc, forKey: .jsonrpc)
    try container.encode(id, forKey: .id)
    if let error {
      try container.encode(error, forKey: .error)
    } else {
      try container.encode(result ?? .null, forKey: .result)
    }
  }
}

/// JSON-RPC 错误对象。
struct JSONRPCError: Encodable {
  let code: Int
  let message: String
}
