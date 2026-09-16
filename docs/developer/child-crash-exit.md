# 终端子进程崩溃导致 Aster 无声退出

## 现象

- Aster 突然整个退出，没有崩溃报告（`~/Library/Logs/DiagnosticReports` 里没有 Aster 的 `.ips`）。
- `launchd` 日志记录为 `exited due to exit(1)`，不是信号。
- 因为没走 `commitTermination`，`aster.session.running.v1` 仍为 true，下次启动被记成一次异常退出；
  连续三次后 `WorkflowSessionRecoveryPlanner` 判定 crash-loop，走 `startFreshAfterCrashLoop`，
  上次工作区不再恢复（这是既定策略，不是恢复失败）。
- 每次退出的同一瞬间，都有一个终端里启动的进程因 `EXC_BAD_ACCESS`（SIGSEGV）崩溃，
  `.ips` 里的 `responsiblePid` 就是 Aster。2026-09-16 的三次分别是 xctest、xctest、ffmpeg。

## 机制

1. GhosttyKit 静态链接了 Sentry-native（Breakpad 后端）。`ghostty_init` 会启动它，Breakpad 用
   `task_set_exception_ports` 给 Aster 进程装 task 级 Mach 异常端口
   （mask `0x4e` = BAD_ACCESS | BAD_INSTRUCTION | ARITHMETIC | BREAKPOINT，行为 `EXCEPTION_DEFAULT`）。
2. task 异常端口会被 fork/exec 出来的所有子孙进程继承。终端里跑的 shell、测试、ffmpeg 等
   一旦触发这些异常，内核先把异常消息发给 Aster 里的 Breakpad 处理线程。
3. Breakpad 用系统 `exc_server` 解析消息，`exc_server` 通过 flat namespace 动态查找 C 回调
   `catch_exception_raise`（Breakpad 自己定义，外部任务的异常直接回 `KERN_FAILURE`，让内核继续
   交给 ReportCrash）。
4. `swift build -c release` 会 dead-strip 掉这个没有静态引用的符号，`dlsym` 也找不到。
   `exc_server` 分发失败返回 FALSE，Breakpad 的 `WaitForMessage` 执行 `exit(1)`。
   debug 构建符号仍导出，所以开发时复现不出来。

验证方法：在 Aster 终端里跑下面的探针，能看到 mask `0x4e` 对应的端口非空；由 `launchctl submit`
启动的对照进程里该端口为 0。

```c
#include <mach/mach.h>
#include <stdio.h>
int main(void){
  exception_mask_t m[EXC_TYPES_COUNT]; mach_msg_type_number_t n=EXC_TYPES_COUNT;
  mach_port_t p[EXC_TYPES_COUNT]; exception_behavior_t b[EXC_TYPES_COUNT]; thread_state_flavor_t f[EXC_TYPES_COUNT];
  task_get_exception_ports(mach_task_self(), EXC_MASK_ALL, m,&n,p,b,f);
  for(unsigned i=0;i<n;i++) printf("mask=0x%x port=%u behavior=0x%x\n",m[i],p[i],b[i]);
}
```

## 复现

用 `Vendor/GhosttyKit.xcframework/macos-arm64/libghostty-internal-fat.a` 里同一份 sentry/breakpad：
父进程 `sentry_init`（自定义空 transport），fork+exec 一个会写非法地址的子进程。

- 默认链接（`catch_exception_raise` 导出）：子进程 SIGSEGV，父进程继续运行。
- 加 `-Wl,-exported_symbols_list,/dev/null`（等价于 release Aster 的状态）：子进程一崩，父进程
  立刻以退出码 1 结束，没有任何输出。

务必用 `launchctl submit` 在 Aster 进程树之外运行复现程序，否则崩溃的子进程会把当前 Aster 一起带走。

## 修复

`Package.swift` 的 Aster target 增加链接参数：

```
-Xlinker -exported_symbol -Xlinker _catch_exception_raise
```

显式导出使符号既不被 dead-strip，又能被 `exc_server` 查到。验证：

```sh
swift build -c release --product Aster
dyld_info -exports .build/release/Aster | grep catch_exception_raise
```

## 可选后续

- 在 libghostty 的 fork 子进程路径（`Command.zig` 的 pre-exec 钩子）里用
  `task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_RESOURCE, MACH_PORT_NULL, ...)`
  清掉继承的端口，让子进程崩溃完全不经过 Aster。需要 ghostty 补丁并重建 GhosttyKit。
- 或者以 `-Dsentry=false` 重建 GhosttyKit，彻底不装 Breakpad。Aster 本身不消费这些崩溃转储。
