import Foundation
import Testing

@testable import AsterCore

/// 远端主机监控解析：Linux 全量、macOS 尽力而为、三种端口格式、磁盘过滤排序与 CPU 差分。

// MARK: - 夹具

private let linuxMonitorOutput = """
  ASTER_MON_V1
  [host]
  ubuntu
  Linux 6.8.0-45-generic x86_64
  [end]
  [uptime]
  123456.78 987654.32
  [end]
  [load]
  0.52 0.58 0.59 1/234 5678
  [end]
  [cpu]
  cpu  10000 200 3000 90000 500 0 100 0 0 0
  cpus=8
  [end]
  [mem]
  MemTotal:       16384000 kB
  MemFree:         1024000 kB
  MemAvailable:    8192000 kB
  Buffers:          102400 kB
  Cached:          4096000 kB
  SwapTotal:       2048000 kB
  SwapFree:        1048576 kB
  [end]
  [disk]
  /dev/sda1      103080888  8000000  90000000   9% /
  tmpfs            8192000        0   8192000   0% /dev/shm
  /dev/loop0         63488    63488         0 100% /snap/core20/2264
  /dev/sdb1      206161776  1000000 194000000   1% /mnt/big data
  [end]
  [ps-cpu]
   1234  82.0  1.5 123456 root     /usr/bin/python3 -m http.server 8080
    567   3.2  0.4  40960 mike     /usr/lib/systemd/systemd --user
  [end]
  [ps-mem]
    567   3.2  9.4 940960 mike     /usr/lib/systemd/systemd --user
  [end]
  [ports-ss]
  tcp   LISTEN 0      4096       0.0.0.0:22    0.0.0.0:*    users:(("sshd",pid=900,fd=3))
  tcp   LISTEN 0      4096          [::]:22       [::]:*
  udp   UNCONN 0      0          0.0.0.0:68    0.0.0.0:*    users:(("dhclient",pid=657,fd=6))
  [end]
  [cwd]
  /var/log
  [end]
  """

private func parse(_ text: String, now: Date = Date()) throws -> RemoteHostMonitorSnapshot {
  try RemoteHostMonitorParser.parse(Data(text.utf8), now: now)
}

// MARK: - argv

@Test func remoteHostMonitorScriptAppendsPidOnlyWhenPresent() {
  let withoutPid = RemoteHostMonitorScript.command(pid: nil)
  #expect(withoutPid == ["/bin/sh", "-c", RemoteHostMonitorScript.script, "sh"])
  let withPid = RemoteHostMonitorScript.command(pid: 4321)
  #expect(withPid.count == 5)
  #expect(withPid[4] == "4321")
  // 远端不许 sleep：每次 tick 都是一次短命 ssh exec。
  #expect(!RemoteHostMonitorScript.script.contains("sleep"))
}

// MARK: - Linux 全量

@Test func remoteHostMonitorParsesLinuxSnapshot() throws {
  let snapshot = try parse(linuxMonitorOutput)

  #expect(snapshot.host == "ubuntu")
  #expect(snapshot.uname == "Linux 6.8.0-45-generic x86_64")
  #expect(snapshot.uptimeSeconds == 123_456.78)
  #expect(snapshot.load == RemoteLoadAverage(one: 0.52, five: 0.58, fifteen: 0.59))
  #expect(snapshot.cwd == "/var/log")
  #expect(snapshot.unavailableSections.isEmpty)

  let cpu = try #require(snapshot.cpuSample)
  #expect(cpu.totalTicks == 103_800)
  // idle 口径含 iowait。
  #expect(cpu.idleTicks == 90_500)
  #expect(cpu.cpuCount == 8)

  let memory = try #require(snapshot.memory)
  #expect(memory.totalKiB == 16_384_000)
  #expect(memory.availableKiB == 8_192_000)
  #expect(memory.usedKiB == 8_192_000)
  let swap = try #require(snapshot.swap)
  #expect(swap.totalKiB == 2_048_000)
  #expect(swap.usedKiB == 999_424)
}

@Test func remoteHostMonitorFiltersAndSortsDisks() throws {
  let snapshot = try parse(linuxMonitorOutput)
  // tmpfs 与 /snap/ 挂载没有参考价值；剩下的按容量降序。
  #expect(snapshot.disks.map(\.mount) == ["/mnt/big data", "/"])
  #expect(snapshot.disks[0].sizeKiB == 206_161_776)
  #expect(snapshot.disks[0].usedKiB == 1_000_000)
  #expect(snapshot.disks[0].availableKiB == 194_000_000)
  #expect(snapshot.disks[1].filesystem == "/dev/sda1")
}

@Test func remoteHostMonitorParsesProcessesWithSpacedArguments() throws {
  let snapshot = try parse(linuxMonitorOutput)
  #expect(snapshot.topByCPU.count == 2)
  let first = snapshot.topByCPU[0]
  #expect(first.pid == 1234)
  #expect(first.cpuPercent == 82.0)
  #expect(first.memoryPercent == 1.5)
  #expect(first.residentKiB == 123_456)
  #expect(first.user == "root")
  // 进程名取 args 首 token 的 basename，完整命令行原样保留。
  #expect(first.command == "python3")
  #expect(first.arguments == "/usr/bin/python3 -m http.server 8080")
  #expect(snapshot.topByMemory.count == 1)
  #expect(snapshot.topByMemory[0].residentKiB == 940_960)
}

@Test func remoteHostMonitorParsesSSPorts() throws {
  let snapshot = try parse(linuxMonitorOutput)
  #expect(snapshot.listeningPorts.count == 3)
  let first = snapshot.listeningPorts[0]
  #expect(first.networkProtocol == .tcp)
  #expect(first.address == "0.0.0.0")
  #expect(first.port == 22)
  #expect(first.pid == 900)
  #expect(first.processName == "sshd")
  // 非 root 看不到他人进程，Process 列整体缺失时只留地址。
  let second = snapshot.listeningPorts[1]
  #expect(second.address == "::")
  #expect(second.pid == nil)
  #expect(second.processName == nil)
  let third = snapshot.listeningPorts[2]
  #expect(third.networkProtocol == .udp)
  #expect(third.port == 68)
  #expect(third.processName == "dhclient")
}

@Test func remoteHostMonitorParsesRealLinuxQuirks() throws {
  // 取自真实 Linux（OrbStack）输出：ss 的地址带 `%eth0` 区域号，df 里混着伪文件系统。
  let text = """
    ASTER_MON_V1
    [disk]
    /dev/vdb1        143130624  81542272  61588352      57% /
    none                   492         4       488       1% /dev
    orbstack           8211508       552   8210956       1% /opt/orbstack-guest
    tmpfs             13138416         4  13138412       1% /tmp
    [end]
    [ports-ss]
    udp UNCONN 0      0      192.168.139.114%eth0:68 0.0.0.0:*
    [end]
    """
  let snapshot = try parse(text)
  #expect(snapshot.disks.map(\.mount) == ["/", "/opt/orbstack-guest", "/dev"])
  #expect(snapshot.listeningPorts.count == 1)
  #expect(snapshot.listeningPorts[0].address == "192.168.139.114%eth0")
  #expect(snapshot.listeningPorts[0].port == 68)
}

// MARK: - 其它端口格式

@Test func remoteHostMonitorParsesNetstatPorts() throws {
  let text = """
    ASTER_MON_V1
    [ports-netstat]
    tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      900/sshd
    tcp6       0      0 :::80                   :::*                    LISTEN      -
    udp        0      0 0.0.0.0:68              0.0.0.0:*                           657/dhclient
    [end]
    """
  let snapshot = try parse(text)
  #expect(snapshot.listeningPorts.count == 3)
  #expect(snapshot.listeningPorts[0].pid == 900)
  #expect(snapshot.listeningPorts[0].processName == "sshd")
  #expect(snapshot.listeningPorts[1].networkProtocol == .tcp)
  #expect(snapshot.listeningPorts[1].address == "::")
  #expect(snapshot.listeningPorts[1].port == 80)
  #expect(snapshot.listeningPorts[1].pid == nil)
  #expect(snapshot.listeningPorts[2].networkProtocol == .udp)
  #expect(snapshot.listeningPorts[2].pid == 657)
}

@Test func remoteHostMonitorParsesLsofPorts() throws {
  // 真实 lsof -F 的字段顺序：f → P → n → TST=；同一 socket 会被多个 fd 重复列出。
  let text = """
    ASTER_MON_V1
    [ports-lsof]
    p710
    crapportd
    f11
    PTCP
    n*:49173
    TST=LISTEN
    TQR=0
    f12
    PTCP
    n*:49173
    TST=LISTEN
    p719
    creplicatord
    f8
    PUDP
    n*:57597
    p720
    cidentityservicesd
    f7
    PUDP
    n*:*
    p746
    cEudic
    f25
    PTCP
    n127.0.0.1:32094
    TST=LISTEN
    [end]
    """
  let snapshot = try parse(text)
  #expect(snapshot.listeningPorts.count == 3)
  #expect(snapshot.listeningPorts[0].port == 49173)
  #expect(snapshot.listeningPorts[0].address == "*")
  #expect(snapshot.listeningPorts[0].processName == "rapportd")
  #expect(snapshot.listeningPorts[1].networkProtocol == .udp)
  #expect(snapshot.listeningPorts[1].port == 57597)
  #expect(snapshot.listeningPorts[2].address == "127.0.0.1")
  #expect(snapshot.listeningPorts[2].pid == 746)
}

@Test func remoteHostMonitorSkipsNonListeningLsofEntries() throws {
  let text = """
    ASTER_MON_V1
    [ports-lsof]
    p100
    cchrome
    f5
    PTCP
    n127.0.0.1:443
    TST=ESTABLISHED
    [end]
    """
  let snapshot = try parse(text)
  #expect(snapshot.listeningPorts.isEmpty)
}

// MARK: - macOS

@Test func remoteHostMonitorParsesDarwinSections() throws {
  let now = Date(timeIntervalSince1970: 1_789_660_000)
  let text = """
    ASTER_MON_V1
    [host]
    mac-mini
    Darwin 27.0.0 arm64
    [end]
    [boottime]
    { sec = 1789653922, usec = 101732 } Thu Sep 17 22:05:22 2026
    [end]
    [load]
    { 5.33 4.35 3.69 }
    [end]
    [mem-darwin]
    hw.memsize=51539607552
    hw.pagesize=16384
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free:                                   326761.
    Pages active:                                1163364.
    Pages inactive:                              1198800.
    Pages speculative:                              1942.
    Pages purgeable:                               41729.
    File-backed pages:                            716344.
    total = 2048.00M  used = 100.00M  free = 1948.00M  (encrypted)
    [end]
    """
  let snapshot = try parse(text, now: now)

  #expect(snapshot.host == "mac-mini")
  #expect(snapshot.uptimeSeconds == 6078)
  #expect(snapshot.load == RemoteLoadAverage(one: 5.33, five: 4.35, fifteen: 3.69))

  let memory = try #require(snapshot.memory)
  #expect(memory.totalKiB == 50_331_648)
  #expect(memory.freeKiB == 326_761 * 16)
  #expect(memory.availableKiB == (326_761 + 1_198_800 + 1_942 + 41_729) * 16)
  #expect(memory.cachedKiB == 716_344 * 16)

  let swap = try #require(snapshot.swap)
  #expect(swap.totalKiB == 2_048 * 1024)
  #expect(swap.freeKiB == 1_948 * 1024)

  // macOS 没有 /proc/stat 与 df/ps 段（脚本里另有分支），缺的段要如实登记。
  #expect(snapshot.unavailableSections.contains(RemoteHostMonitorSection.cpu))
  #expect(snapshot.unavailableSections.contains(RemoteHostMonitorSection.ports))
  #expect(!snapshot.unavailableSections.contains(RemoteHostMonitorSection.memory))
}

// MARK: - 缺段与协议错误

@Test func remoteHostMonitorRecordsMissingSections() throws {
  let snapshot = try parse("ASTER_MON_V1\n[host]\nubuntu\nLinux 6.8 x86_64\n[end]\n")
  #expect(snapshot.host == "ubuntu")
  #expect(snapshot.unavailableSections == Set(RemoteHostMonitorSection.expected).subtracting([
    RemoteHostMonitorSection.host
  ]))
  #expect(snapshot.disks.isEmpty)
  #expect(snapshot.listeningPorts.isEmpty)
  #expect(snapshot.cwd == nil)
}

@Test func remoteHostMonitorRejectsOutputWithoutHeader() {
  #expect(throws: RemoteHostMonitorError.malformed("missing header")) {
    _ = try parse("Welcome to Ubuntu\n[host]\nubuntu\n[end]\n")
  }
}

// MARK: - CPU 差分

@Test func remoteCPUUsageComputesPercentBetweenSamples() {
  let previous = RemoteCPUStatSample(idleTicks: 90_500, totalTicks: 103_800, cpuCount: 8)
  let current = RemoteCPUStatSample(idleTicks: 90_600, totalTicks: 104_800, cpuCount: 8)
  let usage = RemoteCPUUsage.compute(previous: previous, current: current)
  #expect(usage != nil)
  #expect(abs((usage ?? 0) - 90.0) < 0.001)
}

@Test func remoteCPUUsageReturnsNilForUnusableSamples() {
  let base = RemoteCPUStatSample(idleTicks: 100, totalTicks: 1000, cpuCount: 4)
  // 总量没推进：首个 tick 之后重复采样，UI 显示「—」而不是假的 0%。
  #expect(RemoteCPUUsage.compute(previous: base, current: base) == nil)
  // 远端重启后计数器归零，样本倒退。
  let rebooted = RemoteCPUStatSample(idleTicks: 10, totalTicks: 20, cpuCount: 4)
  #expect(RemoteCPUUsage.compute(previous: base, current: rebooted) == nil)
  // idle 增量大于总增量，数据不自洽。
  let skewed = RemoteCPUStatSample(idleTicks: 900, totalTicks: 1100, cpuCount: 4)
  #expect(RemoteCPUUsage.compute(previous: base, current: skewed) == nil)
}

// MARK: - 真实脚本（本机 macOS 路径）

@Test func remoteHostMonitorScriptRunsAgainstRealShell() throws {
  let argv = RemoteHostMonitorScript.command(pid: nil)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: argv[0])
  process.arguments = Array(argv.dropFirst())
  let pipe = Pipe()
  process.standardOutput = pipe
  try process.run()
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  #expect(output.count <= RemoteHostMonitorScript.outputByteLimit)
  let snapshot = try RemoteHostMonitorParser.parse(output)
  #expect(snapshot.host?.isEmpty == false)
  #expect(snapshot.uname?.isEmpty == false)
  #expect(snapshot.load != nil)
  #expect(!snapshot.disks.isEmpty)
  #expect(!snapshot.topByCPU.isEmpty)
}

@Test("同一设备的多个 bind mount 只保留一条最短挂载点")
func monitorParserDeduplicatesBindMounts() throws {
  let output = """
    ASTER_MON_V1
    [disk]
    /dev/vdb1 151584000 87552000 64032000 58% /
    /dev/vdb1 151584000 87552000 64032000 58% /opt/orbstack-guest/data
    /dev/vdb1 151584000 87552000 64032000 58% /mnt/machines/aster-arm64
    mac 972000000 898000000 74000000 93% /mnt/mac
    [end]
    """
  let snapshot = try RemoteHostMonitorParser.parse(Data(output.utf8))
  #expect(snapshot.disks.count == 2)
  #expect(snapshot.disks.map(\.filesystem) == ["mac", "/dev/vdb1"])
  #expect(snapshot.disks.first { $0.filesystem == "/dev/vdb1" }?.mount == "/")
}
