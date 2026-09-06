import Darwin
import Foundation

enum FileSystemDirectoryWatcherError: Error, LocalizedError, Equatable {
  case cannotOpenDirectory(Int32)
  case cannotOpenFile(Int32)

  var errorDescription: String? {
    switch self {
    case .cannotOpenDirectory(let code):
      "无法监听本地目录（errno=\(code)）。"
    case .cannotOpenFile(let code):
      "无法监听本地文件（errno=\(code)）。"
    }
  }
}

/// 以 vnode 事件观察一个已经存在的本地目录，不读取目录或文件内容。
///
/// 文件系统允许合并相邻事件，因此 `onChange` 只表示“目录可能变化”；调用方必须重新读取
/// 自己关心的有界状态，不能假设一个事件对应一个文件。监听源固定运行在主队列，适合
/// 唤醒 AppKit 状态协调器；耗时读取仍应由调用方转移到现有后台基础设施边界。
@MainActor
final class FileSystemDirectoryWatcher {
  private let directory: URL
  private let eventMask: DispatchSource.FileSystemEvent
  private let isFile: Bool
  // DispatchSource 的取消和 deinit 都允许从非隔离上下文发生；生产读写仍只在 MainActor。
  private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?

  init(directory: URL) {
    self.directory = directory.standardizedFileURL
    eventMask = [.write, .delete, .rename, .attrib, .revoke]
    isFile = false
  }

  /// 监听普通文件的追加或替换（vnode 对文件同样可用）。追加写同时触发 `.write` 与
  /// `.extend`；文件被改名或删除时上报，调用方应停止并重新定位。
  init(file: URL) {
    directory = file.standardizedFileURL
    eventMask = [.write, .extend, .delete, .rename, .revoke]
    isFile = true
  }

  var isWatching: Bool { source != nil }

  /// 开始监听目录条目与属性变化。重复调用保持现有监听，不会创建第二个文件描述符。
  func start(onChange: @escaping @MainActor @Sendable () -> Void) throws {
    guard source == nil else { return }
    let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw isFile
        ? FileSystemDirectoryWatcherError.cannotOpenFile(errno)
        : FileSystemDirectoryWatcherError.cannotOpenDirectory(errno)
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: eventMask,
      queue: .main
    )
    source.setEventHandler {
      MainActor.assumeIsolated { onChange() }
    }
    source.setCancelHandler {
      Darwin.close(descriptor)
    }
    self.source = source
    source.activate()
  }

  /// 停止监听并异步关闭文件描述符。重复调用没有额外副作用。
  func stop() {
    let source = source
    self.source = nil
    source?.cancel()
  }

  deinit {
    source?.cancel()
  }
}
