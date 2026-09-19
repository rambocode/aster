// 画中画两种呈现方式（系统镜像 / 可交互小窗）共用的生命周期接口。
import AppKit

/// 画中画呈现方式。原始值就是设置项 `pictureInPicture.style` 落盘的字符串。
enum PictureInPictureStyle: String {
  /// AVKit 系统画中画：只镜像画面，不能输入。
  case mirror
  /// 置顶小窗直接承载真实终端视图，可完整键盘交互。
  case interactive
}

/// AppDelegate 只通过这个接口开关画中画，不关心背后是 AVKit 还是 NSPanel。
///
/// `close()` 可以同步也可以异步结束；无论哪种，结束时必须恰好调用一次 `onClose`，
/// 调用方靠它串行切换模式。
@MainActor
protocol PictureInPicturePresenting: AnyObject {
  var isClosed: Bool { get }
  var onFailure: ((String) -> Void)? { get set }
  var onClose: (() -> Void)? { get set }
  /// 是否已经在为同一工作区、同一模式服务；用于「再次选择同一项即关闭」。
  func matches(model: AppModel, mode: PanePictureInPictureController.Mode) -> Bool
  func show()
  func close()
}

extension PanePictureInPictureController: PictureInPicturePresenting {}
