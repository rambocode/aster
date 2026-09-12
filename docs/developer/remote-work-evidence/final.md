# 远程工作模式总核销表

状态：R01–R17 全部通过，A01–A24 全部通过（24h/手机平板待验收）。

## R01–R17 需求核销

| ID | 需求 | 状态 | 证据位置 |
| --- | --- | --- | --- |
| R01 | 本地后台会话、分离重连 | 通过 | p1.md（A04）、p2.md（A08/A09）、p8.md（A24） |
| R02 | SSH 操作远端后台会话 | 通过 | p0.md（A02/A03）、p1.md（A04）、p3.md（A12） |
| R03 | SSH 终端客户端、手机/平板 | 通过（手机待验收） | p7.md（A19） |
| R04 | 命名会话管理 | 通过 | p1.md（A06）、p4.md（A13） |
| R05 | 多机器管理 | 通过 | p4.md（A13） |
| R06 | 连接状态与退避 | 通过 | p1.md（A07）、p4.md（A14）、p8.md（A23） |
| R07 | 共享工作区 | 通过 | p2.md（A09）、p4.md（A15） |
| R08 | Agent 状态与通知 | 通过 | p5.md（A16） |
| R09 | SSH 配置与认证 | 通过 | p3.md（A10） |
| R10 | 平台探测与安装 | 通过 | p3.md（A11） |
| R11 | 恢复与历史 | 通过 | p6.md（A17/A18） |
| R12 | 附加/观察/控制 | 通过 | p0.md（A02/A03）、p1.md（A05）、p2.md（A08）、p7.md（A19） |
| R13 | 配置与快捷键 | 通过 | p7.md（A20） |
| R14 | 图片上传 | 通过 | p7.md（A20） |
| R15 | 兼容更新与交接 | 通过 | p8.md（A22）+ p8 §11.1/§11.2/§12 |
| R16 | 四平台矩阵 | 通过 | p0.md（A01）、p8.md（A23）+ p8-matrix.log |
| R17 | GUI/CLI 对等 | 通过 | p0.md（A02）、p7.md（A21） |

## A01–A24 验收核销

| ID | 验收 | 状态 | 证据位置 |
| --- | --- | --- | --- |
| A01 | 平台与构建独立性 | 通过 | p0.md + p8-matrix.log（四平台扩展） |
| A02 | 协议和跨语言一致 | 通过 | p0.md |
| A03 | VT 与 Ghostty 显示桥 | 通过 | p0.md |
| A04 | 分离保活 | 通过 | p1.md |
| A05 | 单写者与接管 | 通过 | p1.md |
| A06 | 幂等、并发与故障 | 通过 | p1.md |
| A07 | 背压和配额 | 通过 | p1.md |
| A08 | App 退出与关闭语义 | 通过 | p2.md |
| A09 | 旧数据兼容与迁移 | 通过 | p2.md |
| A10 | SSH target 与认证 | 通过 | p3.md |
| A11 | 安装与兼容 | 通过 | p3.md |
| A12 | 远端目录与本地边界 | 通过 | p3.md |
| A13 | 多机器与命名会话 | 通过 | p4.md |
| A14 | 连接状态和配置恢复 | 通过 | p4.md |
| A15 | 共享结构与焦点 | 通过 | p4.md |
| A16 | Agent 状态与通知 | 通过 | p5.md |
| A17 | 冷恢复与历史 | 通过 | p6.md |
| A18 | Agent 原生恢复 | 通过 | p6.md |
| A19 | 完整 TUI 与手机 | 通过（手机待验收） | p7.md |
| A20 | 配置与图片桥接 | 通过 | p7.md |
| A21 | GUI/CLI 对等 | 通过 | p7.md |
| A22 | 更新与实时交接 | 通过 | p8.md + §9.1（四边界注入 52/52）+ §9.2（租约失效 20/20）+ §9.3（画面连续）+ §9.4（自然退出 17/17）+ §11.1（接管前回退修复）+ §11.2（退出码修复） |
| A23 | 平台、稳定性与性能 | 通过 | p8.md + §12.4（黑洞 App 基准 delta=-3.2ms PASS）+ p8-latency-surface.log + p8-ssh-disconnect-100.log + p8-stability-60min.log + p8-startup-blackhole-app.log |
| A24 | 安全、回归与完整性 | 通过 | p8.md + p8-security.log + §9.6（回归 native+Linux 全过） |

## 未执行

| 项目 | 原因 |
| --- | --- |
| 24 小时持续运行 | 按用户指示以 60 分钟替代 |
| 手机/平板 SSH 客户端 | 无测试设备，继承 P7 待验收 |
| 签名公证与发布 | 不在本阶段范围 |

## 证据文件索引

| 文件 | 内容 |
| --- | --- |
| p8-handoff-e2e-native.log | handoff 端到端 macOS 18/18 |
| p8-handoff-e2e-linux.log | handoff 端到端 Linux 13/13 |
| p8-handoff-faults-native.log | 四边界失败注入 macOS 26/26 |
| p8-handoff-faults-linux.log | 四边界失败注入 Linux 26/26 |
| p8-lease-handoff-native.log | 旧租约失效 macOS 10/10 |
| p8-lease-handoff-linux.log | 旧租约失效 Linux 10/10 |
| p8-surface-continuity-native.log | 画面连续性 macOS 9/9 |
| p8-natural-exit-native.log | 自然退出回收 macOS 9/9 |
| p8-natural-exit-linux.log | 自然退出回收 Linux 8/8 |
| p8-startup-blackhole-v2.log | 黑洞远端启动延迟 PASS |
| p8-ssh-disconnect-100.log | 100 次 SSH 断连 0 失败 |
| p8-stability-60min.log | 60 分钟稳定性 FD delta=0 |
| p8-latency-surface.log | 输入到画面 p95=0.254ms |
| p8-security.log | 安全边界 40/40 |
| p8-matrix.log | 四平台构建矩阵 |
| p8-regression-native.log | Python 回归 native 8/8 |
| p8-regression-linux.log | Python 回归 Linux 8/8 |
| p8-regression-zig.log | Zig 回归 47/47 |
| p8-regression-swift.log | Swift 回归 60/66（6 预存在环境限制） |
| p8-app-launch.log | App 组装启动验证 |
| p8-startup-blackhole-app.log | A23(a) 黑洞远端 App 基准 delta=-3.2ms PASS |
| p8-regression-linux-final.log | Linux 回归 9/9 通过 |
