#ifndef ASTER_PTY_H
#define ASTER_PTY_H

#include <stddef.h>
#include <sys/types.h>

/// 创建 PTY 并在子进程中直接执行目标程序。
///
/// 调用方必须在调用前准备好 argv 与 envp；fork 后的子分支只调用
/// async-signal-safe POSIX 函数，绝不回到 Swift 运行时。成功时返回子进程 PID
/// 并写入 master_fd，失败返回 -1。
pid_t aster_spawn_pty(const char *working_directory, const char *executable,
                      char *const argv[], char *const envp[], int *master_fd,
                      int *startup_stage, int *startup_error,
                      unsigned short rows, unsigned short columns);

/// 子进程启动阶段。通过 close-on-exec 错误管道返回，避免把 shell 自己的退出码
/// 126/127 错判为启动失败。
enum {
  ASTER_STARTUP_STAGE_NONE = 0,
  ASTER_STARTUP_STAGE_CHDIR = 1,
  ASTER_STARTUP_STAGE_EXEC = 2,
};

/// 获取目标进程当前工作目录。成功返回 0，失败返回 -1 并保留 errno。
int aster_process_working_directory(pid_t process_id, char *buffer,
                                    size_t buffer_size);

#endif
