# 诊断与反馈

## 业务背景

Aster 是本机优先的终端工作区。排查应用自身启动、PTY、持久化与集成问题需要运行证据，但终端正文、命令和工作目录天然敏感，不能因诊断而进入反馈包或自动上传。

## 领域概念

- **DiagnosticsCenter**：Aster target 内唯一的诊断 module，负责 Unified Logging、本地 JSONL、轮转和反馈归档。
- **诊断事件**：稳定事件码、分类、有限状态属性和可选错误摘要；错误摘要只有类型、domain 与 code。
- **终端生命周期事件**：Shell 启动、结束、重启及过期回调的结构化记录，只包含 Session ID、代次、退出类型和状态码等安全字段。
- **反馈包**：用户主动生成的 ZIP，仅含 Aster 创建的日志、`manifest.json` 和可选问题描述。

## 核心规则

1. 本地目录是 `~/Library/Logs/Aster`，目录权限 `0700`、日志和归档文件权限 `0600`。
2. 单个 JSONL 文件最多 5 MiB；日志总计最多 20 MiB，或早于 7 天时优先删除最旧文件。
3. 禁止记录终端输入输出、命令、路径、URL、环境变量、剪贴板、配置、账号/主机信息、令牌、secret 及系统 `.ips`。
4. Debug 记录源码位置和 debug 事件；Release 不写这些字段。磁盘失败只降级为 Unified Logging，不能阻止应用启动。
5. 反馈包绝不自动生成或上传；用户只能从“帮助 → 反馈问题…”保存或经系统分享面板发送。
6. 每条记录自动携带 `process` 属性（进程名），新旧构建并存或辅助进程场景可按来源过滤。
7. 测试环境（XCTest / swift-testing）不落盘 JSONL，只写 Unified Logging；显式注入 `rootDirectory` 的测试自查除外。测试噪声混入本地日志曾导致现场排障两轮误判（见 `engineering-pitfalls.md`）。
6. Shell 的正常退出、非零退出、信号终止和 PTY I/O 失败必须使用稳定状态字段记录；不得附带命令、终端正文、启动路径或环境变量。

## 业务流程

```mermaid
flowchart LR
  A[应用边界发生事件] --> B[DiagnosticsCenter.record]
  B --> C[Unified Logging]
  B --> D[受限 JSONL 会话日志]
  D --> E{用户主动反馈}
  E -->|保存或分享| F[刷新并验证 Aster 日志]
  F --> G[manifest 和可选说明]
  G --> H[ZIP]
  H --> I[系统分享面板或用户选择的位置]
```

## 关键实现

- `DiagnosticsCenter.start()` 在 `AsterApplication.main()` 中、创建 AppKit 窗口前调用；`finish(reason:)` 在应用终止时刷新。
- 调用方只能提供稳定事件码与非敏感属性。属性键包含 `path`、`command`、`content`、`prompt`、`clipboard`、`environment`、`token`、`secret`、`url`、`host` 或 `user` 时会被丢弃。
- `TerminalSession` 记录 `terminal.process_started`、`terminal.process_terminated`、`terminal.process_restart_requested` 和 `terminal.stale_termination_ignored`。`waitpid` 原始状态先归一化成退出码、信号或 I/O 失败，日志只写安全属性。
- `makeFeedbackArchive(note:)` 只复制以 `aster-` 命名的普通 JSONL 文件；符号链接、特殊文件和超限文件都会拒绝。压缩使用固定 `/usr/bin/ditto` argv，不经 Shell。
- 异常退出沿用 `AppModel` 已有的会话恢复标记记录恢复决策。该能力不等价于原生 crash stack capture。

## 失败语义

- 日志目录不可用、写入失败或清理失败：继续运行，系统日志记录内部失败；反馈页显示可操作的生成错误。
- Shell 结束：先写入结构化生命周期事件，再显示可恢复状态；日志写入失败不能阻止用户在原 Pane 重启 Shell。
- 归档失败：不创建半成品 ZIP，原日志保持不变。
- 用户取消保存或关闭分享面板：不视为“已发送”，也不触发网络请求。

## 测试与验收

- `DiagnosticsCenterTests` 使用真实 PTY 验证异常退出事件会落盘，同时命令和工作目录不会进入日志；其它用例验证敏感属性和错误描述不会写入日志，且 ZIP 只含 manifest、用户说明和诊断文件。
- 执行 `swift build`、`swift test --no-parallel`、`swift build -c release`、`./scripts/build-app.sh` 与 `codesign --verify --deep --strict dist/Aster.app`。
- 手工检查帮助菜单、反馈面板、Finder 日志目录和生成 ZIP 的内容；不得通过终端内容或用户配置验证。
