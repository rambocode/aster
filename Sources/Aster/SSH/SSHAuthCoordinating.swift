import AsterCore
import Foundation

// 引擎接入包（控制通道）与钥匙串包（认证界面）之间的边界。
// 控制通道收到请求后交给它，拿到回答再写回 broker；钥匙串与弹窗细节都藏在实现里。

/// 回答 broker 的凭证与主机密钥请求。
@MainActor
protocol SSHAuthCoordinating: AnyObject {
  /// 回答一次凭证请求：钥匙串有就直接用；`interactive` 为 true 且没有时弹窗。
  /// 返回 `.authAnswer`（取消时 secret 为 nil）。
  func answer(_ request: SSHAuthRequest) async -> SSHBrokerCommand
  /// broker 报告上一次回答是否被接受：接受且用户勾选了记住时写钥匙串；
  /// 拒绝且秘密来自钥匙串时删除该条目。
  func handleResult(id: String, accepted: Bool)
  /// 回答一次主机密钥确认。非交互请求一律拒绝。
  func confirmHostKey(_ request: SSHHostKeyRequest) async -> SSHBrokerCommand
}
