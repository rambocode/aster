#include "AsterPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

pid_t aster_spawn_pty(const char *working_directory, const char *executable,
                      char *const argv[], char *const envp[], int *master_fd,
                      int *startup_stage, int *startup_error,
                      unsigned short rows, unsigned short columns) {
  int error_pipe[2];
  if (pipe(error_pipe) != 0) {
    return -1;
  }
  if (fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) == -1) {
    int saved_error = errno;
    close(error_pipe[0]);
    close(error_pipe[1]);
    errno = saved_error;
    return -1;
  }

  struct winsize size = {
      .ws_row = rows,
      .ws_col = columns,
      .ws_xpixel = 0,
      .ws_ypixel = 0,
  };
  pid_t process_id = forkpty(master_fd, NULL, NULL, &size);
  if (process_id == -1) {
    int saved_error = errno;
    close(error_pipe[0]);
    close(error_pipe[1]);
    errno = saved_error;
    return -1;
  }
  if (process_id > 0) {
    close(error_pipe[1]);
    int status = 0;
    struct {
      int stage;
      int error;
    } report = {0, 0};
    ssize_t received;
    do {
      received = read(error_pipe[0], &report, sizeof(report));
    } while (received == -1 && errno == EINTR);
    close(error_pipe[0]);

    if (received == (ssize_t)sizeof(report)) {
      while (waitpid(process_id, &status, 0) == -1 && errno == EINTR) {
      }
      close(*master_fd);
      *master_fd = -1;
      *startup_stage = report.stage;
      *startup_error = report.error;
      errno = report.error;
      return -1;
    }
    if (received != 0) {
      int saved_error = received == -1 ? errno : EPROTO;
      close(*master_fd);
      kill(process_id, SIGHUP);
      while (waitpid(process_id, &status, 0) == -1 && errno == EINTR) {
      }
      *master_fd = -1;
      errno = saved_error;
      return -1;
    }

    int flags = fcntl(*master_fd, F_GETFL);
    if (flags == -1 || fcntl(*master_fd, F_SETFL, flags | O_NONBLOCK) == -1) {
      int saved_error = errno;
      close(*master_fd);
      kill(process_id, SIGHUP);
      while (waitpid(process_id, &status, 0) == -1 && errno == EINTR) {
      }
      *master_fd = -1;
      errno = saved_error;
      return -1;
    }
    *startup_stage = ASTER_STARTUP_STAGE_NONE;
    *startup_error = 0;
    return process_id;
  }

  // fork 后只允许 async-signal-safe 调用。所有字符串和数组均由父进程预先准备。
  close(error_pipe[0]);
  if (chdir(working_directory) != 0) {
    int report[2] = {ASTER_STARTUP_STAGE_CHDIR, errno};
    (void)write(error_pipe[1], report, sizeof(report));
    _exit(126);
  }
  execve(executable, argv, envp);
  int report[2] = {ASTER_STARTUP_STAGE_EXEC, errno};
  (void)write(error_pipe[1], report, sizeof(report));
  _exit(127);
}

int aster_process_working_directory(pid_t process_id, char *buffer,
                                    size_t buffer_size) {
  if (buffer == NULL || buffer_size == 0) {
    errno = EINVAL;
    return -1;
  }

  struct proc_vnodepathinfo path_info;
  int bytes = proc_pidinfo(process_id, PROC_PIDVNODEPATHINFO, 0, &path_info,
                           sizeof(path_info));
  if (bytes != sizeof(path_info)) {
    return -1;
  }

  size_t length = strnlen(path_info.pvi_cdir.vip_path, MAXPATHLEN);
  if (length + 1 > buffer_size) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(buffer, path_info.pvi_cdir.vip_path, length);
  buffer[length] = '\0';
  return 0;
}
