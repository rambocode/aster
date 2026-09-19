// 子进程退出后取走管道里剩余输出的非阻塞读取。
import Darwin
import Foundation

extension FileHandle {
  /// 取走管道里已经到达的数据，绝不等待 EOF。
  ///
  /// 子进程退出后它自己的输出已经全部进了管道缓冲区，但 EOF 要等所有写端关闭才出现：
  /// git 拉起的 fsmonitor、ssh 的 ControlMaster 这类后台孙进程会继承并长期握住写端，
  /// `readDataToEndOfFile()` 因此永远不返回，白白占住一个 Swift 并发线程（线程池按核数
  /// 封顶，累积起来会卡住整个并发运行时）。非阻塞读到 EAGAIN 即停，语义上只丢掉
  /// 「孙进程以后可能写的内容」，而那本来就不属于这次命令的输出。
  func readRemainingWithoutBlocking(maximumBytes: Int) -> Data {
    guard maximumBytes > 0 else { return Data() }
    let descriptor = fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }

    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while result.count < maximumBytes {
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes - result.count))
      if count > 0 {
        result.append(buffer, count: count)
      } else if count < 0, errno == EINTR {
        continue
      } else {
        // 0 是 EOF；EAGAIN 表示缓冲区已空但写端仍被孙进程握着，两种情况都结束。
        break
      }
    }
    return result
  }
}
