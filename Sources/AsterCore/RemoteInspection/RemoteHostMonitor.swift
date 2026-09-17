// 远端主机监控：快照模型、CPU 差分与一次性采集脚本。解析逻辑在 RemoteHostMonitorParser.swift。

import Foundation

// MARK: - 快照模型

/// 三档系统负载。
public struct RemoteLoadAverage: Equatable, Sendable {
  public var one: Double
  public var five: Double
  public var fifteen: Double

  public init(one: Double, five: Double, fifteen: Double) {
    self.one = one
    self.five = five
    self.fifteen = fifteen
  }
}

/// 一次 `/proc/stat` 采样。远端不 sleep，CPU 占用由客户端对相邻两次采样做差分。
public struct RemoteCPUStatSample: Equatable, Sendable {
  /// 空闲 tick（idle + iowait）。
  public var idleTicks: UInt64
  /// 全部 tick 之和。
  public var totalTicks: UInt64
  /// 在线逻辑核心数，缺失时为 1。
  public var cpuCount: Int

  public init(idleTicks: UInt64, totalTicks: UInt64, cpuCount: Int) {
    self.idleTicks = idleTicks
    self.totalTicks = totalTicks
    self.cpuCount = cpuCount
  }
}

/// 内存用量，单位 KiB。`available` 在旧内核或 macOS 上可能缺失。
public struct RemoteMemoryUsage: Equatable, Sendable {
  public var totalKiB: UInt64
  public var availableKiB: UInt64?
  public var freeKiB: UInt64
  public var buffersKiB: UInt64
  public var cachedKiB: UInt64

  public init(
    totalKiB: UInt64,
    availableKiB: UInt64?,
    freeKiB: UInt64,
    buffersKiB: UInt64,
    cachedKiB: UInt64
  ) {
    self.totalKiB = totalKiB
    self.availableKiB = availableKiB
    self.freeKiB = freeKiB
    self.buffersKiB = buffersKiB
    self.cachedKiB = cachedKiB
  }

  /// 已用内存：优先用 available 口径，缺失时退回 total - free - buffers - cached。
  public var usedKiB: UInt64 {
    if let availableKiB, availableKiB <= totalKiB { return totalKiB - availableKiB }
    let reclaimable = freeKiB &+ buffersKiB &+ cachedKiB
    return reclaimable >= totalKiB ? 0 : totalKiB - reclaimable
  }
}

/// Swap 用量，单位 KiB。
public struct RemoteSwapUsage: Equatable, Sendable {
  public var totalKiB: UInt64
  public var freeKiB: UInt64

  public init(totalKiB: UInt64, freeKiB: UInt64) {
    self.totalKiB = totalKiB
    self.freeKiB = freeKiB
  }

  public var usedKiB: UInt64 { freeKiB >= totalKiB ? 0 : totalKiB - freeKiB }
}

/// 一个挂载点的容量，单位 KiB。
public struct RemoteDiskUsage: Equatable, Sendable {
  public var mount: String
  public var filesystem: String
  public var sizeKiB: UInt64
  public var usedKiB: UInt64
  public var availableKiB: UInt64

  public init(
    mount: String,
    filesystem: String,
    sizeKiB: UInt64,
    usedKiB: UInt64,
    availableKiB: UInt64
  ) {
    self.mount = mount
    self.filesystem = filesystem
    self.sizeKiB = sizeKiB
    self.usedKiB = usedKiB
    self.availableKiB = availableKiB
  }
}

/// 一个进程的采样值。`command` 是 args 首 token 的 basename，`arguments` 是完整命令行。
public struct RemoteProcessSample: Equatable, Sendable {
  public var pid: Int32
  public var cpuPercent: Double
  public var memoryPercent: Double
  public var residentKiB: UInt64
  public var user: String
  public var command: String
  public var arguments: String

  public init(
    pid: Int32,
    cpuPercent: Double,
    memoryPercent: Double,
    residentKiB: UInt64,
    user: String,
    command: String,
    arguments: String
  ) {
    self.pid = pid
    self.cpuPercent = cpuPercent
    self.memoryPercent = memoryPercent
    self.residentKiB = residentKiB
    self.user = user
    self.command = command
    self.arguments = arguments
  }
}

/// 监听端口的传输层协议。
public enum RemotePortProtocol: String, Equatable, Sendable {
  case tcp
  case udp
}

/// 一个监听端口。非 root 用户看不到他人进程，此时 `pid` / `processName` 为 nil。
public struct RemoteListeningPort: Equatable, Sendable {
  public var networkProtocol: RemotePortProtocol
  public var address: String
  public var port: Int
  public var pid: Int32?
  public var processName: String?

  public init(
    networkProtocol: RemotePortProtocol,
    address: String,
    port: Int,
    pid: Int32?,
    processName: String?
  ) {
    self.networkProtocol = networkProtocol
    self.address = address
    self.port = port
    self.pid = pid
    self.processName = processName
  }
}

/// 一次监控采集的完整结果。缺失的分段记录在 `unavailableSections`，UI 显示「此平台不提供该项」。
public struct RemoteHostMonitorSnapshot: Equatable, Sendable {
  public var host: String?
  public var uname: String?
  public var uptimeSeconds: Double?
  public var load: RemoteLoadAverage?
  public var cpuSample: RemoteCPUStatSample?
  public var memory: RemoteMemoryUsage?
  public var swap: RemoteSwapUsage?
  public var disks: [RemoteDiskUsage]
  public var topByCPU: [RemoteProcessSample]
  public var topByMemory: [RemoteProcessSample]
  public var listeningPorts: [RemoteListeningPort]
  /// 采集不到的分段名，取值见 `RemoteHostMonitorSection`。
  public var unavailableSections: Set<String>
  /// 受管终端 shell 的当前目录，只有传入 pid 且 `/proc/<pid>/cwd` 可读时才有值。
  public var cwd: String?

  public init(
    host: String? = nil,
    uname: String? = nil,
    uptimeSeconds: Double? = nil,
    load: RemoteLoadAverage? = nil,
    cpuSample: RemoteCPUStatSample? = nil,
    memory: RemoteMemoryUsage? = nil,
    swap: RemoteSwapUsage? = nil,
    disks: [RemoteDiskUsage] = [],
    topByCPU: [RemoteProcessSample] = [],
    topByMemory: [RemoteProcessSample] = [],
    listeningPorts: [RemoteListeningPort] = [],
    unavailableSections: Set<String> = [],
    cwd: String? = nil
  ) {
    self.host = host
    self.uname = uname
    self.uptimeSeconds = uptimeSeconds
    self.load = load
    self.cpuSample = cpuSample
    self.memory = memory
    self.swap = swap
    self.disks = disks
    self.topByCPU = topByCPU
    self.topByMemory = topByMemory
    self.listeningPorts = listeningPorts
    self.unavailableSections = unavailableSections
    self.cwd = cwd
  }
}

/// 快照分段的规范名字，同时用作 `unavailableSections` 的取值。
public enum RemoteHostMonitorSection {
  public static let host = "host"
  public static let uptime = "uptime"
  public static let load = "load"
  public static let cpu = "cpu"
  public static let memory = "memory"
  public static let swap = "swap"
  public static let disk = "disk"
  public static let processes = "processes"
  public static let ports = "ports"

  /// 每次采集都期望存在的分段；缺哪个就进 `unavailableSections`。
  public static let expected: [String] = [host, uptime, load, cpu, memory, swap, disk, processes, ports]
}

/// 监控解析失败原因。
public enum RemoteHostMonitorError: Error, Equatable, Sendable {
  /// 输出缺少 `ASTER_MON_V1` 首行，多半是登录 Shell 往 stdout 打了东西或命令没跑起来。
  case malformed(String)
}

// MARK: - CPU 差分

/// 由相邻两次 `/proc/stat` 采样计算 CPU 占用百分比。
public enum RemoteCPUUsage {
  /// 返回 0…100 的占用百分比；样本倒退、总量未推进或数据不自洽时返回 nil（UI 显示「—」）。
  public static func compute(previous: RemoteCPUStatSample, current: RemoteCPUStatSample) -> Double? {
    guard current.totalTicks >= previous.totalTicks, current.idleTicks >= previous.idleTicks else {
      return nil
    }
    let totalDelta = current.totalTicks - previous.totalTicks
    let idleDelta = current.idleTicks - previous.idleTicks
    guard totalDelta > 0, idleDelta <= totalDelta else { return nil }
    return (1.0 - Double(idleDelta) / Double(totalDelta)) * 100.0
  }
}

/// UI 侧沿用短名字；类型本身带 Remote 前缀，避免在 AsterCore 里占用过于通用的名称。
public typealias CPUStatSample = RemoteCPUStatSample
public typealias CPUUsage = RemoteCPUUsage

// MARK: - 脚本

/// 生成远端监控脚本的 argv。受管终端把 shell pid 放 `$1`，用于读取远端 cwd。
public enum RemoteHostMonitorScript {
  /// 客户端读取上限，远端本身不做字节截断（各分段已逐条 `head`）。
  public static let outputByteLimit = 262_144

  /// 返回 `["/bin/sh", "-c", <script>, "sh"]`，pid 非空时追加一个参数。
  public static func command(pid: Int32?) -> [String] {
    var argv = ["/bin/sh", "-c", script, "sh"]
    if let pid { argv.append(String(pid)) }
    return argv
  }

  /// 一次性采集脚本。刻意不 sleep：CPU 占用由客户端按 channelKey 缓存上一 tick 做差分，
  /// 远端 sleep 会让每次 ssh exec 多占住一秒连接。
  public static let script = #"""
  pid=${1:-}
  printf 'ASTER_MON_V1\n'

  printf '[host]\n'
  (hostname 2>/dev/null || uname -n 2>/dev/null) | head -n 1
  uname -srm 2>/dev/null
  printf '[end]\n'

  if [ -r /proc/uptime ]; then
    printf '[uptime]\n'
    head -n 1 /proc/uptime
    printf '[end]\n'
  else
    boot=$(sysctl -n kern.boottime 2>/dev/null) || boot=""
    [ -n "$boot" ] && printf '[boottime]\n%s\n[end]\n' "$boot"
  fi

  if [ -r /proc/loadavg ]; then
    printf '[load]\n'
    head -n 1 /proc/loadavg
    printf '[end]\n'
  else
    loadavg=$(sysctl -n vm.loadavg 2>/dev/null) || loadavg=""
    [ -n "$loadavg" ] && printf '[load]\n%s\n[end]\n' "$loadavg"
  fi

  if [ -r /proc/stat ]; then
    printf '[cpu]\n'
    head -n 1 /proc/stat
    cpus=$(nproc 2>/dev/null) || cpus=""
    [ -n "$cpus" ] || cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus=""
    printf 'cpus=%s\n' "$cpus"
    printf '[end]\n'
  fi

  if [ -r /proc/meminfo ]; then
    printf '[mem]\n'
    grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null
    printf '[end]\n'
  elif command -v vm_stat >/dev/null 2>&1; then
    printf '[mem-darwin]\n'
    printf 'hw.memsize=%s\n' "$(sysctl -n hw.memsize 2>/dev/null)"
    printf 'hw.pagesize=%s\n' "$(sysctl -n hw.pagesize 2>/dev/null)"
    vm_stat 2>/dev/null
    sysctl -n vm.swapusage 2>/dev/null
    printf '[end]\n'
  fi

  disks=$(df -P -k 2>/dev/null | tail -n +2 | head -n 40)
  [ -n "$disks" ] && printf '[disk]\n%s\n[end]\n' "$disks"

  procs=$(ps -A -o pid= -o pcpu= -o pmem= -o rss= -o user= -o args= 2>/dev/null)
  if [ -n "$procs" ]; then
    printf '[ps-cpu]\n%s\n[end]\n' "$(printf '%s\n' "$procs" | sort -k2,2nr | head -n 20)"
    printf '[ps-mem]\n%s\n[end]\n' "$(printf '%s\n' "$procs" | sort -k4,4nr | head -n 20)"
  fi

  ports=""
  if command -v ss >/dev/null 2>&1; then
    ports=$(ss -H -l -t -u -n -p 2>/dev/null | head -n 200)
    [ -n "$ports" ] && printf '[ports-ss]\n%s\n[end]\n' "$ports"
  fi
  # netstat 只在 Linux 上试：BSD/macOS 的 netstat 会把 `-tulpn` 当成别的选项，
  # 输出几万行 UNIX domain socket，既没用又会顶掉后面的 lsof 回退。
  if [ -z "$ports" ] && [ -r /proc/net/tcp ] && command -v netstat >/dev/null 2>&1; then
    ports=$(netstat -tulpn 2>/dev/null | grep -E '^(tcp|udp)' | head -n 200)
    [ -n "$ports" ] && printf '[ports-netstat]\n%s\n[end]\n' "$ports"
  fi
  if [ -z "$ports" ] && command -v lsof >/dev/null 2>&1; then
    ports=$(lsof -nP -iTCP -sTCP:LISTEN -iUDP -F pcfnPT 2>/dev/null | head -n 800)
    [ -n "$ports" ] && printf '[ports-lsof]\n%s\n[end]\n' "$ports"
  fi

  if [ -n "$pid" ] && [ -r "/proc/$pid/cwd" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=""
    [ -n "$cwd" ] && printf '[cwd]\n%s\n[end]\n' "$cwd"
  fi
  exit 0
  """#
}
