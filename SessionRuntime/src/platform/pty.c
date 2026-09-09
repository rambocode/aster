#include "session_pty.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

static int64_t milliseconds(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void abort_child(pid_t child, int master) {
  // This PID is an unreaped child owned by the caller, so it cannot be reused.
  (void)kill(-child, SIGKILL);
  (void)kill(child, SIGKILL);
  if (master >= 0) close(master);
  while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

pid_t session_spawn_pty(const char *cwd, const char *executable,
                       char *const argv[], char *const envp[], int *master,
                       int *startup_stage, unsigned short rows,
                       unsigned short columns) {
  *master = -1;
  *startup_stage = 0;
  if (!rows || !columns) { errno = EINVAL; return -1; }
  int report_pipe[2];
  if (pipe(report_pipe) != 0) return -1;
  if (fcntl(report_pipe[0], F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(report_pipe[1], F_SETFD, FD_CLOEXEC) < 0) {
    int saved = errno;
    close(report_pipe[0]); close(report_pipe[1]);
    errno = saved; return -1;
  }
  struct winsize size = {.ws_row = rows, .ws_col = columns};
  pid_t child = forkpty(master, NULL, NULL, &size);
  if (child < 0) {
    int saved = errno;
    close(report_pipe[0]); close(report_pipe[1]);
    errno = saved; return -1;
  }
  if (child == 0) {
    // All strings are prepared by the parent. Only async-signal-safe calls
    // occur between fork and exec; the error report is smaller than PIPE_BUF.
    close(report_pipe[0]);
    int report[2];
    if (chdir(cwd) != 0) {
      report[0] = 1; report[1] = errno;
    } else {
      execve(executable, argv, envp);
      report[0] = 2; report[1] = errno;
    }
    ssize_t sent;
    do { sent = write(report_pipe[1], report, sizeof(report)); }
    while (sent < 0 && errno == EINTR);
    _exit(127);
  }
  close(report_pipe[1]);
  int report[2] = {0, 0};
  size_t received = 0;
  int failure = 0;
  int64_t started = milliseconds();
  if (started < 0) failure = errno;
  while (!failure) {
    int64_t now = milliseconds();
    if (now < 0) { failure = errno; break; }
    int64_t remaining = 5000 - (now - started);
    if (remaining <= 0) { failure = ETIMEDOUT; break; }
    struct pollfd pfd = {.fd = report_pipe[0], .events = POLLIN};
    int ready = poll(&pfd, 1, (int)remaining);
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) { failure = ready == 0 ? ETIMEDOUT : errno; break; }
    ssize_t count = read(report_pipe[0], (char *)report + received,
                         sizeof(report) - received);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) { failure = errno; break; }
    if (count == 0) {
      if (received != 0) failure = EPROTO;
      break;
    }
    received += (size_t)count;
    if (received == sizeof(report)) {
      *startup_stage = report[0]; failure = report[1]; break;
    }
  }
  close(report_pipe[0]);
  if (!failure) {
    int flags = fcntl(*master, F_GETFL);
    if (flags < 0 || fcntl(*master, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(*master, F_SETFD, FD_CLOEXEC) < 0) failure = errno;
  }
  if (failure) {
    abort_child(child, *master); *master = -1;
    errno = failure; return -1;
  }
  return child;
}

#include <sys/socket.h>
int session_same_user(int fd) {
#ifdef __APPLE__
  uid_t uid;
  gid_t gid;
  return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid();
#else
  struct { pid_t pid; uid_t uid; gid_t gid; } credentials;
  socklen_t length = sizeof(credentials);
  return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 &&
         length == sizeof(credentials) && credentials.uid == geteuid();
#endif
}
