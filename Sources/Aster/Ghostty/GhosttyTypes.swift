import Foundation

/// libghostty 的进度 action 在 Adapter seam 上使用的稳定值类型。
/// Aster 领域层不直接依赖 C enum，后续升级 internal header 时只需修改 Adapter。
enum GhosttyProgress: Equatable, Sendable {
  case clear
  case indeterminate
  case determinate(Int)
  case paused(Int?)
  case error(Int?)
}

/// 终端程序触发的剪贴板访问。普通用户 Copy/Paste 不经过该授权回调。
enum GhosttyClipboardOperation: Equatable, Sendable {
  case read
  case write
}
