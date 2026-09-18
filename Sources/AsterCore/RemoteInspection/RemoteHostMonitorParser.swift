// 远端监控输出解析：分段拆解、Linux / macOS 数据源与三种端口格式的归一化。

import Foundation

/// 把 `RemoteHostMonitorScript` 的输出解析成 `RemoteHostMonitorSnapshot`。
///
/// 输出按 `[section]` … `[end]` 分段，任何一段缺失都不影响其它段：远端发行版差异很大，
/// 解析器对每段单独尽力而为，采不到的写进 `unavailableSections` 交给 UI 提示。
public enum RemoteHostMonitorParser {
  /// 磁盘段过滤掉的伪文件系统；它们的容量对「服务器还剩多少盘」没有意义。
  static let ignoredFilesystems: Set<String> = ["tmpfs", "devtmpfs", "overlay", "squashfs", "efivarfs"]
  /// 磁盘段最多展示的挂载点数。
  static let maximumDiskCount = 8

  public static func parse(_ data: Data, now: Date = Date()) throws -> RemoteHostMonitorSnapshot {
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
      first.trimmingCharacters(in: .whitespaces) == "ASTER_MON_V1"
    else {
      throw RemoteHostMonitorError.malformed("missing header")
    }

    let sections = split(lines: lines)
    var snapshot = RemoteHostMonitorSnapshot()

    if let host = sections["host"] {
      snapshot.host = host.first.flatMap { $0.isEmpty ? nil : $0 }
      snapshot.uname = host.count > 1 && !host[1].isEmpty ? host[1] : nil
    }
    snapshot.uptimeSeconds = parseUptime(sections: sections, now: now)
    snapshot.load = parseLoad(sections["load"])
    snapshot.cpuSample = parseCPU(sections["cpu"])
    let memory = parseMemory(sections: sections)
    snapshot.memory = memory.memory
    snapshot.swap = memory.swap
    snapshot.disks = parseDisks(sections["disk"])
    snapshot.topByCPU = parseProcesses(sections["ps-cpu"])
    snapshot.topByMemory = parseProcesses(sections["ps-mem"])
    snapshot.listeningPorts = parsePorts(sections: sections)
    snapshot.cwd = sections["cwd"]?.first.flatMap { $0.isEmpty ? nil : $0 }
    snapshot.unavailableSections = unavailable(in: snapshot, sections: sections)
    return snapshot
  }

  // MARK: - 分段拆解

  /// 扫描 `[name]` 到 `[end]` 的区间；未闭合的段也会保留已读到的内容。
  private static func split(lines: [String]) -> [String: [String]] {
    var sections: [String: [String]] = [:]
    var current: String?
    var buffer: [String] = []
    for line in lines {
      if line == "[end]" {
        if let current { sections[current] = buffer }
        current = nil
        buffer = []
        continue
      }
      if line.hasPrefix("["), line.hasSuffix("]"), !line.contains(" ") {
        if let current { sections[current] = buffer }
        current = String(line.dropFirst().dropLast())
        buffer = []
        continue
      }
      if current != nil { buffer.append(line) }
    }
    if let current { sections[current] = buffer }
    return sections
  }

  /// 缺哪些规范分段：分段本身没来，或来了但没解析出有效数据。
  private static func unavailable(
    in snapshot: RemoteHostMonitorSnapshot,
    sections: [String: [String]]
  ) -> Set<String> {
    var missing: Set<String> = []
    if snapshot.host == nil { missing.insert(RemoteHostMonitorSection.host) }
    if snapshot.uptimeSeconds == nil { missing.insert(RemoteHostMonitorSection.uptime) }
    if snapshot.load == nil { missing.insert(RemoteHostMonitorSection.load) }
    if snapshot.cpuSample == nil { missing.insert(RemoteHostMonitorSection.cpu) }
    if snapshot.memory == nil { missing.insert(RemoteHostMonitorSection.memory) }
    if snapshot.swap == nil { missing.insert(RemoteHostMonitorSection.swap) }
    if snapshot.disks.isEmpty { missing.insert(RemoteHostMonitorSection.disk) }
    if snapshot.topByCPU.isEmpty, snapshot.topByMemory.isEmpty {
      missing.insert(RemoteHostMonitorSection.processes)
    }
    let hasPortSection = sections.keys.contains { $0.hasPrefix("ports-") }
    if !hasPortSection { missing.insert(RemoteHostMonitorSection.ports) }
    return missing
  }

  // MARK: - 基础信息

  private static func parseUptime(sections: [String: [String]], now: Date) -> Double? {
    if let uptime = sections["uptime"]?.first,
      let seconds = Double(uptime.split(separator: " ").first.map(String.init) ?? "")
    {
      return seconds
    }
    // macOS：`kern.boottime` 形如 `{ sec = 1726500000, usec = 0 } Mon Sep 16 ...`。
    guard let boot = sections["boottime"]?.first,
      let range = boot.range(of: "sec = ")
    else { return nil }
    let digits = boot[range.upperBound...].prefix { $0.isNumber }
    guard let seconds = Double(digits), seconds > 0 else { return nil }
    let uptime = now.timeIntervalSince1970 - seconds
    return uptime >= 0 ? uptime : nil
  }

  private static func parseLoad(_ lines: [String]?) -> RemoteLoadAverage? {
    guard let line = lines?.first else { return nil }
    // Linux `/proc/loadavg` 是裸数字，macOS `vm.loadavg` 带 `{ }`，统一剥掉括号再取前三个数。
    let cleaned = line.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")
    let values = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
    guard values.count >= 3 else { return nil }
    return RemoteLoadAverage(one: values[0], five: values[1], fifteen: values[2])
  }

  private static func parseCPU(_ lines: [String]?) -> RemoteCPUStatSample? {
    guard let lines else { return nil }
    guard let statLine = lines.first(where: { $0.hasPrefix("cpu ") || $0.hasPrefix("cpu\t") }) else {
      return nil
    }
    let ticks = statLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
      .dropFirst()
      .compactMap { UInt64($0) }
    guard ticks.count >= 4 else { return nil }
    let total = ticks.reduce(UInt64(0)) { $0 &+ $1 }
    // idle 口径包含 iowait：等 I/O 的时间不算用户可感知的 CPU 忙。
    let idle = ticks[3] &+ (ticks.count > 4 ? ticks[4] : 0)
    let count = lines.first(where: { $0.hasPrefix("cpus=") })
      .flatMap { Int($0.dropFirst("cpus=".count).trimmingCharacters(in: .whitespaces)) } ?? 1
    return RemoteCPUStatSample(idleTicks: idle, totalTicks: total, cpuCount: max(count, 1))
  }

  // MARK: - 内存

  private static func parseMemory(
    sections: [String: [String]]
  ) -> (memory: RemoteMemoryUsage?, swap: RemoteSwapUsage?) {
    if let lines = sections["mem"] { return parseLinuxMemory(lines) }
    if let lines = sections["mem-darwin"] { return parseDarwinMemory(lines) }
    return (nil, nil)
  }

  private static func parseLinuxMemory(
    _ lines: [String]
  ) -> (memory: RemoteMemoryUsage?, swap: RemoteSwapUsage?) {
    var values: [String: UInt64] = [:]
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let number = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
      guard let number, let value = UInt64(number) else { continue }
      values[String(parts[0])] = value
    }
    guard let total = values["MemTotal"] else { return (nil, nil) }
    let memory = RemoteMemoryUsage(
      totalKiB: total,
      availableKiB: values["MemAvailable"],
      freeKiB: values["MemFree"] ?? 0,
      buffersKiB: values["Buffers"] ?? 0,
      cachedKiB: values["Cached"] ?? 0
    )
    var swap: RemoteSwapUsage?
    if let swapTotal = values["SwapTotal"] {
      swap = RemoteSwapUsage(totalKiB: swapTotal, freeKiB: values["SwapFree"] ?? 0)
    }
    return (memory, swap)
  }

  /// macOS 尽力而为：`vm_stat` 的页计数换算成 KiB，available 用「可回收」页近似。
  private static func parseDarwinMemory(
    _ lines: [String]
  ) -> (memory: RemoteMemoryUsage?, swap: RemoteSwapUsage?) {
    var memsize: UInt64?
    var pageSize: UInt64 = 4096
    var pages: [String: UInt64] = [:]
    var swap: RemoteSwapUsage?
    for line in lines {
      if line.hasPrefix("hw.memsize=") {
        memsize = UInt64(line.dropFirst("hw.memsize=".count).trimmingCharacters(in: .whitespaces))
        continue
      }
      if line.hasPrefix("hw.pagesize=") {
        if let value = UInt64(line.dropFirst("hw.pagesize=".count).trimmingCharacters(in: .whitespaces)),
          value > 0
        {
          pageSize = value
        }
        continue
      }
      if line.hasPrefix("total = ") || line.contains("used = ") {
        swap = parseSwapUsage(line)
        continue
      }
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let digits = parts[1].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
      guard let value = UInt64(digits) else { continue }
      pages[parts[0].trimmingCharacters(in: .whitespaces)] = value
    }
    guard let memsize else { return (nil, swap) }
    let kibPerPage = max(pageSize / 1024, 1)
    let free = (pages["Pages free"] ?? 0) * kibPerPage
    let reclaimable =
      ((pages["Pages free"] ?? 0) + (pages["Pages inactive"] ?? 0) + (pages["Pages speculative"] ?? 0)
        + (pages["Pages purgeable"] ?? 0)) * kibPerPage
    let cached = (pages["File-backed pages"] ?? 0) * kibPerPage
    let memory = RemoteMemoryUsage(
      totalKiB: memsize / 1024,
      availableKiB: reclaimable,
      freeKiB: free,
      buffersKiB: 0,
      cachedKiB: cached
    )
    return (memory, swap)
  }

  /// `vm.swapusage: total = 2048.00M  used = 100.00M  free = 1948.00M  (encrypted)`。
  private static func parseSwapUsage(_ line: String) -> RemoteSwapUsage? {
    func value(after label: String) -> UInt64? {
      guard let range = line.range(of: label) else { return nil }
      let token = line[range.upperBound...].drop(while: { $0 == " " }).prefix { $0 != " " }
      let digits = token.prefix { $0.isNumber || $0 == "." }
      guard let amount = Double(digits) else { return nil }
      let unit = token.dropFirst(digits.count).first.map(String.init)?.uppercased() ?? "K"
      switch unit {
      case "G": return UInt64(amount * 1024 * 1024)
      case "M": return UInt64(amount * 1024)
      case "B": return UInt64(amount / 1024)
      default: return UInt64(amount)
      }
    }
    guard let total = value(after: "total = "), let free = value(after: "free = ") else { return nil }
    return RemoteSwapUsage(totalKiB: total, freeKiB: free)
  }

  // MARK: - 磁盘

  private static func parseDisks(_ lines: [String]?) -> [RemoteDiskUsage] {
    guard let lines else { return [] }
    var disks: [RemoteDiskUsage] = []
    for line in lines {
      guard let parsed = leadingFields(line, count: 5), parsed.fields.count == 5 else { continue }
      let filesystem = parsed.fields[0]
      let mount = parsed.rest.trimmingCharacters(in: .whitespaces)
      guard !mount.isEmpty else { continue }
      guard !ignoredFilesystems.contains(filesystem), !mount.hasPrefix("/snap/") else { continue }
      guard let size = UInt64(parsed.fields[1]), size > 0 else { continue }
      disks.append(
        RemoteDiskUsage(
          mount: mount,
          filesystem: filesystem,
          sizeKiB: size,
          usedKiB: UInt64(parsed.fields[2]) ?? 0,
          availableKiB: UInt64(parsed.fields[3]) ?? 0
        )
      )
    }
    // 同一个设备可能被 bind mount 到多个路径（OrbStack 的 /mnt/machines/* 就是如此），
    // df 会逐条列出，面板照抄就是几行一模一样的容量。按设备去重，保留路径最短的挂载点
    // ——它通常就是用户认得的那个根挂载点。
    var seenFilesystems: Set<String> = []
    var deduplicated: [RemoteDiskUsage] = []
    for disk in disks.sorted(by: { $0.mount.count < $1.mount.count }) {
      guard seenFilesystems.insert(disk.filesystem).inserted else { continue }
      deduplicated.append(disk)
    }
    deduplicated.sort { $0.sizeKiB > $1.sizeKiB }
    return Array(deduplicated.prefix(maximumDiskCount))
  }

  // MARK: - 进程

  private static func parseProcesses(_ lines: [String]?) -> [RemoteProcessSample] {
    guard let lines else { return [] }
    var samples: [RemoteProcessSample] = []
    for line in lines {
      guard let parsed = leadingFields(line, count: 5), parsed.fields.count == 5 else { continue }
      guard let pid = Int32(parsed.fields[0]) else { continue }
      let arguments = parsed.rest.trimmingCharacters(in: .whitespaces)
      guard !arguments.isEmpty else { continue }
      let firstToken = arguments.split(separator: " ", maxSplits: 1).first.map(String.init) ?? arguments
      let command = firstToken.split(separator: "/").last.map(String.init) ?? firstToken
      samples.append(
        RemoteProcessSample(
          pid: pid,
          cpuPercent: Double(parsed.fields[1]) ?? 0,
          memoryPercent: Double(parsed.fields[2]) ?? 0,
          residentKiB: UInt64(parsed.fields[3]) ?? 0,
          user: parsed.fields[4],
          command: command,
          arguments: arguments
        )
      )
    }
    return samples
  }

  // MARK: - 端口

  private static func parsePorts(sections: [String: [String]]) -> [RemoteListeningPort] {
    if let lines = sections["ports-ss"] { return deduplicated(lines.compactMap(parseSSPort)) }
    if let lines = sections["ports-netstat"] { return deduplicated(lines.compactMap(parseNetstatPort)) }
    if let lines = sections["ports-lsof"] { return deduplicated(parseLsofPorts(lines)) }
    return []
  }

  /// 同一个监听 socket 会被多个 fd 重复列出（lsof 尤其明显），按四元组去重并保留首次出现的顺序。
  private static func deduplicated(_ ports: [RemoteListeningPort]) -> [RemoteListeningPort] {
    var seen: Set<String> = []
    var result: [RemoteListeningPort] = []
    for port in ports {
      let key = "\(port.networkProtocol.rawValue)|\(port.address)|\(port.port)|\(port.pid.map(String.init) ?? "")"
      if seen.insert(key).inserted { result.append(port) }
    }
    return result
  }

  private static func parseSSPort(_ line: String) -> RemoteListeningPort? {
    let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard tokens.count >= 5, let networkProtocol = protocolValue(tokens[0]) else { return nil }
    guard let endpoint = endpoint(tokens[4]) else { return nil }
    let processText = tokens.count > 6 ? tokens[6...].joined(separator: " ") : ""
    let process = parseSSProcess(processText)
    return RemoteListeningPort(
      networkProtocol: networkProtocol,
      address: endpoint.address,
      port: endpoint.port,
      pid: process.pid,
      processName: process.name
    )
  }

  /// `users:(("sshd",pid=1234,fd=3))`；非 root 时该列整体缺失，返回空值由 UI 提示。
  private static func parseSSProcess(_ text: String) -> (pid: Int32?, name: String?) {
    guard !text.isEmpty else { return (nil, nil) }
    var name: String?
    if let open = text.firstIndex(of: "\""),
      let close = text[text.index(after: open)...].firstIndex(of: "\"")
    {
      let value = String(text[text.index(after: open)..<close])
      if !value.isEmpty { name = value }
    }
    var pid: Int32?
    if let range = text.range(of: "pid=") {
      pid = Int32(text[range.upperBound...].prefix { $0.isNumber })
    }
    return (pid, name)
  }

  private static func parseNetstatPort(_ line: String) -> RemoteListeningPort? {
    let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard tokens.count >= 4, let networkProtocol = protocolValue(tokens[0]) else { return nil }
    guard let endpoint = endpoint(tokens[3]) else { return nil }
    var pid: Int32?
    var name: String?
    // PID/Program 列形如 `1234/sshd`，非 root 或未带 `-p` 时是 `-`。
    if let field = tokens.last(where: { $0.contains("/") && $0.first?.isNumber == true }) {
      let parts = field.split(separator: "/", maxSplits: 1)
      pid = Int32(parts[0])
      if parts.count > 1, !parts[1].isEmpty { name = String(parts[1]) }
    }
    return RemoteListeningPort(
      networkProtocol: networkProtocol,
      address: endpoint.address,
      port: endpoint.port,
      pid: pid,
      processName: name
    )
  }

  /// `lsof -F` 是「每行一个字段」的流：`p` 开进程块，`f` 开文件块，遇到重复字段即结束上一条。
  private static func parseLsofPorts(_ lines: [String]) -> [RemoteListeningPort] {
    var ports: [RemoteListeningPort] = []
    var pid: Int32?
    var command: String?
    var networkProtocol: RemotePortProtocol?
    var name: String?
    var state: String?

    func flush() {
      defer {
        networkProtocol = nil
        name = nil
        state = nil
      }
      guard let networkProtocol, let name, let endpoint = endpoint(name) else { return }
      // TCP 只收 LISTEN；UDP 没有状态字段，全部当作监听。
      if networkProtocol == .tcp, state != "LISTEN" { return }
      ports.append(
        RemoteListeningPort(
          networkProtocol: networkProtocol,
          address: endpoint.address,
          port: endpoint.port,
          pid: pid,
          processName: command
        )
      )
    }

    for line in lines {
      guard let tag = line.first else { continue }
      let value = String(line.dropFirst())
      switch tag {
      case "p":
        flush()
        pid = Int32(value)
        command = nil
      case "c":
        command = value
      case "f":
        flush()
      case "P":
        if networkProtocol != nil { flush() }
        networkProtocol = protocolValue(value)
      case "n":
        if name != nil { flush() }
        name = value
      case "T":
        if value.hasPrefix("ST=") { state = String(value.dropFirst("ST=".count)) }
      default:
        continue
      }
    }
    flush()
    return ports
  }

  // MARK: - 通用

  private static func protocolValue(_ text: String) -> RemotePortProtocol? {
    let lowered = text.lowercased()
    if lowered.hasPrefix("tcp") { return .tcp }
    if lowered.hasPrefix("udp") { return .udp }
    return nil
  }

  /// 拆 `address:port`：按最后一个 `:` 切，IPv6 的方括号去掉，端口非数字则丢弃该行。
  private static func endpoint(_ text: String) -> (address: String, port: Int)? {
    guard let separator = text.lastIndex(of: ":") else { return nil }
    guard let port = Int(text[text.index(after: separator)...]) else { return nil }
    var address = String(text[text.startIndex..<separator])
    if address.hasPrefix("["), address.hasSuffix("]") {
      address = String(address.dropFirst().dropLast())
    }
    if address.isEmpty { address = "*" }
    return (address, port)
  }

  /// 取前 `count` 个空白分隔字段，其余原样返回；用于 `df` 的挂载点与 `ps` 的 args（都可能含空格）。
  private static func leadingFields(_ line: String, count: Int) -> (fields: [String], rest: String)? {
    var fields: [String] = []
    var index = line.startIndex
    while fields.count < count {
      while index < line.endIndex, line[index] == " " || line[index] == "\t" {
        index = line.index(after: index)
      }
      guard index < line.endIndex else { return nil }
      let start = index
      while index < line.endIndex, line[index] != " ", line[index] != "\t" {
        index = line.index(after: index)
      }
      fields.append(String(line[start..<index]))
    }
    while index < line.endIndex, line[index] == " " || line[index] == "\t" {
      index = line.index(after: index)
    }
    return (fields, String(line[index...]))
  }
}
