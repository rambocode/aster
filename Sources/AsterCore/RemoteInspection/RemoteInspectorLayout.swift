// 远端详情面板的分页与宽度档位：与 AppKit 无关的纯规则，便于定向测试。

import Foundation

/// 服务器监控的分页。一屏堆下全部分段会把主机、磁盘、进程、端口挤成一条长卷轴，
/// 用户找一项要滚很久；按关注点分页后每页都能一眼看完。
public enum RemoteMonitorTab: String, CaseIterable, Equatable, Sendable {
  /// 主机、运行时长、负载、CPU、内存、Swap：一次采集就能回答「这台机器现在忙不忙」。
  case overview
  case disks
  case processes
  case ports

  /// 界面标题。返回的是本地化 key 的原文，视图层再过 `L()`。
  public var titleKey: String {
    switch self {
    case .overview: "概览"
    case .disks: "磁盘"
    case .processes: "进程"
    case .ports: "端口"
    }
  }

  /// 该页在快照里对应的分段名。缺段时页签仍然保留（用户要能看到「此平台不提供该项」），
  /// 只是内容区换成说明文案，不做隐藏——页签忽隐忽现比空页更难用。
  public var sections: [String] {
    switch self {
    case .overview:
      [
        RemoteHostMonitorSection.host, RemoteHostMonitorSection.uptime,
        RemoteHostMonitorSection.load, RemoteHostMonitorSection.cpu,
        RemoteHostMonitorSection.memory, RemoteHostMonitorSection.swap,
      ]
    case .disks: [RemoteHostMonitorSection.disk]
    case .processes: [RemoteHostMonitorSection.processes]
    case .ports: [RemoteHostMonitorSection.ports]
    }
  }
}

/// 详情面板的宽度档位。
///
/// Inspector 宽度可在 240…480pt 之间拖动，同一套固定列宽在两端不可能都合适：
/// 宽的时候右侧留一大片空白，窄的时候进程名和挂载点被截成几个字。按档位切换列的
/// 取舍，而不是让所有列一起压缩。
public enum RemoteInspectorLayout {
  public enum Mode: Equatable, Sendable {
    /// 窄栏：只保留每行最关键的一个数值，次要列（PID、监听地址、修改时间）让位。
    case compact
    /// 常规：完整列。
    case regular
  }

  /// 切换阈值。取 300pt：Inspector 默认 278pt 落在 compact，用户主动拉宽才换成完整列。
  public static let compactWidthThreshold: Double = 300

  public static func mode(forWidth width: Double) -> Mode {
    width.isFinite && width >= compactWidthThreshold ? .regular : .compact
  }
}
